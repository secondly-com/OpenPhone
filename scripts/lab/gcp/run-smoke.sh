#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lab/gcp/common.sh
source "$script_dir/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/lab/gcp/run-smoke.sh [options]

Creates a disposable GCP lab VM, checks out OpenPhone, syncs/builds the Android
tree, runs the same lab smoke used locally, copies artifacts back, and tears the
VM down unless --keep-vm is set.

Options:
  --name <name>               VM name. Default: generated from current ref/time.
  --repo-url <url>            Git repo URL. Default: current origin or GitHub.
  --ref <ref>                 Git ref/SHA to test. Default: current HEAD.
  --slot <name>               Lab slot name on the VM. Default: VM name.
  --project <id>              GCP project. Default: OPENPHONE_GCP_PROJECT.
  --zone <zone>               GCP zone. Default: OPENPHONE_GCP_ZONE.
  --machine-type <type>       Machine type. Default: c3-standard-22.
  --boot-disk-size <size>     Boot disk size. Default: 1000GB.
  --boot-disk-type <type>     Boot disk type. Default: pd-ssd.
  --cache-mode <mode>         scratch, attach-disk, or snapshot. Default: scratch.
  --cache-disk <name>         Existing disk to attach for attach-disk mode.
                               Per-run disk name for snapshot mode.
  --cache-source-snapshot <s> Snapshot to clone for snapshot mode.
  --cache-mount <path>        Mount path for cache disk. Default: /mnt/openphone-cache.
                              The Android tree is bind-mounted back to
                              $HOME/openphone-android for stable build paths.
  --arch arm64|x86_64         Emulator arch. Default: x86_64.
  --variant eng|userdebug     Emulator variant. Default: eng.
  --runtime <name>            Runtime intent: local, openclaw, or hermes.
                             May be repeated. Default: local.
  --timeout <seconds>         Emulator boot timeout. Default: 900.
  --repo-sync-jobs <n>        repo sync jobs. Default: nproc.
  --keep-vm                   Leave VM running for debug.
  --skip-build                Reuse existing Android build outputs on the VM.
  --export-emulator-image     Copy sdk-repo-linux-system-images.zip into lab
                              artifacts for local Mac/SDK installation.
  --skip-smoke                Build/export artifacts but do not boot the
                              emulator. Intended for cross-arch image exports.
  -h, --help                  Show this help.
EOF
}

default_ref="$(git -C "$root" rev-parse HEAD 2>/dev/null || printf 'main')"
default_repo_url="$(git -C "$root" config --get remote.origin.url 2>/dev/null || printf 'https://github.com/secondly-com/OpenPhone.git')"
case "$default_repo_url" in
  git@github.com:secondly-com/OpenPhone.git)
    default_repo_url="https://github.com/secondly-com/OpenPhone.git"
    ;;
esac

name=""
repo_url="$default_repo_url"
ref="$default_ref"
slot=""
project="$OPENPHONE_GCP_PROJECT"
zone="$OPENPHONE_GCP_ZONE"
machine_type="$OPENPHONE_GCP_MACHINE_TYPE"
boot_disk_size="$OPENPHONE_GCP_BOOT_DISK_SIZE"
boot_disk_type="$OPENPHONE_GCP_BOOT_DISK_TYPE"
cache_mode="$OPENPHONE_GCP_CACHE_MODE"
cache_disk="${OPENPHONE_GCP_CACHE_DISK:-}"
cache_source_snapshot="$OPENPHONE_GCP_CACHE_SOURCE_SNAPSHOT"
cache_mount="$OPENPHONE_GCP_CACHE_MOUNT"
arch="x86_64"
variant="eng"
timeout_seconds=900
repo_sync_jobs=""
keep_vm=false
skip_build=false
export_emulator_image=false
skip_smoke=false
runtimes=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      [[ $# -ge 2 ]] || die "--name requires a value"
      name="$2"
      shift 2
      ;;
    --repo-url)
      [[ $# -ge 2 ]] || die "--repo-url requires a value"
      repo_url="$2"
      shift 2
      ;;
    --ref)
      [[ $# -ge 2 ]] || die "--ref requires a value"
      ref="$2"
      shift 2
      ;;
    --slot)
      [[ $# -ge 2 ]] || die "--slot requires a value"
      slot="$2"
      shift 2
      ;;
    --project)
      [[ $# -ge 2 ]] || die "--project requires a value"
      project="$2"
      shift 2
      ;;
    --zone)
      [[ $# -ge 2 ]] || die "--zone requires a value"
      zone="$2"
      shift 2
      ;;
    --machine-type)
      [[ $# -ge 2 ]] || die "--machine-type requires a value"
      machine_type="$2"
      shift 2
      ;;
    --boot-disk-size)
      [[ $# -ge 2 ]] || die "--boot-disk-size requires a value"
      boot_disk_size="$2"
      shift 2
      ;;
    --boot-disk-type)
      [[ $# -ge 2 ]] || die "--boot-disk-type requires a value"
      boot_disk_type="$2"
      shift 2
      ;;
    --cache-mode)
      [[ $# -ge 2 ]] || die "--cache-mode requires a value"
      cache_mode="$2"
      shift 2
      ;;
    --cache-disk)
      [[ $# -ge 2 ]] || die "--cache-disk requires a value"
      cache_disk="$2"
      shift 2
      ;;
    --cache-source-snapshot)
      [[ $# -ge 2 ]] || die "--cache-source-snapshot requires a value"
      cache_source_snapshot="$2"
      shift 2
      ;;
    --cache-mount)
      [[ $# -ge 2 ]] || die "--cache-mount requires a value"
      cache_mount="$2"
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
    --runtime)
      [[ $# -ge 2 ]] || die "--runtime requires a value"
      runtimes+=("$2")
      shift 2
      ;;
    --timeout)
      [[ $# -ge 2 ]] || die "--timeout requires a value"
      timeout_seconds="$2"
      shift 2
      ;;
    --repo-sync-jobs)
      [[ $# -ge 2 ]] || die "--repo-sync-jobs requires a value"
      repo_sync_jobs="$2"
      shift 2
      ;;
    --keep-vm)
      keep_vm=true
      shift
      ;;
    --skip-build)
      skip_build=true
      shift
      ;;
    --export-emulator-image)
      export_emulator_image=true
      shift
      ;;
    --skip-smoke)
      skip_smoke=true
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

need_gcloud

case "$arch" in
  arm64|x86_64) ;;
  *) die "unsupported emulator arch: $arch" ;;
esac

case "$variant" in
  eng|userdebug) ;;
  *) die "unsupported emulator variant: $variant" ;;
esac

case "$cache_mode" in
  scratch|attach-disk|snapshot) ;;
  *) die "unsupported cache mode: $cache_mode" ;;
esac

if [[ "$cache_mode" == "snapshot" && -z "$cache_source_snapshot" ]]; then
  die "--cache-source-snapshot is required when --cache-mode snapshot"
fi

if [[ ${#runtimes[@]} -eq 0 ]]; then
  runtimes=(local)
fi

if [[ -z "$name" ]]; then
  short_ref="$(printf '%s' "$ref" | cut -c1-12)"
  name="openphone-lab-${short_ref}-$(date -u +%H%M%S)"
fi
name="$(sanitize_gcp_name "$name")"
slot="${slot:-$name}"
slot="$(printf '%s' "$slot" | tr -c 'A-Za-z0-9_.-' '-')"

artifact_root="$root/.worktree/gcp-lab/$name"
artifact_dir="$artifact_root/artifacts"
mkdir -p "$artifact_dir"

info "GCP lab target: name=$name project=$project zone=$zone ref=$ref"
info "GCP lab shape: machine=$machine_type disk=$boot_disk_size/$boot_disk_type cache_mode=$cache_mode"
if [[ -n "$cache_source_snapshot" ]]; then
  info "GCP lab cache snapshot: $cache_source_snapshot"
fi

vm_created=false
artifacts_copied=false
remote_script="$(mktemp "${TMPDIR:-/tmp}/openphone-gcp-remote.XXXXXX")"
copy_remote_artifacts() {
  mkdir -p "$artifact_dir"
  if gcp_compute_scp "$project" "$zone" --recurse \
    "$name:~/openphone-src/.worktree/lab/$slot/artifacts" \
    "$artifact_dir/" >/dev/null; then
    artifacts_copied=true
    return 0
  fi
  return 1
}

cleanup() {
  local status=$?
  set +e
  rm -f "$remote_script"
  if [[ "$vm_created" == true && "$artifacts_copied" != true ]]; then
    copy_remote_artifacts >/dev/null 2>&1 || true
  fi
  if [[ "$vm_created" == true && "$keep_vm" != true ]]; then
    "$script_dir/delete-vm.sh" --name "$name" --project "$project" --zone "$zone" || true
  fi
  exit "$status"
}
trap cleanup EXIT

create_args=(
  --name "$name"
  --project "$project"
  --zone "$zone"
  --machine-type "$machine_type"
  --boot-disk-size "$boot_disk_size"
  --boot-disk-type "$boot_disk_type"
  --cache-mode "$cache_mode"
)
if [[ -n "$cache_disk" ]]; then
  create_args+=(--cache-disk "$cache_disk")
fi
if [[ -n "$cache_source_snapshot" ]]; then
  create_args+=(--cache-source-snapshot "$cache_source_snapshot")
fi

"$script_dir/create-vm.sh" "${create_args[@]}"
vm_created=true

"$script_dir/bootstrap-vm.sh" --name "$name" --project "$project" --zone "$zone"

cat > "$remote_script" <<'REMOTE'
#!/usr/bin/env bash
set -euo pipefail

repo_url="${OPENPHONE_REPO_URL:?}"
ref="${OPENPHONE_REF:?}"
slot="${OPENPHONE_LAB_SLOT:?}"
arch="${OPENPHONE_EMULATOR_ARCH:?}"
variant="${OPENPHONE_EMULATOR_VARIANT:?}"
timeout_seconds="${OPENPHONE_EMULATOR_TIMEOUT:?}"
repo_sync_jobs="${OPENPHONE_REPO_SYNC_JOBS:-}"
skip_build="${OPENPHONE_SKIP_BUILD:-0}"
export_emulator_image="${OPENPHONE_EXPORT_EMULATOR_IMAGE:-0}"
skip_smoke="${OPENPHONE_SKIP_SMOKE:-0}"
runtime_csv="${OPENPHONE_LAB_RUNTIMES:-local}"
cache_mode="${OPENPHONE_GCP_CACHE_MODE:-scratch}"
cache_mount="${OPENPHONE_GCP_CACHE_MOUNT:-/mnt/openphone-cache}"

export OPENPHONE_RELEASE="${OPENPHONE_RELEASE:-bp4a}"

prepare_android_workspace() {
  if [[ "$cache_mode" == "scratch" ]]; then
    export OPENPHONE_ANDROID_DIR="${OPENPHONE_ANDROID_DIR:-$HOME/openphone-android}"
    mkdir -p "$OPENPHONE_ANDROID_DIR"
    return 0
  fi

  export OPENPHONE_ANDROID_DIR="${OPENPHONE_ANDROID_DIR:-${OPENPHONE_GCP_CACHE_ANDROID_DIR:-/home/adamcohenhillel/openphone-android}}"

  local device="/dev/disk/by-id/google-openphone-cache"
  local deadline=$((SECONDS + 300))
  while [[ ! -e "$device" ]]; do
    if [[ "$SECONDS" -ge "$deadline" ]]; then
      printf 'error: cache disk device did not appear: %s\n' "$device" >&2
      exit 1
    fi
    sleep 2
  done

  if ! sudo blkid "$device" >/dev/null 2>&1; then
    sudo mkfs.ext4 -F -L openphone-cache "$device"
  fi

  sudo mkdir -p "$cache_mount"
  if ! findmnt --mountpoint "$cache_mount" >/dev/null 2>&1; then
    sudo mount -o defaults,discard "$device" "$cache_mount"
  fi
  sudo chown "$USER:$USER" "$cache_mount"

  local cache_android_dir="$cache_mount/android"
  local android_parent
  android_parent="$(dirname "$OPENPHONE_ANDROID_DIR")"
  sudo mkdir -p "$android_parent"
  sudo chown "$USER:$USER" "$android_parent"
  mkdir -p "$cache_android_dir"
  mkdir -p "$OPENPHONE_ANDROID_DIR"
  if ! findmnt --mountpoint "$OPENPHONE_ANDROID_DIR" >/dev/null 2>&1; then
    sudo mount --bind "$cache_android_dir" "$OPENPHONE_ANDROID_DIR"
  fi
  sudo chown "$USER:$USER" "$cache_mount" "$cache_android_dir" "$OPENPHONE_ANDROID_DIR"
}

prepare_android_workspace

printf '==> Android workspace path: %s\n' "$OPENPHONE_ANDROID_DIR"

ensure_android_workspace_writable() {
  local probe_dir="$OPENPHONE_ANDROID_DIR"
  if [[ -d "$OPENPHONE_ANDROID_DIR/.repo" ]]; then
    probe_dir="$OPENPHONE_ANDROID_DIR/.repo"
  fi

  if touch "$probe_dir/.openphone-write-probe" >/dev/null 2>&1; then
    rm -f "$probe_dir/.openphone-write-probe"
    return 0
  fi

  printf '==> Android tree is not writable by %s; normalizing cache ownership under %s\n' "$USER" "$OPENPHONE_ANDROID_DIR"
  sudo chown -R "$USER:$USER" "$OPENPHONE_ANDROID_DIR"
  touch "$probe_dir/.openphone-write-probe"
  rm -f "$probe_dir/.openphone-write-probe"
}

ensure_android_workspace_writable

if [[ ! -d "$HOME/openphone-src/.git" ]]; then
  rm -rf "$HOME/openphone-src"
  git clone "$repo_url" "$HOME/openphone-src"
fi

cd "$HOME/openphone-src"
git remote set-url origin "$repo_url"
git fetch --tags --prune origin
git fetch origin "$ref" || true
git checkout --force "$ref" || git checkout --force FETCH_HEAD

./scripts/bootstrap-android-build-host.sh
./scripts/lab/install-android-sdk-tools.sh
export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-/opt/android-sdk}"
export ANDROID_HOME="${ANDROID_HOME:-$ANDROID_SDK_ROOT}"
export PATH="$ANDROID_SDK_ROOT/platform-tools:$ANDROID_SDK_ROOT/emulator:$ANDROID_SDK_ROOT/cmdline-tools/latest/bin:$PATH"
OPENPHONE_SKIP_JAVA_CHECK=1 ./scripts/check.sh

if [[ "$skip_build" != "1" ]]; then
  sync_args=()
  if [[ -n "$repo_sync_jobs" ]]; then
    sync_args+=(-j"$repo_sync_jobs")
  else
    sync_args+=(-j"$(nproc)")
  fi
  sync_args+=(--detach)
  if [[ "$cache_mode" == "scratch" ]]; then
    sync_args+=(--force-sync --force-checkout)
  fi
  ./scripts/sync.sh "${sync_args[@]}"
  if [[ "$cache_mode" == "scratch" ]]; then
    ./scripts/apply-patches.sh
  else
    OPENPHONE_RESET_PATCH_TARGETS=1 ./scripts/apply-patches.sh
  fi
  ./scripts/check.sh
fi

emulator_product_dir() {
  case "$arch" in
    arm64) printf 'emu64a' ;;
    x86_64) printf 'emu64x' ;;
    *)
      printf 'error: unsupported emulator arch for export: %s\n' "$arch" >&2
      exit 1
      ;;
  esac
}

if [[ "$export_emulator_image" == "1" && "$skip_build" != "1" ]]; then
  ./scripts/build-emulator.sh --arch "$arch" --variant "$variant"
  skip_build=1
fi

if [[ "$export_emulator_image" == "1" ]]; then
  product_dir="$(emulator_product_dir)"
  image_zip="$OPENPHONE_ANDROID_DIR/out/target/product/$product_dir/sdk-repo-linux-system-images.zip"
  artifact_image_dir="$HOME/openphone-src/.worktree/lab/$slot/artifacts/emulator-image"
  mkdir -p "$artifact_image_dir"
  if [[ ! -f "$image_zip" ]]; then
    printf 'error: emulator image zip not found for export: %s\n' "$image_zip" >&2
    exit 1
  fi
  cp "$image_zip" "$artifact_image_dir/openphone-sdk-phone-${arch}-${variant}.zip"
  (
    cd "$artifact_image_dir"
    sha256sum "openphone-sdk-phone-${arch}-${variant}.zip" \
      > "openphone-sdk-phone-${arch}-${variant}.zip.sha256"
  )
fi

if [[ "$skip_smoke" == "1" ]]; then
  printf '==> Skipping emulator smoke by request after build/export\n'
  exit 0
fi

IFS=',' read -r -a runtimes <<< "$runtime_csv"
smoke_args=(--slot "$slot" --arch "$arch" --variant "$variant" --timeout "$timeout_seconds")
if [[ "$skip_build" == "1" ]]; then
  smoke_args+=(--skip-build)
fi
for runtime in "${runtimes[@]}"; do
  [[ -n "$runtime" ]] || continue
  smoke_args+=(--runtime "$runtime")
done

./scripts/lab/smoke.sh "${smoke_args[@]}"
REMOTE

info "Copying remote smoke script to $name"
gcp_compute_scp "$project" "$zone" \
  "$remote_script" "$name:/tmp/openphone-gcp-run-smoke.sh" >/dev/null

runtime_csv="$(IFS=,; printf '%s' "${runtimes[*]}")"
skip_build_value=0
if [[ "$skip_build" == true ]]; then
  skip_build_value=1
fi
export_emulator_image_value=0
if [[ "$export_emulator_image" == true ]]; then
  export_emulator_image_value=1
fi
skip_smoke_value=0
if [[ "$skip_smoke" == true ]]; then
  skip_smoke_value=1
fi
remote_command="OPENPHONE_REPO_URL=$(shell_quote "$repo_url")"
remote_command+=" OPENPHONE_REF=$(shell_quote "$ref")"
remote_command+=" OPENPHONE_LAB_SLOT=$(shell_quote "$slot")"
remote_command+=" OPENPHONE_EMULATOR_ARCH=$(shell_quote "$arch")"
remote_command+=" OPENPHONE_EMULATOR_VARIANT=$(shell_quote "$variant")"
remote_command+=" OPENPHONE_EMULATOR_TIMEOUT=$(shell_quote "$timeout_seconds")"
remote_command+=" OPENPHONE_REPO_SYNC_JOBS=$(shell_quote "$repo_sync_jobs")"
remote_command+=" OPENPHONE_SKIP_BUILD=$(shell_quote "$skip_build_value")"
remote_command+=" OPENPHONE_EXPORT_EMULATOR_IMAGE=$(shell_quote "$export_emulator_image_value")"
remote_command+=" OPENPHONE_SKIP_SMOKE=$(shell_quote "$skip_smoke_value")"
remote_command+=" OPENPHONE_LAB_RUNTIMES=$(shell_quote "$runtime_csv")"
remote_command+=" OPENPHONE_GCP_CACHE_MODE=$(shell_quote "$cache_mode")"
remote_command+=" OPENPHONE_GCP_CACHE_MOUNT=$(shell_quote "$cache_mount")"
remote_command+=" bash /tmp/openphone-gcp-run-smoke.sh"

info "Running GCP emulator lab on $name"
gcp_compute_ssh "$name" "$project" "$zone" \
  --command "$remote_command" \
  | tee "$artifact_root/gcp-run-smoke.log"

copy_remote_artifacts
info "GCP emulator lab passed; artifacts copied to $artifact_dir"
