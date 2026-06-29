#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$root/apps/docs"

if ! command -v npm >/dev/null 2>&1; then
  printf 'npm is required to build the Fumadocs site\n' >&2
  exit 1
fi

npm ci --ignore-scripts
npm run typecheck
npm run build
