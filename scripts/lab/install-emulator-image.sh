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
  --sha256 <digest|path|url>
                            Expected image SHA-256 digest or sidecar file.
                            If omitted, local <zip>.sha256 and remote
                            <zip-url>.sha256 sidecars are used when present.
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

is_url() {
  case "$1" in
    http://*|https://*) return 0 ;;
    *) return 1 ;;
  esac
}

compute_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    die "missing SHA-256 tool: install sha256sum or shasum"
  fi
}

extract_sha256_digest() {
  grep -Eo '[[:xdigit:]]{64}' "$1" | head -n 1 || true
}

lowercase() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

image_zip=""
sha256_source=""
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
    --sha256)
      [[ $# -ge 2 ]] || die "--sha256 requires a value"
      sha256_source="$2"
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
if is_url "$image_zip"; then
  need_cmd curl
  file_name="${image_zip##*/}"
  file_name="${file_name%%\?*}"
  [[ -n "$file_name" ]] || file_name="sdk-repo-linux-system-images-${arch}.zip"
  image_path="$download_dir/$file_name"
  if [[ "$force" == true || ! -f "$image_path" ]]; then
    info "Downloading OpenPhone emulator image zip"
    curl --fail --location --show-error --output "$image_path" "$image_zip"
  fi
  if [[ -z "$sha256_source" ]]; then
    sidecar_url="${image_zip%%\?*}.sha256"
    sidecar_path="$image_path.sha256"
    if [[ "$force" == true || ! -f "$sidecar_path" ]]; then
      if curl --fail --location --show-error --output "$sidecar_path" "$sidecar_url"; then
        sha256_source="$sidecar_path"
      else
        rm -f "$sidecar_path"
      fi
    else
      sha256_source="$sidecar_path"
    fi
  fi
fi

[[ -f "$image_path" ]] || die "emulator image zip not found: $image_path"

if [[ -z "$sha256_source" && -f "$image_path.sha256" ]]; then
  sha256_source="$image_path.sha256"
fi

if [[ -n "$sha256_source" ]]; then
  if [[ "$sha256_source" =~ ^[[:xdigit:]]{64}$ ]]; then
    expected_sha256="$sha256_source"
  else
    sha256_path="$sha256_source"
    if is_url "$sha256_source"; then
      need_cmd curl
      sha256_name="${sha256_source##*/}"
      sha256_name="${sha256_name%%\?*}"
      [[ -n "$sha256_name" ]] || sha256_name="${file_name:-$(basename "$image_path")}.sha256"
      sha256_path="$download_dir/$sha256_name"
      if [[ "$force" == true || ! -f "$sha256_path" ]]; then
        info "Downloading OpenPhone emulator image checksum"
        curl --fail --location --show-error --output "$sha256_path" "$sha256_source"
      fi
    fi
    [[ -f "$sha256_path" ]] || die "checksum file not found: $sha256_source"
    expected_sha256="$(extract_sha256_digest "$sha256_path")"
    [[ -n "$expected_sha256" ]] || die "checksum file does not contain a SHA-256 digest: $sha256_source"
  fi

  actual_sha256="$(compute_sha256 "$image_path")"
  if [[ "$(lowercase "$actual_sha256")" != "$(lowercase "$expected_sha256")" ]]; then
    die "checksum mismatch for $image_path: expected $expected_sha256, got $actual_sha256"
  fi
  info "Verified OpenPhone emulator image SHA-256"
elif is_url "$image_zip"; then
  die "remote emulator image requires a SHA-256 checksum: pass --sha256 or publish ${image_zip%%\?*}.sha256"
else
  info "No SHA-256 checksum supplied for local emulator image"
fi

if command -v bsdtar >/dev/null 2>&1; then
  extractor="bsdtar"
elif command -v unzip >/dev/null 2>&1; then
  extractor="unzip"
else
  die "missing extractor: install bsdtar or unzip"
fi

install_root="$sdk_root/system-images/android-36.1/lineage"
target_dir="$install_root/$abi"
digest_file=".openphone-image-sha256"
requested_sha256="$(compute_sha256 "$image_path")"

mkdir -p "$install_root"

tmp=""
staging_dir=""
lock_dir="$install_root/.${abi}.install.lock"
lock_acquired=false
cleanup() {
  rm -rf "$tmp" "$staging_dir"
  if [[ "$lock_acquired" == true ]]; then
    rmdir "$lock_dir" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

info "Acquiring OpenPhone emulator image install lock"
deadline=$((SECONDS + 300))
while ! mkdir "$lock_dir" 2>/dev/null; do
  if [[ "$SECONDS" -ge "$deadline" ]]; then
    die "timed out waiting for install lock: $lock_dir"
  fi
  sleep 1
done
lock_acquired=true

if [[ -d "$target_dir" && "$force" != true ]]; then
  installed_sha256=""
  if [[ -f "$target_dir/$digest_file" ]]; then
    installed_sha256="$(extract_sha256_digest "$target_dir/$digest_file")"
  fi

  if [[ -n "$installed_sha256" && "$(lowercase "$installed_sha256")" == "$(lowercase "$requested_sha256")" ]]; then
    info "OpenPhone emulator image already installed with matching SHA-256: $target_dir"
  elif [[ -z "$installed_sha256" ]]; then
    die "OpenPhone emulator image already exists without a recorded SHA-256: $target_dir; rerun with --force to replace it"
  else
    die "OpenPhone emulator image already exists with different SHA-256: $target_dir; rerun with --force to replace it"
  fi
else
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/openphone-emulator-image.XXXXXX")"

  info "Extracting OpenPhone emulator image zip"
  case "$extractor" in
    bsdtar) bsdtar -xf "$image_path" -C "$tmp" ;;
    unzip) unzip -q "$image_path" -d "$tmp" ;;
    *) die "unsupported extractor: $extractor" ;;
  esac

  candidate="$tmp/$abi"
  if [[ ! -d "$candidate" ]]; then
    candidate="$(find "$tmp" -type d -name "$abi" -print | sed -n '1p')"
  fi
  [[ -n "$candidate" && -d "$candidate" ]] \
    || die "image zip did not contain expected ABI directory: $abi"

  staging_dir="$(mktemp -d "$install_root/.${abi}.install.XXXXXX")"
  rm -rf "$staging_dir"
  cp -R "$candidate" "$staging_dir"
  printf '%s  %s\n' "$requested_sha256" "$(basename "$image_path")" \
    > "$staging_dir/$digest_file"

  rm -rf "$target_dir"
  mv "$staging_dir" "$target_dir"
  staging_dir=""
fi

[[ -d "$target_dir" ]] || die "failed to install emulator image: $target_dir"

cat <<MSG
OpenPhone emulator image installed:
  ANDROID_SDK_ROOT=$sdk_root
  ABI=$abi
  system_image=$target_dir
MSG
