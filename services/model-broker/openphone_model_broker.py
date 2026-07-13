#!/usr/bin/env python3
"""Small dependency-free OpenPhone model broker.

This broker intentionally avoids logging request bodies because screenshots,
audio, and text prompts can contain private user data.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import http.server
import json
import os
import secrets
import threading
import time
import urllib.error
import urllib.request
from collections import defaultdict, deque
from dataclasses import dataclass
from typing import Deque


OPENAI_RESPONSES_URL = "https://api.openai.com/v1/responses"
OPENAI_TRANSCRIPTIONS_URL = "https://api.openai.com/v1/audio/transcriptions"


@dataclass(frozen=True)
class BrokerConfig:
    api_key: str
    session_tokens: frozenset[str]
    admin_tokens: frozenset[str]
    token_secret: bytes | None
    allowed_token_subjects: frozenset[str]
    device_attestation_secrets: dict[str, bytes]
    device_attestation_max_skew_seconds: int
    allowed_response_models: frozenset[str]
    responses_url: str
    transcriptions_url: str
    audit_log_path: str | None
    max_body_bytes: int
    max_bytes_per_minute: int
    max_images_per_request: int
    require_openphone_metadata: bool
    reject_sensitive_screen: bool
    provider_max_retries: int
    provider_retry_backoff_seconds: float
    rate_limit_per_minute: int
    token_max_ttl_seconds: int


class RateLimiter:
    _EVICTION_INTERVAL_SECONDS = 60.0

    def __init__(self, max_events: int, window_seconds: int = 60) -> None:
        self._max_events = max_events
        self._window_seconds = window_seconds
        self._events: dict[str, Deque[float]] = defaultdict(deque)
        self._lock = threading.Lock()
        self._last_eviction = time.monotonic()

    def allow(self, key: str) -> bool:
        now = time.monotonic()
        cutoff = now - self._window_seconds
        with self._lock:
            self._maybe_evict_stale_keys(now, cutoff)
            events = self._events[key]
            while events and events[0] < cutoff:
                events.popleft()
            if len(events) >= self._max_events:
                return False
            events.append(now)
            return True

    def _maybe_evict_stale_keys(self, now: float, cutoff: float) -> None:
        """Drop keys whose newest event fell out of the window. Caller holds lock."""
        if now - self._last_eviction < self._EVICTION_INTERVAL_SECONDS:
            return
        self._last_eviction = now
        stale = [key for key, events in self._events.items() if not events or events[-1] < cutoff]
        for key in stale:
            del self._events[key]


class ByteRateLimiter:
    _EVICTION_INTERVAL_SECONDS = 60.0

    def __init__(self, max_bytes: int, window_seconds: int = 60) -> None:
        self._max_bytes = max_bytes
        self._window_seconds = window_seconds
        self._events: dict[str, Deque[tuple[float, int]]] = defaultdict(deque)
        self._lock = threading.Lock()
        self._last_eviction = time.monotonic()

    def allow(self, key: str, size: int) -> bool:
        if self._max_bytes <= 0:
            return True
        now = time.monotonic()
        cutoff = now - self._window_seconds
        with self._lock:
            self._maybe_evict_stale_keys(now, cutoff)
            events = self._events[key]
            while events and events[0][0] < cutoff:
                events.popleft()
            total = sum(event_size for _, event_size in events)
            if total + size > self._max_bytes:
                return False
            events.append((now, size))
            return True

    def _maybe_evict_stale_keys(self, now: float, cutoff: float) -> None:
        """Drop keys whose newest event fell out of the window. Caller holds lock."""
        if now - self._last_eviction < self._EVICTION_INTERVAL_SECONDS:
            return
        self._last_eviction = now
        stale = [key for key, events in self._events.items() if not events or events[-1][0] < cutoff]
        for key in stale:
            del self._events[key]


class BrokerHandler(http.server.BaseHTTPRequestHandler):
    server_version = "OpenPhoneModelBroker/0.1"

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/healthz":
            self._write_json(200, {"ok": True})
            return
        self._write_json(404, {"error": "not_found"})

    def do_POST(self) -> None:  # noqa: N802
        started_at = time.monotonic()
        endpoint = self.path.split("?", 1)[0]
        if endpoint == "/v1/session_tokens":
            self._handle_session_token_request(started_at)
            return
        if endpoint not in ("/v1/responses", "/v1/audio/transcriptions"):
            self._audit_request("not_found", None, 404, 0, started_at)
            self._write_json(404, {"error": "not_found"})
            return

        token = self._bearer_token()
        token_subject = self.server.validate_token(token)
        if token_subject is None:
            self._audit_request("unauthorized", None, 401, 0, started_at)
            self._write_json(401, {"error": "unauthorized"})
            return

        rate_key = f"{self.client_address[0]}:{token_subject}"
        if not self.server.rate_limiter.allow(rate_key):
            self._audit_request("rate_limited", token_subject, 429, 0, started_at)
            self._write_json(429, {"error": "rate_limited"})
            return

        content_length = self.headers.get("Content-Length")
        if content_length is None:
            self._audit_request("content_length_required", token_subject, 411, 0, started_at)
            self._write_json(411, {"error": "content_length_required"})
            return
        try:
            body_size = int(content_length)
        except ValueError:
            self._audit_request("invalid_content_length", token_subject, 400, 0, started_at)
            self._write_json(400, {"error": "invalid_content_length"})
            return
        if body_size > self.server.config.max_body_bytes:
            self._audit_request("body_too_large", token_subject, 413, body_size, started_at)
            self._write_json(413, {"error": "body_too_large"})
            return
        if not self.server.byte_rate_limiter.allow(rate_key, body_size):
            self._audit_request("byte_rate_limited", token_subject, 429, body_size, started_at)
            self._write_json(429, {"error": "byte_rate_limited"})
            return

        body = self.rfile.read(body_size)
        if endpoint == "/v1/responses":
            payload = self._response_payload(body)
            if payload is None:
                self._audit_request("invalid_json", token_subject, 400, body_size, started_at)
                self._write_json(400, {"error": "invalid_json"})
                return
            model = payload.get("model")
            if not isinstance(model, str) or not model:
                self._audit_request("invalid_json", token_subject, 400, body_size, started_at)
                self._write_json(400, {"error": "invalid_json"})
                return
            if not self.server.is_response_model_allowed(model):
                self._audit_request(
                    "model_not_allowed",
                    token_subject,
                    403,
                    body_size,
                    started_at,
                    model=model,
                )
                self._write_json(403, {"error": "model_not_allowed"})
                return
            privacy_error = self._responses_privacy_error(payload)
            if privacy_error is not None:
                self._audit_request(privacy_error, token_subject, 403, body_size, started_at, model=model)
                self._write_json(403, {"error": privacy_error})
                return
            self._proxy_to_openai(
                self.server.config.responses_url,
                body,
                "application/json",
                token_subject,
                endpoint,
                body_size,
                started_at,
                model,
                stream=self._wants_stream(payload),
            )
            return

        content_type = self.headers.get("Content-Type", "")
        if not content_type.startswith("multipart/form-data"):
            self._audit_request(
                "multipart_form_data_required",
                token_subject,
                415,
                body_size,
                started_at,
            )
            self._write_json(415, {"error": "multipart_form_data_required"})
            return
        self._proxy_to_openai(
            self.server.config.transcriptions_url,
            body,
            content_type,
            token_subject,
            endpoint,
            body_size,
            started_at,
            None,
        )

    def _handle_session_token_request(self, started_at: float) -> None:
        admin_subject = self.server.validate_admin_token(self._bearer_token())
        if admin_subject is None:
            self._audit_request("admin_unauthorized", None, 401, 0, started_at)
            self._write_json(401, {"error": "unauthorized"})
            return
        if self.server.config.token_secret is None:
            self._audit_request("token_issuer_disabled", admin_subject, 503, 0, started_at)
            self._write_json(503, {"error": "token_issuer_disabled"})
            return

        content_length = self.headers.get("Content-Length")
        if content_length is None:
            self._audit_request("content_length_required", admin_subject, 411, 0, started_at)
            self._write_json(411, {"error": "content_length_required"})
            return
        try:
            body_size = int(content_length)
        except ValueError:
            self._audit_request("invalid_content_length", admin_subject, 400, 0, started_at)
            self._write_json(400, {"error": "invalid_content_length"})
            return
        if body_size > 4096:
            self._audit_request("body_too_large", admin_subject, 413, body_size, started_at)
            self._write_json(413, {"error": "body_too_large"})
            return

        body = self.rfile.read(body_size)
        try:
            payload = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            self._audit_request("invalid_json", admin_subject, 400, body_size, started_at)
            self._write_json(400, {"error": "invalid_json"})
            return

        subject = payload.get("subject")
        ttl_seconds = payload.get("ttl_seconds", self.server.config.token_max_ttl_seconds)
        if not isinstance(subject, str) or not subject.strip():
            self._audit_request("invalid_subject", admin_subject, 400, body_size, started_at)
            self._write_json(400, {"error": "invalid_subject"})
            return
        subject = subject.strip()
        if not self.server.is_token_subject_allowed(subject):
            self._audit_request("subject_not_allowed", admin_subject, 403, body_size, started_at)
            self._write_json(403, {"error": "subject_not_allowed"})
            return
        attestation_result = self.server.verify_device_attestation(subject, payload)
        if attestation_result is not None:
            status = 400 if attestation_result == "attestation_invalid" else 403
            self._audit_request(attestation_result, admin_subject, status, body_size, started_at)
            self._write_json(status, {"error": attestation_result})
            return
        if not isinstance(ttl_seconds, int) or ttl_seconds <= 0:
            self._audit_request("invalid_ttl", admin_subject, 400, body_size, started_at)
            self._write_json(400, {"error": "invalid_ttl"})
            return
        ttl_seconds = min(ttl_seconds, self.server.config.token_max_ttl_seconds)
        token = mint_signed_token(self.server.config.token_secret, subject, ttl_seconds)
        expires_at = int(token.split(".", 3)[1])
        self._audit_request("token_minted", admin_subject, 200, body_size, started_at)
        self._write_json(
            200,
            {
                "token": token,
                "token_type": "Bearer",
                "subject": subject,
                "expires_at": expires_at,
                "ttl_seconds": ttl_seconds,
            },
        )

    def log_message(self, fmt: str, *args: object) -> None:
        path = self.path.split("?", 1)[0]
        line = "%s - - [%s] %s" % (
            self.client_address[0],
            self.log_date_time_string(),
            fmt % args,
        )
        print(line.replace(self.path, path))

    def _proxy_to_openai(
        self,
        url: str,
        body: bytes,
        content_type: str,
        token_subject: str,
        endpoint: str,
        body_size: int,
        started_at: float,
        model: str | None,
        stream: bool = False,
    ) -> None:
        headers = {
            "Authorization": f"Bearer {self.server.config.api_key}",
            "Content-Type": content_type,
            "OpenAI-Beta": "responses=v1",
        }
        request = urllib.request.Request(url, data=body, headers=headers, method="POST")
        attempts = 0
        while True:
            attempts += 1
            try:
                with urllib.request.urlopen(request, timeout=120) as response:
                    if stream:
                        self._stream_provider_response(
                            response,
                            token_subject,
                            body_size,
                            started_at,
                            endpoint,
                            model,
                            attempts,
                        )
                        return
                    response_body = response.read()
                    self._audit_request(
                        "proxied",
                        token_subject,
                        response.status,
                        body_size,
                        started_at,
                        endpoint,
                        model,
                        provider_attempts=attempts,
                    )
                    self.send_response(response.status)
                    self.send_header(
                        "Content-Type",
                        response.headers.get("Content-Type", "application/json"),
                    )
                    self.send_header("Cache-Control", "no-store")
                    self.send_header("Content-Length", str(len(response_body)))
                    self.end_headers()
                    self.wfile.write(response_body)
                    return
            except urllib.error.HTTPError as error:
                response_body = error.read()
                if self._should_retry_provider(error.code, attempts):
                    self._sleep_before_retry(attempts)
                    continue
                self._audit_request(
                    "provider_error",
                    token_subject,
                    error.code,
                    body_size,
                    started_at,
                    endpoint,
                    model,
                    provider_attempts=attempts,
                )
                self.send_response(error.code)
                self.send_header(
                    "Content-Type",
                    error.headers.get("Content-Type", "application/json"),
                )
                self.send_header("Cache-Control", "no-store")
                self.send_header("Content-Length", str(len(response_body)))
                self.end_headers()
                self.wfile.write(response_body)
                return
            except urllib.error.URLError as error:
                if self._should_retry_provider(502, attempts):
                    self._sleep_before_retry(attempts)
                    continue
                self._audit_request(
                    "provider_unavailable",
                    token_subject,
                    502,
                    body_size,
                    started_at,
                    endpoint,
                    model,
                    provider_attempts=attempts,
                )
                self._write_json(
                    502,
                    {"error": "provider_unavailable", "detail": str(error.reason)},
                )
                return

    def _wants_stream(self, payload: dict[str, object]) -> bool:
        accept = self.headers.get("Accept", "")
        if "text/event-stream" in accept.lower():
            return True
        return payload.get("stream") is True

    def _stream_provider_response(
        self,
        response: object,
        token_subject: str,
        body_size: int,
        started_at: float,
        endpoint: str,
        model: str | None,
        attempts: int,
    ) -> None:
        """Relay the upstream body chunk-by-chunk instead of buffering it.

        The response is delimited by connection close (HTTP/1.0 semantics),
        which every SSE-capable client handles; no Content-Length is sent.
        """
        self._audit_request(
            "proxied",
            token_subject,
            response.status,
            body_size,
            started_at,
            endpoint,
            model,
            provider_attempts=attempts,
        )
        self.send_response(response.status)
        self.send_header(
            "Content-Type",
            response.headers.get("Content-Type", "text/event-stream"),
        )
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True
        while True:
            chunk = response.read1(65536)
            if not chunk:
                break
            self.wfile.write(chunk)
            self.wfile.flush()

    def _should_retry_provider(self, status: int, attempts: int) -> bool:
        if attempts > self.server.config.provider_max_retries:
            return False
        return status in (429, 500, 502, 503, 504)

    def _sleep_before_retry(self, attempts: int) -> None:
        delay = self.server.config.provider_retry_backoff_seconds * attempts
        if delay > 0:
            time.sleep(min(delay, 5.0))

    def _response_payload(self, body: bytes) -> dict[str, object] | None:
        try:
            payload = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            return None
        return payload if isinstance(payload, dict) else None

    def _responses_privacy_error(self, payload: dict[str, object]) -> str | None:
        metadata = payload.get("metadata")
        if self.server.config.require_openphone_metadata:
            if not isinstance(metadata, dict) or metadata.get("openphone_task") != "true":
                return "openphone_metadata_required"

        image_count = count_input_images(payload)
        if image_count > self.server.config.max_images_per_request:
            return "too_many_images"

        if self.server.config.reject_sensitive_screen and isinstance(metadata, dict):
            risk_flags = metadata.get("risk_flags", [])
            if isinstance(risk_flags, str):
                risk_flags = [flag.strip() for flag in risk_flags.split(",") if flag.strip()]
            if isinstance(risk_flags, list):
                sensitive_flags = {
                    "sensitive_input_visible",
                    "account_or_payment_hint_visible",
                }
                if any(flag in sensitive_flags for flag in risk_flags):
                    return "sensitive_screen_rejected"
        return None

    def _audit_request(
        self,
        outcome: str,
        token_subject: str | None,
        status: int,
        body_size: int,
        started_at: float,
        endpoint: str | None = None,
        model: str | None = None,
        provider_attempts: int | None = None,
    ) -> None:
        payload = {
            "type": "broker_request",
            "ts": int(time.time()),
            "endpoint": endpoint or self.path.split("?", 1)[0],
            "subject": token_subject,
            "client": self.client_address[0],
            "outcome": outcome,
            "status": status,
            "body_size": body_size,
            "model": model,
            "duration_ms": int((time.monotonic() - started_at) * 1000),
        }
        if provider_attempts is not None:
            payload["provider_attempts"] = provider_attempts
        self.server.audit(payload)

    def _bearer_token(self) -> str | None:
        authorization = self.headers.get("Authorization", "")
        prefix = "Bearer "
        if not authorization.startswith(prefix):
            return None
        token = authorization[len(prefix) :].strip()
        return token or None

    def _write_json(self, status: int, payload: dict[str, object]) -> None:
        body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class BrokerServer(http.server.ThreadingHTTPServer):
    def __init__(self, server_address: tuple[str, int], config: BrokerConfig) -> None:
        super().__init__(server_address, BrokerHandler)
        self.config = config
        self.rate_limiter = RateLimiter(config.rate_limit_per_minute)
        self.byte_rate_limiter = ByteRateLimiter(config.max_bytes_per_minute)
        self._audit_lock = threading.Lock()

    def validate_token(self, token: str | None) -> str | None:
        if token is None:
            return None
        token_matches = False
        for session_token in self.config.session_tokens:
            # Check every configured token so the comparison time does not
            # depend on where (or whether) the match occurs.
            token_matches |= hmac.compare_digest(token, session_token)
        if token_matches:
            digest = hashlib.sha256(token.encode("utf-8")).hexdigest()[:16]
            return f"static:{digest}"
        if self.config.token_secret is None:
            return None
        return validate_signed_token(token, self.config.token_secret)

    def validate_admin_token(self, token: str | None) -> str | None:
        if token is None:
            return None
        for admin_token in self.config.admin_tokens:
            if hmac.compare_digest(token, admin_token):
                digest = hashlib.sha256(token.encode("utf-8")).hexdigest()[:16]
                return f"admin:{digest}"
        return None

    def is_response_model_allowed(self, model: str) -> bool:
        allowed = self.config.allowed_response_models
        return not allowed or model in allowed

    def is_token_subject_allowed(self, subject: str) -> bool:
        allowed = self.config.allowed_token_subjects
        return not allowed or subject in allowed

    def verify_device_attestation(self, subject: str, payload: dict[str, object]) -> str | None:
        secret = self.config.device_attestation_secrets.get(subject)
        if secret is None:
            return None
        timestamp = payload.get("attestation_timestamp")
        nonce = payload.get("attestation_nonce")
        signature = payload.get("attestation_signature")
        if not isinstance(timestamp, int) or not isinstance(nonce, str) or not nonce:
            return "attestation_required"
        if not isinstance(signature, str) or not signature:
            return "attestation_required"
        now = int(time.time())
        if abs(now - timestamp) > self.config.device_attestation_max_skew_seconds:
            return "attestation_expired"
        body = f"{subject}.{timestamp}.{nonce}".encode("utf-8")
        expected = hmac.new(secret, body, hashlib.sha256).hexdigest()
        if not hmac.compare_digest(signature.lower(), expected):
            return "attestation_invalid"
        return None

    def audit(self, payload: dict[str, object]) -> None:
        line = json.dumps(payload, sort_keys=True, separators=(",", ":"))
        with self._audit_lock:
            if self.config.audit_log_path:
                with open(self.config.audit_log_path, "a", encoding="utf-8") as handle:
                    handle.write(line + "\n")
            else:
                print(line)


def _b64url_encode(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).decode("ascii").rstrip("=")


def _b64url_decode(value: str) -> bytes:
    padding = "=" * (-len(value) % 4)
    return base64.urlsafe_b64decode(value + padding)


def _token_signature(secret: bytes, expires_at: int, subject: str, nonce: str) -> str:
    body = f"{expires_at}.{subject}.{nonce}".encode("utf-8")
    return _b64url_encode(hmac.new(secret, body, hashlib.sha256).digest())


def mint_signed_token(secret: bytes, subject: str, ttl_seconds: int) -> str:
    if ttl_seconds <= 0:
        raise ValueError("ttl_seconds must be positive")
    expires_at = int(time.time()) + ttl_seconds
    encoded_subject = _b64url_encode(subject.encode("utf-8"))
    nonce = secrets.token_urlsafe(18)
    signature = _token_signature(secret, expires_at, encoded_subject, nonce)
    return f"op1.{expires_at}.{encoded_subject}.{nonce}.{signature}"


def validate_signed_token(token: str, secret: bytes) -> str | None:
    parts = token.split(".")
    if len(parts) != 5 or parts[0] != "op1":
        return None
    _, raw_expires_at, encoded_subject, nonce, signature = parts
    try:
        expires_at = int(raw_expires_at)
    except ValueError:
        return None
    if expires_at < int(time.time()):
        return None
    expected = _token_signature(secret, expires_at, encoded_subject, nonce)
    if not hmac.compare_digest(signature, expected):
        return None
    try:
        subject = _b64url_decode(encoded_subject).decode("utf-8")
    except (UnicodeDecodeError, ValueError):
        return None
    return f"signed:{subject}"


def count_input_images(value: object) -> int:
    if isinstance(value, dict):
        count = 0
        if value.get("type") == "input_image":
            count += 1
        image_url = value.get("image_url")
        if value.get("type") != "input_image" and isinstance(image_url, str) and image_url.startswith("data:image/"):
            count += 1
        for child in value.values():
            count += count_input_images(child)
        return count
    if isinstance(value, list):
        return sum(count_input_images(child) for child in value)
    return 0


def env_bool(name: str, default: bool) -> bool:
    raw_value = os.environ.get(name)
    if raw_value is None or raw_value == "":
        return default
    return raw_value.strip().lower() in {"1", "true", "yes", "on"}


def load_provider_registry(path: str) -> tuple[frozenset[str], str, str]:
    with open(path, "r", encoding="utf-8") as handle:
        payload = json.load(handle)
    providers = payload.get("providers")
    if not isinstance(providers, dict):
        raise SystemExit("provider registry must contain a providers object")
    openai = providers.get("openai")
    if not isinstance(openai, dict):
        raise SystemExit("provider registry must contain providers.openai")

    responses_url = openai.get("responses_url", OPENAI_RESPONSES_URL)
    transcriptions_url = openai.get("transcriptions_url", OPENAI_TRANSCRIPTIONS_URL)
    models = openai.get("responses_models", [])
    if not isinstance(responses_url, str) or not responses_url:
        raise SystemExit("providers.openai.responses_url must be a non-empty string")
    if not isinstance(transcriptions_url, str) or not transcriptions_url:
        raise SystemExit("providers.openai.transcriptions_url must be a non-empty string")
    if not isinstance(models, list) or not all(isinstance(model, str) and model for model in models):
        raise SystemExit("providers.openai.responses_models must be a list of non-empty strings")
    return frozenset(models), responses_url, transcriptions_url


def load_device_registry(path: str) -> tuple[frozenset[str], dict[str, bytes]]:
    with open(path, "r", encoding="utf-8") as handle:
        payload = json.load(handle)
    devices = payload.get("devices")
    if not isinstance(devices, list):
        raise SystemExit("device registry must contain a devices list")
    subjects: set[str] = set()
    attestation_secrets: dict[str, bytes] = {}
    for device in devices:
        if not isinstance(device, dict):
            raise SystemExit("device registry entries must be objects")
        subject = device.get("subject")
        if not isinstance(subject, str) or not subject:
            raise SystemExit("device registry entries must contain a non-empty subject")
        subjects.add(subject)
        secret_env = device.get("attestation_secret_env")
        if secret_env is not None:
            if not isinstance(secret_env, str) or not secret_env:
                raise SystemExit("device attestation_secret_env must be a non-empty string")
            raw_secret = os.environ.get(secret_env, "").strip()
            if raw_secret:
                attestation_secrets[subject] = raw_secret.encode("utf-8")
    return frozenset(subjects), attestation_secrets


def load_config() -> BrokerConfig:
    api_key = os.environ.get("OPENAI_API_KEY", "").strip()
    if not api_key:
        raise SystemExit("OPENAI_API_KEY is required")

    raw_tokens = os.environ.get("OPENPHONE_BROKER_SESSION_TOKENS", "")
    tokens = frozenset(token.strip() for token in raw_tokens.split(",") if token.strip())
    raw_admin_tokens = os.environ.get("OPENPHONE_BROKER_ADMIN_TOKENS", "")
    admin_tokens = frozenset(
        token.strip() for token in raw_admin_tokens.split(",") if token.strip()
    )
    raw_secret = os.environ.get("OPENPHONE_BROKER_TOKEN_SECRET", "").strip()
    token_secret = raw_secret.encode("utf-8") if raw_secret else None
    if not tokens and token_secret is None:
        raise SystemExit(
            "OPENPHONE_BROKER_SESSION_TOKENS or OPENPHONE_BROKER_TOKEN_SECRET is required"
        )

    registry_path = os.environ.get("OPENPHONE_BROKER_PROVIDER_REGISTRY", "").strip()
    responses_url = OPENAI_RESPONSES_URL
    transcriptions_url = OPENAI_TRANSCRIPTIONS_URL
    allowed_response_models: frozenset[str] = frozenset()
    if registry_path:
        allowed_response_models, responses_url, transcriptions_url = load_provider_registry(
            registry_path
        )

    raw_allowed_models = os.environ.get("OPENPHONE_BROKER_ALLOWED_RESPONSE_MODELS", "")
    env_allowed_response_models = frozenset(
        model.strip() for model in raw_allowed_models.split(",") if model.strip()
    )
    if env_allowed_response_models:
        allowed_response_models = env_allowed_response_models

    device_registry_path = os.environ.get("OPENPHONE_BROKER_DEVICE_REGISTRY", "").strip()
    allowed_token_subjects: frozenset[str] = frozenset()
    device_attestation_secrets: dict[str, bytes] = {}
    if device_registry_path:
        allowed_token_subjects, device_attestation_secrets = load_device_registry(
            device_registry_path
        )

    return BrokerConfig(
        api_key=api_key,
        session_tokens=tokens,
        admin_tokens=admin_tokens,
        token_secret=token_secret,
        allowed_token_subjects=allowed_token_subjects,
        device_attestation_secrets=device_attestation_secrets,
        device_attestation_max_skew_seconds=int(
            os.environ.get("OPENPHONE_BROKER_ATTESTATION_MAX_SKEW_SECONDS", "300")
        ),
        allowed_response_models=allowed_response_models,
        responses_url=responses_url,
        transcriptions_url=transcriptions_url,
        audit_log_path=os.environ.get("OPENPHONE_BROKER_AUDIT_LOG", "").strip() or None,
        max_body_bytes=int(os.environ.get("OPENPHONE_BROKER_MAX_BODY_BYTES", "15728640")),
        max_bytes_per_minute=int(
            os.environ.get("OPENPHONE_BROKER_MAX_BYTES_PER_MINUTE", "62914560")
        ),
        max_images_per_request=int(
            os.environ.get("OPENPHONE_BROKER_MAX_IMAGES_PER_REQUEST", "1")
        ),
        require_openphone_metadata=env_bool(
            "OPENPHONE_BROKER_REQUIRE_OPENPHONE_METADATA", False
        ),
        reject_sensitive_screen=env_bool("OPENPHONE_BROKER_REJECT_SENSITIVE_SCREEN", True),
        provider_max_retries=int(os.environ.get("OPENPHONE_BROKER_PROVIDER_MAX_RETRIES", "1")),
        provider_retry_backoff_seconds=float(
            os.environ.get("OPENPHONE_BROKER_PROVIDER_RETRY_BACKOFF_SECONDS", "0.25")
        ),
        rate_limit_per_minute=int(os.environ.get("OPENPHONE_BROKER_RATE_LIMIT_PER_MINUTE", "30")),
        token_max_ttl_seconds=int(
            os.environ.get("OPENPHONE_BROKER_TOKEN_MAX_TTL_SECONDS", "3600")
        ),
    )


def load_token_secret() -> bytes:
    raw_secret = os.environ.get("OPENPHONE_BROKER_TOKEN_SECRET", "").strip()
    if not raw_secret:
        raise SystemExit("OPENPHONE_BROKER_TOKEN_SECRET is required for token minting")
    return raw_secret.encode("utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description="Run the OpenPhone model broker")
    parser.add_argument("--host", default=os.environ.get("OPENPHONE_BROKER_HOST", "127.0.0.1"))
    parser.add_argument(
        "--port",
        type=int,
        default=int(os.environ.get("OPENPHONE_BROKER_PORT", "8787")),
    )
    parser.add_argument("--mint-token", action="store_true", help="mint a signed broker token")
    parser.add_argument("--subject", default="dev-device", help="signed token subject")
    parser.add_argument("--ttl-seconds", type=int, default=3600, help="signed token lifetime")
    args = parser.parse_args()

    if args.mint_token:
        print(mint_signed_token(load_token_secret(), args.subject, args.ttl_seconds))
        return

    server = BrokerServer((args.host, args.port), load_config())
    print(f"OpenPhone model broker listening on http://{args.host}:{args.port}")
    server.serve_forever()


if __name__ == "__main__":
    main()
