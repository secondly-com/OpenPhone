# OpenPhone Runtime MCP Server

MCP server exposing OpenPhone runtime tools from
`runtime/protocol/openphone-commands.json`.

The first transport is ADB, so this is useful for local development, Hermes
tool access, and other MCP-capable agents that need phone inspection or simple
phone actions without a custom Android runtime adapter.

Run:

```sh
node integrations/mcp-server/src/index.mjs
```

Set `ANDROID_SERIAL` to target a specific ADB device or emulator.

Safety defaults:

- `OPENPHONE_DRY_RUN=1` is the safe default for exploration: every tool call is
  echoed back without touching ADB or the device at all.
- Without dry-run, the ADB transport still refuses state-changing tools (tap,
  type, clipboard, open-url, and anything else the runtime manifest marks with
  a `confirmation` requirement) because ADB has no on-device confirmation UI.
  Read-only tools such as `openphone.screen.get` work normally.
- Set `OPENPHONE_ADB_ALLOW_STATEFUL=1` to opt in to real device driving for the
  session. Programmatic users can pass `allowStateful: true` to
  `OpenPhoneAdbTransport` instead. Only enable this when you trust every MCP
  client connected to the server, since confirmation prompts are not enforced.

The server speaks the MCP stdio transport: newline-delimited JSON-RPC (one
message per line, no `Content-Length` headers) and negotiates
`protocolVersion` during `initialize` (latest supported: `2025-11-25`).

The same ADB transport works with the OpenPhone SDK phone emulator:

```sh
ANDROID_SERIAL=emulator-5584 \
ADB="$ANDROID_HOME/platform-tools/adb" \
node integrations/mcp-server/src/index.mjs
```

See [../../docs/EMULATOR.md](../../docs/EMULATOR.md) for the AVD setup and
emulator smoke commands.

Boundary:

- MCP exposes tools.
- Runtime sessions, volume-button attention, watcher pushes, and Dynamic Island
  lifecycle are still owned by the OpenPhone runtime protocol.
