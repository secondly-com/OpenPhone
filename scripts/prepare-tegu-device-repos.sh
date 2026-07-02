#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

need_cmd curl
need_cmd repo
need_cmd unzip

tegu_product="$OPENPHONE_ANDROID_DIR/device/google/tegu/lineage_tegu.mk"
tegu_vendor="$OPENPHONE_ANDROID_DIR/vendor/google/tegu/tegu-vendor.mk"
tegu_kernel_dir="$OPENPHONE_ANDROID_DIR/device/google/tegu-kernels/6.1"
tegu_kernel_image="$tegu_kernel_dir/vendor_kernel_boot.img"
cache_root="${OPENPHONE_BUILD_CACHE_DIR:-$OPENPHONE_ROOT/.worktree/cache}"
vendor_zip="${OPENPHONE_TEGU_VENDOR_ZIP:-}"
vendor_zip_url="${OPENPHONE_TEGU_VENDOR_ZIP_URL:-}"
vendor_zip_sha256="${OPENPHONE_TEGU_VENDOR_ZIP_SHA256:-}"

[[ -f "$OPENPHONE_ANDROID_DIR/build/envsetup.sh" ]] || die "missing build/envsetup.sh; run scripts/sync.sh first"

extract_tegu_vendor_kernel_boot() {
  local source_zip="$1"
  local target="$2"
  local extractor image_cache raw_image_path tmp payload image_tmp

  mkdir -p "$cache_root/tegu" "$(dirname "$target")"
  image_cache="$cache_root/tegu/${source_zip##*/}"
  image_cache="${image_cache%.zip}-vendor_kernel_boot.img"

  if [[ ! -s "$image_cache" ]]; then
    extractor="$OPENPHONE_ANDROID_DIR/prebuilts/extract-tools/linux-x86/bin/ota_extractor"
    [[ -x "$extractor" ]] || {
      die "missing OTA payload extractor: $extractor"
    }

    tmp="$(mktemp -d "${TMPDIR:-/tmp}/openphone-tegu-vkb.XXXXXX")"
    image_tmp="$tmp/vendor_kernel_boot.img"

    raw_image_path="$(unzip -Z1 "$source_zip" | grep -E '(^|/)vendor_kernel_boot\.img$' | head -n 1 || true)"
    if [[ -n "$raw_image_path" ]]; then
      info "Extracting Pixel 9a vendor_kernel_boot image from $raw_image_path"
      if ! unzip -p "$source_zip" "$raw_image_path" >"$image_tmp"; then
        rm -rf "$tmp"
        die "failed to extract $raw_image_path from $source_zip"
      fi
    else
      info "Extracting Pixel 9a vendor_kernel_boot image from OTA payload"
      payload="$tmp/payload.bin"
      if ! unzip -p "$source_zip" payload.bin >"$payload"; then
        rm -rf "$tmp"
        die "failed to extract payload.bin from $source_zip"
      fi
      if ! "$extractor" \
        --payload "$payload" \
        --output-dir "$tmp" \
        --partitions vendor_kernel_boot; then
        rm -rf "$tmp"
        die "failed to extract vendor_kernel_boot from OTA payload"
      fi
    fi

    [[ -s "$image_tmp" ]] || {
      rm -rf "$tmp"
      die "Pixel 9a vendor_kernel_boot extraction produced no image"
    }

    mv "$image_tmp" "$image_cache"
    rm -rf "$tmp"
  else
    info "Using cached Pixel 9a vendor_kernel_boot image: $image_cache"
  fi

  cp "$image_cache" "$target"
  [[ -s "$target" ]] || die "Pixel 9a vendor_kernel_boot image not created: $target"
}

if [[ ! -f "$tegu_product" || ! -d "$tegu_kernel_dir" ]]; then
  info "Preparing Pixel 9a Lineage device repositories with breakfast tegu"
  set +e
  (
    cd "$OPENPHONE_ANDROID_DIR"
    set +u
    # shellcheck disable=SC1091
    source build/envsetup.sh
    breakfast tegu
  )
  breakfast_status=$?
  set -e

  [[ -f "$tegu_product" ]] || {
    die "breakfast tegu did not fetch device/google/tegu; exit status: $breakfast_status"
  }
  [[ -d "$tegu_kernel_dir" ]] || {
    die "breakfast tegu did not fetch device/google/tegu-kernels; exit status: $breakfast_status"
  }
fi

if [[ -f "$tegu_vendor" && -f "$tegu_kernel_image" ]]; then
  info "Pixel 9a vendor tree already present: $tegu_vendor"
  info "Pixel 9a vendor_kernel_boot image already present: $tegu_kernel_image"
  exit 0
fi

if [[ -z "$vendor_zip" ]]; then
  [[ -n "$vendor_zip_url" ]] || {
    die "Pixel 9a vendor blobs missing. Set OPENPHONE_TEGU_VENDOR_ZIP or OPENPHONE_TEGU_VENDOR_ZIP_URL plus OPENPHONE_TEGU_VENDOR_ZIP_SHA256."
  }
  [[ -n "$vendor_zip_sha256" ]] || die "OPENPHONE_TEGU_VENDOR_ZIP_SHA256 is required when downloading Pixel 9a vendor blobs"

  mkdir -p "$cache_root/tegu"
  vendor_zip="$cache_root/tegu/${vendor_zip_url##*/}"
  if [[ ! -f "$vendor_zip" ]]; then
    info "Downloading Pixel 9a vendor source zip: $vendor_zip_url"
    curl -L --fail --retry 5 --retry-delay 5 -o "$vendor_zip" "$vendor_zip_url"
  else
    info "Using cached Pixel 9a vendor source zip: $vendor_zip"
  fi
fi

[[ -f "$vendor_zip" ]] || die "Pixel 9a vendor source zip not found: $vendor_zip"

if [[ -n "$vendor_zip_sha256" ]]; then
  actual="$(file_sha256 "$vendor_zip")"
  [[ "$actual" == "$vendor_zip_sha256" ]] || {
    rm -f "$vendor_zip"
    die "Pixel 9a vendor source zip SHA256 mismatch: got $actual expected $vendor_zip_sha256"
  }
fi

if [[ ! -f "$tegu_vendor" ]]; then
  info "Extracting Pixel 9a vendor blobs from $vendor_zip"
  (
    cd "$OPENPHONE_ANDROID_DIR"
    device/google/tegu/extract-files.py "$vendor_zip"
  )
else
  info "Pixel 9a vendor tree already present: $tegu_vendor"
fi

if [[ ! -f "$tegu_kernel_image" ]]; then
  extract_tegu_vendor_kernel_boot "$vendor_zip" "$tegu_kernel_image"
else
  info "Pixel 9a vendor_kernel_boot image already present: $tegu_kernel_image"
fi

[[ -f "$tegu_vendor" ]] || die "Pixel 9a vendor extraction did not create $tegu_vendor"
[[ -f "$tegu_kernel_image" ]] || die "Pixel 9a vendor_kernel_boot extraction did not create $tegu_kernel_image"
info "Pixel 9a vendor tree ready: $tegu_vendor"
info "Pixel 9a vendor_kernel_boot image ready: $tegu_kernel_image"
