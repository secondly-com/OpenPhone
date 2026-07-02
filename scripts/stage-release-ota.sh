#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/common.sh
source "$root/scripts/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/stage-release-ota.sh --android-dir <path> --device <codename> --version <tag> --output-dir <dir> [options]

Stages a release OTA from an Android target-files package. This avoids relying
on Lineage's bacon wrapper as the release artifact contract.

Options:
  --android-dir <path>       Android source/output tree.
  --device <codename>        Device codename, for example tegu.
  --product <name>           Android product. Default: openphone_<device>.
  --version <tag>            Release version, for example v0.0.2.
  --target-files <zip>       Explicit target-files zip. Default: auto-detect.
  --output-dir <dir>         Staging directory for release artifacts.
  --package-key <path>       OTA signing key pair. Default: Android testkey.
  -h, --help                 Show this help.
EOF
}

android_dir=""
device=""
product=""
version=""
target_files=""
output_dir=""
package_key=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --android-dir)
      [[ $# -ge 2 ]] || die "--android-dir requires a value"
      android_dir="$2"
      shift 2
      ;;
    --device)
      [[ $# -ge 2 ]] || die "--device requires a value"
      device="$2"
      shift 2
      ;;
    --product)
      [[ $# -ge 2 ]] || die "--product requires a value"
      product="$2"
      shift 2
      ;;
    --version)
      [[ $# -ge 2 ]] || die "--version requires a value"
      version="$2"
      shift 2
      ;;
    --target-files)
      [[ $# -ge 2 ]] || die "--target-files requires a value"
      target_files="$2"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || die "--output-dir requires a value"
      output_dir="$2"
      shift 2
      ;;
    --package-key)
      [[ $# -ge 2 ]] || die "--package-key requires a value"
      package_key="$2"
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

[[ -n "$android_dir" ]] || die "--android-dir is required"
[[ -n "$device" ]] || die "--device is required"
[[ -n "$version" ]] || die "--version is required"
[[ -n "$output_dir" ]] || die "--output-dir is required"

android_dir="$(cd "$android_dir" && pwd)"
[[ -f "$android_dir/build/envsetup.sh" ]] || die "missing Android envsetup: $android_dir/build/envsetup.sh"

product="${product:-openphone_${device}}"
product_dir="$android_dir/out/target/product/$device"
[[ -d "$product_dir" ]] || die "missing product output directory: $product_dir"

if [[ -z "$target_files" ]]; then
  expected="$product_dir/obj/PACKAGING/target_files_intermediates/${product}-target_files.zip"
  if [[ -f "$expected" ]]; then
    target_files="$expected"
  else
    mapfile -t candidates < <(
      find "$product_dir/obj/PACKAGING/target_files_intermediates" \
        -maxdepth 2 \
        -type f \
        -name '*target_files*.zip' \
        -printf '%T@ %p\n' 2>/dev/null \
        | sort -nr \
        | awk '{sub(/^[^ ]+ /, ""); print}'
    )
    if [[ ${#candidates[@]} -gt 0 ]]; then
      target_files="${candidates[0]}"
    fi
  fi
fi

[[ -f "$target_files" ]] || {
  printf 'error: target-files zip not found for %s under %s\n' "$product" "$product_dir" >&2
  find "$product_dir/obj/PACKAGING" -maxdepth 3 -type f -name '*.zip' -print >&2 2>/dev/null || true
  exit 1
}

ota_tool="$android_dir/out/host/linux-x86/bin/ota_from_target_files"
if [[ -x "$ota_tool" ]]; then
  ota_cmd=("$ota_tool")
elif [[ -x "$android_dir/build/make/tools/releasetools/ota_from_target_files" ]]; then
  ota_cmd=("$android_dir/build/make/tools/releasetools/ota_from_target_files")
elif [[ -f "$android_dir/build/make/tools/releasetools/ota_from_target_files.py" ]]; then
  ota_cmd=(python3 "$android_dir/build/make/tools/releasetools/ota_from_target_files.py")
else
  die "missing ota_from_target_files; build the ota_from_target_files host tool first"
fi

package_key="${package_key:-$android_dir/build/make/target/product/security/testkey}"
[[ -f "$package_key.x509.pem" || -f "$package_key.pk8" || -f "$package_key" ]] || {
  die "missing OTA package key pair prefix: $package_key"
}

mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
ota_name="openphone_${device}-${version}-ota.zip"
ota_path="$output_dir/$ota_name"
metadata_path="$output_dir/openphone_${device}-${version}-release-metadata.txt"

info "Target files: $target_files"
info "OTA output: $ota_path"

PATH="$android_dir/out/host/linux-x86/bin:$android_dir/out/soong/host/linux-x86/bin:$PATH" \
  "${ota_cmd[@]}" \
  -k "$package_key" \
  "$target_files" \
  "$ota_path"

unzip -tq "$ota_path" >/dev/null
sha256sum "$ota_path" > "$ota_path.sha256"

{
  printf 'version=%s\n' "$version"
  printf 'device=%s\n' "$device"
  printf 'product=%s\n' "$product"
  printf 'android_dir=%s\n' "$android_dir"
  printf 'target_files=%s\n' "$target_files"
  printf 'ota=%s\n' "$ota_path"
  printf 'ota_sha256=%s\n' "$(file_sha256 "$ota_path")"
  printf 'generated_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$metadata_path"

printf 'Staged OTA: %s\n' "$ota_path"
printf 'Staged OTA SHA-256: %s\n' "$ota_path.sha256"
printf 'Release metadata: %s\n' "$metadata_path"
