#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/lab/install-android-sdk-tools.sh [options]

Installs the Android SDK command-line tools, platform-tools, and emulator.

Options:
  --sdk-root <path>        SDK install root. Default: ANDROID_SDK_ROOT,
                           ANDROID_HOME, or /opt/android-sdk.
  -h, --help              Show this help.
EOF
}

sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-/opt/android-sdk}}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sdk-root)
      [[ $# -ge 2 ]] || {
        printf 'error: --sdk-root requires a value\n' >&2
        exit 1
      }
      sdk_root="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'error: unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ "$(id -u)" -ne 0 ]]; then
  exec sudo -E bash "$0" --sdk-root "$sdk_root"
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'error: missing required command: %s\n' "$1" >&2
    exit 1
  }
}

host_os() {
  case "$(uname -s)" in
    Linux) printf 'linux' ;;
    Darwin) printf 'macosx' ;;
    *) printf 'error: unsupported host OS: %s\n' "$(uname -s)" >&2; exit 1 ;;
  esac
}

need_cmd curl
need_cmd python3
need_cmd unzip

sdk_root="${sdk_root%/}"
install -d -m 0755 "$sdk_root/cmdline-tools"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/openphone-android-sdk.XXXXXX")"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

cmdline_tools_url="$(
  python3 - "$(host_os)" <<'PY'
import sys
import urllib.request
import xml.etree.ElementTree as ET

host_os = sys.argv[1]
base_url = "https://dl.google.com/android/repository/"
with urllib.request.urlopen(base_url + "repository2-1.xml", timeout=60) as response:
    root = ET.fromstring(response.read())

for package in root.findall("remotePackage"):
    if package.attrib.get("path") != "cmdline-tools;latest":
        continue
    for archive in package.findall("./archives/archive"):
        if archive.findtext("host-os") != host_os:
            continue
        url = archive.findtext("./complete/url")
        if not url:
            continue
        print(base_url + url)
        raise SystemExit(0)

raise SystemExit(f"no cmdline-tools;latest archive found for {host_os}")
PY
)"

curl -fL --retry 3 --retry-delay 2 \
  "$cmdline_tools_url" \
  -o "$tmp_dir/cmdline-tools.zip"
unzip -q "$tmp_dir/cmdline-tools.zip" -d "$tmp_dir"

rm -rf "$sdk_root/cmdline-tools/latest"
mv "$tmp_dir/cmdline-tools" "$sdk_root/cmdline-tools/latest"

sdkmanager="$sdk_root/cmdline-tools/latest/bin/sdkmanager"
{ yes || true; } | "$sdkmanager" --sdk_root="$sdk_root" --licenses >/dev/null
{ yes || true; } | "$sdkmanager" --sdk_root="$sdk_root" --install \
  "platform-tools" \
  "emulator"
{ yes || true; } | "$sdkmanager" --sdk_root="$sdk_root" --licenses >/dev/null

ln -sf "$sdk_root/platform-tools/adb" /usr/local/bin/adb
ln -sf "$sdk_root/emulator/emulator" /usr/local/bin/emulator

cat > /etc/profile.d/openphone-android-sdk.sh <<EOF
export ANDROID_SDK_ROOT="$sdk_root"
export ANDROID_HOME="$sdk_root"
export PATH="$sdk_root/platform-tools:$sdk_root/emulator:$sdk_root/cmdline-tools/latest/bin:\$PATH"
EOF

printf 'OpenPhone Android SDK tools installed at %s\n' "$sdk_root"
