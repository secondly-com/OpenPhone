#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/common.sh
source "$root/scripts/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/lab/up.sh [options]

Allocates a local OpenPhone lab slot, boots the emulator, runs the smoke checks,
and leaves the emulator running for Codex/human iteration.

Options:
  --slot <name>              Lab slot name. Default: checkout hash.
  --arch arm64|x86_64        Emulator image architecture. Default: host arch.
  --runtime <name>           Runtime intent: local, openclaw, or hermes.
                             May be repeated. Default: local.
  --skip-build               Reuse an already-built emulator image.
  --timeout <seconds>        Boot timeout. Default: run-emulator-smoke default.
  -h, --help                 Show this help.
EOF
}

slot=""
arch=""
skip_build=false
timeout_seconds=""
runtimes=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --slot)
      [[ $# -ge 2 ]] || die "--slot requires a value"
      slot="$2"
      shift 2
      ;;
    --arch)
      [[ $# -ge 2 ]] || die "--arch requires a value"
      arch="$2"
      shift 2
      ;;
    --runtime)
      [[ $# -ge 2 ]] || die "--runtime requires a value"
      runtimes+=("$2")
      shift 2
      ;;
    --skip-build)
      skip_build=true
      shift
      ;;
    --timeout)
      [[ $# -ge 2 ]] || die "--timeout requires a value"
      timeout_seconds="$2"
      shift 2
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

if [[ -z "$slot" ]]; then
  need_cmd python3
  slot="$(
    python3 - <<'PY' "$root"
import hashlib
import sys

root = sys.argv[1]
print("checkout-" + hashlib.sha1(root.encode("utf-8")).hexdigest()[:8])
PY
  )"
fi

if [[ ${#runtimes[@]} -eq 0 ]]; then
  runtimes=(local)
fi

"$root/scripts/lab/allocate-slot.sh" --slot "$slot" >/dev/null

env_file="$root/.worktree/lab/$slot/env"
[[ -f "$env_file" ]] || die "missing lab env file: $env_file"
# shellcheck disable=SC1090
source "$env_file"

args=(--slot "$OPENPHONE_LAB_SLOT" --keep-running)
if [[ -n "$arch" ]]; then
  args+=(--arch "$arch")
fi
if [[ "$skip_build" == true ]]; then
  args+=(--skip-build)
fi
if [[ -n "$timeout_seconds" ]]; then
  args+=(--timeout "$timeout_seconds")
fi
for runtime in "${runtimes[@]}"; do
  args+=(--runtime "$runtime")
done

"$root/scripts/lab/smoke.sh" "${args[@]}"

printf '\nLab is up. To use it in another shell:\n'
printf '  source %q\n' "$env_file"
printf '  node integrations/cli/src/index.mjs --serial "$ANDROID_SERIAL" --json runtime status\n'
