#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lab/gcp/common.sh
source "$script_dir/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/lab/gcp/latest-cache-snapshot.sh [options]

Prints the newest labeled OpenPhone GCP lab cache snapshot for an emulator arch.
Exits successfully with no output when no matching snapshot exists.

Options:
  --project <id>      GCP project. Default: OPENPHONE_GCP_PROJECT.
  --arch arm64|x86_64 Emulator architecture. Default: x86_64.
  --release <name>    Android release key. Default: OPENPHONE_RELEASE/bp4a.
  -h, --help          Show this help.
EOF
}

project="$OPENPHONE_GCP_PROJECT"
arch="${OPENPHONE_EMULATOR_ARCH:-x86_64}"
release="${OPENPHONE_RELEASE:-bp4a}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)
      [[ $# -ge 2 ]] || die "--project requires a value"
      project="$2"
      shift 2
      ;;
    --arch)
      [[ $# -ge 2 ]] || die "--arch requires a value"
      arch="$2"
      shift 2
      ;;
    --release)
      [[ $# -ge 2 ]] || die "--release requires a value"
      release="$2"
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

case "$arch" in
  arm64|x86_64) ;;
  *) die "unsupported emulator arch: $arch" ;;
esac

need_gcloud

arch_slug="${arch//_/-}"
prefix="openphone-cache-${arch_slug}-${release}-"

gcloud compute snapshots list \
  --project "$project" \
  --filter="labels.app=openphone AND labels.purpose=lab-cache AND name~^${prefix}" \
  --sort-by="~creationTimestamp" \
  --limit 1 \
  --format="value(name)"
