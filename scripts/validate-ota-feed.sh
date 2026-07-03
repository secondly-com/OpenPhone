#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/validate-ota-feed.sh <feed.json> [artifact-dir]

Validates the OpenPhone OTA feed structure and, when artifact-dir is supplied,
checks that each feed entry's filename, size, and SHA-256 match a local file.
EOF
}

feed="${1:-}"
artifact_dir="${2:-}"

if [[ -z "$feed" ]]; then
  usage >&2
  exit 2
fi

[[ -f "$feed" ]] || {
  printf 'missing OTA feed: %s\n' "$feed" >&2
  exit 1
}

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - <<'PY' "$feed" "$artifact_dir" "$root/schemas/ota-feed.schema.json"
import hashlib
import json
import pathlib
import re
import sys

feed_path = pathlib.Path(sys.argv[1])
artifact_dir = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] else None
schema = json.loads(pathlib.Path(sys.argv[3]).read_text(encoding="utf-8"))
payload = json.loads(feed_path.read_text(encoding="utf-8"))

required_top = set(schema["required"])
expected_schema_version = schema["properties"]["schema_version"]["const"]
update_schema = schema["properties"]["updates"]["items"]
required_update = set(update_schema["required"])
sha256_re = update_schema["properties"]["sha256"]["pattern"]

if set(payload) != required_top:
    raise SystemExit(f"unexpected OTA feed top-level keys: {sorted(payload)}")
if payload["schema_version"] != expected_schema_version:
    raise SystemExit("unsupported OTA feed schema_version")
if not isinstance(payload["updates"], list) or not payload["updates"]:
    raise SystemExit("OTA feed must contain at least one update")

for update in payload["updates"]:
    if set(update) != required_update:
        raise SystemExit(f"unexpected OTA update keys: {sorted(update)}")
    if not re.fullmatch(sha256_re, update["sha256"]):
        raise SystemExit(f"invalid SHA-256: {update['sha256']}")
    if not isinstance(update["size"], int) or update["size"] <= 0:
        raise SystemExit("OTA update size must be a positive integer")
    if not isinstance(update["requires_wipe"], bool):
        raise SystemExit("requires_wipe must be boolean")
    if "/" in update["filename"]:
        raise SystemExit("OTA update filename must be a basename")
    if artifact_dir is not None:
        artifact = artifact_dir / update["filename"]
        if not artifact.is_file():
            raise SystemExit(f"missing OTA artifact for feed entry: {artifact}")
        actual_size = artifact.stat().st_size
        if actual_size != update["size"]:
            raise SystemExit(f"size mismatch for {artifact.name}: feed {update['size']} actual {actual_size}")
        actual_sha = hashlib.sha256(artifact.read_bytes()).hexdigest()
        if actual_sha != update["sha256"]:
            raise SystemExit(f"SHA-256 mismatch for {artifact.name}")
PY

printf 'OTA feed validation passed: %s\n' "$feed"
