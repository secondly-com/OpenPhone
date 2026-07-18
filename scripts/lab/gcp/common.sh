#!/usr/bin/env bash

set -euo pipefail

gcp_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$gcp_script_dir/../../.." && pwd)"
# shellcheck source=scripts/common.sh
source "$root/scripts/common.sh"

OPENPHONE_GCP_PROJECT="${OPENPHONE_GCP_PROJECT:-openphone-lab}"
OPENPHONE_GCP_REGION="${OPENPHONE_GCP_REGION:-us-central1}"
OPENPHONE_GCP_ZONE="${OPENPHONE_GCP_ZONE:-us-central1-a}"
OPENPHONE_GCP_FALLBACK_ZONES="${OPENPHONE_GCP_FALLBACK_ZONES:-}"
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
OPENPHONE_GCP_TUNNEL_THROUGH_IAP="${OPENPHONE_GCP_TUNNEL_THROUGH_IAP:-1}"

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

gcp_zone_candidates() {
  local primary_zone="${1:-$OPENPHONE_GCP_ZONE}"
  local fallback_zones="${2:-$OPENPHONE_GCP_FALLBACK_ZONES}"
  local candidate
  local seen
  local duplicate
  local -a emitted=()

  fallback_zones="${fallback_zones//,/ }"
  for candidate in "$primary_zone" $fallback_zones; do
    [[ -n "$candidate" ]] || continue
    duplicate=false
    for seen in "${emitted[@]-}"; do
      if [[ "$seen" == "$candidate" ]]; then
        duplicate=true
        break
      fi
    done
    if [[ "$duplicate" == true ]]; then
      continue
    fi
    emitted+=("$candidate")
    printf '%s\n' "$candidate"
  done
}

gcp_is_capacity_error() {
  local message="$1"
  grep -Eq \
    'ZONE_RESOURCE_POOL_EXHAUSTED|RESOURCE_POOL_EXHAUSTED|resource pool exhausted|reason: stockout|currently unavailable in the .* zone' \
    <<<"$message"
}

gcp_instance_exists() {
  local name="$1" project="$2" zone="$3"
  gcloud compute instances describe "$name" \
    --project "$project" \
    --zone "$zone" >/dev/null 2>&1
}

gcp_use_iap_tunnel() {
  local value
  value="$(printf '%s' "$OPENPHONE_GCP_TUNNEL_THROUGH_IAP" | tr '[:upper:]' '[:lower:]')"
  case "$value" in
    1|true|yes|on) return 0 ;;
    0|false|no|off) return 1 ;;
    *) die "OPENPHONE_GCP_TUNNEL_THROUGH_IAP must be 1/true or 0/false" ;;
  esac
}

gcp_compute_ssh() {
  local name="$1" project="$2" zone="$3"
  shift 3

  local args=(compute ssh "$name" --project "$project" --zone "$zone")
  if gcp_use_iap_tunnel; then
    args+=(--tunnel-through-iap)
  fi
  gcloud "${args[@]}" "$@"
}

gcp_compute_scp() {
  local project="$1" zone="$2"
  shift 2

  local args=(compute scp)
  if gcp_use_iap_tunnel; then
    args+=(--tunnel-through-iap)
  fi
  gcloud "${args[@]}" "$@" --project "$project" --zone "$zone"
}
