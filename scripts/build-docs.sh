#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export npm_config_yes=true

cd "$root/docs"

if ! command -v npx >/dev/null 2>&1; then
  printf 'npx is required to run Mintlify docs validation\n' >&2
  exit 1
fi

npx mint@latest validate
npx mint@latest broken-links
