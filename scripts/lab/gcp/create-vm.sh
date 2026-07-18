#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lab/gcp/common.sh
source "$script_dir/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/lab/gcp/create-vm.sh [options]

Creates one disposable OpenPhone lab VM inside the shared GCP lab project.
Returns exit status 75 when GCP reports a retryable zone-capacity stockout.

Options:
  --name <name>               VM name. Default: generated.
  --project <id>              GCP project. Default: OPENPHONE_GCP_PROJECT.
  --zone <zone>               GCP zone. Default: OPENPHONE_GCP_ZONE.
  --machine-type <type>       Machine type. Default: c3-standard-22.
  --boot-disk-size <size>     Boot disk size. Default: 1000GB.
  --boot-disk-type <type>     Boot disk type. Default: pd-ssd.
  --cache-mode <mode>         scratch, attach-disk, or snapshot. Default: scratch.
  --cache-disk <name>         Existing disk to attach for attach-disk mode.
                               Per-run disk name for snapshot mode.
  --cache-source-snapshot <s> Snapshot to clone for snapshot mode.
  --network <name>            Network. Default: default.
  --labels <labels>           Extra comma-separated labels.
  -h, --help                  Show this help.
EOF
}

name=""
project="$OPENPHONE_GCP_PROJECT"
zone="$OPENPHONE_GCP_ZONE"
machine_type="$OPENPHONE_GCP_MACHINE_TYPE"
boot_disk_size="$OPENPHONE_GCP_BOOT_DISK_SIZE"
boot_disk_type="$OPENPHONE_GCP_BOOT_DISK_TYPE"
cache_mode="$OPENPHONE_GCP_CACHE_MODE"
cache_disk="${OPENPHONE_GCP_CACHE_DISK:-}"
cache_source_snapshot="$OPENPHONE_GCP_CACHE_SOURCE_SNAPSHOT"
cache_disk_size="$OPENPHONE_GCP_CACHE_DISK_SIZE"
cache_disk_type="$OPENPHONE_GCP_CACHE_DISK_TYPE"
network="$OPENPHONE_GCP_NETWORK"
extra_labels=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      [[ $# -ge 2 ]] || die "--name requires a value"
      name="$2"
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
    --network)
      [[ $# -ge 2 ]] || die "--network requires a value"
      network="$2"
      shift 2
      ;;
    --labels)
      [[ $# -ge 2 ]] || die "--labels requires a value"
      extra_labels="$2"
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

need_gcloud

if [[ -z "$name" ]]; then
  name="$(sanitize_gcp_name "openphone-lab-$(date -u +%Y%m%d-%H%M%S)")"
else
  name="$(sanitize_gcp_name "$name")"
fi

case "$cache_mode" in
  scratch|attach-disk|snapshot) ;;
  *) die "unsupported cache mode: $cache_mode" ;;
esac

if gcp_instance_exists "$name" "$project" "$zone"; then
  info "VM already exists: $name"
  printf '%s\n' "$name"
  exit 0
fi

if [[ "$cache_mode" == "attach-disk" ]]; then
  [[ -n "$cache_disk" ]] || die "--cache-disk is required when --cache-mode attach-disk"
  gcloud compute disks describe "$cache_disk" \
    --project "$project" \
    --zone "$zone" >/dev/null
fi

if [[ "$cache_mode" == "snapshot" ]]; then
  [[ -n "$cache_source_snapshot" ]] || die "--cache-source-snapshot is required when --cache-mode snapshot"
  if [[ -z "$cache_disk" ]]; then
    cache_disk="$(sanitize_gcp_name "${name}-cache")"
  else
    cache_disk="$(sanitize_gcp_name "$cache_disk")"
  fi
  if gcloud compute disks describe "$cache_disk" \
    --project "$project" \
    --zone "$zone" >/dev/null 2>&1; then
    die "cache disk already exists for snapshot mode: $cache_disk"
  fi
fi

labels="app=openphone,purpose=lab,managed-by=codex"
if [[ -n "$extra_labels" ]]; then
  labels="${labels},${extra_labels}"
fi

created_cache_disk=false
cleanup_cache_disk() {
  local status=$?
  if [[ "$created_cache_disk" == true ]]; then
    gcloud compute disks delete "$cache_disk" \
      --project "$project" \
      --zone "$zone" \
      --quiet >/dev/null 2>&1 || true
  fi
  exit "$status"
}
trap cleanup_cache_disk EXIT

if [[ "$cache_mode" == "snapshot" ]]; then
  info "Creating per-run cache disk from snapshot: $cache_disk"
  gcloud compute disks create "$cache_disk" \
    --project "$project" \
    --zone "$zone" \
    --type "$cache_disk_type" \
    --size "$cache_disk_size" \
    --source-snapshot "$cache_source_snapshot" \
    --labels "$labels"
  created_cache_disk=true
fi

args=(
  compute instances create "$name"
  --project "$project"
  --zone "$zone"
  --machine-type "$machine_type"
  --boot-disk-size "$boot_disk_size"
  --boot-disk-type "$boot_disk_type"
  --image-family "$OPENPHONE_GCP_IMAGE_FAMILY"
  --image-project "$OPENPHONE_GCP_IMAGE_PROJECT"
  --enable-nested-virtualization
  --maintenance-policy TERMINATE
  --restart-on-failure
  --no-service-account
  --no-scopes
  --labels "$labels"
  --tags openphone-lab
  --metadata "openphone-lab=true"
)

if [[ -n "$network" ]]; then
  args+=(--network "$network")
fi

if [[ "$cache_mode" == "attach-disk" || "$cache_mode" == "snapshot" ]]; then
  cache_auto_delete="no"
  if [[ "$cache_mode" == "snapshot" ]]; then
    cache_auto_delete="yes"
  fi
  args+=(--disk "name=$cache_disk,device-name=openphone-cache,mode=rw,boot=no,auto-delete=$cache_auto_delete")
fi

info "Creating GCP lab VM: $name"
set +e
create_output="$(gcloud "${args[@]}" 2>&1)"
create_status=$?
set -e
if [[ "$create_status" -ne 0 ]]; then
  printf '%s\n' "$create_output" >&2
  if gcp_is_capacity_error "$create_output"; then
    printf 'GCP zone capacity is temporarily unavailable: %s\n' "$zone" >&2
    exit 75
  fi
  exit "$create_status"
fi
printf '%s\n' "$create_output"
created_cache_disk=false
printf '%s\n' "$name"
