#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

need_cmd curl
need_cmd repo

tegu_product="$OPENPHONE_ANDROID_DIR/device/google/tegu/lineage_tegu.mk"
tegu_vendor="$OPENPHONE_ANDROID_DIR/vendor/google/tegu/tegu-vendor.mk"
cache_root="${OPENPHONE_BUILD_CACHE_DIR:-$OPENPHONE_ROOT/.worktree/cache}"
vendor_zip="${OPENPHONE_TEGU_VENDOR_ZIP:-}"
vendor_zip_url="${OPENPHONE_TEGU_VENDOR_ZIP_URL:-}"
vendor_zip_sha256="${OPENPHONE_TEGU_VENDOR_ZIP_SHA256:-}"

[[ -f "$OPENPHONE_ANDROID_DIR/build/envsetup.sh" ]] || die "missing build/envsetup.sh; run scripts/sync.sh first"

if [[ ! -f "$tegu_product" ]]; then
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
fi

if [[ -f "$tegu_vendor" ]]; then
  info "Pixel 9a vendor tree already present: $tegu_vendor"
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

info "Extracting Pixel 9a vendor blobs from $vendor_zip"
(
  cd "$OPENPHONE_ANDROID_DIR"
  device/google/tegu/extract-files.py "$vendor_zip"
)

[[ -f "$tegu_vendor" ]] || die "Pixel 9a vendor extraction did not create $tegu_vendor"
info "Pixel 9a vendor tree ready: $tegu_vendor"
