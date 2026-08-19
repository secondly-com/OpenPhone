#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

node "$root/runtime/protocol/validate-runtime-protocol.mjs"
node --check "$root/runtime/protocol/openphone-runtime-tools.mjs"
node --check "$root/integrations/adb/openphone-adb-transport.mjs"
node --check "$root/integrations/cli/src/index.mjs"
node --check "$root/integrations/mcp-server/src/index.mjs"
node --no-warnings=ExperimentalWarning "$root/tests/integrations/ifp1-conformance-contract.mjs"
node --no-warnings=ExperimentalWarning "$root/tests/integrations/ifp1-adapter-contract.mjs"
node "$root/tests/integrations/adb-stateful-gating-contract.mjs"
node "$root/tests/integrations/openclaw-plugin-policy-contract.mjs"
node "$root/tests/integrations/runtime-cli-contract.mjs"
node "$root/tests/integrations/runtime-mcp-contract.mjs"
node "$root/tests/integrations/runtime-protocol-versioning-contract.mjs"
node "$root/tests/integrations/runtime-package-contract.mjs"

printf 'Runtime protocol checks passed.\n'
