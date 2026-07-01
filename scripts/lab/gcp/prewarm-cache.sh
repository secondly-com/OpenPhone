#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lab/gcp/common.sh
source "$script_dir/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/lab/gcp/prewarm-cache.sh [options]

Creates or refreshes a persistent OpenPhone Android cache disk, runs the GCP lab
smoke against it, and snapshots the disk for parallel warm lab runs.

Options:
  --cache-disk <name>         Persistent cache disk to create/reuse.
  --snapshot <name>           Snapshot name to create after smoke passes.
  --source-snapshot <name>    Optional snapshot to seed a new cache disk.
  --repo-url <url>            Git repo URL. Default: current origin or GitHub.
  --ref <ref>                 Git ref/SHA to prewarm. Default: current HEAD.
  --project <id>              GCP project. Default: OPENPHONE_GCP_PROJECT.
  --zone <zone>               GCP zone. Default: OPENPHONE_GCP_ZONE.
  --machine-type <type>       Machine type. Default: c3-standard-22.
  --boot-disk-size <size>     Boot disk size. Default: 1000GB.
  --boot-disk-type <type>     Boot disk type. Default: pd-ssd.
  --cache-disk-size <size>    Cache disk size. Default: 1000GB.
  --cache-disk-type <type>    Cache disk type. Default: boot disk type.
  --arch arm64|x86_64         Emulator arch. Default: x86_64.
  --variant eng|userdebug     Emulator variant. Default: eng.
  --timeout <seconds>         Emulator boot timeout. Default: 900.
  --repo-sync-jobs <n>        repo sync jobs. Default: nproc on the VM.
  --keep-vm                   Leave the prewarm VM running for debug.
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

repo_url="$default_repo_url"
ref="$default_ref"
project="$OPENPHONE_GCP_PROJECT"
zone="$OPENPHONE_GCP_ZONE"
machine_type="$OPENPHONE_GCP_MACHINE_TYPE"
boot_disk_size="$OPENPHONE_GCP_BOOT_DISK_SIZE"
boot_disk_type="$OPENPHONE_GCP_BOOT_DISK_TYPE"
cache_disk=""
cache_disk_size="$OPENPHONE_GCP_CACHE_DISK_SIZE"
cache_disk_type="$OPENPHONE_GCP_CACHE_DISK_TYPE"
source_snapshot=""
snapshot=""
arch="x86_64"
variant="eng"
timeout_seconds=900
repo_sync_jobs=""
keep_vm=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cache-disk)
      [[ $# -ge 2 ]] || die "--cache-disk requires a value"
      cache_disk="$2"
      shift 2
      ;;
    --snapshot)
      [[ $# -ge 2 ]] || die "--snapshot requires a value"
      snapshot="$2"
      shift 2
      ;;
    --source-snapshot)
      [[ $# -ge 2 ]] || die "--source-snapshot requires a value"
      source_snapshot="$2"
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
    --cache-disk-size)
      [[ $# -ge 2 ]] || die "--cache-disk-size requires a value"
      cache_disk_size="$2"
      shift 2
      ;;
    --cache-disk-type)
      [[ $# -ge 2 ]] || die "--cache-disk-type requires a value"
      cache_disk_type="$2"
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
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

case "$arch" in
  arm64|x86_64) ;;
  *) die "unsupported emulator arch: $arch" ;;
esac

case "$variant" in
  eng|userdebug) ;;
  *) die "unsupported emulator variant: $variant" ;;
esac

need_gcloud

if [[ -z "$cache_disk" ]]; then
  cache_disk="$(sanitize_gcp_name "openphone-cache-${arch}-${OPENPHONE_RELEASE}")"
else
  cache_disk="$(sanitize_gcp_name "$cache_disk")"
fi

if [[ -z "$snapshot" ]]; then
  snapshot="$(sanitize_gcp_name "${cache_disk}-$(date -u +%Y%m%d-%H%M%S)")"
else
  snapshot="$(sanitize_gcp_name "$snapshot")"
fi

if gcloud compute snapshots describe "$snapshot" \
  --project "$project" >/dev/null 2>&1; then
  die "snapshot already exists: $snapshot"
fi

if ! gcloud compute disks describe "$cache_disk" \
  --project "$project" \
  --zone "$zone" >/dev/null 2>&1; then
  create_args=(
    compute disks create "$cache_disk"
    --project "$project"
    --zone "$zone"
    --type "$cache_disk_type"
    --size "$cache_disk_size"
    --labels "app=openphone,purpose=lab-cache,managed-by=codex"
  )
  if [[ -n "$source_snapshot" ]]; then
    create_args+=(--source-snapshot "$source_snapshot")
  fi
  info "Creating cache disk: $cache_disk"
  gcloud "${create_args[@]}"
else
  info "Reusing cache disk: $cache_disk"
fi

short_ref="$(printf '%s' "$ref" | cut -c1-12)"
name="$(sanitize_gcp_name "openphone-lab-prewarm-${short_ref}-$(date -u +%H%M%S)")"
run_args=(
  --name "$name"
  --repo-url "$repo_url"
  --ref "$ref"
  --project "$project"
  --zone "$zone"
  --machine-type "$machine_type"
  --boot-disk-size "$boot_disk_size"
  --boot-disk-type "$boot_disk_type"
  --cache-mode attach-disk
  --cache-disk "$cache_disk"
  --arch "$arch"
  --variant "$variant"
  --runtime local
  --timeout "$timeout_seconds"
)
if [[ -n "$repo_sync_jobs" ]]; then
  run_args+=(--repo-sync-jobs "$repo_sync_jobs")
fi
if [[ "$keep_vm" == true ]]; then
  run_args+=(--keep-vm)
fi

"$script_dir/run-smoke.sh" "${run_args[@]}"

if [[ "$keep_vm" == true ]]; then
  info "--keep-vm left the cache disk attached; skipping snapshot creation"
  printf 'Cache disk: %s\n' "$cache_disk"
  printf 'Rerun without --keep-vm to publish a warm snapshot.\n'
  exit 0
fi

info "Creating cache snapshot: $snapshot"
gcloud compute snapshots create "$snapshot" \
  --project "$project" \
  --source-disk "$cache_disk" \
  --source-disk-zone "$zone" \
  --storage-location "$OPENPHONE_GCP_REGION" \
  --labels "app=openphone,purpose=lab-cache,managed-by=codex"

printf 'Cache disk: %s\n' "$cache_disk"
printf 'Cache snapshot: %s\n' "$snapshot"
printf 'Set this repo variable for warm PR/release labs:\n'
printf '  OPENPHONE_GCP_CACHE_SOURCE_SNAPSHOT=%s\n' "$snapshot"
