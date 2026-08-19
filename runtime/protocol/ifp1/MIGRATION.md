# Migration: OpenPhone runtime protocol v0 -> Interfaces Protocol v1 (`ifp/1`)

- **Status:** in progress on `rewrite/protocol-v1` (WS5 of the Interfaces v1
  rewrite plan; ADR 0004 in silentspeech-app
  `docs/architecture/adr/0004-interfaces-protocol-v1-greenfield.md`).
- **Spec:** silentspeech-app
  `packages/interfaces-protocol/spec/interfaces-protocol-1.md`
  (v1.0.0-draft — fixture corpus not yet frozen).
- **This directory** vendors the ifp/1 TypeScript reference validator and
  state machine (`validator.ts`, `machine.ts`), the conformance fixture
  corpus (`fixtures/`), the OpenPhone tool capability manifest
  (`openphone-tools.ifp1.json`), and the legacy-event adapter
  (`adapter.mjs`). Tests:
  `tests/integrations/ifp1-conformance-contract.mjs` and
  `tests/integrations/ifp1-adapter-contract.mjs`, run by
  `scripts/check-runtime-protocol.sh` (and so by `scripts/check.sh`).

## Deprecation of the v0 manifests

`runtime/protocol/openphone-commands.json` and
`runtime/protocol/openphone-events.json` now carry top-level
`"deprecated": true` and `"superseded_by": "ifp1/"`. The v0 loader
(`openphone-runtime-tools.mjs`), the manifest validator
(`validate-runtime-protocol.mjs`), and all contract tests tolerate the
extra top-level keys (verified; the vendored copies under
`integrations/cli/runtime/protocol/` and
`integrations/mcp-server/runtime/protocol/` are byte-synced as the
package contract requires). The old manifests are NOT deleted yet: the
Java side (`RuntimeToolBridge`, `OpenClawCommandRegistry`) and the
OpenClaw plugin still read them. Deletion is gated on the remainder items
in `WS5-REMAINDER.md` at the repo root.

## Concept mapping

| Runtime protocol v0 | ifp/1 |
|---|---|
| Command (`openphone.<tool>`) | Tool capability `tool:<tool>` declared at hello/pairing (spec §6.4); invoked via the action lifecycle (spec §8) |
| `runtime.tool.requested` event | `action.propose` (runtime -> surface) |
| `runtime.confirmation.required` event | No wire message: confirmation is surface-local authority (spec §8.2); the runtime only observes the outcome |
| `runtime.confirmation.resolved` event | `action.approve` (with exact `params_hash` binding + `confirmation.mode`/`ref`) or `action.reject` (`reason_class`, terminal) |
| `runtime.tool.result` event | `action.result` (`executed`/`failed`; `binding_mismatch` if executed params diverge from the approved hash; `action_expired` past `expires_at`) |
| Autonomy `observe_only` / `ask_before_action` / `trusted_actions` | Surface-local policy, NOT negotiable over the wire (spec §8.2). `trusted_actions` auto-approvals become `confirmation.mode: "policy_auto"` |
| `confirmation: "always"` command metadata | `risk: "high"` on the tool declaration and on `action.propose` |
| Ed25519 device identity (OpenClaw adapter) | ifp/1 pairing (spec §6.1–6.3): keypair at pairing, challenge signature, `control.hello` proof over the connection nonce |
| Manifest integer `version` + range negotiation | Envelope `ifp: "1"` major version; `control.hello payload.protocol {min,max}` negotiation |
| `deprecated`/`superseded_by` per command | Same policy, adopted by the ifp/1 type registry (spec §3) |

## Command -> tool mapping (all 37)

The ifp/1 tool name is the v0 command name without the `openphone.` prefix.
Aliases are retired: ifp/1 has exactly one name per tool (old aliases are
recorded in each manifest entry's `x-openphone.superseded_aliases`).
`risk` carries over from the v0 manifest unchanged; the v0 `confirmation`
and `default_exposure` columns become surface-local policy inputs and are
preserved under `x-openphone` for the Java bridge migration.

| v0 command | v0 aliases | ifp/1 tool | risk | v0 confirmation | v0 exposure |
|---|---|---|---|---|---|
| `openphone.device.status` | `device.status`, `device.info` | `device.status` | medium | none | private_read |
| `openphone.apps.search` | `device.apps` | `apps.search` | low | none | safe_read |
| `openphone.screen.get` | `canvas.snapshot` | `screen.get` | low | none | safe_read |
| `openphone.screen.understand_local` | `openphone.local.screen_understanding` | `screen.understand_local` | low | none | safe_read |
| `openphone.notifications.list` | `notifications.list` | `notifications.list` | medium | none | private_read |
| `openphone.notifications.search` | `notifications.search` | `notifications.search` | medium | none | private_read |
| `openphone.notifications.open` | `notifications.open` | `notifications.open` | medium | ask_before_action | dangerous |
| `openphone.contacts.search` | `contacts.search` | `contacts.search` | medium | none | private_read |
| `openphone.calendar.search` | `calendar.events` | `calendar.search` | medium | none | private_read |
| `openphone.calendar.add` | `calendar.add` | `calendar.add` | medium | ask_before_action | dangerous |
| `openphone.calendar.update` | `calendar.update` | `calendar.update` | medium | ask_before_action | dangerous |
| `openphone.calendar.delete` | `calendar.delete` | `calendar.delete` | high | always | dangerous |
| `openphone.messages.search` | `sms.search` | `messages.search` | medium | none | private_read |
| `openphone.messages.draft` | `sms.draft` | `messages.draft` | medium | ask_before_action | dangerous |
| `openphone.messages.send` | `sms.send` | `messages.send` | high | always | dangerous |
| `openphone.calls.search` | `callLog.search` | `calls.search` | medium | none | private_read |
| `openphone.calls.place` | `calls.place` | `calls.place` | high | always | dangerous |
| `openphone.memory.search` | — | `memory.search` | low | none | private_read |
| `openphone.memory.save` | — | `memory.save` | medium | ask_before_action | dangerous |
| `openphone.watchers.list` | — | `watchers.list` | low | none | private_read |
| `openphone.watchers.create` | — | `watchers.create` | medium | ask_before_action | dangerous |
| `openphone.watchers.stop` | — | `watchers.stop` | medium | ask_before_action | dangerous |
| `openphone.jobs.list` | — | `jobs.list` | low | none | safe_read |
| `openphone.jobs.create` | — | `jobs.create` | medium | ask_before_action | dangerous |
| `openphone.jobs.stop` | — | `jobs.stop` | medium | ask_before_action | dangerous |
| `openphone.app.open` | — | `app.open` | low | ask_before_action | dangerous |
| `openphone.url.open` | — | `url.open` | medium | ask_before_action | dangerous |
| `openphone.ui.tap` | — | `ui.tap` | medium | ask_before_action | dangerous |
| `openphone.ui.tap_element` | — | `ui.tap_element` | medium | ask_before_action | dangerous |
| `openphone.ui.long_press` | — | `ui.long_press` | medium | ask_before_action | dangerous |
| `openphone.ui.long_press_element` | — | `ui.long_press_element` | medium | ask_before_action | dangerous |
| `openphone.ui.swipe` | — | `ui.swipe` | medium | ask_before_action | dangerous |
| `openphone.ui.type_text` | — | `ui.type_text` | medium | ask_before_action | dangerous |
| `openphone.input.press_key` | — | `input.press_key` | medium | ask_before_action | dangerous |
| `openphone.clipboard.set` | — | `clipboard.set` | low | ask_before_action | dangerous |
| `openphone.clipboard.paste` | — | `clipboard.paste` | medium | ask_before_action | dangerous |
| `openphone.share.text` | — | `share.text` | high | always | dangerous |

## params_hash

`action.propose`/`action.approve` bind exact parameters with
`params_hash` = `sha256:` + hex SHA-256 of the canonical JSON encoding of
`params` (UTF-8, keys sorted lexicographically at every depth, no
insignificant whitespace) — spec §8.1. Reference implementation:
`adapter.mjs` `canonicalJson()`/`paramsHash()`; shared test vectors:
`fixtures/params-hash-vectors.json` (the first vector is the spec §8.1
example params object).
