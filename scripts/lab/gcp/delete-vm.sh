#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lab/gcp/common.sh
source "$script_dir/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/lab/gcp/delete-vm.sh --name <name> [options]

Deletes one OpenPhone lab VM. Boot disks are auto-deleted by default by
create-vm.sh; named cache disks are retained.

Options:
  --name <name>      VM name.
  --project <id>     GCP project. Default: OPENPHONE_GCP_PROJECT.
  --zone <zone>      GCP zone. Default: OPENPHONE_GCP_ZONE.
  -h, --help         Show this help.
EOF
}

name=""
project="$OPENPHONE_GCP_PROJECT"
zone="$OPENPHONE_GCP_ZONE"

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
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n "$name" ]] || die "--name is required"
name="$(sanitize_gcp_name "$name")"
need_gcloud

if ! gcp_instance_exists "$name" "$project" "$zone"; then
  info "VM does not exist: $name"
  exit 0
fi

info "Deleting GCP lab VM: $name"
gcloud compute instances delete "$name" \
  --project "$project" \
  --zone "$zone" \
  --quiet
