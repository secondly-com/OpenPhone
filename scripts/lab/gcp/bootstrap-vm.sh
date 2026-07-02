#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lab/gcp/common.sh
source "$script_dir/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/lab/gcp/bootstrap-vm.sh --name <name> [options]

Waits for SSH and installs base packages/KVM access on one OpenPhone GCP lab VM.
The repo-specific Android build bootstrap still runs from the checked-out repo.

Options:
  --name <name>           VM name.
  --project <id>          GCP project. Default: OPENPHONE_GCP_PROJECT.
  --zone <zone>           GCP zone. Default: OPENPHONE_GCP_ZONE.
  --timeout <seconds>     SSH timeout. Default: 600.
  -h, --help              Show this help.
EOF
}

name=""
project="$OPENPHONE_GCP_PROJECT"
zone="$OPENPHONE_GCP_ZONE"
timeout_seconds=600

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

[[ -n "$name" ]] || die "--name is required"
name="$(sanitize_gcp_name "$name")"
[[ "$timeout_seconds" =~ ^[0-9]+$ ]] || die "--timeout must be numeric"
need_gcloud

tmp_script="$(mktemp "${TMPDIR:-/tmp}/openphone-gcp-bootstrap.XXXXXX")"
cleanup_tmp() {
  rm -f "$tmp_script"
}
trap cleanup_tmp EXIT

cat > "$tmp_script" <<'REMOTE'
#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

apt_get() {
  sudo env DEBIAN_FRONTEND=noninteractive timeout --foreground "${OPENPHONE_APT_TIMEOUT_SECONDS:-600}" \
    apt-get \
      -o "Acquire::Retries=${OPENPHONE_APT_RETRIES:-5}" \
      -o "Acquire::http::Timeout=${OPENPHONE_APT_HTTP_TIMEOUT_SECONDS:-30}" \
      -o "Acquire::https::Timeout=${OPENPHONE_APT_HTTPS_TIMEOUT_SECONDS:-30}" \
      -o "DPkg::Lock::Timeout=${OPENPHONE_APT_LOCK_TIMEOUT_SECONDS:-120}" \
      "$@"
}

apt_get update
apt_get install -y \
  acl \
  ca-certificates \
  curl \
  git \
  git-lfs \
  jq \
  kmod \
  lsof \
  qemu-kvm \
  rsync \
  unzip \
  zip

sudo modprobe kvm || true
sudo modprobe kvm_intel || true
sudo modprobe kvm_amd || true

if [[ -e /dev/kvm ]]; then
  sudo chmod 0666 /dev/kvm || true
fi

git lfs install --skip-repo
git config --global user.name "${OPENPHONE_LAB_GIT_NAME:-OpenPhone Lab}"
git config --global user.email "${OPENPHONE_LAB_GIT_EMAIL:-openphone-lab@example.invalid}"
mkdir -p "$HOME/openphone-lab" "$HOME/openphone-android"
printf 'OpenPhone GCP VM bootstrap complete.\n'
REMOTE

deadline=$((SECONDS + timeout_seconds))
until gcloud compute ssh "$name" \
  --project "$project" \
  --zone "$zone" \
  --command "true" >/dev/null 2>&1; do
  if [[ "$SECONDS" -ge "$deadline" ]]; then
    die "SSH was not ready for $name within ${timeout_seconds}s"
  fi
  sleep 10
done

info "Copying bootstrap script to $name"
gcloud compute scp "$tmp_script" "$name:/tmp/openphone-bootstrap-vm.sh" \
  --project "$project" \
  --zone "$zone" >/dev/null

info "Bootstrapping $name"
gcloud compute ssh "$name" \
  --project "$project" \
  --zone "$zone" \
  --command "bash /tmp/openphone-bootstrap-vm.sh"
