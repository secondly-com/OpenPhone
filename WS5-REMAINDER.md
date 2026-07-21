# WS5 remainder — OpenPhone conformance to Interfaces Protocol v1

Status of WS5 (Interfaces v1 rewrite plan, Part III) on `rewrite/protocol-v1`:
the working vertical slice is done — vendored ifp/1 validator/machine/fixtures,
the `openphone-tools.ifp1.json` manifest re-expressing all 37 commands, the
legacy-event -> action-lifecycle adapter with lifecycle tests, and deprecation
notices on the v0 manifests — all wired into `scripts/check.sh`
(see `runtime/protocol/ifp1/` and `runtime/protocol/ifp1/MIGRATION.md`).
This file lists what remains before the WS5 exit gate.

## 1. Java-side wiring: RuntimeToolBridge / PhoneToolGateway -> ifp/1

- `overlay/packages/apps/OpenPhoneAssistant/src/org/openphone/assistant/runtime/RuntimeToolBridge.java`
  is where the v0 lifecycle lives today: it validates commands against the v0
  manifest, applies autonomy policy, creates `runtime-confirm-*` confirmations
  for mutating tools, executes, and returns tool results. Port it to emit and
  consume ifp/1 action messages using the mapping in
  `runtime/protocol/ifp1/adapter.mjs` (proposal ingestion -> local
  confirmation -> `action.approve`/`action.reject` with canonical
  `params_hash` binding -> idempotent execution -> `action.result` with
  `binding_mismatch`/`action_expired` failure classes). A Java
  canonical-JSON + SHA-256 helper must reproduce
  `runtime/protocol/ifp1/fixtures/params-hash-vectors.json` exactly.
- `overlay/packages/apps/OpenPhoneAssistant/src/org/openphone/assistant/platform/PhoneToolGateway.java`
  (and `OpenPhoneOsToolGateway.java`) — the seam from `refactor/app-os-boundary`
  is already aligned with the target; the ifp/1 executor should call through
  it unchanged. Do not redo the seam.
- Tool-name translation at the boundary: Java command registries key on
  `openphone.<tool>` while ifp/1 uses `<tool>`
  (`x-openphone.superseded_command` in `openphone-tools.ifp1.json` is the
  lookup bridge).

## 2. Ed25519 pairing alignment

The OpenClaw adapter already has Ed25519 device identity:

- `overlay/packages/apps/OpenPhoneAssistant/src/org/openphone/assistant/runtime/adapters/openclaw/OpenClawEd25519.java`
- `overlay/packages/apps/OpenPhoneAssistant/src/org/openphone/assistant/runtime/adapters/openclaw/OpenClawDeviceIdentity.java`

Remaining work: promote this from an OpenClaw-adapter detail to the surface's
ifp/1 identity (spec §6.1–6.3): keypair generated at pairing with the entity's
home, `pair.request`/`pair.grant`/`pair.complete` challenge signature, and a
`control.hello` `payload.proof` signature over the transport nonce
(`x-ifp-nonce` for WebSocket). Key storage should move to the OS keystore
path. No default/dev credential may exist in any configuration.

## 3. OpenClaw / MCP / CLI adapter migration

All three still speak v0 and read `runtime/protocol/openphone-commands.json`:

- `integrations/openclaw-plugin/src/index.ts` (+ `dist/`) — command buckets
  (safe read / private read / dangerous) become ifp/1 tool capabilities and
  surface-local policy.
- `integrations/mcp-server/src/index.mjs` — MCP tools should be generated
  from `openphone-tools.ifp1.json`; the `serverInfo.runtimeProtocol` range
  advertisement becomes ifp/1 `control.hello` protocol negotiation semantics.
- `integrations/cli/src/index.mjs` — same manifest switch; `openphone info`
  advertises ifp/1.
- The byte-sync package copies under `integrations/cli/runtime/protocol/` and
  `integrations/mcp-server/runtime/protocol/` (enforced by
  `tests/integrations/runtime-package-contract.mjs`) must then vendor the
  ifp1 manifest instead.
- `runtime/protocol/openphone-runtime-tools.mjs` grows an ifp/1 loader (or a
  successor module under `ifp1/`) so `mcpTools()`/`commandMap()` consumers
  migrate without ad-hoc parsing.

## 4. Surface/entity ownership stubs (plan WS5 deliverable 3)

Re-label the system_server memory/context/audit stores (patches 0014–0016)
as surface-owned offline cache + audit evidence; stub the sync boundary so
durable-memory writes emit ifp/1 `event.journal.append` to a runtime endpoint
(pointed at the WS3 runtime in a local harness). OS-owned audit stays
phone-permanent; no framework patch is reverted.

## 5. Old-manifest deletion gate

`runtime/protocol/openphone-commands.json` and `openphone-events.json` are
deprecated (`"deprecated": true`, `"superseded_by": "ifp1/"`) but MUST NOT be
deleted until all of the following hold:

1. Items 1–3 above are done (no Java, plugin, MCP, or CLI reader of the v0
   manifests remains).
2. The v0 sections of `runtime/protocol/validate-runtime-protocol.mjs`,
   `openphone-runtime-tools.mjs`, and the v0 contract tests are replaced by
   ifp/1 equivalents (including the Android command-registry cross-checks,
   re-pointed at `openphone-tools.ifp1.json`).
3. `docs/runtime/runtime-agent-protocol.md` is rewritten for ifp/1 (it names
   the v0 manifests as single sources of truth).
4. The ifp/1 fixture corpus has frozen at `v1.0.0-draft` upstream (ADR 0004:
   freeze happens after WS4/presence-kit e2e conformance), so the vendored
   copies here stop moving.

Deletion is the clean major-version break (D5): no compat path ships.

## 6. iOS runtime note

`ios/` does not exist on this branch (the iOS runtime is in flight on
`add-ios-support`). When that line lands or rebases onto ifp/1 work, add to
its README: "This runtime will consume Interfaces Protocol v1; see
`runtime/protocol/ifp1/`." Per the plan, `add-ios-support` is out of scope
for WS5 and consumes ifp/1 later.

## 7. Device-in-loop conformance lane (exit gate)

The WS5 exit gate also requires: existing CI green (full Android build needs
a LineageOS tree — not runnable here), the fixture corpus passing against the
phone-side implementation (device-in-loop or emulator lane), and the
end-to-end local demo with the WS3 runtime (propose -> confirm -> approve
with exact binding -> execute -> audit on both sides; mismatched
approved-vs-executed params rejected by the phone). The node-side halves of
these checks exist today in `tests/integrations/ifp1-adapter-contract.mjs`.

## Spec divergences found (feed back to WS1 before corpus freeze)

1. **Spec §8.1 example `params_hash` is wrong.** The example proposal in
   `interfaces-protocol-1.md` shows
   `sha256:2c26b46b...` for params `{"to": "+15551234567", "body": "on my way"}`,
   but that digest is SHA-256 of the literal string `"foo"`. The canonical
   encoding `{"body":"on my way","to":"+15551234567"}` hashes to
   `sha256:1e920af2c02daa49a449d1ebe938e08f196a9dfa6a3c05b36adbabbd7387193b`
   (vector `spec_8_1_example_params` in
   `runtime/protocol/ifp1/fixtures/params-hash-vectors.json`).
2. **No canonical-JSON test vectors in the shared fixture corpus.** The
   validators only regex-check `sha256:<hex64>`; nothing cross-checks the
   canonicalization itself (unicode handling, nested key sorting). Upstream
   `fixtures/params-hash-vectors.json` into
   `packages/interfaces-protocol/fixtures/` and both reference validators.
3. **Canonicalization needs one more sentence of precision.** "UTF-8, sorted
   keys, no insignificant whitespace" should state: keys sorted at every
   nesting depth by Unicode code point, strings serialized without ASCII
   escaping of non-ASCII characters (UTF-8 bytes hashed), and numbers
   restricted to interoperable forms (e.g. no `1.0` vs `1` ambiguity — or
   forbid non-integer numbers in params).
4. **`action.propose` sender lacks generation fencing.** `generation` is
   required on `event.*`, `action.approve`, and `action.result`, but a stale
   runtime can still propose actions. Probably fine (the approve/result fence
   catches it), but worth an explicit spec note.
5. **Risk taxonomy loses information.** v0 distinguishes `risk` from
   `confirmation` (`none`/`ask_before_action`/`always`) and `default_exposure`.
   ifp/1 folds these into `risk` + surface-local policy — intentional per
   §8.2, but the tools manifest needed an `x-` extension
   (`x-openphone`) to carry the policy inputs. If other surfaces need the
   same, consider a standard optional field on tool capability declarations.
