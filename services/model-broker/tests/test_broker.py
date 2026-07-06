"""Unit tests for the OpenPhone model broker security primitives.

The broker is deliberately stdlib-only; these tests import the module
directly and exercise the token, attestation, rate-limiting, and privacy
logic without starting an HTTP server.
"""

import hashlib
import hmac
import threading
import time
import types

import openphone_model_broker as broker


SECRET = b"unit-test-token-secret"
OTHER_SECRET = b"unit-test-token-secret-v2"


# ---------------------------------------------------------------------------
# Signed session tokens
# ---------------------------------------------------------------------------


class TestSignedTokens:
    def test_valid_token_round_trip(self):
        token = broker.mint_signed_token(SECRET, "device-1", ttl_seconds=60)
        assert broker.validate_signed_token(token, SECRET) == "signed:device-1"

    def test_expired_token_rejected(self):
        expires_at = int(time.time()) - 10
        encoded_subject = broker._b64url_encode(b"device-1")
        nonce = "unit-nonce"
        signature = broker._token_signature(SECRET, expires_at, encoded_subject, nonce)
        token = f"op1.{expires_at}.{encoded_subject}.{nonce}.{signature}"
        assert broker.validate_signed_token(token, SECRET) is None

    def test_token_valid_until_expiry_boundary(self):
        # A token expiring in the future must validate right up to expiry.
        token = broker.mint_signed_token(SECRET, "device-1", ttl_seconds=2)
        assert broker.validate_signed_token(token, SECRET) is not None

    def test_bit_flipped_subject_rejected(self):
        token = broker.mint_signed_token(SECRET, "device-1", ttl_seconds=60)
        prefix, expires_at, encoded_subject, nonce, signature = token.split(".")
        flipped = ("B" if encoded_subject[0] != "B" else "C") + encoded_subject[1:]
        tampered = ".".join([prefix, expires_at, flipped, nonce, signature])
        assert broker.validate_signed_token(tampered, SECRET) is None

    def test_bit_flipped_expiry_rejected(self):
        token = broker.mint_signed_token(SECRET, "device-1", ttl_seconds=60)
        prefix, expires_at, encoded_subject, nonce, signature = token.split(".")
        extended = str(int(expires_at) + 86400)
        tampered = ".".join([prefix, extended, encoded_subject, nonce, signature])
        assert broker.validate_signed_token(tampered, SECRET) is None

    def test_bit_flipped_signature_rejected(self):
        token = broker.mint_signed_token(SECRET, "device-1", ttl_seconds=60)
        prefix, expires_at, encoded_subject, nonce, signature = token.split(".")
        flipped = ("A" if signature[-1] != "A" else "B") + signature[1:]
        tampered = ".".join([prefix, expires_at, encoded_subject, nonce, flipped])
        assert broker.validate_signed_token(tampered, SECRET) is None

    def test_wrong_hmac_key_rejected(self):
        # A token minted under a rotated-out key version must not validate.
        token = broker.mint_signed_token(SECRET, "device-1", ttl_seconds=60)
        assert broker.validate_signed_token(token, OTHER_SECRET) is None

    def test_malformed_tokens_rejected(self):
        assert broker.validate_signed_token("", SECRET) is None
        assert broker.validate_signed_token("op1.only.three.parts", SECRET) is None
        assert broker.validate_signed_token("op2.1.a.b.c", SECRET) is None
        assert broker.validate_signed_token("op1.not-a-number.a.b.c", SECRET) is None

    def test_mint_requires_positive_ttl(self):
        try:
            broker.mint_signed_token(SECRET, "device-1", ttl_seconds=0)
        except ValueError:
            pass
        else:
            raise AssertionError("mint_signed_token accepted a non-positive TTL")


# ---------------------------------------------------------------------------
# Device attestation clock skew
# ---------------------------------------------------------------------------


ATTESTATION_SECRET = b"unit-test-attestation-secret"
ATTESTATION_SUBJECT = "unit-device"


def _attestation_server(max_skew_seconds: int) -> types.SimpleNamespace:
    """Build a stand-in for BrokerServer exposing only .config."""
    config = types.SimpleNamespace(
        device_attestation_secrets={ATTESTATION_SUBJECT: ATTESTATION_SECRET},
        device_attestation_max_skew_seconds=max_skew_seconds,
    )
    return types.SimpleNamespace(config=config)


def _attestation_payload(timestamp: int, nonce: str = "unit-nonce") -> dict:
    body = f"{ATTESTATION_SUBJECT}.{timestamp}.{nonce}".encode("utf-8")
    signature = hmac.new(ATTESTATION_SECRET, body, hashlib.sha256).hexdigest()
    return {
        "attestation_timestamp": timestamp,
        "attestation_nonce": nonce,
        "attestation_signature": signature,
    }


class TestDeviceAttestation:
    def _verify(self, server, subject, payload):
        return broker.BrokerServer.verify_device_attestation(server, subject, payload)

    def test_timestamp_inside_skew_window_accepted(self):
        server = _attestation_server(max_skew_seconds=300)
        payload = _attestation_payload(int(time.time()) - 250)
        assert self._verify(server, ATTESTATION_SUBJECT, payload) is None

    def test_future_timestamp_inside_skew_window_accepted(self):
        server = _attestation_server(max_skew_seconds=300)
        payload = _attestation_payload(int(time.time()) + 250)
        assert self._verify(server, ATTESTATION_SUBJECT, payload) is None

    def test_timestamp_outside_skew_window_rejected(self):
        server = _attestation_server(max_skew_seconds=300)
        payload = _attestation_payload(int(time.time()) - 301)
        assert self._verify(server, ATTESTATION_SUBJECT, payload) == "attestation_expired"

    def test_future_timestamp_outside_skew_window_rejected(self):
        server = _attestation_server(max_skew_seconds=300)
        payload = _attestation_payload(int(time.time()) + 301)
        assert self._verify(server, ATTESTATION_SUBJECT, payload) == "attestation_expired"

    def test_tampered_signature_rejected(self):
        server = _attestation_server(max_skew_seconds=300)
        payload = _attestation_payload(int(time.time()))
        signature = payload["attestation_signature"]
        payload["attestation_signature"] = ("0" if signature[0] != "0" else "1") + signature[1:]
        assert self._verify(server, ATTESTATION_SUBJECT, payload) == "attestation_invalid"

    def test_missing_fields_require_attestation(self):
        server = _attestation_server(max_skew_seconds=300)
        assert self._verify(server, ATTESTATION_SUBJECT, {}) == "attestation_required"
        payload = _attestation_payload(int(time.time()))
        del payload["attestation_signature"]
        assert self._verify(server, ATTESTATION_SUBJECT, payload) == "attestation_required"

    def test_subject_without_secret_skips_attestation(self):
        server = _attestation_server(max_skew_seconds=300)
        assert self._verify(server, "unknown-device", {}) is None


# ---------------------------------------------------------------------------
# Rate limiter concurrency and eviction
# ---------------------------------------------------------------------------


class TestRateLimiterConcurrency:
    def test_exactly_max_events_allowed_under_contention(self):
        max_events = 50
        thread_count = 16
        attempts_per_thread = 25  # 400 total attempts against a budget of 50
        limiter = broker.RateLimiter(max_events, window_seconds=60)
        allowed = []
        allowed_lock = threading.Lock()
        start_barrier = threading.Barrier(thread_count)

        def hammer():
            start_barrier.wait()
            local_allowed = 0
            for _ in range(attempts_per_thread):
                if limiter.allow("shared-key"):
                    local_allowed += 1
            with allowed_lock:
                allowed.append(local_allowed)

        threads = [threading.Thread(target=hammer) for _ in range(thread_count)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        assert sum(allowed) == max_events

    def test_keys_are_isolated(self):
        limiter = broker.RateLimiter(1, window_seconds=60)
        assert limiter.allow("a") is True
        assert limiter.allow("a") is False
        assert limiter.allow("b") is True

    def test_stale_key_eviction(self):
        limiter = broker.RateLimiter(5, window_seconds=1)
        now = time.monotonic()
        # A key whose newest event fell out of the window is stale.
        limiter._events["stale"].append(now - 10)
        # A key with a recent event must survive eviction.
        limiter._events["fresh"].append(now)
        # Force the next allow() call to run the eviction sweep.
        limiter._last_eviction = now - limiter._EVICTION_INTERVAL_SECONDS - 1
        assert limiter.allow("active") is True
        assert "stale" not in limiter._events
        assert "fresh" in limiter._events
        assert "active" in limiter._events

    def test_events_refill_after_window(self):
        limiter = broker.RateLimiter(1, window_seconds=60)
        assert limiter.allow("key") is True
        assert limiter.allow("key") is False
        # Age the stored event past the window; the next call must succeed.
        limiter._events["key"][0] = time.monotonic() - 61
        assert limiter.allow("key") is True


class TestByteRateLimiter:
    def test_byte_budget_enforced(self):
        limiter = broker.ByteRateLimiter(100, window_seconds=60)
        assert limiter.allow("key", 60) is True
        assert limiter.allow("key", 60) is False
        assert limiter.allow("key", 40) is True

    def test_zero_budget_disables_limiting(self):
        limiter = broker.ByteRateLimiter(0, window_seconds=60)
        assert limiter.allow("key", 10**9) is True

    def test_concurrent_byte_accounting(self):
        max_bytes = 1000
        chunk = 10
        thread_count = 8
        attempts_per_thread = 50  # 4000 bytes attempted against a 1000 budget
        limiter = broker.ByteRateLimiter(max_bytes, window_seconds=60)
        allowed = []
        allowed_lock = threading.Lock()
        start_barrier = threading.Barrier(thread_count)

        def hammer():
            start_barrier.wait()
            local_allowed = 0
            for _ in range(attempts_per_thread):
                if limiter.allow("shared-key", chunk):
                    local_allowed += 1
            with allowed_lock:
                allowed.append(local_allowed)

        threads = [threading.Thread(target=hammer) for _ in range(thread_count)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        assert sum(allowed) * chunk == max_bytes


# ---------------------------------------------------------------------------
# Admin and static token validation
# ---------------------------------------------------------------------------


def _token_server(
    session_tokens=frozenset(),
    admin_tokens=frozenset(),
    token_secret=None,
) -> types.SimpleNamespace:
    config = types.SimpleNamespace(
        session_tokens=frozenset(session_tokens),
        admin_tokens=frozenset(admin_tokens),
        token_secret=token_secret,
    )
    return types.SimpleNamespace(config=config)


class TestAdminTokenValidation:
    def test_matching_admin_token_accepted(self):
        server = _token_server(admin_tokens={"admin-token-1", "admin-token-2"})
        subject = broker.BrokerServer.validate_admin_token(server, "admin-token-2")
        expected_digest = hashlib.sha256(b"admin-token-2").hexdigest()[:16]
        assert subject == f"admin:{expected_digest}"

    def test_wrong_admin_token_rejected(self):
        server = _token_server(admin_tokens={"admin-token-1"})
        assert broker.BrokerServer.validate_admin_token(server, "admin-token-x") is None

    def test_none_token_rejected(self):
        server = _token_server(admin_tokens={"admin-token-1"})
        assert broker.BrokerServer.validate_admin_token(server, None) is None

    def test_empty_admin_set_rejects_everything(self):
        server = _token_server()
        assert broker.BrokerServer.validate_admin_token(server, "anything") is None


class TestSessionTokenValidation:
    def test_static_token_accepted(self):
        server = _token_server(session_tokens={"static-token"})
        subject = broker.BrokerServer.validate_token(server, "static-token")
        expected_digest = hashlib.sha256(b"static-token").hexdigest()[:16]
        assert subject == f"static:{expected_digest}"

    def test_unknown_token_without_secret_rejected(self):
        server = _token_server(session_tokens={"static-token"})
        assert broker.BrokerServer.validate_token(server, "other") is None

    def test_signed_token_fallback(self):
        server = _token_server(session_tokens={"static-token"}, token_secret=SECRET)
        token = broker.mint_signed_token(SECRET, "device-9", ttl_seconds=60)
        assert broker.BrokerServer.validate_token(server, token) == "signed:device-9"

    def test_none_token_rejected(self):
        server = _token_server(session_tokens={"static-token"})
        assert broker.BrokerServer.validate_token(server, None) is None


# ---------------------------------------------------------------------------
# Privacy: image counting on adversarial payloads
# ---------------------------------------------------------------------------


class TestCountInputImages:
    def test_simple_input_image(self):
        payload = {"input": [{"type": "input_image", "image_url": "data:image/png;base64,AA=="}]}
        assert broker.count_input_images(payload) == 1

    def test_data_uri_without_input_image_type_counts(self):
        # Smuggling a data:image URL under a different type must still count.
        payload = {"input": [{"type": "input_text", "image_url": "data:image/jpeg;base64,AA=="}]}
        assert broker.count_input_images(payload) == 1

    def test_input_image_with_data_uri_counts_once(self):
        payload = {
            "input": [{"type": "input_image", "image_url": "data:image/jpeg;base64,AA=="}]
        }
        assert broker.count_input_images(payload) == 1

    def test_deeply_nested_images_are_found(self):
        payload = {
            "metadata": {
                "hidden": [
                    {"deeper": {"type": "input_image"}},
                    [{"type": "input_image"}],
                ]
            },
            "input": [
                {
                    "role": "user",
                    "content": [
                        {"type": "input_image", "image_url": "data:image/png;base64,AA=="}
                    ],
                }
            ],
        }
        assert broker.count_input_images(payload) == 3

    def test_non_image_data_uri_not_counted(self):
        payload = {"input": [{"type": "input_text", "image_url": "data:text/plain;base64,AA=="}]}
        assert broker.count_input_images(payload) == 0

    def test_non_string_image_url_not_counted(self):
        payload = {"input": [{"image_url": {"url": "data:image/png;base64,AA=="}}]}
        # The nested dict has no type/image_url string, so nothing counts.
        assert broker.count_input_images(payload) == 0

    def test_scalar_and_empty_payloads(self):
        assert broker.count_input_images(None) == 0
        assert broker.count_input_images("data:image/png;base64,AA==") == 0
        assert broker.count_input_images(123) == 0
        assert broker.count_input_images({}) == 0
        assert broker.count_input_images([]) == 0

    def test_many_images_all_counted(self):
        images = [{"type": "input_image"} for _ in range(25)]
        assert broker.count_input_images({"input": images}) == 25
