#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$root/scripts/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/configure-silent-speech-camera-demo.sh --url <https-url> [token option]

Configures the temporary on-device Silent Speech camera demo without placing
the decoder credential in the APK, repository, shell argv, or Android intent.

Token options (choose one):
  --token-stdin          Read the bearer token from stdin.
  --token-file <path>    Read the bearer token from a local file.
  --token-env <name>     Read the bearer token from an environment variable.

Other options:
  --serial <adb-serial>  Select a connected OpenPhone device.
  -h, --help             Show this help.
EOF
}

url=""
token_source=""
token_value=""
serial="${ANDROID_SERIAL:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)
      [[ $# -ge 2 ]] || die "--url requires a value"
      url="$2"
      shift 2
      ;;
    --token-stdin)
      [[ -z "$token_source" ]] || die "choose only one token source"
      token_source="stdin"
      shift
      ;;
    --token-file)
      [[ $# -ge 2 ]] || die "--token-file requires a value"
      [[ -z "$token_source" ]] || die "choose only one token source"
      token_source="file"
      token_value="$2"
      shift 2
      ;;
    --token-env)
      [[ $# -ge 2 ]] || die "--token-env requires a value"
      [[ -z "$token_source" ]] || die "choose only one token source"
      token_source="env"
      token_value="$2"
      shift 2
      ;;
    --serial)
      [[ $# -ge 2 ]] || die "--serial requires a value"
      serial="$2"
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

[[ "$url" == https://* ]] || die "--url must use HTTPS"
[[ -n "$token_source" ]] || die "choose a token source"

case "$token_source" in
  stdin)
    IFS= read -r token || true
    ;;
  file)
    [[ -f "$token_value" ]] || die "token file does not exist: $token_value"
    token="$(tr -d '\r\n' < "$token_value")"
    ;;
  env)
    token="${!token_value:-}"
    ;;
esac
[[ -n "${token:-}" ]] || die "the bearer token is empty"
[[ "$token" != *$'\n'* && "$token" != *$'\r'* ]] || die "the bearer token must be one line"

need_cmd adb
adb_cmd=(adb)
if [[ -n "$serial" ]]; then
  adb_cmd+=(-s "$serial")
fi
"${adb_cmd[@]}" wait-for-device >/dev/null

build_type="$("${adb_cmd[@]}" shell getprop ro.build.type | tr -d '\r')"
case "$build_type" in
  userdebug|eng) ;;
  *) die "the temporary camera demo requires an OpenPhone userdebug/eng build" ;;
esac

"${adb_cmd[@]}" shell settings put secure \
  openphone_silent_speech_decode_url "$url"
printf '%s\n' "$token" |
  "${adb_cmd[@]}" shell \
    'IFS= read -r token; settings put secure openphone_silent_speech_bearer_token "$token"'

printf 'Configured the on-device Silent Speech camera demo.\n'
