#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

need_cmd repo
need_cmd git

if ! git lfs version >/dev/null 2>&1; then
  die "git-lfs is required for Lineage WebView prebuilts. Install it with: brew install git-lfs && git lfs install"
fi

ensure_android_dir

if ! is_case_sensitive_dir "$OPENPHONE_ANDROID_DIR"; then
  die "Android tree must be on a case-sensitive filesystem. On macOS run scripts/create-macos-build-volume.sh and set OPENPHONE_ANDROID_DIR to the mounted path."
fi

info "Android tree: $OPENPHONE_ANDROID_DIR"
info "Lineage manifest: $LINEAGE_MANIFEST_URL"
info "Lineage branch: $LINEAGE_BRANCH"

cd "$OPENPHONE_ANDROID_DIR"

if [[ ! -d .repo ]]; then
  info "initializing repo checkout"
  repo init -u "$LINEAGE_MANIFEST_URL" -b "$LINEAGE_BRANCH" --git-lfs
else
  info "repo checkout already initialized"
fi

mkdir -p .repo/local_manifests
cp "$OPENPHONE_ROOT/manifests/openphone.xml" .repo/local_manifests/openphone.xml

info "syncing upstream sources"
sync_args=(--current-branch --no-tags --optimized-fetch --prune)
case "${OPENPHONE_REPO_SYNC_NO_CLONE_BUNDLE:-0}" in
  1|true|TRUE|yes|YES)
    sync_args+=(--no-clone-bundle)
    ;;
esac
repo sync "${sync_args[@]}" "$@"

info "sync complete"
