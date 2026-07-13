#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/validate-agent-eval-report.sh <eval-report.json> [evidence-root]

Validates an OpenPhone agent eval report and, when evidence-root is supplied,
also validates referenced trajectory and audit evidence files.
EOF
}

report="${1:-}"
evidence_root="${2:-}"

if [[ "$report" == "-h" || "$report" == "--help" ]]; then
  usage
  exit 0
fi
if [[ -z "$report" ]]; then
  usage >&2
  exit 2
fi
[[ -f "$report" ]] || {
  printf 'missing eval report: %s\n' "$report" >&2
  exit 1
}

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - <<'PY' "$report" "$root"
import json
import pathlib
import re
import sys

report_path = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
payload = json.loads(report_path.read_text(encoding="utf-8"))

schema = json.loads(
    (root / "schemas/agent-eval-report.schema.json").read_text(encoding="utf-8"))
properties = schema["properties"]
schema_marker = properties["schema"]["const"]
allowed_device_keys = set(properties["device"]["properties"])
required_build = set(properties["build"]["required"])
ota_sha256_re = properties["build"]["properties"]["ota_sha256"]["pattern"]
allowed_model_keys = set(properties["model"]["properties"])
allowed_transports = set(properties["model"]["properties"]["transport"]["enum"])
allowed_result_keys = set(properties["result"]["properties"])
allowed_statuses = set(properties["result"]["properties"]["status"]["enum"])
allowed_evidence_keys = set(properties["evidence"]["properties"])

required_top = set(schema["required"])
if set(payload) != required_top:
    raise SystemExit(f"unexpected eval report top-level keys: {sorted(payload)}")
if payload["schema"] != schema_marker:
    raise SystemExit("invalid eval report schema marker")
if not payload["eval_id"].strip():
    raise SystemExit("eval_id must be non-empty")
if not payload["goal"].strip():
    raise SystemExit("goal must be non-empty")

device = payload["device"]
if set(device) - allowed_device_keys:
    raise SystemExit(f"unexpected device keys: {sorted(device)}")
if not device.get("codename"):
    raise SystemExit("device.codename must be non-empty")
if "serial" in device:
    raise SystemExit("device serial must not be included; use serial_redacted")

build = payload["build"]
if not required_build.issubset(build):
    raise SystemExit("build object missing required fields")
if not isinstance(build["assistant_version_code"], int) or build["assistant_version_code"] <= 0:
    raise SystemExit("assistant_version_code must be a positive integer")
if not build["assistant_version_name"]:
    raise SystemExit("assistant_version_name must be non-empty")
if "ota_sha256" in build and not re.fullmatch(ota_sha256_re, build["ota_sha256"]):
    raise SystemExit("build.ota_sha256 must be lowercase SHA-256")

manifest = root / "overlay/packages/apps/OpenPhoneAssistant/AndroidManifest.xml"
manifest_text = manifest.read_text(encoding="utf-8")
code_match = re.search(r'android:versionCode="([0-9]+)"', manifest_text)
name_match = re.search(r'android:versionName="([^"]+)"', manifest_text)
if code_match and int(code_match.group(1)) != build["assistant_version_code"]:
    raise SystemExit("eval report assistant_version_code does not match repo manifest")
if name_match and name_match.group(1) != build["assistant_version_name"]:
    raise SystemExit("eval report assistant_version_name does not match repo manifest")

model = payload["model"]
if set(model) != allowed_model_keys:
    raise SystemExit(f"unexpected model keys: {sorted(model)}")
if model["transport"] not in allowed_transports:
    raise SystemExit("model.transport is invalid")
if not isinstance(model["cloud"], bool):
    raise SystemExit("model.cloud must be boolean")
if model["transport"] == "local" and model["cloud"]:
    raise SystemExit("local transport cannot be cloud=true")
if model["transport"] in allowed_transports - {"local"} and not model["cloud"]:
    raise SystemExit("cloud transport must set cloud=true")

result = payload["result"]
if set(result) - allowed_result_keys:
    raise SystemExit(f"unexpected result keys: {sorted(result)}")
if result.get("status") not in allowed_statuses:
    raise SystemExit("result.status is invalid")
if not result.get("summary"):
    raise SystemExit("result.summary must be non-empty")
if result["status"] in {"fail", "blocked"} and not result.get("failure_reason"):
    raise SystemExit("fail/blocked eval reports require result.failure_reason")

evidence = payload["evidence"]
if set(evidence) - allowed_evidence_keys:
    raise SystemExit(f"unexpected evidence keys: {sorted(evidence)}")
for field in sorted(set(properties["evidence"]["required"])):
    value = evidence.get(field)
    if not isinstance(value, str) or not value.strip():
        raise SystemExit(f"evidence.{field} must be a non-empty string")
    if pathlib.PurePosixPath(value).is_absolute() or pathlib.PurePath(value).is_absolute():
        raise SystemExit(f"evidence.{field} must be relative to evidence-root")
    if ".." in pathlib.PurePath(value).parts:
        raise SystemExit(f"evidence.{field} must not contain parent traversal")

print(f"Agent eval report validation passed: {report_path}")
PY

if [[ -n "$evidence_root" ]]; then
  [[ -d "$evidence_root" ]] || {
    printf 'missing evidence root: %s\n' "$evidence_root" >&2
    exit 1
  }
  trajectory="$(python3 - <<'PY' "$report"
import json
import pathlib
import sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))["evidence"]["trajectory"])
PY
)"
  audit="$(python3 - <<'PY' "$report"
import json
import pathlib
import sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))["evidence"]["audit"])
PY
)"
  "$root/scripts/validate-trajectory-export.sh" "$evidence_root/$trajectory" >/dev/null
  "$root/scripts/validate-audit-evidence-export.sh" "$evidence_root/$audit" >/dev/null
fi
