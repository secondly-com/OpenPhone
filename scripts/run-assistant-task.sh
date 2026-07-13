#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$root/scripts/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/run-assistant-task.sh --goal <text> [options]

Starts OpenPhone Assistant through the userdebug/eng debug harness.

Options:
  --goal <text>        Task goal to run.
  --api-key-env <var>  Environment variable holding the dev OpenAI API key.
                       Defaults to OPENAI_API_KEY.
  --api-key-file <path>
                       File holding the dev OpenAI API key. Defaults to
                       .worktree/secrets/openai_api_key when present.
  --local              Do not pass an OpenAI key; useful for local model mode.
  --wait <seconds>     Seconds to wait after launching. Defaults to 30.
  -h, --help           Show this help.

The API key is delivered through the Settings.Secure debug slot the assistant
already reads on userdebug/eng builds (openphone_dev_openai_api_key). It is
never passed as an intent extra, so it does not show up in logcat intent dumps
or dumpsys activity. This harness is ignored on production user builds.
EOF
}

goal=""
api_key_env="OPENAI_API_KEY"
api_key_file=""
use_local=false
wait_seconds=30

while [[ $# -gt 0 ]]; do
  case "$1" in
    --goal)
      [[ $# -ge 2 ]] || die "--goal requires a value"
      goal="$2"
      shift 2
      ;;
    --api-key-env)
      [[ $# -ge 2 ]] || die "--api-key-env requires a value"
      api_key_env="$2"
      shift 2
      ;;
    --api-key-file)
      [[ $# -ge 2 ]] || die "--api-key-file requires a value"
      api_key_file="$2"
      shift 2
      ;;
    --local)
      use_local=true
      shift
      ;;
    --wait)
      [[ $# -ge 2 ]] || die "--wait requires a value"
      wait_seconds="$2"
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

[[ -n "$goal" ]] || {
  usage >&2
  exit 2
}
[[ "$wait_seconds" =~ ^[0-9]+$ ]] || die "--wait must be an integer number of seconds"

need_cmd adb
need_cmd python3

api_key=""
if [[ "$use_local" != true ]]; then
  api_key="${!api_key_env:-}"
  if [[ -z "$api_key" ]]; then
    if [[ -z "$api_key_file" && -f "$root/.worktree/secrets/openai_api_key" ]]; then
      api_key_file="$root/.worktree/secrets/openai_api_key"
    fi
    if [[ -n "$api_key_file" ]]; then
      [[ -f "$api_key_file" ]] || die "API key file does not exist: $api_key_file"
      api_key="$(tr -d '\r\n' < "$api_key_file")"
    fi
  fi
  [[ -n "$api_key" ]] || die "set $api_key_env, pass --api-key-file, or pass --local"
fi

goal_b64="$(python3 - <<'PY' "$goal"
import base64
import sys
print(base64.b64encode(sys.argv[1].encode("utf-8")).decode("ascii"))
PY
)"

adb wait-for-device >/dev/null

if [[ "$use_local" != true ]]; then
  # Deliver the key through the Settings.Secure debug slot the assistant reads
  # at startup on userdebug/eng builds (SECURE_DEV_OPENAI_API_KEY). Passing it
  # as an `am start` intent extra would leave it visible in logcat intent
  # dumps and `dumpsys activity`. The key is piped over stdin so it never
  # appears in host argv.
  printf '%s\n' "$api_key" |
    adb shell 'IFS= read -r key; settings put secure openphone_dev_openai_api_key "$key"'
  # The assistant loads this setting in onCreate; restart it so a running
  # instance does not keep stale model config.
  adb shell am force-stop org.openphone.assistant >/dev/null 2>&1 || true
fi

adb shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
adb shell wm dismiss-keyguard >/dev/null 2>&1 || true
adb shell input swipe 540 2100 540 650 250 >/dev/null 2>&1 || true
adb shell input keyevent KEYCODE_BACK >/dev/null 2>&1 || true
adb shell input keyevent KEYCODE_BACK >/dev/null 2>&1 || true
sleep 1

cmd=(
  adb shell am start
  -W
  -n org.openphone.assistant/.MainActivity
  -f 0x24000000
  --es org.openphone.assistant.extra.GOAL_BASE64 "$goal_b64"
  --ez org.openphone.assistant.extra.RUN true
)

"${cmd[@]}"

if [[ "$wait_seconds" -gt 0 ]]; then
  sleep "$wait_seconds"
fi

adb shell dumpsys window | grep -E 'mCurrentFocus|mFocusedApp' || true
adb shell uiautomator dump /sdcard/window.xml >/dev/null
adb exec-out cat /sdcard/window.xml |
  grep -Eo 'text="[^"]*"|bounds="[^"]*"' |
  sed -n '1,260p'
