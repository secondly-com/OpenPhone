# Contributing Without an Android Build Host

A full OpenPhone Android build needs 64 GB RAM, ~700 GB fast disk, and an
x86_64 Linux host. Most of the repository does not. Everything below is
plain JSON, JavaScript, Python, shell, and markdown, validated end-to-end by
`./scripts/check.sh` on an ordinary laptop.

## What you can work on

- [`schemas/`](https://github.com/secondly-com/OpenPhone/tree/main/schemas)
  — JSON Schema contracts for action requests, tools, screen context, audit
  events, trajectories, OTA feeds, and eval reports. `check.sh` loads
  several of them for cross-consistency checks.
- [`runtime/protocol/`](https://github.com/secondly-com/OpenPhone/tree/main/runtime/protocol)
  — the Runtime Agent Protocol manifests (commands, events, capabilities)
  and their validator.
- [`integrations/cli`](https://github.com/secondly-com/OpenPhone/tree/main/integrations/cli),
  [`integrations/mcp-server`](https://github.com/secondly-com/OpenPhone/tree/main/integrations/mcp-server),
  [`integrations/adb`](https://github.com/secondly-com/OpenPhone/tree/main/integrations/adb)
  — Node CLI, MCP server, and ADB transport. Pure `.mjs`, no build step.
- [`services/model-broker/`](https://github.com/secondly-com/OpenPhone/tree/main/services/model-broker)
  — the dependency-free Python model broker and its deploy files.
- [`tests/integrations/`](https://github.com/secondly-com/OpenPhone/tree/main/tests/integrations)
  — Node contract tests for the CLI, MCP server, and OpenClaw plugin policy
  buckets.
- `docs/` — everything on the docs site.
- [`scripts/`](https://github.com/secondly-com/OpenPhone/tree/main/scripts)
  — sync, validation, and release helpers.

## Setup

```bash
git clone https://github.com/secondly-com/OpenPhone.git
cd OpenPhone
node --version     # CI uses Node 24
python3 --version  # any recent Python 3
./scripts/check.sh
git diff --check
```

`check.sh` skips the standalone Java compile check when no Android SDK is
present (or set `OPENPHONE_SKIP_JAVA_CHECK=1`). Everything else — required
files, JSON validity, schema cross-consistency, protocol validation, broker
smoke test, and the Node contract tests — runs locally in a few minutes.

To build the docs site locally, run `./scripts/build-docs.sh` (needs `npm`).

## Example tasks

### Add a schema field

Contracts live in `schemas/*.schema.json`. To document a new payload field,
edit the schema (for example a new optional property in
`screen-context.schema.json`), keep `required` accurate, and run
`./scripts/check.sh`. Note which schemas drive validator behavior directly —
read
[schemas/README.md](https://github.com/secondly-com/OpenPhone/blob/main/schemas/README.md)
before changing enums, `required` keys, or `const` markers.

### Add or change a runtime command

Runtime commands are declared in
`runtime/protocol/openphone-commands.json`. Each entry needs a name,
`android_tool`, capability, risk, exposure, and input/output schemas.
`runtime/protocol/validate-runtime-protocol.mjs` (run by `check.sh`)
cross-checks the manifest against the Android action registry, the OpenClaw
plugin command buckets, and the Android adapter mapping — so a new command
also touches those files, but all of them are text edits validated without
a build. Start by reading an existing entry like `openphone.apps.search`.

### Fix or improve docs

Edit the markdown under `docs/`, keep relative links valid, and run
`./scripts/check.sh` plus `./scripts/build-docs.sh` if you can. New pages
need an entry in the directory's `meta.json` to appear in the docs-site nav.

### Extend a broker or integration test

The broker's behavior contract is exercised by
`scripts/smoke-test-model-broker.sh` (started against a fake provider, no
API key needed). The Node surfaces are covered by
`tests/integrations/*.mjs`, which run the CLI and MCP server in dry-run mode
with no device attached. Adding an assertion for an uncovered behavior is a
small, high-value PR.

## Before opening a PR

Read the contributor terms in
[.github/CONTRIBUTING.md](https://github.com/secondly-com/OpenPhone/blob/main/.github/CONTRIBUTING.md),
keep the PR focused, and make sure `./scripts/check.sh` and
`git diff --check` pass. The CI ladder that runs on fork PRs is documented
there too.
