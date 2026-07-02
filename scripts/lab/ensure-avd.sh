#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/common.sh
source "$root/scripts/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/lab/ensure-avd.sh [options]

Creates or refreshes a lab-slot-owned AVD for an installed OpenPhone SDK system
image and records the AVD settings in .worktree/lab/<slot>/env.

Options:
  --slot <name>             Lab slot name. Default: checkout hash.
  --arch arm64|x86_64      Emulator image architecture. Default: host arch.
  --name <avd>             AVD name. Default: OpenPhone_<slot>_<arch>.
  --sdk-root <path>        Android SDK root. Default: ANDROID_SDK_ROOT,
                            ANDROID_HOME, or the host SDK default.
  --force                  Rewrite an existing AVD directory.
  --print                  Print the slot env after updating it.
  -h, --help               Show this help.
EOF
}

detect_emulator_arch() {
  case "$(uname -m)" in
    arm64|aarch64) printf 'arm64' ;;
    x86_64|amd64) printf 'x86_64' ;;
    *) die "unsupported host architecture: $(uname -m). Pass --arch arm64 or --arch x86_64." ;;
  esac
}

default_sdk_root() {
  if [[ -n "${ANDROID_SDK_ROOT:-}" ]]; then
    printf '%s' "$ANDROID_SDK_ROOT"
  elif [[ -n "${ANDROID_HOME:-}" ]]; then
    printf '%s' "$ANDROID_HOME"
  elif [[ "$(uname -s)" == "Darwin" ]]; then
    printf '%s/Library/Android/sdk' "$HOME"
  else
    printf '%s/Android/Sdk' "$HOME"
  fi
}

sanitize_name() {
  python3 - <<'PY' "$1"
import re
import sys

name = re.sub(r"[^A-Za-z0-9_.-]+", "_", sys.argv[1]).strip("._-")
print(name or "OpenPhone")
PY
}

normalize_slot() {
  python3 - <<'PY' "$root" "$1"
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
}

abi_for_arch() {
  case "$1" in
    arm64) printf 'arm64-v8a' ;;
    x86_64) printf 'x86_64' ;;
    *) die "unsupported emulator arch: $1" ;;
  esac
}

cpu_for_arch() {
  case "$1" in
    arm64) printf 'arm64' ;;
    x86_64) printf 'x86_64' ;;
    *) die "unsupported emulator arch: $1" ;;
  esac
}

slot=""
arch=""
avd_name=""
sdk_root="$(default_sdk_root)"
force=false
print_env=false

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
    --name)
      [[ $# -ge 2 ]] || die "--name requires a value"
      avd_name="$2"
      shift 2
      ;;
    --sdk-root)
      [[ $# -ge 2 ]] || die "--sdk-root requires a value"
      sdk_root="$2"
      shift 2
      ;;
    --force)
      force=true
      shift
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

arch="${arch:-$(detect_emulator_arch)}"
case "$arch" in
  arm64|x86_64) ;;
  *) die "unsupported emulator arch: $arch" ;;
esac

slot="$(normalize_slot "$slot")"
"$root/scripts/lab/allocate-slot.sh" --slot "$slot" >/dev/null

env_file="$root/.worktree/lab/$slot/env"
[[ -f "$env_file" ]] || die "missing lab env file: $env_file"
# shellcheck disable=SC1090
source "$env_file"

slot="$OPENPHONE_LAB_SLOT"
abi="$(abi_for_arch "$arch")"
cpu_arch="$(cpu_for_arch "$arch")"
avd_name="${avd_name:-OpenPhone_${slot}_${arch}}"
avd_name="$(sanitize_name "$avd_name")"

image_dir="$sdk_root/system-images/android-36.1/lineage/$abi"
[[ -d "$image_dir" ]] || {
  die "OpenPhone emulator image is not installed: $image_dir
Run scripts/lab/install-emulator-image.sh --arch $arch --zip <sdk-repo-linux-system-images.zip>"
}

avd_home="$OPENPHONE_LAB_DIR/avd"
avd_dir="$avd_home/$avd_name.avd"
ini_file="$avd_home/$avd_name.ini"

mkdir -p "$avd_home"
if [[ "$force" == true ]]; then
  rm -rf "$avd_dir" "$ini_file"
fi
mkdir -p "$avd_dir"

cat > "$ini_file" <<EOF
avd.ini.encoding=UTF-8
path=$avd_dir
target=android-36.1
EOF

cat > "$avd_dir/config.ini" <<EOF
AvdId = $avd_name
PlayStore.enabled = false
abi.type = $abi
avd.ini.displayname = OpenPhone Emulator ($slot)
avd.ini.encoding = UTF-8
disk.dataPartition.size = 6442450944
fastboot.chosenSnapshotFile =
fastboot.forceChosenSnapshotBoot = no
fastboot.forceColdBoot = yes
fastboot.forceFastBoot = no
hw.accelerometer = yes
hw.arc = false
hw.audioInput = yes
hw.battery = yes
hw.camera.back = virtualscene
hw.camera.front = emulated
hw.cpu.arch = $cpu_arch
hw.cpu.ncore = 4
hw.dPad = no
hw.device.hash2 = MD5:3db3250dab5d0d93b29353040181c7e9
hw.device.manufacturer = Generic
hw.device.name = medium_phone
hw.gps = yes
hw.gpu.enabled = yes
hw.gpu.mode = auto
hw.initialOrientation = portrait
hw.keyboard = yes
hw.lcd.density = 420
hw.lcd.height = 2400
hw.lcd.width = 1080
hw.mainKeys = no
hw.ramSize = 2048
hw.sdCard = yes
hw.sensors.orientation = yes
hw.sensors.proximity = yes
hw.trackBall = no
image.sysdir.1 = system-images/android-36.1/lineage/$abi/
runtime.network.latency = none
runtime.network.speed = full
sdcard.size = 512M
showDeviceFrame = no
skin.dynamic = yes
skin.name = 1080x2400
skin.path = _no_skin
skin.path.backup = _no_skin
tag.display = LineageOS
tag.displaynames = LineageOS
tag.id = lineage
tag.ids = lineage
vm.heapSize = 228
EOF

{
  printf 'export ANDROID_SDK_ROOT=%q\n' "$sdk_root"
  printf 'export ANDROID_HOME=%q\n' "$sdk_root"
  printf 'export ANDROID_AVD_HOME=%q\n' "$avd_home"
  printf 'export OPENPHONE_EMULATOR_AVD=%q\n' "$avd_name"
  printf 'export OPENPHONE_EMULATOR_SYSTEM_IMAGE=%q\n' "$image_dir"
} >> "$env_file"

cat <<MSG
OpenPhone lab AVD is ready:
  slot=$slot
  avd=$avd_name
  ANDROID_AVD_HOME=$avd_home
  image=$image_dir
MSG

if [[ "$print_env" == true ]]; then
  cat "$env_file"
fi
