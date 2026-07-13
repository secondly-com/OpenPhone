#!/usr/bin/env bash

set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"
export PATH="/opt/homebrew/opt/coreutils/libexec/gnubin:/usr/local/opt/coreutils/libexec/gnubin:$PATH"
if [[ "$(uname -s)" == "Darwin" && -x /opt/homebrew/opt/openjdk@17/bin/java ]] \
  && { [[ -z "${JAVA_HOME:-}" ]] || [[ "${JAVA_HOME:-}" == /opt/homebrew/opt/openjdk/* ]]; }; then
  export JAVA_HOME="/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home"
  export PATH="/opt/homebrew/opt/openjdk@17/bin:$PATH"
fi

OPENPHONE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPENPHONE_ANDROID_DIR="${OPENPHONE_ANDROID_DIR:-$OPENPHONE_ROOT/.worktree/android}"
LINEAGE_MANIFEST_URL="${LINEAGE_MANIFEST_URL:-https://github.com/LineageOS/android.git}"
LINEAGE_BRANCH="${LINEAGE_BRANCH:-lineage-23.2}"
OPENPHONE_RELEASE="${OPENPHONE_RELEASE:-bp4a}"
OPENPHONE_TEGU_DTB_SHA256="${OPENPHONE_TEGU_DTB_SHA256:-f1aed2bc4c07d3cb1e610f5227a566f22e995dfe05341ca6bf14805be6928688}"

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

info() {
  printf '==> %s\n' "$*"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

need_gnu_coreutils_on_macos() {
  if [[ "$(uname -s)" == "Darwin" ]] && ! date -d @0 +%s >/dev/null 2>&1; then
    die "GNU coreutils are required on macOS. Install with: brew install coreutils"
  fi
}

android_path_for_patch_dir() {
  case "$1" in
    frameworks_base) printf 'frameworks/base' ;;
    frameworks_native) printf 'frameworks/native' ;;
    frameworks_proto_logging) printf 'frameworks/proto_logging' ;;
    packages_apps_Settings) printf 'packages/apps/Settings' ;;
    packages_apps_SystemUI) printf 'packages/apps/SystemUI' ;;
    vendor_lineage) printf 'vendor/lineage' ;;
    *)
      printf '%s' "${1//_//}"
      ;;
  esac
}

ensure_android_dir() {
  mkdir -p "$OPENPHONE_ANDROID_DIR"
}

is_case_sensitive_dir() {
  local dir="$1"
  local probe
  probe="$(mktemp -d "$dir/.openphone-case-test.XXXXXX")"
  touch "$probe/case"
  if [[ -e "$probe/CASE" ]]; then
    rm -rf "$probe"
    return 1
  fi
  rm -rf "$probe"
  return 0
}

is_tegu_product() {
  case "$1" in
    openphone_tegu|openphone_tegu_smoke) return 0 ;;
    *) return 1 ;;
  esac
}

build_goals_need_target_files() {
  local goal
  for goal in "$@"; do
    case "$goal" in
      droid|bacon|dist|target-files-package|otapackage) return 0 ;;
    esac
  done
  return 1
}

tegu_kernel_dir() {
  printf '%s/device/google/tegu-kernels/6.1' "$OPENPHONE_ANDROID_DIR"
}

tegu_unpack_bootimg() {
  printf '%s/out/host/linux-x86/bin/unpack_bootimg' "$OPENPHONE_ANDROID_DIR"
}

ensure_tegu_boot_prebuilt() {
  local kernel_dir boot_image
  kernel_dir="$(tegu_kernel_dir)"
  boot_image="$kernel_dir/boot.img"

  [[ -s "$boot_image" ]] || {
    die "missing Pixel 9a prebuilt boot image: $boot_image; run scripts/prepare-tegu-device-repos.sh before building target-files"
  }

  info "Pixel 9a prebuilt boot image ready: $boot_image"
}

file_sha256() {
  local path="$1"
  sha256sum "$path" | awk '{print $1}'
}

ensure_tegu_dtb() {
  local kernel_dir prebuilt_image target_dtb unpack_tool tmp actual stray
  kernel_dir="$(tegu_kernel_dir)"
  prebuilt_image="$kernel_dir/vendor_kernel_boot.img"
  target_dtb="$kernel_dir/tegu.dtb"
  unpack_tool="$(tegu_unpack_bootimg)"

  [[ -f "$prebuilt_image" ]] || die "missing Pixel 9a prebuilt vendor_kernel_boot image: $prebuilt_image"
  [[ -x "$unpack_tool" ]] || die "missing unpack_bootimg tool: $unpack_tool"

  # The vendor_kernel_boot rule concatenates EVERY *.dtb in this directory, so
  # stray per-SoC DTBs (zumapro-*.dtb, dropped by kernel prebuilt updates)
  # double the image and fail the pinned-hash verification at the very end of
  # the build. Remove anything that is not the pinned tegu.dtb.
  for stray in "$kernel_dir"/*.dtb; do
    [[ -e "$stray" ]] || continue
    [[ "$stray" == "$target_dtb" ]] && continue
    info "Removing stray DTB (would corrupt vendor_kernel_boot): $stray"
    rm -f "$stray"
  done

  if [[ -f "$target_dtb" ]]; then
    actual="$(file_sha256 "$target_dtb")"
    if [[ "$actual" == "$OPENPHONE_TEGU_DTB_SHA256" ]]; then
      info "Pixel 9a DTB already prepared: $target_dtb"
      return 0
    fi
    info "Pixel 9a DTB hash mismatch; regenerating $target_dtb"
  fi

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/openphone-tegu-dtb.XXXXXX")"
  "$unpack_tool" --boot_img "$prebuilt_image" --out "$tmp" >/dev/null
  [[ -s "$tmp/dtb" ]] || {
    rm -rf "$tmp"
    die "failed to extract non-empty Pixel 9a DTB from $prebuilt_image"
  }
  cp "$tmp/dtb" "$target_dtb"
  rm -rf "$tmp"

  actual="$(file_sha256 "$target_dtb")"
  [[ "$actual" == "$OPENPHONE_TEGU_DTB_SHA256" ]] || {
    rm -f "$target_dtb"
    die "Pixel 9a DTB hash mismatch: got $actual expected $OPENPHONE_TEGU_DTB_SHA256"
  }

  info "Prepared Pixel 9a DTB: $target_dtb"
}

verify_tegu_vendor_kernel_boot() {
  local product image unpack_tool tmp zip actual
  product="$1"
  unpack_tool="$(tegu_unpack_bootimg)"
  image="$OPENPHONE_ANDROID_DIR/out/target/product/tegu/obj/PACKAGING/target_files_intermediates/${product}-target_files/IMAGES/vendor_kernel_boot.img"
  zip="$OPENPHONE_ANDROID_DIR/out/target/product/tegu/obj/PACKAGING/target_files_intermediates/${product}-target_files.zip"

  [[ -x "$unpack_tool" ]] || die "missing unpack_bootimg tool: $unpack_tool"

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/openphone-tegu-vkb.XXXXXX")"
  if [[ -f "$image" ]]; then
    cp "$image" "$tmp/vendor_kernel_boot.img"
  elif [[ -f "$zip" ]]; then
    need_cmd unzip
    unzip -p "$zip" IMAGES/vendor_kernel_boot.img >"$tmp/vendor_kernel_boot.img"
  else
    rm -rf "$tmp"
    die "cannot find generated vendor_kernel_boot image for $product"
  fi

  "$unpack_tool" --boot_img "$tmp/vendor_kernel_boot.img" --out "$tmp/unpacked" >/dev/null
  [[ -s "$tmp/unpacked/dtb" ]] || {
    rm -rf "$tmp"
    die "generated vendor_kernel_boot for $product has an empty DTB"
  }

  actual="$(file_sha256 "$tmp/unpacked/dtb")"
  rm -rf "$tmp"
  [[ "$actual" == "$OPENPHONE_TEGU_DTB_SHA256" ]] || {
    die "generated vendor_kernel_boot DTB hash mismatch for $product: got $actual expected $OPENPHONE_TEGU_DTB_SHA256"
  }

  info "Verified generated Pixel 9a vendor_kernel_boot DTB for $product"
}
