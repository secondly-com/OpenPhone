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

Set `ANDROID_SERIAL` to target a specific ADB device or emulator. Set
`OPENPHONE_DRY_RUN=1` for parser/protocol tests without ADB.

The server speaks the MCP stdio transport: newline-delimited JSON-RPC (one
message per line, no `Content-Length` headers) and negotiates
`protocolVersion` during `initialize` (latest supported: `2025-06-18`).

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
