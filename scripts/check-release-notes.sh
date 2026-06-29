#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: scripts/check-release-notes.sh <version-or-tag> [release-notes.md]

Validates that a release version, release notes file, and changelog entry are
aligned before publishing a GitHub Release.

If release-notes.md is omitted, the script expects docs/releases/<version>.md,
with a leading "v" stripped from the version/tag.
EOF
}

die() {
  printf 'check-release-notes: %s\n' "$*" >&2
  exit 1
}

version="${1:-}"
release_notes="${2:-}"

if [[ -z "$version" || "$version" == "-h" || "$version" == "--help" ]]; then
  usage >&2
  exit 2
fi

normalized_version="${version#v}"
tag="v$normalized_version"
expected_notes="docs/releases/$normalized_version.md"

if [[ -z "$release_notes" ]]; then
  release_notes="$expected_notes"
  explicit_notes="false"
else
  explicit_notes="true"
fi

case "$release_notes" in
  /*) release_notes_path="$release_notes" ;;
  *) release_notes_path="$root/$release_notes" ;;
esac

[[ -f "$release_notes_path" ]] || die "missing release notes file: $release_notes"

if [[ "$explicit_notes" == "false" && "$release_notes" != "$expected_notes" ]]; then
  die "release $tag should use $expected_notes unless a notes file is supplied explicitly"
fi

if [[ "$explicit_notes" == "true" && "$release_notes" != "$expected_notes" ]]; then
  printf 'check-release-notes: using explicit release notes file %s for %s\n' "$release_notes" "$tag"
fi

changelog=""
for candidate in "$root/CHANGELOG.md" "$root/docs/releases/CHANGELOG.md"; do
  if [[ -f "$candidate" ]]; then
    changelog="$candidate"
    break
  fi
done
[[ -n "$changelog" ]] || die "missing changelog: expected CHANGELOG.md or docs/releases/CHANGELOG.md"

if grep -Eq "^##[[:space:]]+\\[?v?${normalized_version//./\\.}\\]?" "$changelog"; then
  printf 'check-release-notes: changelog contains release section for %s\n' "$tag"
elif grep -Eq '^##[[:space:]]+\[?Unreleased\]?' "$changelog"; then
  printf 'check-release-notes: changelog has an Unreleased section for %s\n' "$tag"
else
  die "changelog must mention $tag/$normalized_version or include a clear Unreleased section"
fi

printf 'check-release-notes: validated %s with %s\n' "$tag" "$release_notes"
