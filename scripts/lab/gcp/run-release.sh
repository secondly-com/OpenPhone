#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lab/gcp/common.sh
source "$script_dir/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/lab/gcp/run-release.sh --version <tag> --device <codename> --release-notes <path> [options]

Creates a disposable GCP lab VM, updates a warm Android tree/cache, builds the
device release artifact, optionally boots the OpenPhone emulator smoke gate, and
copies release artifacts back to .worktree/gcp-lab/<vm>/artifacts/release/.

Options:
  --name <name>               VM name. Default: generated from version/ref.
  --repo-url <url>            Git repo URL. Default: current origin or GitHub.
  --ref <ref>                 Git ref/SHA to build. Default: current HEAD.
  --version <tag>             Release version, for example v0.0.2.
  --device <codename>         Device codename. Default: tegu.
  --release-notes <path>      Release notes file in the repo.
  --project <id>              GCP project. Default: OPENPHONE_GCP_PROJECT.
  --zone <zone>               GCP zone. Default: OPENPHONE_GCP_ZONE.
  --machine-type <type>       Machine type. Default: c3-standard-22.
  --boot-disk-size <size>     Boot disk size. Default: 1000GB.
  --boot-disk-type <type>     Boot disk type. Default: pd-ssd.
  --cache-mode <mode>         scratch, attach-disk, or snapshot. Default: scratch.
  --cache-disk <name>         Existing disk to attach, or per-run disk name for snapshot mode.
  --cache-source-snapshot <s> Snapshot to clone for snapshot mode.
  --cache-mount <path>        Mount path for cache disk. Default: /mnt/openphone-cache.
  --repo-sync-jobs <n>        repo sync jobs. Default: nproc on the VM.
  --build-goal <goals>        Android build goals. Default: target-files-package ota_from_target_files.
  --emulator-arch arm64|x86_64
                              Emulator arch for the release smoke. Default: x86_64.
  --emulator-variant <v>      Emulator variant. Default: eng.
  --emulator-timeout <sec>    Emulator boot timeout. Default: 900.
  --emulator-build-goal <g>   Build goals for the emulator smoke image.
                              Default: droid emu_img_zip.
  --skip-emulator-smoke       Build/stage release artifacts without emulator smoke.
  --keep-vm                   Leave VM running for debug.
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
version=""
device="tegu"
release_notes=""
project="$OPENPHONE_GCP_PROJECT"
zone="$OPENPHONE_GCP_ZONE"
machine_type="$OPENPHONE_GCP_MACHINE_TYPE"
boot_disk_size="$OPENPHONE_GCP_BOOT_DISK_SIZE"
boot_disk_type="$OPENPHONE_GCP_BOOT_DISK_TYPE"
cache_mode="$OPENPHONE_GCP_CACHE_MODE"
cache_disk="${OPENPHONE_GCP_CACHE_DISK:-}"
cache_source_snapshot="$OPENPHONE_GCP_CACHE_SOURCE_SNAPSHOT"
cache_mount="$OPENPHONE_GCP_CACHE_MOUNT"
repo_sync_jobs=""
build_goal="${OPENPHONE_RELEASE_BUILD_GOAL:-target-files-package ota_from_target_files}"
emulator_arch="x86_64"
emulator_variant="eng"
emulator_timeout="900"
emulator_build_goal="${OPENPHONE_EMULATOR_BUILD_GOAL:-droid emu_img_zip}"
skip_emulator_smoke=false
keep_vm=false

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
    --version)
      [[ $# -ge 2 ]] || die "--version requires a value"
      version="$2"
      shift 2
      ;;
    --device)
      [[ $# -ge 2 ]] || die "--device requires a value"
      device="$2"
      shift 2
      ;;
    --release-notes)
      [[ $# -ge 2 ]] || die "--release-notes requires a value"
      release_notes="$2"
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
    --repo-sync-jobs)
      [[ $# -ge 2 ]] || die "--repo-sync-jobs requires a value"
      repo_sync_jobs="$2"
      shift 2
      ;;
    --build-goal)
      [[ $# -ge 2 ]] || die "--build-goal requires a value"
      build_goal="$2"
      shift 2
      ;;
    --emulator-arch)
      [[ $# -ge 2 ]] || die "--emulator-arch requires a value"
      emulator_arch="$2"
      shift 2
      ;;
    --emulator-variant)
      [[ $# -ge 2 ]] || die "--emulator-variant requires a value"
      emulator_variant="$2"
      shift 2
      ;;
    --emulator-timeout)
      [[ $# -ge 2 ]] || die "--emulator-timeout requires a value"
      emulator_timeout="$2"
      shift 2
      ;;
    --emulator-build-goal)
      [[ $# -ge 2 ]] || die "--emulator-build-goal requires a value"
      emulator_build_goal="$2"
      shift 2
      ;;
    --skip-emulator-smoke)
      skip_emulator_smoke=true
      shift
      ;;
    --keep-vm)
      keep_vm=true
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

[[ -n "$version" ]] || die "--version is required"
[[ -n "$release_notes" ]] || die "--release-notes is required"

case "$device" in
  tegu) ;;
  *) die "unsupported release device: $device" ;;
esac

case "$cache_mode" in
  scratch|attach-disk|snapshot) ;;
  *) die "unsupported cache mode: $cache_mode" ;;
esac

case "$emulator_arch" in
  arm64|x86_64) ;;
  *) die "unsupported emulator arch: $emulator_arch" ;;
esac

case "$emulator_variant" in
  eng|userdebug) ;;
  *) die "unsupported emulator variant: $emulator_variant" ;;
esac

if [[ "$cache_mode" == "snapshot" && -z "$cache_source_snapshot" ]]; then
  die "--cache-source-snapshot is required when --cache-mode snapshot"
fi

need_gcloud

if [[ -z "$name" ]]; then
  short_ref="$(printf '%s' "$ref" | cut -c1-12)"
  name="openphone-release-${version}-${short_ref}-$(date -u +%H%M%S)"
fi
name="$(sanitize_gcp_name "$name")"
slot="$(printf '%s' "$name" | tr -c 'A-Za-z0-9_.-' '-')"

artifact_root="$root/.worktree/gcp-lab/$name"
artifact_dir="$artifact_root/artifacts"
release_artifact_parent="$artifact_dir/release"
emulator_artifact_parent="$artifact_dir/emulator"
mkdir -p "$release_artifact_parent" "$emulator_artifact_parent"

info "GCP release target: name=$name project=$project zone=$zone ref=$ref"
info "GCP release shape: machine=$machine_type disk=$boot_disk_size/$boot_disk_type cache_mode=$cache_mode"
if [[ -n "$cache_source_snapshot" ]]; then
  info "GCP release cache snapshot: $cache_source_snapshot"
fi

vm_created=false
release_copied=false
emulator_copied=false
remote_script="$(mktemp "${TMPDIR:-/tmp}/openphone-gcp-release.XXXXXX")"

copy_release_artifacts() {
  mkdir -p "$release_artifact_parent"
  if gcloud compute scp --recurse \
    "$name:~/openphone-src/.worktree/releases/$version" \
    "$release_artifact_parent/" \
    --project "$project" \
    --zone "$zone" >/dev/null; then
    release_copied=true
    return 0
  fi
  return 1
}

copy_emulator_artifacts() {
  mkdir -p "$emulator_artifact_parent"
  if gcloud compute scp --recurse \
    "$name:~/openphone-src/.worktree/lab/$slot/artifacts" \
    "$emulator_artifact_parent/" \
    --project "$project" \
    --zone "$zone" >/dev/null; then
    emulator_copied=true
    return 0
  fi
  return 1
}

cleanup() {
  local status=$?
  set +e
  rm -f "$remote_script"
  if [[ "$vm_created" == true && "$release_copied" != true ]]; then
    copy_release_artifacts >/dev/null 2>&1 || true
  fi
  if [[ "$vm_created" == true && "$emulator_copied" != true ]]; then
    copy_emulator_artifacts >/dev/null 2>&1 || true
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
version="${OPENPHONE_RELEASE_VERSION:?}"
device="${OPENPHONE_RELEASE_DEVICE:?}"
release_notes="${OPENPHONE_RELEASE_NOTES:?}"
slot="${OPENPHONE_LAB_SLOT:?}"
build_goal="${OPENPHONE_RELEASE_BUILD_GOAL:?}"
repo_sync_jobs="${OPENPHONE_REPO_SYNC_JOBS:-}"
cache_mode="${OPENPHONE_GCP_CACHE_MODE:-scratch}"
cache_mount="${OPENPHONE_GCP_CACHE_MOUNT:-/mnt/openphone-cache}"
skip_emulator_smoke="${OPENPHONE_SKIP_EMULATOR_SMOKE:-0}"
emulator_arch="${OPENPHONE_EMULATOR_ARCH:-x86_64}"
emulator_variant="${OPENPHONE_EMULATOR_VARIANT:-eng}"
emulator_timeout="${OPENPHONE_EMULATOR_TIMEOUT:-900}"
emulator_build_goal="${OPENPHONE_EMULATOR_BUILD_GOAL:-droid emu_img_zip}"

export OPENPHONE_RELEASE="${OPENPHONE_RELEASE:-bp4a}"

prepare_android_workspace() {
  if [[ "$cache_mode" == "scratch" ]]; then
    export OPENPHONE_ANDROID_DIR="${OPENPHONE_ANDROID_DIR:-$HOME/openphone-android}"
    mkdir -p "$OPENPHONE_ANDROID_DIR"
    export OPENPHONE_BUILD_CACHE_DIR="${OPENPHONE_BUILD_CACHE_DIR:-$HOME/openphone-build-cache}"
    mkdir -p "$OPENPHONE_BUILD_CACHE_DIR"
    return 0
  fi

  export OPENPHONE_ANDROID_DIR="${OPENPHONE_ANDROID_DIR:-${OPENPHONE_GCP_CACHE_ANDROID_DIR:-$HOME/openphone-android}}"

  local device_path="/dev/disk/by-id/google-openphone-cache"
  local deadline=$((SECONDS + 300))
  while [[ ! -e "$device_path" ]]; do
    if [[ "$SECONDS" -ge "$deadline" ]]; then
      printf 'error: cache disk device did not appear: %s\n' "$device_path" >&2
      exit 1
    fi
    sleep 2
  done

  if ! sudo blkid "$device_path" >/dev/null 2>&1; then
    sudo mkfs.ext4 -F -L openphone-cache "$device_path"
  fi

  sudo mkdir -p "$cache_mount"
  if ! findmnt --mountpoint "$cache_mount" >/dev/null 2>&1; then
    sudo mount -o defaults,discard "$device_path" "$cache_mount"
  fi
  sudo chown "$USER:$USER" "$cache_mount"

  local cache_android_dir="$cache_mount/android"
  local android_parent
  android_parent="$(dirname "$OPENPHONE_ANDROID_DIR")"
  sudo mkdir -p "$android_parent"
  sudo chown "$USER:$USER" "$android_parent"
  mkdir -p "$cache_android_dir" "$OPENPHONE_ANDROID_DIR"
  if ! findmnt --mountpoint "$OPENPHONE_ANDROID_DIR" >/dev/null 2>&1; then
    sudo mount --bind "$cache_android_dir" "$OPENPHONE_ANDROID_DIR"
  fi
  sudo chown "$USER:$USER" "$cache_mount" "$cache_android_dir" "$OPENPHONE_ANDROID_DIR"

  export OPENPHONE_BUILD_CACHE_DIR="${OPENPHONE_BUILD_CACHE_DIR:-$cache_mount/cache}"
  mkdir -p "$OPENPHONE_BUILD_CACHE_DIR"
}

prepare_android_workspace

printf '==> Cloud provider: GCP\n'
printf '==> Android workspace path: %s\n' "$OPENPHONE_ANDROID_DIR"
printf '==> Build cache path: %s\n' "$OPENPHONE_BUILD_CACHE_DIR"

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
./scripts/check-release-notes.sh "$version" "$release_notes"
test -f "$release_notes"

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

if [[ "$device" == "tegu" ]]; then
  ./scripts/prepare-tegu-device-repos.sh
fi

export OPENPHONE_BUILD_GOAL="$build_goal"
./scripts/build.sh "openphone_${device}"

release_dir="$HOME/openphone-src/.worktree/releases/$version"
rm -rf "$release_dir"
mkdir -p "$release_dir"
./scripts/stage-release-ota.sh \
  --android-dir "$OPENPHONE_ANDROID_DIR" \
  --device "$device" \
  --version "$version" \
  --output-dir "$release_dir"
./scripts/generate-release-manifest.sh "$version" "$release_dir" "$release_dir"
./scripts/validate-release-artifacts.sh "$release_dir"

if [[ "$skip_emulator_smoke" != "1" ]]; then
  OPENPHONE_BUILD_GOAL="$emulator_build_goal" ./scripts/lab/smoke.sh \
    --slot "$slot" \
    --arch "$emulator_arch" \
    --variant "$emulator_variant" \
    --timeout "$emulator_timeout" \
    --runtime local
fi
REMOTE

info "Copying remote release script to $name"
gcloud compute scp "$remote_script" "$name:/tmp/openphone-gcp-run-release.sh" \
  --project "$project" \
  --zone "$zone" >/dev/null

skip_emulator_value=0
if [[ "$skip_emulator_smoke" == true ]]; then
  skip_emulator_value=1
fi

remote_command="OPENPHONE_REPO_URL=$(shell_quote "$repo_url")"
remote_command+=" OPENPHONE_REF=$(shell_quote "$ref")"
remote_command+=" OPENPHONE_RELEASE_VERSION=$(shell_quote "$version")"
remote_command+=" OPENPHONE_RELEASE_DEVICE=$(shell_quote "$device")"
remote_command+=" OPENPHONE_RELEASE_NOTES=$(shell_quote "$release_notes")"
remote_command+=" OPENPHONE_LAB_SLOT=$(shell_quote "$slot")"
remote_command+=" OPENPHONE_RELEASE_BUILD_GOAL=$(shell_quote "$build_goal")"
remote_command+=" OPENPHONE_REPO_SYNC_JOBS=$(shell_quote "$repo_sync_jobs")"
remote_command+=" OPENPHONE_GCP_CACHE_MODE=$(shell_quote "$cache_mode")"
remote_command+=" OPENPHONE_GCP_CACHE_MOUNT=$(shell_quote "$cache_mount")"
remote_command+=" OPENPHONE_SKIP_EMULATOR_SMOKE=$(shell_quote "$skip_emulator_value")"
remote_command+=" OPENPHONE_EMULATOR_ARCH=$(shell_quote "$emulator_arch")"
remote_command+=" OPENPHONE_EMULATOR_VARIANT=$(shell_quote "$emulator_variant")"
remote_command+=" OPENPHONE_EMULATOR_TIMEOUT=$(shell_quote "$emulator_timeout")"
remote_command+=" OPENPHONE_EMULATOR_BUILD_GOAL=$(shell_quote "$emulator_build_goal")"
remote_command+=" OPENPHONE_TEGU_VENDOR_ZIP_URL=$(shell_quote "${OPENPHONE_TEGU_VENDOR_ZIP_URL:-}")"
remote_command+=" OPENPHONE_TEGU_VENDOR_ZIP_SHA256=$(shell_quote "${OPENPHONE_TEGU_VENDOR_ZIP_SHA256:-}")"
remote_command+=" OPENPHONE_BUILD_CACHE_DIR=$(shell_quote "${OPENPHONE_BUILD_CACHE_DIR:-}")"
remote_command+=" bash /tmp/openphone-gcp-run-release.sh"

info "Running GCP release build on $name"
gcloud compute ssh "$name" \
  --project "$project" \
  --zone "$zone" \
  --command "$remote_command" \
  | tee "$artifact_root/gcp-run-release.log"

copy_release_artifacts
if [[ "$skip_emulator_smoke" != true ]]; then
  copy_emulator_artifacts || true
fi

staging="$release_artifact_parent/$version"
[[ -f "$staging/SHA256SUMS" ]] || die "release artifacts were not copied back: $staging"
info "GCP release artifacts copied to $staging"
printf '%s\n' "$staging"
