#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/common.sh
source "$root/scripts/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/lab/up.sh [options]

Allocates a local OpenPhone lab slot, boots the emulator, runs the smoke checks,
and leaves the emulator running for Codex/human iteration.

Options:
  --slot <name>              Lab slot name. Default: checkout hash.
  --arch arm64|x86_64        Emulator image architecture. Default: host arch.
  --variant eng|userdebug    Emulator build variant. Default: eng.
  --runtime <name>           Runtime intent: local, openclaw, or hermes.
                             May be repeated. Default: local.
  --android-dir <path>       Android checkout path for this slot.
  --prepare                  Run local Android tree sync/patch prep before smoke.
  --no-prepare               Do not auto-prepare a missing Android tree.
  --repo-sync-jobs <n>       repo sync jobs when preparation runs.
  --from-scratch             Force repo sync/checkout when preparation runs.
  --reset-patch-targets      Reset patched Android repos before applying patches.
  --no-clone-bundle          Pass repo sync --no-clone-bundle during preparation.
  --emulator-image <path>    Install this portable SDK system image zip or URL
                             and boot it through a slot-owned AVD.
  --prebuilt                 Boot an already installed SDK system image/AVD
                             without syncing/building Android locally.
  --sdk-root <path>          Android SDK root for --emulator-image/--prebuilt.
  --skip-build               Reuse an already-built emulator image.
  --timeout <seconds>        Boot timeout. Default: run-emulator-smoke default.
  -h, --help                 Show this help.
EOF
}

slot=""
arch=""
variant=""
android_dir="${OPENPHONE_ANDROID_DIR:-}"
prepare_mode="auto"
repo_sync_jobs=""
from_scratch=false
reset_patch_targets=false
no_clone_bundle=false
skip_build=false
timeout_seconds=""
emulator_image=""
prebuilt=false
sdk_root=""
runtimes=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --slot)
      [[ $# -ge 2 ]] || die "--slot requires a value"
      slot="$2"
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
    --android-dir)
      [[ $# -ge 2 ]] || die "--android-dir requires a value"
      android_dir="$2"
      shift 2
      ;;
    --prepare)
      prepare_mode="always"
      shift
      ;;
    --no-prepare)
      prepare_mode="never"
      shift
      ;;
    --repo-sync-jobs)
      [[ $# -ge 2 ]] || die "--repo-sync-jobs requires a value"
      repo_sync_jobs="$2"
      shift 2
      ;;
    --from-scratch)
      from_scratch=true
      shift
      ;;
    --reset-patch-targets)
      reset_patch_targets=true
      shift
      ;;
    --no-clone-bundle)
      no_clone_bundle=true
      shift
      ;;
    --emulator-image)
      [[ $# -ge 2 ]] || die "--emulator-image requires a value"
      emulator_image="$2"
      prebuilt=true
      skip_build=true
      prepare_mode="never"
      shift 2
      ;;
    --prebuilt)
      prebuilt=true
      skip_build=true
      prepare_mode="never"
      shift
      ;;
    --sdk-root)
      [[ $# -ge 2 ]] || die "--sdk-root requires a value"
      sdk_root="$2"
      shift 2
      ;;
    --runtime)
      [[ $# -ge 2 ]] || die "--runtime requires a value"
      runtimes+=("$2")
      shift 2
      ;;
    --skip-build)
      skip_build=true
      shift
      ;;
    --timeout)
      [[ $# -ge 2 ]] || die "--timeout requires a value"
      timeout_seconds="$2"
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

if [[ -z "$slot" ]]; then
  need_cmd python3
  slot="$(
    python3 - <<'PY' "$root"
import hashlib
import sys

root = sys.argv[1]
print("checkout-" + hashlib.sha1(root.encode("utf-8")).hexdigest()[:8])
PY
  )"
fi

if [[ ${#runtimes[@]} -eq 0 ]]; then
  runtimes=(local)
fi

if [[ -n "$android_dir" ]]; then
  export OPENPHONE_ANDROID_DIR="$android_dir"
fi

"$root/scripts/lab/allocate-slot.sh" --slot "$slot" >/dev/null

env_file="$root/.worktree/lab/$slot/env"
[[ -f "$env_file" ]] || die "missing lab env file: $env_file"
# shellcheck disable=SC1090
source "$env_file"

if [[ -n "$sdk_root" ]]; then
  export ANDROID_SDK_ROOT="$sdk_root"
  export ANDROID_HOME="$sdk_root"
fi

if [[ -n "$emulator_image" ]]; then
  install_args=(--zip "$emulator_image")
  if [[ -n "$arch" ]]; then
    install_args+=(--arch "$arch")
  fi
  if [[ -n "$sdk_root" ]]; then
    install_args+=(--sdk-root "$sdk_root")
  fi
  "$root/scripts/lab/install-emulator-image.sh" "${install_args[@]}"
fi

should_prepare=false
case "$prepare_mode" in
  always)
    should_prepare=true
    ;;
  auto)
    if [[ "$skip_build" != true && ! -f "$OPENPHONE_ANDROID_DIR/build/envsetup.sh" ]]; then
      should_prepare=true
    fi
    ;;
  never)
    ;;
  *)
    die "invalid prepare mode: $prepare_mode"
    ;;
esac

if [[ "$should_prepare" == true ]]; then
  prepare_args=(--slot "$OPENPHONE_LAB_SLOT" --android-dir "$OPENPHONE_ANDROID_DIR")
  if [[ -n "$arch" ]]; then
    prepare_args+=(--arch "$arch")
  fi
  if [[ -n "$variant" ]]; then
    prepare_args+=(--variant "$variant")
  fi
  if [[ -n "$repo_sync_jobs" ]]; then
    prepare_args+=(--repo-sync-jobs "$repo_sync_jobs")
  fi
  if [[ "$from_scratch" == true ]]; then
    prepare_args+=(--from-scratch)
  fi
  if [[ "$reset_patch_targets" == true ]]; then
    prepare_args+=(--reset-patch-targets)
  fi
  if [[ "$no_clone_bundle" == true ]]; then
    prepare_args+=(--no-clone-bundle)
  fi
  "$root/scripts/lab/prepare-local.sh" "${prepare_args[@]}"
  # Refresh the env file because prepare-local may choose/create the macOS
  # case-sensitive build volume and persist its Android dir into the slot.
  # shellcheck disable=SC1090
  source "$env_file"
fi

args=(--slot "$OPENPHONE_LAB_SLOT" --keep-running)
if [[ -n "$arch" ]]; then
  args+=(--arch "$arch")
fi
if [[ -n "$variant" ]]; then
  args+=(--variant "$variant")
fi
if [[ "$skip_build" == true ]]; then
  args+=(--skip-build)
fi
if [[ "$prebuilt" == true ]]; then
  args+=(--prebuilt)
fi
if [[ -n "$timeout_seconds" ]]; then
  args+=(--timeout "$timeout_seconds")
fi
for runtime in "${runtimes[@]}"; do
  args+=(--runtime "$runtime")
done

"$root/scripts/lab/smoke.sh" "${args[@]}"

printf '\nLab is up. To use it in another shell:\n'
printf '  source %q\n' "$env_file"
printf '  node integrations/cli/src/index.mjs --serial "$ANDROID_SERIAL" --json runtime status\n'
