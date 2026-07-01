#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/common.sh
source "$root/scripts/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/lab/allocate-slot.sh [--slot <name>] [--index <n>] [--print]

Creates a deterministic local OpenPhone lab slot and writes an env file with
isolated emulator/runtime ports and artifact directories.

Options:
  --slot <name>  Human-readable slot name. Default: hash of checkout path.
  --index <n>    Explicit numeric slot index. Default: stable hash modulo 100.
  --print        Print shell exports after writing the env file.
  -h, --help     Show this help.

The slot env file is written to .worktree/lab/<slot>/env.
EOF
}

slot=""
index=""
print_env=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --slot)
      [[ $# -ge 2 ]] || die "--slot requires a value"
      slot="$2"
      shift 2
      ;;
    --index)
      [[ $# -ge 2 ]] || die "--index requires a value"
      index="$2"
      shift 2
      ;;
    --print)
      print_env=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

need_cmd python3

slot="$(
  python3 - <<'PY' "$root" "$slot"
import hashlib
import re
import sys

root = sys.argv[1]
slot = sys.argv[2].strip()
if not slot:
    slot = "checkout-" + hashlib.sha1(root.encode("utf-8")).hexdigest()[:8]
slot = re.sub(r"[^A-Za-z0-9_.-]+", "-", slot).strip(".-")
print(slot or "default")
PY
)"

if [[ -z "$index" ]]; then
  index="$(
    python3 - <<'PY' "$slot"
import hashlib
import sys

slot = sys.argv[1]
print(int(hashlib.sha1(slot.encode("utf-8")).hexdigest()[:8], 16) % 100)
PY
  )"
fi

[[ "$index" =~ ^[0-9]+$ ]] || die "--index must be numeric"

lab_root="$root/.worktree/lab"
slot_dir="$lab_root/$slot"
mkdir -p "$slot_dir"/{artifacts,emulator-data,logs,run,runtimes,secrets}

base_emulator_port="${OPENPHONE_LAB_BASE_EMULATOR_PORT:-5584}"
base_openclaw_port="${OPENPHONE_LAB_BASE_OPENCLAW_PORT:-18791}"
base_hermes_port="${OPENPHONE_LAB_BASE_HERMES_PORT:-18891}"
base_model_broker_port="${OPENPHONE_LAB_BASE_MODEL_BROKER_PORT:-18991}"

emulator_port=$((base_emulator_port + (index * 2)))
openclaw_port=$((base_openclaw_port + index))
hermes_port=$((base_hermes_port + index))
model_broker_port=$((base_model_broker_port + index))

env_file="$slot_dir/env"
cat > "$env_file" <<EOF
export OPENPHONE_LAB_SLOT='$slot'
export OPENPHONE_LAB_INDEX='$index'
export OPENPHONE_LAB_DIR='$slot_dir'
export OPENPHONE_EMULATOR_PORT='$emulator_port'
export OPENPHONE_EMULATOR_SERIAL='emulator-$emulator_port'
export ANDROID_SERIAL='emulator-$emulator_port'
export OPENPHONE_OPENCLAW_PORT='$openclaw_port'
export OPENPHONE_OPENCLAW_URL='ws://127.0.0.1:$openclaw_port'
export OPENPHONE_HERMES_PORT='$hermes_port'
export OPENPHONE_HERMES_URL='http://127.0.0.1:$hermes_port'
export OPENPHONE_MODEL_BROKER_PORT='$model_broker_port'
export OPENPHONE_MODEL_BROKER_URL='http://127.0.0.1:$model_broker_port'
export OPENPHONE_ANDROID_DIR='$OPENPHONE_ANDROID_DIR'
EOF

printf 'OpenPhone lab slot written to %s\n' "$env_file"
printf 'Slot: %s\n' "$slot"
printf 'Emulator: emulator-%s\n' "$emulator_port"
printf 'OpenClaw: ws://127.0.0.1:%s\n' "$openclaw_port"
printf 'Hermes: http://127.0.0.1:%s\n' "$hermes_port"

if [[ "$print_env" == true ]]; then
  cat "$env_file"
fi
