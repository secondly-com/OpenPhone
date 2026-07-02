#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/validate-trajectory-export.sh <trajectory.zip|trajectory-dir>

Validates an OpenPhone assistant trajectory export:

- finds exactly one events.jsonl file;
- verifies trajectory event schema markers, event names, and sequential indexes;
- requires task_started and agent_result events;
- verifies screenshot file references exist in the export;
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

[[ -e "$input" ]] || {
  printf 'missing trajectory export: %s\n' "$input" >&2
  exit 1
}

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - <<'PY' "$input" "$root/schemas/trajectory-event.schema.json"
import base64
import json
import pathlib
import re
import sys
import zipfile

path = pathlib.Path(sys.argv[1])
schema = json.loads(pathlib.Path(sys.argv[2]).read_text(encoding="utf-8"))
schema_marker = schema["properties"]["schema"]["const"]
allowed_events = set(schema["properties"]["event"]["enum"])
secret_name_re = re.compile(r"(api[_-]?key|authorization|token|secret|private[_-]?key)", re.I)
secret_value_re = re.compile(
    r"(sk-proj-|sk-[A-Za-z0-9_-]{20,}|BEGIN (RSA |OPENSSH |EC |DSA )?PRIVATE KEY|"
    r"PRIVATE KEY-----|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9_]{30,})"
)
base64ish_re = re.compile(r"^[A-Za-z0-9+/=\r\n]+$")


class Export:
    def __init__(self, root):
        self.root = root
        self.zip = None
        self.files = set()
        self.bytes_by_name = {}
        if root.is_dir():
            for item in root.rglob("*"):
                if item.is_file():
                    name = item.relative_to(root).as_posix()
                    self.files.add(name)
                    self.bytes_by_name[name] = item.read_bytes()
        elif zipfile.is_zipfile(root):
            self.zip = zipfile.ZipFile(root)
            for info in self.zip.infolist():
                if not info.is_dir():
                    self.files.add(info.filename)
                    self.bytes_by_name[info.filename] = self.zip.read(info)
        else:
            raise SystemExit(f"trajectory export must be a directory or zip: {root}")

    def close(self):
        if self.zip is not None:
            self.zip.close()


def is_screenshot_object(obj):
    return isinstance(obj, dict) and obj.get("encoding") == "base64" and "mime_type" in obj


def maybe_raw_base64(value):
    if not isinstance(value, str) or len(value) < 128:
        return False
    if not base64ish_re.fullmatch(value.strip()):
        return False
    try:
        decoded = base64.b64decode(value, validate=True)
    except Exception:
        return False
    return len(decoded) > 64


def walk(value, export, current_path=""):
    if isinstance(value, dict):
        if is_screenshot_object(value):
            data = value.get("data", "")
            if isinstance(data, str) and not data.startswith("<"):
                raise SystemExit(f"raw screenshot base64 leaked at {current_path}.data")
            screenshot_file = value.get("file")
            if screenshot_file:
                matches = [name for name in export.files if name.endswith("/" + screenshot_file)
                           or name == screenshot_file]
                if not matches:
                    raise SystemExit(f"trajectory references missing screenshot file: {screenshot_file}")
        for key, child in value.items():
            child_path = f"{current_path}.{key}" if current_path else key
            if secret_name_re.search(str(key)) and child != "<redacted>":
                raise SystemExit(f"secret-like field is not redacted: {child_path}")
            walk(child, export, child_path)
        return
    if isinstance(value, list):
        for index, child in enumerate(value):
            walk(child, export, f"{current_path}[{index}]")
        return
    if isinstance(value, str):
        if secret_value_re.search(value):
            raise SystemExit(f"secret-like value found at {current_path}")
        if maybe_raw_base64(value):
            raise SystemExit(f"raw base64-like payload found at {current_path}")


export = Export(path)
try:
    events_files = sorted(name for name in export.files if name.endswith("events.jsonl"))
    if len(events_files) != 1:
        raise SystemExit(f"expected exactly one events.jsonl, found {len(events_files)}")
    events_name = events_files[0]
    events_text = export.bytes_by_name[events_name].decode("utf-8")
    lines = [line for line in events_text.splitlines() if line.strip()]
    if not lines:
        raise SystemExit("events.jsonl is empty")

    seen_events = set()
    for expected_index, line in enumerate(lines):
        try:
            event = json.loads(line)
        except json.JSONDecodeError as exc:
            raise SystemExit(f"invalid JSONL at line {expected_index + 1}: {exc}") from exc
        if event.get("schema") != schema_marker:
            raise SystemExit(f"event {expected_index} has missing/invalid schema marker")
        if event.get("index") != expected_index:
            raise SystemExit(f"event index mismatch: expected {expected_index} got {event.get('index')}")
        if not isinstance(event.get("timestamp_ms"), int):
            raise SystemExit(f"event {expected_index} timestamp_ms must be integer")
        event_type = event.get("event")
        if event_type not in allowed_events:
            raise SystemExit(f"unknown trajectory event type: {event_type}")
        if not isinstance(event.get("payload"), dict):
            raise SystemExit(f"event {expected_index} payload must be object")
        seen_events.add(event_type)
        walk(event, export)

    missing = {"task_started", "agent_result"} - seen_events
    if missing:
        raise SystemExit("trajectory missing required event types: " + ", ".join(sorted(missing)))
finally:
    export.close()

print(f"Trajectory export validation passed: {path}")
PY
