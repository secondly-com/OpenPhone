#!/usr/bin/env bash

set -euo pipefail

requested_android_dir="${OPENPHONE_ANDROID_DIR:-}"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/common.sh
source "$root/scripts/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/lab/prepare-local.sh [options]

Prepares the local Android tree used by a Mac Studio/Linux OpenPhone lab slot.
It can create/mount the macOS case-sensitive build volume, sync Lineage sources,
apply OpenPhone overlay/patches, and optionally build the emulator image.

Options:
  --slot <name>              Lab slot whose env should remember the Android dir.
  --android-dir <path>       Android checkout path. Default: OPENPHONE_ANDROID_DIR.
  --arch arm64|x86_64        Emulator image architecture for optional build.
                             Default: host arch.
  --variant eng|userdebug    Emulator build variant for optional build. Default: eng.
  --repo-sync-jobs <n>       repo sync jobs. Default: host CPU count.
  --skip-sync                Do not run scripts/sync.sh.
  --skip-patches             Do not run scripts/apply-patches.sh.
  --reset-patch-targets      Reset patched Android repos to manifest revisions
                             before applying OpenPhone patches.
  --from-scratch             Force repo sync/checkout when syncing.
  --no-clone-bundle          Pass repo sync --no-clone-bundle. Useful for
                             resumable local cold syncs on flaky networks.
  --build-emulator           Build the emulator image after sync/patch.
  --no-macos-volume          Do not auto-create/mount the macOS sparsebundle.
  -h, --help                 Show this help.

Environment:
  OPENPHONE_ANDROID_DIR        Android checkout path.
  OPENPHONE_MACOS_IMAGE        macOS sparsebundle path.
  OPENPHONE_MACOS_VOLUME_NAME  macOS mounted volume name.
  OPENPHONE_MACOS_IMAGE_SIZE   macOS sparsebundle max size. Default here: 700g.
EOF
}

detect_emulator_arch() {
  case "$(uname -m)" in
    arm64|aarch64) printf 'arm64' ;;
    x86_64|amd64) printf 'x86_64' ;;
    *) die "unsupported host architecture: $(uname -m). Pass --arch arm64 or --arch x86_64." ;;
  esac
}

host_cpu_count() {
  if command -v nproc >/dev/null 2>&1; then
    nproc
  elif command -v sysctl >/dev/null 2>&1; then
    sysctl -n hw.ncpu
  else
    printf '4'
  fi
}

slot=""
android_dir="$requested_android_dir"
arch=""
variant="eng"
repo_sync_jobs=""
run_sync=true
run_patches=true
reset_patch_targets=false
from_scratch=false
no_clone_bundle=false
build_emulator=false
auto_macos_volume=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --slot)
      [[ $# -ge 2 ]] || die "--slot requires a value"
      slot="$2"
      shift 2
      ;;
    --android-dir)
      [[ $# -ge 2 ]] || die "--android-dir requires a value"
      android_dir="$2"
      shift 2
      ;;
    --arch)
      [[ $# -ge 2 ]] || die "--arch requires a value"
      arch="$2"
      shift 2
      ;;
    --variant)
      [[ $# -ge 2 ]] || die "--variant requires a value"
      variant="$2"
      shift 2
      ;;
    --repo-sync-jobs)
      [[ $# -ge 2 ]] || die "--repo-sync-jobs requires a value"
      repo_sync_jobs="$2"
      shift 2
      ;;
    --skip-sync)
      run_sync=false
      shift
      ;;
    --skip-patches)
      run_patches=false
      shift
      ;;
    --reset-patch-targets)
      reset_patch_targets=true
      shift
      ;;
    --from-scratch)
      from_scratch=true
      shift
      ;;
    --no-clone-bundle)
      no_clone_bundle=true
      shift
      ;;
    --build-emulator)
      build_emulator=true
      shift
      ;;
    --no-macos-volume)
      auto_macos_volume=false
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

arch="${arch:-$(detect_emulator_arch)}"
repo_sync_jobs="${repo_sync_jobs:-$(host_cpu_count)}"
android_dir="${android_dir:-$OPENPHONE_ANDROID_DIR}"

case "$arch" in
  arm64|x86_64) ;;
  *) die "unsupported emulator arch: $arch" ;;
esac

case "$variant" in
  eng|userdebug) ;;
  *) die "unsupported emulator variant: $variant" ;;
esac

[[ "$repo_sync_jobs" =~ ^[0-9]+$ ]] || die "--repo-sync-jobs must be numeric"

if [[ "$(uname -s)" == "Darwin" && "$auto_macos_volume" == true ]]; then
  mkdir -p "$android_dir"
  if ! is_case_sensitive_dir "$android_dir"; then
    info "Local Android dir is not case-sensitive; preparing macOS build volume"
    export OPENPHONE_MACOS_IMAGE_SIZE="${OPENPHONE_MACOS_IMAGE_SIZE:-700g}"
    "$root/scripts/create-macos-build-volume.sh"
    android_dir="$root/.worktree/${OPENPHONE_MACOS_VOLUME_NAME:-OpenPhoneAndroid}/android"
  fi
fi

export OPENPHONE_ANDROID_DIR="$android_dir"

if [[ -n "$slot" ]]; then
  "$root/scripts/lab/allocate-slot.sh" --slot "$slot" >/dev/null
fi

need_cmd git
if ! command -v repo >/dev/null 2>&1; then
  info "Installing repo tool into ~/.local/bin"
  "$root/scripts/install-repo.sh"
fi

if [[ "$run_sync" == true ]]; then
  sync_args=(-j"$repo_sync_jobs")
  if [[ "$from_scratch" == true ]]; then
    sync_args+=(--force-sync --force-checkout)
  fi
  if [[ "$no_clone_bundle" == true ]]; then
    sync_args+=(--no-clone-bundle)
  fi
  "$root/scripts/sync.sh" "${sync_args[@]}"
else
  [[ -d "$OPENPHONE_ANDROID_DIR/.repo" ]] \
    || die "Android tree not initialized and --skip-sync was used: $OPENPHONE_ANDROID_DIR"
fi

if [[ "$run_patches" == true ]]; then
  if [[ "$reset_patch_targets" == true ]]; then
    OPENPHONE_RESET_PATCH_TARGETS=1 "$root/scripts/apply-patches.sh"
  else
    "$root/scripts/apply-patches.sh"
  fi
fi

if [[ "$build_emulator" == true ]]; then
  "$root/scripts/build-emulator.sh" --arch "$arch" --variant "$variant"
fi

cat <<MSG
OpenPhone local lab Android tree is ready:
  OPENPHONE_ANDROID_DIR=$OPENPHONE_ANDROID_DIR

Use:
  scripts/lab/up.sh --slot ${slot:-codex-local} --arch $arch --runtime local
MSG
