#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/validate-audit-evidence-export.sh <audit-evidence.json>

Validates an OpenPhone audit evidence export:

- verifies the audit evidence schema marker and required top-level fields;
- checks service status and audit payloads are structured when available;
- verifies audit event names match the public audit-event contract;
- rejects obvious API key/token/private-key leakage and raw base64 screenshot data.
EOF
}

input="${1:-}"
if [[ "$input" == "-h" || "$input" == "--help" ]]; then
  usage
  exit 0
fi
if [[ -z "$input" ]]; then
  usage >&2
  exit 2
fi

[[ -f "$input" ]] || {
  printf 'missing audit evidence export: %s\n' "$input" >&2
  exit 1
}

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - <<'PY' "$input" "$root"
import base64
import json
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])

evidence_schema = json.loads(
    (root / "schemas/audit-evidence.schema.json").read_text(encoding="utf-8"))
evidence_marker = evidence_schema["properties"]["schema"]["const"]
required_evidence_keys = set(evidence_schema["required"])

allowed_events = None
contract_path = root / "schemas/audit-event.schema.json"
if contract_path.is_file():
    contract = json.loads(contract_path.read_text(encoding="utf-8"))
    allowed_events = set(contract["properties"]["event_type"]["enum"])

secret_name_re = re.compile(r"(api[_-]?key|authorization|token|secret|private[_-]?key)", re.I)
secret_value_re = re.compile(
    r"(sk-proj-|sk-[A-Za-z0-9_-]{20,}|BEGIN (RSA |OPENSSH |EC |DSA )?PRIVATE KEY|"
    r"PRIVATE KEY-----|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9_]{30,})"
)
base64ish_re = re.compile(r"^[A-Za-z0-9+/=\r\n]+$")


def maybe_raw_base64(value):
    if not isinstance(value, str) or len(value) < 128:
        return False
    if value.startswith("<"):
        return False
    if not base64ish_re.fullmatch(value.strip()):
        return False
    try:
        decoded = base64.b64decode(value, validate=True)
    except Exception:
        return False
    return len(decoded) > 64


def is_screenshot_object(obj):
    return isinstance(obj, dict) and obj.get("encoding") == "base64" and "mime_type" in obj


def walk(value, current_path=""):
    if isinstance(value, dict):
        if is_screenshot_object(value):
            data = value.get("data", "")
            if isinstance(data, str) and not data.startswith("<"):
                raise SystemExit(f"raw screenshot base64 leaked at {current_path}.data")
        for key, child in value.items():
            child_path = f"{current_path}.{key}" if current_path else key
            if secret_name_re.search(str(key)) and child != "<redacted>":
                raise SystemExit(f"secret-like field is not redacted: {child_path}")
            walk(child, child_path)
        return
    if isinstance(value, list):
        for index, child in enumerate(value):
            walk(child, f"{current_path}[{index}]")
        return
    if isinstance(value, str):
        if secret_value_re.search(value):
            raise SystemExit(f"secret-like value found at {current_path}")
        if maybe_raw_base64(value):
            raise SystemExit(f"raw base64-like payload found at {current_path}")


payload = json.loads(path.read_text(encoding="utf-8"))
if set(payload) != required_evidence_keys:
    raise SystemExit(f"unexpected audit evidence keys: {sorted(payload)}")
if payload.get("schema") != evidence_marker:
    raise SystemExit("invalid audit evidence schema marker")
if not isinstance(payload.get("exported_at_ms"), int):
    raise SystemExit("exported_at_ms must be an integer")
redaction_text = payload.get("redaction")
if not isinstance(redaction_text, str):
    raise SystemExit("redaction description is missing or weak")
redaction_lower = redaction_text.lower()
if "redact" not in redaction_lower and "removed" not in redaction_lower:
    raise SystemExit("redaction description is missing or weak")

service_status = payload.get("service_status")
if isinstance(service_status, dict):
    for field in ("state", "service"):
        if field not in service_status:
            raise SystemExit(f"service_status missing field: {field}")

audit = payload.get("audit")
events = []
if isinstance(audit, dict):
    if "events" in audit:
        if not isinstance(audit["events"], list):
            raise SystemExit("audit.events must be an array")
        events = audit["events"]
    elif "error" not in audit and "state" not in audit:
        raise SystemExit("structured audit payload has neither events nor status")
elif isinstance(audit, list):
    events = audit
elif not isinstance(audit, str):
    raise SystemExit("audit must be object, array, or string")

for index, event in enumerate(events):
    if not isinstance(event, dict):
        raise SystemExit(f"audit event {index} must be an object")
    event_type = event.get("event_type")
    if allowed_events is not None and event_type not in allowed_events:
        raise SystemExit(f"audit event {index} has unknown event_type: {event_type}")
    if "timestamp_elapsed_ms" in event and not isinstance(event["timestamp_elapsed_ms"], int):
        raise SystemExit(f"audit event {index} timestamp_elapsed_ms must be integer")

walk(payload)
print(f"Audit evidence validation passed: {path}")
PY
