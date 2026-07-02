#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/common.sh
source "$root/scripts/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/lab/smoke.sh [options]

Runs the emulator smoke in an isolated lab slot.

Options:
  --slot <name>              Lab slot name. Default: checkout hash.
  --arch arm64|x86_64        Emulator image architecture. Default: host arch.
  --variant eng|userdebug    Emulator build variant. Default: eng.
  --runtime <name>           Runtime intent: local, openclaw, or hermes.
                             May be repeated. Default: local.
  --openclaw                 Alias for --runtime openclaw.
  --prebuilt                 Use an installed SDK system image/AVD instead of
                             the Android source-tree emulator launcher.
  --avd <name>               Installed AVD name to boot.
  --avd-home <path>          ANDROID_AVD_HOME for --avd.
  --skip-build               Reuse an already-built emulator image.
  --keep-running             Leave the emulator running on exit.
  --timeout <seconds>        Boot timeout. Default: run-emulator-smoke default.
  --ci                       CI mode alias; currently only makes intent explicit.
  -h, --help                 Show this help.

Runtime launch hooks:
  OPENPHONE_OPENCLAW_UP_CMD   Optional command to start OpenClaw for this slot.
  OPENPHONE_HERMES_UP_CMD     Optional command to start Hermes for this slot.
  OPENPHONE_HERMES_HEALTH_CMD Optional command that must pass for Hermes smoke.
EOF
}

slot=""
arch=""
variant=""
skip_build=false
keep_running=false
timeout_seconds=""
prebuilt=false
avd_name="${OPENPHONE_EMULATOR_AVD:-}"
avd_home="${ANDROID_AVD_HOME:-}"
avd_explicit=false
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
    --variant)
      [[ $# -ge 2 ]] || die "--variant requires a value"
      variant="$2"
      shift 2
      ;;
    --skip-build)
      skip_build=true
      shift
      ;;
    --keep-running)
      keep_running=true
      shift
      ;;
    --timeout)
      [[ $# -ge 2 ]] || die "--timeout requires a value"
      timeout_seconds="$2"
      shift 2
      ;;
    --runtime)
      [[ $# -ge 2 ]] || die "--runtime requires a value"
      runtimes+=("$2")
      shift 2
      ;;
    --openclaw)
      runtimes+=(openclaw)
      shift
      ;;
    --prebuilt)
      prebuilt=true
      skip_build=true
      shift
      ;;
    --avd)
      [[ $# -ge 2 ]] || die "--avd requires a value"
      avd_name="$2"
      avd_explicit=true
      skip_build=true
      shift 2
      ;;
    --avd-home)
      [[ $# -ge 2 ]] || die "--avd-home requires a value"
      avd_home="$2"
      shift 2
      ;;
    --ci)
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

if [[ ${#runtimes[@]} -eq 0 ]]; then
  runtimes=(local)
fi

needs_runtime() {
  local needle="$1"
  local runtime
  for runtime in "${runtimes[@]}"; do
    [[ "$runtime" == "$needle" ]] && return 0
  done
  return 1
}

for runtime in "${runtimes[@]}"; do
  case "$runtime" in
    local|openclaw|hermes) ;;
    *) die "unsupported runtime: $runtime" ;;
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

allocate_args=()
allocate_args+=(--slot "$slot")
"$root/scripts/lab/allocate-slot.sh" "${allocate_args[@]}" >/dev/null

env_file="$root/.worktree/lab/$slot/env"
[[ -f "$env_file" ]] || die "missing lab env file"
# shellcheck disable=SC1090
source "$env_file"

avd_name="${avd_name:-${OPENPHONE_EMULATOR_AVD:-}}"
avd_home="${avd_home:-${ANDROID_AVD_HOME:-}}"

if [[ "$prebuilt" == true && "$avd_explicit" != true ]]; then
  ensure_args=(--slot "$OPENPHONE_LAB_SLOT")
  if [[ -n "$arch" ]]; then
    ensure_args+=(--arch "$arch")
  fi
  "$root/scripts/lab/ensure-avd.sh" "${ensure_args[@]}"
  # Refresh because ensure-avd appends Android SDK/AVD exports to the slot env.
  # shellcheck disable=SC1090
  source "$env_file"
  avd_name="$OPENPHONE_EMULATOR_AVD"
  avd_home="$ANDROID_AVD_HOME"
fi

runtime_pids=()
cleanup_runtimes() {
  set +e
  if [[ "$keep_running" == true ]]; then
    return 0
  fi
  local pid
  for pid in "${runtime_pids[@]:-}"; do
    kill "$pid" >/dev/null 2>&1 || true
    wait "$pid" >/dev/null 2>&1 || true
  done
}
trap cleanup_runtimes EXIT

start_runtime_cmd() {
  local name="$1"
  local cmd="$2"
  local log="$OPENPHONE_LAB_DIR/artifacts/${name}.log"
  local runtime_pid

  mkdir -p "$OPENPHONE_LAB_DIR/artifacts" "$OPENPHONE_LAB_DIR/run"
  info "Starting $name runtime command"
  (
    cd "$root"
    OPENPHONE_LAB_SLOT="$OPENPHONE_LAB_SLOT" \
      OPENPHONE_LAB_DIR="$OPENPHONE_LAB_DIR" \
      ANDROID_SERIAL="$ANDROID_SERIAL" \
      OPENPHONE_OPENCLAW_URL="$OPENPHONE_OPENCLAW_URL" \
      OPENPHONE_HERMES_URL="$OPENPHONE_HERMES_URL" \
      OPENPHONE_MODEL_BROKER_URL="$OPENPHONE_MODEL_BROKER_URL" \
      bash -lc "$cmd"
  ) > "$log" 2>&1 &
  runtime_pid="$!"
  runtime_pids+=("$runtime_pid")
  printf '%s\n' "$runtime_pid" > "$OPENPHONE_LAB_DIR/run/$name.pid"
  sleep "${OPENPHONE_RUNTIME_BOOT_SLEEP:-5}"
}

if needs_runtime openclaw && [[ -n "${OPENPHONE_OPENCLAW_UP_CMD:-}" ]]; then
  start_runtime_cmd openclaw "$OPENPHONE_OPENCLAW_UP_CMD"
fi

if needs_runtime hermes && [[ -n "${OPENPHONE_HERMES_UP_CMD:-}" ]]; then
  start_runtime_cmd hermes "$OPENPHONE_HERMES_UP_CMD"
fi

args=(--slot "$OPENPHONE_LAB_SLOT" --port "$OPENPHONE_EMULATOR_PORT" --serial "$ANDROID_SERIAL")
if [[ -n "$arch" ]]; then
  args+=(--arch "$arch")
fi
if [[ -n "$variant" ]]; then
  args+=(--variant "$variant")
fi
if [[ -n "$avd_name" ]]; then
  args+=(--avd "$avd_name")
  skip_build=true
fi
if [[ -n "$avd_home" ]]; then
  args+=(--avd-home "$avd_home")
fi
if [[ "$skip_build" == true ]]; then
  args+=(--skip-build)
fi
if [[ "$keep_running" == true ]] || needs_runtime openclaw || needs_runtime hermes; then
  args+=(--keep-running)
fi
if [[ -n "$timeout_seconds" ]]; then
  args+=(--timeout "$timeout_seconds")
fi

"$root/scripts/run-emulator-smoke.sh" "${args[@]}"

if needs_runtime openclaw; then
  [[ -n "${OPENPHONE_OPENCLAW_TOKEN:-${OPENCLAW_GATEWAY_TOKEN:-}}" ]] \
    || die "set OPENPHONE_OPENCLAW_TOKEN or OPENCLAW_GATEWAY_TOKEN before --openclaw"
  OPENPHONE_OPENCLAW_URL="$OPENPHONE_OPENCLAW_URL" \
    ANDROID_SERIAL="$ANDROID_SERIAL" \
    "$root/scripts/smoke-test-openclaw-runtime.sh"
fi

if needs_runtime hermes; then
  if [[ -n "${OPENPHONE_HERMES_HEALTH_CMD:-}" ]]; then
    info "Running Hermes health command"
    OPENPHONE_HERMES_URL="$OPENPHONE_HERMES_URL" \
      ANDROID_SERIAL="$ANDROID_SERIAL" \
      bash -lc "$OPENPHONE_HERMES_HEALTH_CMD"
  elif command -v curl >/dev/null 2>&1; then
    info "Checking Hermes health endpoint"
    curl --fail --silent --show-error "${OPENPHONE_HERMES_HEALTH_URL:-$OPENPHONE_HERMES_URL/health}" \
      > "$OPENPHONE_LAB_DIR/artifacts/hermes-health.json"
  else
    die "Hermes runtime requested, but no OPENPHONE_HERMES_HEALTH_CMD and curl is unavailable"
  fi
fi
