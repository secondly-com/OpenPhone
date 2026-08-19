# OpenPhone Runtime Agent Protocol

OpenPhone exposes the phone as a runtime endpoint. A runtime can be local
(`Phone`) or remote (`OpenClaw`, future `Hermes`, MCP clients, CLI tools).
Android owns the screen/action surface, session records, and user confirmation
boundary; remote runtimes own agent reasoning.

## Flow

1. A phone surface creates an attention request: chat, volume voice, Dynamic
   Island, watcher, job, or notification.
2. `RuntimeManager` creates a phone execution session and sends the request to
   the selected `RuntimeAdapter`.
3. The adapter maps the generic request to the runtime's wire protocol.
4. The runtime may answer directly or request phone tools.
5. `RuntimeToolBridge` validates the command, applies autonomy policy, creates
   confirmations for mutating actions, runs the phone tool, and returns the
   result.
6. A runtime may return plain text unchanged, or explicitly send an
   `openphone.assistant_output.v1` envelope containing speech/text and an
   optional `openphone.surface.v1` document. OpenPhone never attempts to parse
   arbitrary assistant prose as an envelope.

## Stable Concepts

- Runtime: an agent backend selected by the user.
- Surface: the phone source that initiated a request.
- Phone session: durable Android-owned execution state.
- Runtime session: backend-owned session/thread/run key.
- Attention request: phone-to-runtime user request.
- Tool request: runtime-to-phone inspect/action request.
- Confirmation: Android-local approval for risky actions.
- Assistant output: runtime-neutral structured result with optional surface.
- Adaptive surface: revisioned, phone-validated UI document whose actions are
  bound back to registered phone tools.

## Adaptive Surface Events

The additive V1 events are:

- `runtime.surface.present`;
- `runtime.surface.replace` with `expected_revision`;
- `runtime.surface.dismiss`;
- `runtime.surface.action_result`;
- `phone.surface.action_invoked`;
- `phone.surface.dismissed`.

The phone verifies transport/runtime/session ownership before accepting a
surface. Replacement and dismissal are revision-bound. Renderer actions resolve
against the current stored revision and use `RuntimeToolBridge`; remote
runtimes cannot bypass local policy or confirmation. Accepted surfaces remain
inspectable if the runtime disconnects, while the phone execution session moves
to a terminal error state.

## Autonomy

- `observe_only`: read-only tools may run; mutating tools are denied.
- `ask_before_action`: mutating tools require Android confirmation.
- `trusted_actions`: low/medium-risk mutating tools may run without OpenPhone
  confirmation, but high-risk tools and OS/app confirmations still require
  confirmation.

If a runtime tool call omits autonomy, OpenPhone inherits the phone execution
session's autonomy. If no session is available, it falls back to
`ask_before_action`.

## Single Sources Of Truth

- Commands: `runtime/protocol/openphone-commands.json`
- Events: `runtime/protocol/openphone-events.json`
- Capabilities: `runtime/protocol/openphone-capabilities.json`
- Shape reference: `runtime/protocol/openphone-runtime.schema.json`
- Surface/output contracts: `schemas/openphone-surface.schema.json` and
  `schemas/openphone-assistant-output.schema.json`

## Versioning

Every protocol manifest carries an integer `version`. Consumers load
manifests through `runtime/protocol/openphone-runtime-tools.mjs`, which
accepts an inclusive supported range (`RUNTIME_PROTOCOL_VERSION_RANGE`,
currently `min_version=1`, `max_version=1`) instead of a single pinned
version, so new manifest versions can roll out without breaking older
clients.

### Handshake advertisement

Integrations advertise the supported runtime-protocol range in a
structured way so clients can negotiate before invoking tools:

- MCP server: the `initialize` result's `serverInfo.runtimeProtocol`
  field carries `{ name, min_version, max_version }`. (This is separate
  from the MCP `protocolVersion` date string, which versions the MCP
  transport itself.)
- CLI: `openphone info --json` prints the same structure under
  `runtime_protocol`.

### Version-bump policy

- Additive, backward-compatible changes (new commands, new optional
  fields, new events/capabilities) do NOT bump the manifest version.
- Breaking changes (removing or renaming a command, changing a field's
  meaning or required shape) require bumping the manifest `version` and
  raising `max_version` in `RUNTIME_PROTOCOL_VERSION_RANGE`. Keep
  `min_version` unchanged while old clients are still supported.
- Raise `min_version` only when support for an old manifest version is
  deliberately dropped; announce it in release notes first.
- Instead of removing a command in place, mark it `deprecated: true` and
  point at its replacement with `superseded_by: "<command>"`. The
  validator (`runtime/protocol/validate-runtime-protocol.mjs`, run by
  `scripts/check.sh`) enforces that `superseded_by` references an
  existing command and is only set alongside `deprecated: true`.
  Deprecated commands must keep working for at least one released
  version before removal (which is the breaking change that bumps the
  manifest version).
