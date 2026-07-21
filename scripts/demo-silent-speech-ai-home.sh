#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$root/scripts/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/demo-silent-speech-ai-home.sh [options]

Injects a decoded Silent Speech transcript into OpenPhone AI Home and runs it
through the normal agent and phone-action approval path.

Input (choose one):
  --text <text>            Use a transcript directly.
  --response-file <path>   Read a /v1/decode JSON response from a file.
  stdin                    Read a /v1/decode JSON response or plain text.

Options:
  --serial <adb-serial>    Select a connected OpenPhone device.
  --wait <seconds>         Wait before showing UI state. Defaults to 3.
  --dry-run                Validate input and print the adb target only.
  -h, --help               Show this help.

Examples:
  scripts/demo-silent-speech-ai-home.sh --text "Call mom"
  curl <authenticated-/v1/decode-request> | scripts/demo-silent-speech-ai-home.sh
  scripts/demo-silent-speech-ai-home.sh --response-file /tmp/decode.json

This is a temporary demo harness. The intent hook is ignored on production
user builds, and no Silent Speech or model credentials are stored by it.
EOF
}

text_input=""
response_file=""
serial="${ANDROID_SERIAL:-}"
wait_seconds=3
dry_run=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --text)
      [[ $# -ge 2 ]] || die "--text requires a value"
      text_input="$2"
      shift 2
      ;;
    --response-file)
      [[ $# -ge 2 ]] || die "--response-file requires a value"
      response_file="$2"
      shift 2
      ;;
    --serial)
      [[ $# -ge 2 ]] || die "--serial requires a value"
      serial="$2"
      shift 2
      ;;
    --wait)
      [[ $# -ge 2 ]] || die "--wait requires a value"
      wait_seconds="$2"
      shift 2
      ;;
    --dry-run)
      dry_run=true
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

[[ "$wait_seconds" =~ ^[0-9]+$ ]] || die "--wait must be an integer number of seconds"
[[ -z "$text_input" || -z "$response_file" ]] || die "choose only one input source"

need_cmd python3

if [[ -n "$text_input" ]]; then
  payload="$text_input"
elif [[ -n "$response_file" ]]; then
  [[ -f "$response_file" ]] || die "response file does not exist: $response_file"
  payload="$(<"$response_file")"
elif [[ ! -t 0 ]]; then
  payload="$(cat)"
else
  usage >&2
  exit 2
fi

transcript_b64="$({ python3 - "$payload" <<'PY'
import base64
import json
import sys

payload = sys.argv[1].strip()
if not payload:
    raise SystemExit("Silent Speech returned an empty response")

if payload.startswith(("{", "[")):
    try:
        decoded = json.loads(payload)
    except json.JSONDecodeError as error:
        raise SystemExit(f"Silent Speech returned invalid JSON: {error.msg}") from error
    if not isinstance(decoded, dict) or not isinstance(decoded.get("text"), str):
        raise SystemExit("Silent Speech response is missing its text field")
    transcript = decoded["text"].strip()
else:
    transcript = payload

if not transcript:
    raise SystemExit("Silent Speech returned an empty transcript")
if len(transcript) > 4096:
    raise SystemExit("Silent Speech transcript exceeds the 4096-character demo limit")
if "\x00" in transcript:
    raise SystemExit("Silent Speech transcript contains a NUL character")

print(base64.b64encode(transcript.encode("utf-8")).decode("ascii"))
PY
  } 2>&1)" || die "$transcript_b64"

if [[ "$dry_run" == true ]]; then
  printf 'Validated Silent Speech transcript for OpenPhone AI Home (dry run).\n'
  exit 0
fi

need_cmd adb

adb_cmd=(adb)
if [[ -n "$serial" ]]; then
  adb_cmd+=(-s "$serial")
fi

"${adb_cmd[@]}" wait-for-device >/dev/null

build_type="$("${adb_cmd[@]}" shell getprop ro.build.type | tr -d '\r')"
case "$build_type" in
  userdebug|eng) ;;
  *) die "the temporary Silent Speech hook requires an OpenPhone userdebug/eng build (found: ${build_type:-unknown})" ;;
esac

"${adb_cmd[@]}" shell pm path org.openphone.assistant >/dev/null 2>&1 ||
  die "OpenPhone Assistant is not installed on the selected device"

"${adb_cmd[@]}" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
"${adb_cmd[@]}" shell wm dismiss-keyguard >/dev/null 2>&1 || true

"${adb_cmd[@]}" shell am start \
  -W \
  -n org.openphone.assistant/.OpenPhoneHomeActivity \
  -f 0x24000000 \
  --es org.openphone.assistant.extra.GOAL_BASE64 "$transcript_b64" \
  --es org.openphone.assistant.extra.INPUT_SOURCE silent_speech \
  --ez org.openphone.assistant.extra.RUN true

if [[ "$wait_seconds" -gt 0 ]]; then
  sleep "$wait_seconds"
fi

printf 'Sent Silent Speech transcript to OpenPhone AI Home.\n'
"${adb_cmd[@]}" shell dumpsys window |
  grep -E 'mCurrentFocus|mFocusedApp' || true
