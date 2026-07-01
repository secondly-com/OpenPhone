#!/usr/bin/env bash

set -euo pipefail

gcp_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$gcp_script_dir/../../.." && pwd)"
# shellcheck source=scripts/common.sh
source "$root/scripts/common.sh"

OPENPHONE_GCP_PROJECT="${OPENPHONE_GCP_PROJECT:-openphone-lab}"
OPENPHONE_GCP_REGION="${OPENPHONE_GCP_REGION:-us-central1}"
OPENPHONE_GCP_ZONE="${OPENPHONE_GCP_ZONE:-us-central1-a}"
OPENPHONE_GCP_MACHINE_TYPE="${OPENPHONE_GCP_MACHINE_TYPE:-c3-standard-22}"
OPENPHONE_GCP_BOOT_DISK_SIZE="${OPENPHONE_GCP_BOOT_DISK_SIZE:-1000GB}"
OPENPHONE_GCP_BOOT_DISK_TYPE="${OPENPHONE_GCP_BOOT_DISK_TYPE:-pd-ssd}"
OPENPHONE_GCP_IMAGE_FAMILY="${OPENPHONE_GCP_IMAGE_FAMILY:-ubuntu-2404-lts-amd64}"
OPENPHONE_GCP_IMAGE_PROJECT="${OPENPHONE_GCP_IMAGE_PROJECT:-ubuntu-os-cloud}"
OPENPHONE_GCP_NETWORK="${OPENPHONE_GCP_NETWORK:-default}"
OPENPHONE_GCP_CACHE_MODE="${OPENPHONE_GCP_CACHE_MODE:-scratch}"
OPENPHONE_GCP_CACHE_DISK_TYPE="${OPENPHONE_GCP_CACHE_DISK_TYPE:-$OPENPHONE_GCP_BOOT_DISK_TYPE}"
OPENPHONE_GCP_CACHE_DISK_SIZE="${OPENPHONE_GCP_CACHE_DISK_SIZE:-1000GB}"
OPENPHONE_GCP_CACHE_MOUNT="${OPENPHONE_GCP_CACHE_MOUNT:-/mnt/openphone-cache}"
OPENPHONE_GCP_CACHE_SOURCE_SNAPSHOT="${OPENPHONE_GCP_CACHE_SOURCE_SNAPSHOT:-}"

need_gcloud() {
  need_cmd gcloud
}

sanitize_gcp_name() {
  need_cmd python3
  python3 - "$1" <<'PY'
import re
import sys

value = sys.argv[1].lower()
value = re.sub(r"[^a-z0-9-]+", "-", value).strip("-")
if not value:
    value = "openphone-lab"
if not value[0].isalpha():
    value = "openphone-" + value
value = value[:63].rstrip("-")
print(value)
PY
}

shell_quote() {
  printf '%q' "$1"
}

gcp_instance_exists() {
  local name="$1" project="$2" zone="$3"
  gcloud compute instances describe "$name" \
    --project "$project" \
    --zone "$zone" >/dev/null 2>&1
}
