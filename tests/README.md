# Tests

This directory contains repo-level tests that are reusable across packages.

## Contract Tests

`tests/integrations/` covers developer-facing runtime integrations:

- `adb-stateful-gating-contract.mjs` checks that the ADB transport refuses
  manifest-flagged stateful tools unless the operator opts in.
- `runtime-cli-contract.mjs` checks the manifest-backed CLI surface.
- `runtime-mcp-contract.mjs` checks the MCP JSON-RPC tool surface.
- `runtime-protocol-versioning-contract.mjs` checks manifest version-range
  acceptance/rejection, the handshake version advertisement, and
  `deprecated`/`superseded_by` metadata validation.
- `openclaw-plugin-policy-contract.mjs` checks the OpenClaw plugin policy
  registration.

Run them through the standard repository check:

```bash
./scripts/check.sh
```

Or run only runtime protocol and integration contracts:

```bash
./scripts/check-runtime-protocol.sh
```

## Scripted Checks

Executable harnesses stay under `scripts/` because they are command-line tools,
not reusable test modules:

- `scripts/check.sh` is the CI entrypoint.
- `scripts/check-assistant-java.sh` compiles assistant Java sources against the
  Android SDK.
- `scripts/smoke-test-*.sh` scripts require external state such as a USB phone,
  a model broker, or a running OpenClaw gateway.

## Schemas

JSON Schema files live under `schemas/`. They are contract definitions for
payloads that cross process, tool, audit, eval, and release boundaries.
