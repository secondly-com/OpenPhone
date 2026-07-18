# Contract Schemas

This directory contains machine-readable JSON Schema files for OpenPhone
contracts. These are not database schemas. They are payload contracts for data
that crosses process, tool, audit, eval, runtime, and release boundaries.

They define the shapes that the assistant, framework patches, validators,
release tooling, and eval tooling must agree on:

- action requests and action results;
- model-visible tool registry entries;
- capability and app-policy configuration;
- screen-context payloads;
- audit events and audit evidence exports;
- trajectory events;
- background agent jobs and task reports;
- phone-owned adaptive surfaces and runtime-neutral assistant outputs;
- OTA feed metadata.

`scripts/check.sh` loads `action-registry`, `action-request`, `audit-event`,
`screen-context`, and `trajectory-event` schemas for its cross-consistency
checks, and the validation scripts derive their checks directly from the
schemas they validate against:

- `scripts/validate-trajectory-export.sh` — `trajectory-event.schema.json`;
- `scripts/validate-ota-feed.sh` — `ota-feed.schema.json`;
- `scripts/validate-agent-eval-report.sh` — `agent-eval-report.schema.json`;
- `scripts/validate-audit-evidence-export.sh` — `audit-evidence.schema.json`
  and `audit-event.schema.json`;
- `scripts/validate-surface-contract.mjs` —
  `openphone-surface.schema.json` and
  `openphone-assistant-output.schema.json`, including known-valid and
  known-invalid conformance fixtures.

Editing enums, required keys, or const markers in those schemas changes
validator behavior directly. The remaining schemas (`action-result`,
`agent-job`, `agent-task`, `app-policy`, `audit-log`, `model-tool`) document
contracts but are not yet wired into any validator; `scripts/check.sh` only
verifies they exist.
