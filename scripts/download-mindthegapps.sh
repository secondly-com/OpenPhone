#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/common.sh
source "$root/scripts/common.sh"

android_version="16.0.0"
arch="arm64"
output_dir="$root/.worktree/downloads/gms"

usage() {
  cat <<'EOF'
Usage: scripts/download-mindthegapps.sh [--android-version 16.0.0] [--arch arm64] [--output-dir <dir>]

Downloads the latest MindTheGapps release asset from GitHub and verifies the
release-provided SHA-256 file. The ZIP is saved under ignored local worktree
state by default.

This is a local convenience helper. It does not vendor, mirror, bundle, or
redistribute Google Mobile Services as part of OpenPhone.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --android-version)
      [[ $# -ge 2 ]] || die "--android-version requires a value"
      android_version="$2"
      shift 2
      ;;
    --arch)
      [[ $# -ge 2 ]] || die "--arch requires a value"
      arch="$2"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || die "--output-dir requires a value"
      output_dir="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown argument: $1"
      ;;
  esac
done

need_cmd curl
need_cmd python3
need_cmd sha256sum

repo="MindTheGapps/${android_version}-${arch}"
api_url="https://api.github.com/repos/${repo}/releases/latest"
mkdir -p "$output_dir"

metadata="$output_dir/mindthegapps-${android_version}-${arch}-latest.json"
info "Fetching latest release metadata: $repo"
curl -fsSL "$api_url" -o "$metadata"

assets=()
while IFS= read -r asset; do
  assets+=("$asset")
done < <(python3 - <<'PY' "$metadata"
import json
import sys

release = json.load(open(sys.argv[1], encoding="utf-8"))
zip_asset = None
sum_asset = None
for asset in release.get("assets", []):
    name = asset.get("name", "")
    url = asset.get("browser_download_url", "")
    if name.endswith(".zip"):
        zip_asset = (name, url)
    elif name.endswith(".zip.sha256sum"):
        sum_asset = (name, url)

if not zip_asset:
    raise SystemExit("latest MindTheGapps release has no .zip asset")
if not sum_asset:
    raise SystemExit("latest MindTheGapps release has no .zip.sha256sum asset")

print(release.get("tag_name", "unknown"))
print(zip_asset[0])
print(zip_asset[1])
print(sum_asset[0])
print(sum_asset[1])
PY
)

tag="${assets[0]}"
zip_name="${assets[1]}"
zip_url="${assets[2]}"
sum_name="${assets[3]}"
sum_url="${assets[4]}"

info "Latest release: $tag"
info "Downloading: $zip_name"
curl -fL --progress-bar "$zip_url" -o "$output_dir/$zip_name"
curl -fsSL "$sum_url" -o "$output_dir/$sum_name"

(
  cd "$output_dir"
  sha256sum -c "$sum_name"
)

cat <<EOF
Downloaded and verified:
$output_dir/$zip_name
EOF
