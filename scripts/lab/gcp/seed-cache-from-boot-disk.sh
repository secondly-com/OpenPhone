#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lab/gcp/common.sh
source "$script_dir/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/lab/gcp/seed-cache-from-boot-disk.sh --source-disk <disk> [options]

Copies a completed scratch lab Android tree from a preserved VM boot disk into a
persistent cache disk, then optionally snapshots that cache disk for warm lab
runs.

Options:
  --source-disk <name>        Preserved scratch VM boot disk to read.
  --source-android-dir <path> Android tree path on source disk.
                              Default: auto-detect /home/*/openphone-android.
  --cache-disk <name>         Cache disk to create/reuse.
  --snapshot <name>           Optional snapshot name to create after copy.
  --project <id>              GCP project. Default: OPENPHONE_GCP_PROJECT.
  --zone <zone>               GCP zone. Default: OPENPHONE_GCP_ZONE.
  --machine-type <type>       Converter VM type. Default: c3-standard-4.
  --boot-disk-size <size>     Converter boot disk size. Default: 50GB.
  --boot-disk-type <type>     Converter boot disk type. Default: pd-balanced.
  --cache-disk-size <size>    Cache disk size. Default: 1000GB.
  --cache-disk-type <type>    Cache disk type. Default: pd-ssd.
  --keep-vm                   Leave converter VM running for debug.
  -h, --help                  Show this help.
EOF
}

source_disk=""
source_android_dir="auto"
cache_disk="${OPENPHONE_GCP_CACHE_DISK:-}"
snapshot=""
project="$OPENPHONE_GCP_PROJECT"
zone="$OPENPHONE_GCP_ZONE"
machine_type="${OPENPHONE_GCP_SEED_MACHINE_TYPE:-c3-standard-4}"
boot_disk_size="${OPENPHONE_GCP_SEED_BOOT_DISK_SIZE:-50GB}"
boot_disk_type="${OPENPHONE_GCP_SEED_BOOT_DISK_TYPE:-pd-balanced}"
cache_disk_size="$OPENPHONE_GCP_CACHE_DISK_SIZE"
cache_disk_type="$OPENPHONE_GCP_CACHE_DISK_TYPE"
keep_vm=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-disk)
      [[ $# -ge 2 ]] || die "--source-disk requires a value"
      source_disk="$2"
      shift 2
      ;;
    --source-android-dir)
      [[ $# -ge 2 ]] || die "--source-android-dir requires a value"
      source_android_dir="$2"
      shift 2
      ;;
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

[[ -n "$source_disk" ]] || die "--source-disk is required"
need_gcloud

source_disk="$(sanitize_gcp_name "$source_disk")"
if [[ -z "$cache_disk" ]]; then
  cache_disk="$(sanitize_gcp_name "openphone-cache-x86-64-${OPENPHONE_RELEASE}")"
else
  cache_disk="$(sanitize_gcp_name "$cache_disk")"
fi
if [[ -n "$snapshot" ]]; then
  snapshot="$(sanitize_gcp_name "$snapshot")"
fi

gcloud compute disks describe "$source_disk" \
  --project "$project" \
  --zone "$zone" >/dev/null

if ! gcloud compute disks describe "$cache_disk" \
  --project "$project" \
  --zone "$zone" >/dev/null 2>&1; then
  info "Creating cache disk: $cache_disk"
  gcloud compute disks create "$cache_disk" \
    --project "$project" \
    --zone "$zone" \
    --type "$cache_disk_type" \
    --size "$cache_disk_size" \
    --labels "app=openphone,purpose=lab-cache,managed-by=codex"
else
  info "Reusing cache disk: $cache_disk"
fi

name="$(sanitize_gcp_name "openphone-cache-seed-$(date -u +%H%M%S)")"
vm_created=false
tmp_script="$(mktemp "${TMPDIR:-/tmp}/openphone-cache-seed.XXXXXX")"
cleanup() {
  local status=$?
  set +e
  rm -f "$tmp_script"
  if [[ "$vm_created" == true && "$keep_vm" != true ]]; then
    gcloud compute instances delete "$name" \
      --project "$project" \
      --zone "$zone" \
      --quiet >/dev/null 2>&1 || true
  fi
  exit "$status"
}
trap cleanup EXIT

info "Creating cache seed VM: $name"
gcloud compute instances create "$name" \
  --project "$project" \
  --zone "$zone" \
  --machine-type "$machine_type" \
  --boot-disk-size "$boot_disk_size" \
  --boot-disk-type "$boot_disk_type" \
  --image-family "$OPENPHONE_GCP_IMAGE_FAMILY" \
  --image-project "$OPENPHONE_GCP_IMAGE_PROJECT" \
  --maintenance-policy TERMINATE \
  --restart-on-failure \
  --no-service-account \
  --no-scopes \
  --labels "app=openphone,purpose=lab-cache-seed,managed-by=codex" \
  --tags openphone-lab \
  --metadata "openphone-lab=true" \
  --disk "name=$source_disk,device-name=openphone-source,mode=ro,boot=no,auto-delete=no" \
  --disk "name=$cache_disk,device-name=openphone-cache,mode=rw,boot=no,auto-delete=no"
vm_created=true

cat > "$tmp_script" <<'REMOTE'
#!/usr/bin/env bash
set -euo pipefail

source_android_dir="${OPENPHONE_SOURCE_ANDROID_DIR:?}"
source_root="/mnt/openphone-source"
cache_root="/mnt/openphone-cache"
source_device="/dev/disk/by-id/google-openphone-source"
cache_device="/dev/disk/by-id/google-openphone-cache"

sudo apt-get update
sudo apt-get install -y rsync

deadline=$((SECONDS + 300))
while [[ ! -e "$source_device" || ! -e "$cache_device" ]]; do
  if [[ "$SECONDS" -ge "$deadline" ]]; then
    printf 'error: expected source/cache disks did not appear\n' >&2
    exit 1
  fi
  sleep 2
done

source_mount_device="$source_device"
if compgen -G "${source_device}-part*" >/dev/null; then
  source_mount_device="$(ls "${source_device}"-part* | sort | head -1)"
fi

if ! sudo blkid "$cache_device" >/dev/null 2>&1; then
  sudo mkfs.ext4 -F -L openphone-cache "$cache_device"
fi

sudo mkdir -p "$source_root" "$cache_root"
if ! findmnt --mountpoint "$source_root" >/dev/null 2>&1; then
  sudo mount -o ro "$source_mount_device" "$source_root"
fi
if ! findmnt --mountpoint "$cache_root" >/dev/null 2>&1; then
  sudo mount -o defaults,discard "$cache_device" "$cache_root"
fi

if [[ "$source_android_dir" == "auto" ]]; then
  source_path=""
  for candidate in "$source_root"/home/*/openphone-android "$source_root"/root/openphone-android; do
    [[ -d "$candidate/.repo" ]] || continue
    source_path="$candidate"
    break
  done
  [[ -n "$source_path" ]] || {
    printf 'error: could not auto-detect source Android tree under mounted source disk\n' >&2
    exit 1
  }
else
  source_path="$source_root${source_android_dir}"
fi
[[ -d "$source_path/.repo" ]] || {
  printf 'error: source Android tree not found: %s\n' "$source_path" >&2
  exit 1
}

sudo mkdir -p "$cache_root/android"
sudo rsync -aH --delete "$source_path/" "$cache_root/android/"
sudo sync
sudo umount "$cache_root"
sudo umount "$source_root"
REMOTE

deadline=$((SECONDS + 600))
until gcp_compute_ssh "$name" "$project" "$zone" --command "true" >/dev/null 2>&1; do
  if [[ "$SECONDS" -ge "$deadline" ]]; then
    die "SSH was not ready for $name within 600s"
  fi
  sleep 10
done

info "Copying cache seed script to $name"
gcp_compute_scp "$project" "$zone" \
  "$tmp_script" "$name:/tmp/openphone-cache-seed.sh" >/dev/null

info "Copying Android tree from $source_disk to $cache_disk"
gcp_compute_ssh "$name" "$project" "$zone" \
  --command "OPENPHONE_SOURCE_ANDROID_DIR=$(shell_quote "$source_android_dir") bash /tmp/openphone-cache-seed.sh"

if [[ "$keep_vm" == true ]]; then
  info "--keep-vm left the converter VM running; skipping snapshot creation"
  printf 'Cache disk: %s\n' "$cache_disk"
  exit 0
fi

if [[ -n "$snapshot" ]]; then
  info "Creating cache snapshot: $snapshot"
  gcloud compute snapshots create "$snapshot" \
    --project "$project" \
    --source-disk "$cache_disk" \
    --source-disk-zone "$zone" \
    --storage-location "$OPENPHONE_GCP_REGION" \
    --labels "app=openphone,purpose=lab-cache,managed-by=codex"
  printf 'Cache snapshot: %s\n' "$snapshot"
fi

printf 'Cache disk: %s\n' "$cache_disk"
