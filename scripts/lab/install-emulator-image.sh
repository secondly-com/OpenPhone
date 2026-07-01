#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/common.sh
source "$root/scripts/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/lab/install-emulator-image.sh --zip <path-or-url> [options]

Installs a portable OpenPhone SDK emulator system image zip into the local
Android SDK. This is the Mac Studio / workstation path: Linux or GCP builds the
image zip, and local Codex lab slots boot it without syncing/building Android.

Options:
  --zip <path-or-url>       sdk-repo-linux-system-images.zip path or URL.
  --arch arm64|x86_64      Emulator image architecture. Default: host arch.
  --sdk-root <path>        Android SDK root. Default: ANDROID_SDK_ROOT,
                            ANDROID_HOME, or the host SDK default.
  --force                  Replace an already installed image.
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

abi_for_arch() {
  case "$1" in
    arm64) printf 'arm64-v8a' ;;
    x86_64) printf 'x86_64' ;;
    *) die "unsupported emulator arch: $1" ;;
  esac
}

image_zip=""
arch=""
sdk_root="$(default_sdk_root)"
force=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --zip)
      [[ $# -ge 2 ]] || die "--zip requires a value"
      image_zip="$2"
      shift 2
      ;;
    --arch)
      [[ $# -ge 2 ]] || die "--arch requires a value"
      arch="$2"
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
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n "$image_zip" ]] || die "--zip is required"
arch="${arch:-$(detect_emulator_arch)}"
abi="$(abi_for_arch "$arch")"

case "$arch" in
  arm64|x86_64) ;;
  *) die "unsupported emulator arch: $arch" ;;
esac

download_dir="$root/.worktree/emulator-images"
mkdir -p "$download_dir"

image_path="$image_zip"
case "$image_zip" in
  http://*|https://*)
    need_cmd curl
    file_name="${image_zip##*/}"
    file_name="${file_name%%\?*}"
    [[ -n "$file_name" ]] || file_name="sdk-repo-linux-system-images-${arch}.zip"
    image_path="$download_dir/$file_name"
    if [[ "$force" == true || ! -f "$image_path" ]]; then
      info "Downloading OpenPhone emulator image zip"
      curl --fail --location --show-error --output "$image_path" "$image_zip"
    fi
    ;;
esac

[[ -f "$image_path" ]] || die "emulator image zip not found: $image_path"

if command -v bsdtar >/dev/null 2>&1; then
  extractor="bsdtar"
elif command -v unzip >/dev/null 2>&1; then
  extractor="unzip"
else
  die "missing extractor: install bsdtar or unzip"
fi

install_root="$sdk_root/system-images/android-36.1/lineage"
target_dir="$install_root/$abi"

if [[ -d "$target_dir" && "$force" != true ]]; then
  info "OpenPhone emulator image already installed: $target_dir"
else
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/openphone-emulator-image.XXXXXX")"
  cleanup_tmp() {
    rm -rf "$tmp"
  }
  trap cleanup_tmp EXIT

  info "Extracting OpenPhone emulator image zip"
  case "$extractor" in
    bsdtar) bsdtar -xf "$image_path" -C "$tmp" ;;
    unzip) unzip -q "$image_path" -d "$tmp" ;;
    *) die "unsupported extractor: $extractor" ;;
  esac

  candidate="$tmp/$abi"
  if [[ ! -d "$candidate" ]]; then
    candidate="$(find "$tmp" -type d -name "$abi" -print -quit)"
  fi
  [[ -n "$candidate" && -d "$candidate" ]] \
    || die "image zip did not contain expected ABI directory: $abi"

  mkdir -p "$install_root"
  rm -rf "$target_dir"
  cp -R "$candidate" "$target_dir"
  rm -rf "$tmp"
  trap - EXIT
fi

[[ -d "$target_dir" ]] || die "failed to install emulator image: $target_dir"

cat <<MSG
OpenPhone emulator image installed:
  ANDROID_SDK_ROOT=$sdk_root
  ABI=$abi
  system_image=$target_dir
MSG
