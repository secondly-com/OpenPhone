#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
broker="$root/services/model-broker/openphone_model_broker.py"

if ! command -v python3 >/dev/null 2>&1; then
  printf 'python3 is required for the model broker smoke test\n' >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  printf 'curl is required for the model broker smoke test\n' >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
audit_log="$tmp_dir/audit.jsonl"
server_log="$tmp_dir/server.log"
provider_log="$tmp_dir/provider.log"
device_registry="$tmp_dir/devices.json"
provider_registry="$tmp_dir/providers.json"
token_secret="openphone-smoke-test-secret"
static_token="openphone-smoke-static-token"
admin_token="openphone-smoke-admin-token"
attestation_secret="openphone-smoke-device-proof-secret"
private_marker="private-screen-text-that-must-not-be-logged"

cleanup() {
  if [[ -n "${broker_pid:-}" ]]; then
    kill "$broker_pid" >/dev/null 2>&1 || true
    wait "$broker_pid" >/dev/null 2>&1 || true
  fi
  if [[ -n "${provider_pid:-}" ]]; then
    kill "$provider_pid" >/dev/null 2>&1 || true
    wait "$provider_pid" >/dev/null 2>&1 || true
  fi
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

port="$(
  python3 - <<'PY'
import socket

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)"

provider_port="$(
  python3 - <<'PY'
import socket

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)"

cat >"$tmp_dir/fake_provider.py" <<'PY'
import http.server
import json
import pathlib
import sys
import time

state_path = pathlib.Path(sys.argv[1])


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        try:
            payload = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            payload = {}
        if isinstance(payload, dict) and payload.get("stream") is True:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Connection", "close")
            self.end_headers()
            for index in range(3):
                self.wfile.write(f"data: chunk-{index}\n\n".encode("utf-8"))
                self.wfile.flush()
                time.sleep(0.4)
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
            return
        attempts = int(state_path.read_text(encoding="utf-8")) if state_path.exists() else 0
        attempts += 1
        state_path.write_text(str(attempts), encoding="utf-8")
        if attempts == 1:
            self.send_response(503)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"error":"try_again"}')
            return
        body = json.dumps({"id": "fake-response", "output_text": "ok"}).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        return


http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[2])), Handler).serve_forever()
PY

python3 "$tmp_dir/fake_provider.py" "$tmp_dir/provider-state.txt" "$provider_port" \
  >"$provider_log" 2>&1 &
provider_pid="$!"

for _ in 1 2 3 4 5 6 7 8 9 10; do
  if python3 - <<'PY' "$provider_port" >/dev/null 2>&1
import socket
import sys

with socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=0.2):
    pass
PY
  then
    break
  fi
  sleep 0.2
done

cat >"$provider_registry" <<'JSON'
{
  "version": 1,
  "providers": {
    "openai": {
      "responses_url": "http://127.0.0.1:PROVIDER_PORT/v1/responses",
      "transcriptions_url": "https://api.openai.com/v1/audio/transcriptions",
      "responses_models": [
        "gpt-4.1-mini"
      ]
    }
  }
}
JSON
sed -i.bak "s/PROVIDER_PORT/$provider_port/g" "$provider_registry"

cat >"$device_registry" <<'JSON'
{
  "version": 1,
  "devices": [
    {
      "subject": "smoke-device",
      "label": "Smoke test device",
      "device": "tegu",
      "attestation_secret_env": "OPENPHONE_DEVICE_SMOKE_SECRET"
    }
  ]
}
JSON

OPENAI_API_KEY="sk-smoke-test" \
OPENPHONE_BROKER_SESSION_TOKENS="$static_token" \
OPENPHONE_BROKER_ADMIN_TOKENS="$admin_token" \
OPENPHONE_BROKER_TOKEN_SECRET="$token_secret" \
OPENPHONE_DEVICE_SMOKE_SECRET="$attestation_secret" \
OPENPHONE_BROKER_DEVICE_REGISTRY="$device_registry" \
OPENPHONE_BROKER_PROVIDER_REGISTRY="$provider_registry" \
OPENPHONE_BROKER_MAX_BODY_BYTES=4096 \
OPENPHONE_BROKER_MAX_BYTES_PER_MINUTE=1200 \
OPENPHONE_BROKER_MAX_IMAGES_PER_REQUEST=1 \
OPENPHONE_BROKER_REQUIRE_OPENPHONE_METADATA=true \
OPENPHONE_BROKER_REJECT_SENSITIVE_SCREEN=true \
OPENPHONE_BROKER_PROVIDER_MAX_RETRIES=1 \
OPENPHONE_BROKER_PROVIDER_RETRY_BACKOFF_SECONDS=0 \
OPENPHONE_BROKER_RATE_LIMIT_PER_MINUTE=30 \
OPENPHONE_BROKER_AUDIT_LOG="$audit_log" \
  python3 "$broker" --host 127.0.0.1 --port "$port" >"$server_log" 2>&1 &
broker_pid="$!"

for _ in 1 2 3 4 5 6 7 8 9 10; do
  if curl -fsS "http://127.0.0.1:$port/healthz" >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done

expect_status() {
  local expected="$1"
  shift
  local actual
  actual="$(curl -sS -o "$tmp_dir/response.json" -w '%{http_code}' "$@")"
  if [[ "$actual" != "$expected" ]]; then
    printf 'expected HTTP %s, got %s for: curl %s\n' "$expected" "$actual" "$*" >&2
    printf 'response: ' >&2
    cat "$tmp_dir/response.json" >&2 || true
    printf '\nserver log:\n' >&2
    cat "$server_log" >&2 || true
    exit 1
  fi
}

expect_status 401 \
  -X POST "http://127.0.0.1:$port/v1/session_tokens" \
  -H 'Content-Type: application/json' \
  --data '{"subject":"smoke-device","ttl_seconds":60}'

expect_status 403 \
  -X POST "http://127.0.0.1:$port/v1/session_tokens" \
  -H "Authorization: Bearer $admin_token" \
  -H 'Content-Type: application/json' \
  --data '{"subject":"smoke-device","ttl_seconds":60}'

expect_status 400 \
  -X POST "http://127.0.0.1:$port/v1/session_tokens" \
  -H "Authorization: Bearer $admin_token" \
  -H 'Content-Type: application/json' \
  --data "$(python3 - <<'PY'
import json
import time

print(json.dumps({
    "subject": "smoke-device",
    "ttl_seconds": 60,
    "attestation_timestamp": int(time.time()),
    "attestation_nonce": "bad",
    "attestation_signature": "bad",
}))
PY
)"

attested_token_request="$(
  python3 - <<'PY' "$attestation_secret"
import hashlib
import hmac
import json
import sys
import time

secret = sys.argv[1].encode("utf-8")
subject = "smoke-device"
timestamp = int(time.time())
nonce = "smoke-nonce"
body = f"{subject}.{timestamp}.{nonce}".encode("utf-8")
signature = hmac.new(secret, body, hashlib.sha256).hexdigest()
print(json.dumps({
    "subject": subject,
    "ttl_seconds": 60,
    "attestation_timestamp": timestamp,
    "attestation_nonce": nonce,
    "attestation_signature": signature,
}))
PY
)"

expect_status 200 \
  -X POST "http://127.0.0.1:$port/v1/session_tokens" \
  -H "Authorization: Bearer $admin_token" \
  -H 'Content-Type: application/json' \
  --data "$attested_token_request"

signed_token="$(
  python3 - <<'PY' "$tmp_dir/response.json"
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
print(payload["token"])
PY
)"

expect_status 403 \
  -X POST "http://127.0.0.1:$port/v1/session_tokens" \
  -H "Authorization: Bearer $admin_token" \
  -H 'Content-Type: application/json' \
  --data '{"subject":"unknown-device","ttl_seconds":60}'

expect_status 401 \
  -X POST "http://127.0.0.1:$port/v1/responses" \
  -H 'Content-Type: application/json' \
  --data '{"model":"gpt-4.1-mini"}'

expect_status 400 \
  -X POST "http://127.0.0.1:$port/v1/responses" \
  -H "Authorization: Bearer $signed_token" \
  -H 'Content-Type: application/json' \
  --data "$private_marker"

expect_status 403 \
  -X POST "http://127.0.0.1:$port/v1/responses" \
  -H "Authorization: Bearer $static_token" \
  -H 'Content-Type: application/json' \
  --data '{"model":"not-allowed"}'

expect_status 403 \
  -X POST "http://127.0.0.1:$port/v1/responses" \
  -H "Authorization: Bearer $static_token" \
  -H 'Content-Type: application/json' \
  --data '{"model":"gpt-4.1-mini","input":[]}'

expect_status 403 \
  -X POST "http://127.0.0.1:$port/v1/responses" \
  -H "Authorization: Bearer $static_token" \
  -H 'Content-Type: application/json' \
  --data '{"model":"gpt-4.1-mini","metadata":{"openphone_task":"true","risk_flags":"sensitive_input_visible"},"input":[]}'

expect_status 403 \
  -X POST "http://127.0.0.1:$port/v1/responses" \
  -H "Authorization: Bearer $static_token" \
  -H 'Content-Type: application/json' \
  --data '{"model":"gpt-4.1-mini","metadata":{"openphone_task":"true","risk_flags":""},"input":[{"role":"user","content":[{"type":"input_image","image_url":"data:image/jpeg;base64,AA=="},{"type":"input_image","image_url":"data:image/jpeg;base64,AA=="}]}]}'

expect_status 413 \
  -X POST "http://127.0.0.1:$port/v1/responses" \
  -H "Authorization: Bearer $static_token" \
  -H 'Content-Type: application/json' \
  --data "$(python3 - <<'PY'
import json
print(json.dumps({"model": "gpt-4.1-mini", "input": "x" * 5000}))
PY
)"

expect_status 415 \
  -X POST "http://127.0.0.1:$port/v1/audio/transcriptions" \
  -H "Authorization: Bearer $static_token" \
  -H 'Content-Type: application/octet-stream' \
  --data 'audio'

expect_status 200 \
  -X POST "http://127.0.0.1:$port/v1/responses" \
  -H "Authorization: Bearer $static_token" \
  -H 'Content-Type: application/json' \
  --data '{"model":"gpt-4.1-mini","metadata":{"openphone_task":"true","risk_flags":""},"input":[{"role":"user","content":[{"type":"input_text","text":"hello"}]}]}'

# Streaming: the broker must relay SSE chunks incrementally instead of
# buffering the full upstream response before replying.
python3 - <<'PY' "$port" "$static_token"
import http.client
import json
import sys
import time

port, token = sys.argv[1:]
body = json.dumps({
    "model": "gpt-4.1-mini",
    "stream": True,
    "metadata": {"openphone_task": "true", "risk_flags": ""},
    "input": [{"role": "user", "content": [{"type": "input_text", "text": "hi"}]}],
})
connection = http.client.HTTPConnection("127.0.0.1", int(port), timeout=30)
connection.request(
    "POST",
    "/v1/responses",
    body=body,
    headers={
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
        "Accept": "text/event-stream",
    },
)
response = connection.getresponse()
if response.status != 200:
    raise SystemExit(f"streaming request failed: HTTP {response.status}")
content_type = response.headers.get("Content-Type", "")
if not content_type.startswith("text/event-stream"):
    raise SystemExit(f"streaming response has wrong content-type: {content_type}")

chunks = []
arrival_times = []
while True:
    chunk = response.read1(65536)
    if not chunk:
        break
    chunks.append(chunk)
    arrival_times.append(time.monotonic())
payload = b"".join(chunks).decode("utf-8")
for expected in ("data: chunk-0", "data: chunk-1", "data: chunk-2", "data: [DONE]"):
    if expected not in payload:
        raise SystemExit(f"streaming response missing {expected!r}: {payload!r}")
if len(arrival_times) < 2:
    raise SystemExit("streaming response arrived as a single buffered chunk")
spread = arrival_times[-1] - arrival_times[0]
if spread < 0.2:
    raise SystemExit(f"streaming chunks were not delivered incrementally (spread={spread:.3f}s)")
print(f"streaming smoke case passed ({len(chunks)} chunks over {spread:.2f}s)")
PY

expect_status 429 \
  -X POST "http://127.0.0.1:$port/v1/responses" \
  -H "Authorization: Bearer $static_token" \
  -H 'Content-Type: application/json' \
  --data "$(python3 - <<'PY'
import json
print(json.dumps({
    "model": "gpt-4.1-mini",
    "metadata": {"openphone_task": "true", "risk_flags": ""},
    "input": [{"role": "user", "content": [{"type": "input_text", "text": "x" * 900}]}],
}))
PY
)"

if [[ ! -s "$audit_log" ]]; then
  printf 'broker audit log was not written\n' >&2
  exit 1
fi

if grep -q "$private_marker" "$audit_log" "$server_log"; then
  printf 'broker logged request body contents\n' >&2
  exit 1
fi

python3 - <<'PY' "$audit_log"
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
events = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]
outcomes = {event.get("outcome") for event in events}
required = {
    "unauthorized",
    "admin_unauthorized",
    "attestation_required",
    "attestation_invalid",
    "token_minted",
    "subject_not_allowed",
    "invalid_json",
    "model_not_allowed",
    "openphone_metadata_required",
    "sensitive_screen_rejected",
    "too_many_images",
    "body_too_large",
    "multipart_form_data_required",
    "proxied",
    "byte_rate_limited",
}
missing = sorted(required - outcomes)
if missing:
    raise SystemExit(f"missing broker audit outcomes: {', '.join(missing)}")
for event in events:
    if "body" in event or "request" in event or "response" in event:
        raise SystemExit(f"audit event contains body-like key: {event}")
proxied = [event for event in events if event.get("outcome") == "proxied"]
if not any(event.get("provider_attempts") == 2 for event in proxied):
    raise SystemExit("broker did not record retried provider forwarding")
PY

printf 'OpenPhone model broker smoke test passed.\n'
