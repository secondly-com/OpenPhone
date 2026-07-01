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

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

version="${1:-}"
release_notes="${2:-}"

if [[ -z "$version" ]]; then
  usage >&2
  exit 2
fi

normalized_version="${version#v}"
tag="v$normalized_version"
expected_notes="docs/releases/$normalized_version.md"

if [[ -z "$release_notes" ]]; then
  release_notes="$expected_notes"
fi

case "$release_notes" in
  /*)
    release_notes_path="$release_notes"
    case "$release_notes" in
      "$root"/*) release_notes_display="${release_notes#"$root"/}" ;;
      *) release_notes_display="$release_notes" ;;
    esac
    ;;
  *)
    release_notes_path="$root/$release_notes"
    release_notes_display="$release_notes"
    ;;
esac

[[ -f "$release_notes_path" ]] || die "missing release notes file: $release_notes"

if [[ "$release_notes_display" != "$expected_notes" ]]; then
  die "release $tag must use $expected_notes, got $release_notes"
fi

changelog=""
for candidate in "$root/CHANGELOG.md" "$root/docs/releases/CHANGELOG.md"; do
  if [[ -f "$candidate" ]]; then
    changelog="$candidate"
    break
  fi
done
[[ -n "$changelog" ]] \
  || die "missing changelog: expected CHANGELOG.md or docs/releases/CHANGELOG.md"

escaped_version="$(printf '%s' "$normalized_version" | sed -e 's/[][(){}.^$*+?|\\]/\\&/g')"
if grep -Eq "^##[[:space:]]+\\[?v?${escaped_version}\\]?([[:space:]]|$)" "$changelog"; then
  printf 'check-release-notes: changelog contains release section for %s\n' "$tag"
else
  die "changelog must contain an exact release section for $tag/$normalized_version"
fi

printf 'check-release-notes: validated %s with %s\n' "$tag" "$release_notes"
