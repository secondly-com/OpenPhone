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

tegu_kernel_module_lists=(
  vendor_kernel_boot.modules.load
  system_dlkm.modules.load
  vendor_dlkm.modules.load
)

tegu_missing_kernel_modules=()

collect_tegu_missing_kernel_modules() {
  local list_file module module_name

  tegu_missing_kernel_modules=()
  for list_file in "${tegu_kernel_module_lists[@]}"; do
    [[ -f "$tegu_kernel_dir/$list_file" ]] || die "missing Pixel 9a kernel module list: $tegu_kernel_dir/$list_file"
    while IFS= read -r module || [[ -n "$module" ]]; do
      module="${module%%#*}"
      module="${module//[[:space:]]/}"
      [[ -n "$module" ]] || continue
      module_name="${module##*/}"
      [[ -s "$tegu_kernel_dir/$module_name" ]] || tegu_missing_kernel_modules+=("$module_name")
    done <"$tegu_kernel_dir/$list_file"
  done
}

tegu_kernel_modules_ready() {
  collect_tegu_missing_kernel_modules
  ((${#tegu_missing_kernel_modules[@]} == 0))
}

extract_tegu_ota_partition() {
  local source_zip="$1"
  local partition="$2"
  local target="$3"
  local extractor raw_image_path tmp payload image_tmp

  mkdir -p "$(dirname "$target")"
  if [[ -s "$target" ]]; then
    return 0
  fi

  raw_image_path="$(unzip -Z1 "$source_zip" | grep -E "(^|/)${partition}[.]img$" | head -n 1 || true)"
  if [[ -n "$raw_image_path" ]]; then
    info "Extracting Pixel 9a $partition image from $raw_image_path"
    if ! unzip -p "$source_zip" "$raw_image_path" >"$target"; then
      rm -f "$target"
      die "failed to extract $raw_image_path from $source_zip"
    fi
  else
    extractor="$OPENPHONE_ANDROID_DIR/prebuilts/extract-tools/linux-x86/bin/ota_extractor"
    [[ -x "$extractor" ]] || die "missing OTA payload extractor: $extractor"

    tmp="$(mktemp -d "${TMPDIR:-/tmp}/openphone-tegu-${partition}.XXXXXX")"
    payload="$tmp/payload.bin"
    image_tmp="$tmp/${partition}.img"

    info "Extracting Pixel 9a $partition image from OTA payload"
    if ! unzip -p "$source_zip" payload.bin >"$payload"; then
      rm -rf "$tmp"
      die "failed to extract payload.bin from $source_zip"
    fi
    if ! "$extractor" \
      --payload "$payload" \
      --output-dir "$tmp" \
      --partitions "$partition"; then
      rm -rf "$tmp"
      die "failed to extract $partition from OTA payload"
    fi
    [[ -s "$image_tmp" ]] || {
      rm -rf "$tmp"
      die "Pixel 9a $partition extraction produced no image"
    }
    mv "$image_tmp" "$target"
    rm -rf "$tmp"
  fi

  [[ -s "$target" ]] || die "Pixel 9a $partition image not created: $target"
}

copy_tegu_modules_from_dump() {
  local dump_root="$1"
  local modules_list="$2"
  local source_label="$3"
  local module module_name source

  [[ -d "$dump_root" ]] || die "missing Pixel 9a kernel module dump: $dump_root"

  while IFS= read -r module || [[ -n "$module" ]]; do
    module="${module%%#*}"
    module="${module//[[:space:]]/}"
    [[ -n "$module" ]] || continue
    module_name="${module##*/}"
    [[ -s "$tegu_kernel_dir/$module_name" ]] && continue

    source="$(find "$dump_root" \( -type f -o -type l \) -name "$module_name" -print -quit)"
    [[ -n "$source" ]] || die "missing $module_name in $source_label"
    cp -L "$source" "$tegu_kernel_dir/$module_name"
  done <"$modules_list"
}

copy_tegu_modules_from_dlkm_image() {
  local image="$1"
  local modules_list="$2"
  local dump_root="$3"

  [[ -s "$image" ]] || die "missing Pixel 9a DLKM image: $image"

  mkdir -p "$dump_root"
  if [[ ! -e "$dump_root/.openphone-extracted" ]]; then
    info "Extracting kernel modules from ${image##*/}"
    if ! debugfs -R "rdump /lib/modules $dump_root" "$image" >/dev/null 2>&1; then
      rm -rf "$dump_root"
      die "failed to extract /lib/modules from $image"
    fi
    touch "$dump_root/.openphone-extracted"
  fi

  copy_tegu_modules_from_dump "$dump_root" "$modules_list" "$image"
}

extract_tegu_ramdisk_file() {
  local ramdisk="$1"
  local out_dir="$2"
  local head_hex

  [[ -s "$ramdisk" ]] || return 1

  head_hex="$(xxd -p -l 6 "$ramdisk" | tr -d '\n')"
  mkdir -p "$out_dir"

  case "$head_hex" in
    070701*|070702*)
      (cd "$out_dir" && cpio -id --no-absolute-filenames <"$ramdisk") >/dev/null 2>&1
      ;;
    1f8b*)
      gzip -dc "$ramdisk" | (cd "$out_dir" && cpio -id --no-absolute-filenames) >/dev/null 2>&1
      ;;
    04224d18*|02214c18*)
      lz4 -dc "$ramdisk" | (cd "$out_dir" && cpio -id --no-absolute-filenames) >/dev/null 2>&1
      ;;
    *)
      rm -rf "$out_dir"
      return 1
      ;;
  esac
}

copy_tegu_modules_from_vendor_kernel_boot_image() {
  local image="$1"
  local modules_list="$2"
  local dump_root="$3"
  local unpack_tool unpack_dir ramdisk_root candidate candidate_out found

  [[ -s "$image" ]] || die "missing Pixel 9a vendor_kernel_boot image: $image"

  if [[ ! -e "$dump_root/.openphone-extracted" ]]; then
    need_cmd cpio
    need_cmd gzip
    need_cmd lz4
    need_cmd xxd

    unpack_tool="$(tegu_unpack_bootimg)"
    [[ -x "$unpack_tool" ]] || die "missing unpack_bootimg tool: $unpack_tool"

    rm -rf "$dump_root"
    mkdir -p "$dump_root"
    unpack_dir="$dump_root/unpacked"
    ramdisk_root="$dump_root/ramdisks"

    info "Extracting kernel modules from ${image##*/}"
    "$unpack_tool" --boot_img "$image" --out "$unpack_dir" --format mkbootimg >/dev/null

    found=0
    while IFS= read -r candidate; do
      candidate_out="$ramdisk_root/${candidate#$unpack_dir/}"
      if extract_tegu_ramdisk_file "$candidate" "$candidate_out"; then
        found=1
      fi
    done < <(find "$unpack_dir" -type f -print)

    ((found == 1)) || die "failed to extract any vendor ramdisk from $image"
    touch "$dump_root/.openphone-extracted"
  fi

  copy_tegu_modules_from_dump "$dump_root" "$modules_list" "$image"
}

ensure_tegu_kernel_modules() {
  local source_zip="$1"
  local partition image_cache dump_root

  collect_tegu_missing_kernel_modules
  if ((${#tegu_missing_kernel_modules[@]} == 0)); then
    info "Pixel 9a kernel modules already present"
    return 0
  fi

  need_cmd debugfs
  mkdir -p "$cache_root/tegu" "$tegu_kernel_dir"

  dump_root="$cache_root/tegu/${source_zip##*/}"
  dump_root="${dump_root%.zip}-vendor_kernel_boot-modules"
  copy_tegu_modules_from_vendor_kernel_boot_image \
    "$tegu_kernel_image" \
    "$tegu_kernel_dir/vendor_kernel_boot.modules.load" \
    "$dump_root"

  for partition in system_dlkm vendor_dlkm; do
    image_cache="$cache_root/tegu/${source_zip##*/}"
    image_cache="${image_cache%.zip}-${partition}.img"
    extract_tegu_ota_partition "$source_zip" "$partition" "$image_cache"
    dump_root="$cache_root/tegu/${source_zip##*/}"
    dump_root="${dump_root%.zip}-${partition}-modules"
    copy_tegu_modules_from_dlkm_image "$image_cache" "$tegu_kernel_dir/${partition}.modules.load" "$dump_root"
  done

  collect_tegu_missing_kernel_modules
  ((${#tegu_missing_kernel_modules[@]} == 0)) || {
    printf 'error: missing Pixel 9a kernel modules after OTA extraction:\n' >&2
    printf '  %s\n' "${tegu_missing_kernel_modules[@]}" >&2
    exit 1
  }

  info "Pixel 9a kernel modules ready: $tegu_kernel_dir"
}

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

if [[ -f "$tegu_vendor" && -f "$tegu_kernel_image" ]] && tegu_kernel_modules_ready; then
  info "Pixel 9a vendor tree already present: $tegu_vendor"
  info "Pixel 9a vendor_kernel_boot image already present: $tegu_kernel_image"
  info "Pixel 9a kernel modules already present: $tegu_kernel_dir"
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

ensure_tegu_kernel_modules "$vendor_zip"

[[ -f "$tegu_vendor" ]] || die "Pixel 9a vendor extraction did not create $tegu_vendor"
[[ -f "$tegu_kernel_image" ]] || die "Pixel 9a vendor_kernel_boot extraction did not create $tegu_kernel_image"
info "Pixel 9a vendor tree ready: $tegu_vendor"
info "Pixel 9a vendor_kernel_boot image ready: $tegu_kernel_image"
