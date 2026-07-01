#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/common.sh
source "$root/scripts/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/lab/down.sh --slot <name> [--purge]

Stops emulator/runtime processes for a local OpenPhone lab slot. With --purge,
deletes that slot's ignored .worktree/lab directory.
EOF
}

slot=""
purge=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --slot)
      [[ $# -ge 2 ]] || die "--slot requires a value"
      slot="$2"
      shift 2
      ;;
    --purge)
      purge=true
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

[[ -n "$slot" ]] || die "--slot is required"
env_file="$root/.worktree/lab/$slot/env"
[[ -f "$env_file" ]] || die "missing lab env file: $env_file"
# shellcheck disable=SC1090
source "$env_file"

if command -v adb >/dev/null 2>&1; then
  adb -s "$ANDROID_SERIAL" emu kill >/dev/null 2>&1 || true
fi

pid_dir="$OPENPHONE_LAB_DIR/run"
if [[ -d "$pid_dir" ]]; then
  for pid_file in "$pid_dir"/*.pid; do
    [[ -e "$pid_file" ]] || continue
    pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [[ "$pid" =~ ^[0-9]+$ ]]; then
      kill "$pid" >/dev/null 2>&1 || true
      wait "$pid" >/dev/null 2>&1 || true
    fi
    rm -f "$pid_file"
  done
fi

if [[ "$purge" == true ]]; then
  rm -rf "$OPENPHONE_LAB_DIR"
fi

printf 'Stopped lab slot %s (%s)\n' "$slot" "$ANDROID_SERIAL"
