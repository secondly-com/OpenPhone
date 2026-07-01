#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

usage() {
  cat <<'USAGE'
Usage: scripts/create-macos-build-volume.sh

Creates and mounts a case-sensitive APFS sparsebundle for Android source builds
on macOS.

Environment:
  OPENPHONE_MACOS_IMAGE        Sparsebundle path.
  OPENPHONE_MACOS_VOLUME_NAME  Mounted volume directory name.
  OPENPHONE_MACOS_IMAGE_SIZE   Sparsebundle max size, default 700g.
USAGE
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
  "")
    ;;
  *)
    usage >&2
    die "unknown argument: $1"
    ;;
esac

if [[ "$(uname -s)" != "Darwin" ]]; then
  die "this helper is only for macOS"
fi

need_cmd hdiutil

image_path="${OPENPHONE_MACOS_IMAGE:-$OPENPHONE_ROOT/.worktree/OpenPhoneAndroid.sparsebundle}"
volume_name="${OPENPHONE_MACOS_VOLUME_NAME:-OpenPhoneAndroid}"
size="${OPENPHONE_MACOS_IMAGE_SIZE:-700g}"

mkdir -p "$(dirname "$image_path")"

if [[ ! -e "$image_path" ]]; then
  info "creating case-sensitive APFS sparsebundle: $image_path"
  hdiutil create \
    -size "$size" \
    -type SPARSEBUNDLE \
    -fs "Case-sensitive APFS" \
    -volname "$volume_name" \
    "$image_path"
else
  info "sparsebundle already exists: $image_path"
fi

mount_path="$OPENPHONE_ROOT/.worktree/$volume_name"
if mount | grep -F " on $mount_path (" >/dev/null 2>&1; then
  info "sparsebundle already mounted: $mount_path"
else
  info "mounting $image_path"
  mount_output="$(hdiutil attach "$image_path" -mountpoint "$mount_path" -nobrowse 2>&1)" || {
    printf '%s\n' "$mount_output" >&2
    die "failed to mount sparsebundle: $image_path"
  }
  printf '%s\n' "$mount_output"
fi

mkdir -p "$mount_path/android"

cat <<MSG

Case-sensitive Android volume is ready:
  $mount_path

Use:
  export OPENPHONE_ANDROID_DIR="$mount_path/android"
  ./scripts/sync.sh -j4 --fail-fast
MSG
