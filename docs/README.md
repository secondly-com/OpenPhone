# OpenPhone Documentation

This is the public documentation map for OpenPhone. Start here for current
build, architecture, release, device, and policy docs.

The first static docs site scaffold uses Mintlify. Validate it locally with:

```bash
./scripts/build-docs.sh
```

## Start Here

- [Architecture](ARCHITECTURE.md) - system layers, OS services, agent runtime,
  and current implementation boundaries.
- [AI-First Engineering](AI_FIRST_ENGINEERING.md) - repository operating loops,
  CI/eval target state, agent routines, and docs-site direction.
- [Agent Runtime V1](AGENT_RUNTIME_V1.md) - background job model, scheduling,
  safety posture, and migration path for durable agent work.
- [Runtime Agent Protocol](runtime/runtime-agent-protocol.md) - generic
  Phone/OpenClaw/Hermes runtime boundary, sessions, tool requests, and
  autonomy.
- [Runtime Security Model](runtime/security-model.md) - remote runtime trust
  boundaries, confirmation requirements, identity storage, and prompt/context
  safety.
- [OpenClaw Integration](runtime/openclaw-integration.md) - Android adapter,
  OpenClaw plugin boundary, and validation path.
- [Hermes Integration](runtime/hermes-integration.md) - expected future
  Hermes adapter shape on the same runtime protocol.
- [MCP Bridge](runtime/mcp-bridge.md) - manifest-backed MCP and CLI access to
  OpenPhone tools.
- [Emulator First Test Path](EMULATOR.md) - build the SDK phone image, install
  a local AVD, view the emulator UI, and smoke CLI/MCP/OpenClaw integrations.
- [Build](BUILD.md) - Android repo sync, patch application, generic build, and
  Pixel 9a build commands.
- [Testing](TESTING.md) - repository checks, physical device smoke tests,
  assistant evals, and trajectory validation.
- [Capability Model](CAPABILITIES.md) - named capabilities, risk levels, and
  policy configuration.
- [Local Agent Notes](LOCAL_AGENT_NOTES.md) - convention for ignored local-only
  markdown scratch space.

## Device And Release Docs

- [Device Support](DEVICE_SUPPORT.md)
- [Device Matrix](devices/MATRIX.md)
- [Pixel 9a Notes](devices/tegu.md)
- [Pixel 9a Boot Chain](TEGU_BOOTCHAIN.md)
- [Google Mobile Services Notes](GMS.md)
- [Release Process](RELEASE_PROCESS.md)
- [0.0.1 Release Notes](releases/0.0.1.md)
- [Changelog](releases/CHANGELOG.md)

## Contract Schemas And Protocols

Machine-readable JSON Schema contracts live in [../schemas](../schemas). They
define payload shapes for action requests, model tools, screen context, audit
events, trajectories, OTA feeds, and agent eval reports.
The Runtime Agent Protocol command/event/capability manifests live in
[../runtime/protocol](../runtime/protocol).

## Licensing

- [Licensing Notes](LICENSING.md)
- [Legal Index](legal/README.md)
- [Commercial Licensing](legal/COMMERCIAL.md)
- [Contribution Terms](../.github/CONTRIBUTING.md)
- [Security Policy](../.github/SECURITY.md)
