#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/common.sh
source "$root/scripts/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/run-emulator-smoke.sh [options]

Builds or reuses an OpenPhone SDK phone emulator image, boots it headlessly,
and runs the fast OpenPhone runtime smoke checks used by CI.

Options:
  --arch arm64|x86_64      Emulator image architecture. Default: host arch.
  --variant eng|userdebug  Emulator build variant. Default: eng.
  --slot <name>            Lab slot name for isolated data/artifacts.
  --port <port>            Emulator console port. Default: 5584.
  --serial <serial>        ADB serial. Default: emulator-<port>.
  --avd <name>             Boot an installed Android SDK AVD instead of the
                           Android source-tree emulator launcher.
  --avd-home <path>        ANDROID_AVD_HOME for --avd.
  --timeout <seconds>      Boot timeout. Default: 600.
  --skip-build             Reuse an already-built image.
  --keep-running           Do not stop the emulator on exit.
  -h, --help               Show this help.

Environment:
  OPENPHONE_ANDROID_DIR                 Android checkout path.
  OPENPHONE_LAB_SLOT                    Lab slot name.
  OPENPHONE_LAB_DIR                     Lab slot directory.
  OPENPHONE_EMULATOR_PORT               Emulator console port.
  OPENPHONE_EMULATOR_SERIAL             Emulator ADB serial.
  OPENPHONE_EMULATOR_AVD                Installed AVD name for prebuilt images.
  OPENPHONE_EMULATOR_BUILD              Set to 0 to skip build.
  OPENPHONE_EMULATOR_ASSISTANT_SMOKE    Set to 0 to skip local assistant task.
  OPENPHONE_EMULATOR_ARGS               Extra emulator arguments.
  ANDROID_AVD_HOME                      AVD home for installed SDK images.

Artifacts are written under .worktree/emulator-smoke/<timestamp>/.
EOF
}

detect_emulator_arch() {
  case "$(uname -m)" in
    arm64|aarch64) printf 'arm64' ;;
    x86_64|amd64) printf 'x86_64' ;;
    *) die "unsupported host architecture: $(uname -m). Pass --arch arm64 or --arch x86_64." ;;
  esac
}

run_adb_shell_with_timeout() {
  local seconds="$1"
  local log_file="$2"
  shift 2

  adb -s "$serial" shell "$@" > "$log_file" 2>&1 &
  local command_pid="$!"
  local command_deadline=$((SECONDS + seconds))

  while kill -0 "$command_pid" >/dev/null 2>&1; do
    if [[ "$SECONDS" -ge "$command_deadline" ]]; then
      {
        echo
        echo "Timed out after ${seconds}s: adb -s $serial shell $*"
      } >> "$log_file"
      kill "$command_pid" >/dev/null 2>&1 || true
      sleep 2
      kill -9 "$command_pid" >/dev/null 2>&1 || true
      wait "$command_pid" >/dev/null 2>&1 || true
      return 124
    fi
    sleep 1
  done

  wait "$command_pid"
}

arch=""
variant="eng"
slot="${OPENPHONE_LAB_SLOT:-}"
port="${OPENPHONE_EMULATOR_PORT:-5584}"
serial=""
timeout_seconds="600"
build="${OPENPHONE_EMULATOR_BUILD:-1}"
keep_running=false
avd_name="${OPENPHONE_EMULATOR_AVD:-}"
avd_home="${ANDROID_AVD_HOME:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
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
    --slot)
      [[ $# -ge 2 ]] || die "--slot requires a value"
      slot="$2"
      shift 2
      ;;
    --port)
      [[ $# -ge 2 ]] || die "--port requires a value"
      port="$2"
      shift 2
      ;;
    --serial)
      [[ $# -ge 2 ]] || die "--serial requires a value"
      serial="$2"
      shift 2
      ;;
    --avd)
      [[ $# -ge 2 ]] || die "--avd requires a value"
      avd_name="$2"
      shift 2
      ;;
    --avd-home)
      [[ $# -ge 2 ]] || die "--avd-home requires a value"
      avd_home="$2"
      shift 2
      ;;
    --timeout)
      [[ $# -ge 2 ]] || die "--timeout requires a value"
      timeout_seconds="$2"
      shift 2
      ;;
    --skip-build)
      build=0
      shift
      ;;
    --keep-running)
      keep_running=true
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

arch="${arch:-$(detect_emulator_arch)}"
serial="${serial:-${OPENPHONE_EMULATOR_SERIAL:-${ANDROID_SERIAL:-emulator-$port}}}"

case "$arch" in
  arm64|x86_64) ;;
  *) die "unsupported emulator arch: $arch" ;;
esac

case "$variant" in
  eng|userdebug) ;;
  *) die "unsupported emulator variant: $variant" ;;
esac

[[ "$port" =~ ^[0-9]+$ ]] || die "--port must be numeric"
[[ "$timeout_seconds" =~ ^[0-9]+$ ]] || die "--timeout must be numeric"

if [[ -n "$avd_name" ]]; then
  build=0
fi
if [[ -n "$avd_home" ]]; then
  export ANDROID_AVD_HOME="$avd_home"
fi

need_cmd adb
need_cmd node
need_cmd python3
need_cmd emulator

stamp="$(date -u +%Y%m%d-%H%M%S)"
if [[ -n "$slot" ]]; then
  lab_dir="${OPENPHONE_LAB_DIR:-$root/.worktree/lab/$slot}"
  emulator_data_dir="$lab_dir/emulator-data"
  out_dir="$lab_dir/artifacts/emulator-smoke/$stamp"
else
  lab_dir=""
  emulator_data_dir="$root/.worktree/emulator-smoke/$stamp/emulator-data"
  out_dir="$root/.worktree/emulator-smoke/$stamp"
fi
mkdir -p "$emulator_data_dir"
mkdir -p "$out_dir"

export ANDROID_SERIAL="$serial"

emulator_pid=""
cleanup() {
  set +e
  adb -s "$serial" logcat -d > "$out_dir/logcat.txt" 2>/dev/null
  adb -s "$serial" exec-out screencap -p > "$out_dir/screenshot.png" 2>/dev/null
  adb -s "$serial" shell uiautomator dump /sdcard/openphone-emulator-smoke.xml >/dev/null 2>&1
  adb -s "$serial" exec-out cat /sdcard/openphone-emulator-smoke.xml \
    > "$out_dir/window.xml" 2>/dev/null
  if [[ "$keep_running" != true ]]; then
    adb -s "$serial" emu kill >/dev/null 2>&1
  fi
  if [[ -n "$emulator_pid" ]]; then
    wait "$emulator_pid" >/dev/null 2>&1
  fi
}
trap cleanup EXIT

if [[ "$build" != "0" ]]; then
  info "Building OpenPhone emulator image for $arch/$variant"
  "$root/scripts/build-emulator.sh" --arch "$arch" --variant "$variant"
fi

info "Stopping any existing emulator on $serial"
adb -s "$serial" emu kill >/dev/null 2>&1 || true
sleep 2

extra_emulator_args=()
if [[ -n "${OPENPHONE_EMULATOR_ARGS:-}" ]]; then
  read -r -a extra_emulator_args <<< "$OPENPHONE_EMULATOR_ARGS"
fi
emulator_args=(
  -port "$port"
  -datadir "$emulator_data_dir"
  -no-window
  -gpu swiftshader_indirect
  -no-snapshot
  -wipe-data
  -no-boot-anim
  -no-audio
)
emulator_args+=("${extra_emulator_args[@]}")

if [[ -n "$avd_name" ]]; then
  info "Launching emulator $serial from AVD $avd_name"
  emulator -avd "$avd_name" "${emulator_args[@]}" > "$out_dir/emulator.log" 2>&1 &
else
  info "Launching emulator $serial"
  "$root/scripts/run-emulator.sh" --arch "$arch" --variant "$variant" -- \
    "${emulator_args[@]}" > "$out_dir/emulator.log" 2>&1 &
fi
emulator_pid="$!"

info "Waiting for ADB device"
deadline=$((SECONDS + timeout_seconds))
adb_state=""
while [[ "$SECONDS" -lt "$deadline" ]]; do
  if ! kill -0 "$emulator_pid" >/dev/null 2>&1; then
    die "emulator process exited before ADB became ready; see $out_dir/emulator.log"
  fi
  adb_state="$(adb -s "$serial" get-state 2>/dev/null || true)"
  if [[ "$adb_state" == "device" ]]; then
    break
  fi
  sleep 2
done
[[ "$adb_state" == "device" ]] || die "ADB device $serial was not ready within ${timeout_seconds}s"

boot_completed=""
while [[ "$SECONDS" -lt "$deadline" ]]; do
  boot_completed="$(adb -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)"
  if [[ "$boot_completed" == "1" ]]; then
    break
  fi
  sleep 5
done
[[ "$boot_completed" == "1" ]] || die "emulator did not finish booting within ${timeout_seconds}s"

info "Emulator booted"
adb -s "$serial" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
adb -s "$serial" shell wm dismiss-keyguard >/dev/null 2>&1 || true

info "Preparing emulator for headless smoke"
{
  echo "Marking setup complete"
  adb -s "$serial" shell settings put global device_provisioned 1 || true
  adb -s "$serial" shell settings put secure user_setup_complete 1 || true
  adb -s "$serial" shell settings put secure tv_user_setup_complete 1 || true

  for package in org.lineageos.setupwizard com.google.android.setupwizard com.android.provision; do
    if adb -s "$serial" shell pm path "$package" >/dev/null 2>&1; then
      echo "Disabling setup/provisioning package: $package"
      adb -s "$serial" shell am force-stop "$package" || true
      adb -s "$serial" shell pm disable-user --user 0 "$package" || true
    fi
  done

  adb -s "$serial" shell input keyevent KEYCODE_HOME || true
} > "$out_dir/headless-provisioning.txt" 2>&1

identity="$out_dir/device-identity.txt"
adb -s "$serial" shell 'printf "model="; getprop ro.product.model; printf "device="; getprop ro.product.device; printf "openphone="; getprop ro.openphone.version; printf "lineage="; getprop ro.lineage.version; printf "boot_completed="; getprop sys.boot_completed' \
  > "$identity"
cat "$identity"

grep -q '^boot_completed=1' "$identity" || die "boot_completed was not recorded as 1"
grep -q '^openphone=.' "$identity" || die "ro.openphone.version was empty"

info "Checking OpenPhone framework services"
adb -s "$serial" shell 'service check openphone_agent' | tee "$out_dir/service-openphone-agent.txt"
adb -s "$serial" shell 'service check openphone_context' | tee "$out_dir/service-openphone-context.txt"
adb -s "$serial" shell 'service check openphone_assistant_data' | tee "$out_dir/service-openphone-assistant-data.txt"
grep -q 'found' "$out_dir/service-openphone-agent.txt" || die "openphone_agent service not found"
grep -q 'found' "$out_dir/service-openphone-context.txt" || die "openphone_context service not found"
grep -q 'found' "$out_dir/service-openphone-assistant-data.txt" || die "openphone_assistant_data service not found"

info "Checking assistant package"
adb -s "$serial" shell 'pm path org.openphone.assistant' | tee "$out_dir/assistant-path.txt"
adb -s "$serial" shell 'cmd package list packages --show-versioncode org.openphone.assistant' \
  | tee "$out_dir/assistant-package.txt"
grep -q 'org.openphone.assistant' "$out_dir/assistant-package.txt" \
  || die "OpenPhone Assistant package is not installed"

info "Starting assistant activity"
if ! run_adb_shell_with_timeout 60 "$out_dir/start-assistant.txt" \
  am start -W -n org.openphone.assistant/.MainActivity; then
  adb -s "$serial" shell dumpsys activity activities \
    > "$out_dir/activity-after-start-failure.txt" 2>/dev/null || true
  die "assistant activity did not start within 60s; see $out_dir/start-assistant.txt"
fi
grep -q 'Status: ok' "$out_dir/start-assistant.txt" \
  || die "assistant activity start did not report Status: ok"
adb -s "$serial" shell dumpsys activity activities > "$out_dir/activity-after-start.txt"
grep -q 'ResumedActivity: .*org.openphone.assistant/.MainActivity' \
  "$out_dir/activity-after-start.txt" \
  || die "assistant activity was not the resumed activity"

info "Running runtime CLI status smoke"
node "$root/integrations/cli/src/index.mjs" --serial "$serial" --json runtime status \
  > "$out_dir/runtime-status.json"
python3 - <<'PY' "$out_dir/runtime-status.json"
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
for key in ("chat_runtime", "volume_runtime", "background_runtime"):
    if key not in data:
        raise SystemExit(f"missing runtime status key: {key}")
PY

info "Running runtime screen smoke"
node "$root/integrations/cli/src/index.mjs" --serial "$serial" --json \
  tool invoke openphone.screen.get '{"include_screenshot":false}' \
  > "$out_dir/screen-get.json"
python3 - <<'PY' "$out_dir/screen-get.json"
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
if data.get("ok") is not True:
    raise SystemExit(f"screen smoke failed: {data}")
if "ui_tree_xml" not in data:
    raise SystemExit("screen smoke did not return ui_tree_xml")
PY

if [[ "${OPENPHONE_EMULATOR_ASSISTANT_SMOKE:-1}" != "0" ]]; then
  info "Running local assistant task smoke"
  "$root/scripts/run-assistant-task.sh" \
    --goal "Just respond with the word pong." \
    --local \
    --wait 20 > "$out_dir/assistant-task.txt"
fi

info "Emulator smoke passed; artifacts in $out_dir"
