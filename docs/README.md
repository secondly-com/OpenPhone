# OpenPhone Documentation

This is the topic index for OpenPhone docs. For the narrative landing, see
[index.md](index.md) (also served at `/docs` on the docs site).

The static docs site uses Fumadocs with a Next.js app in `docs/site`. Build
it locally with:

```bash
./scripts/build-docs.sh
```

## Get Started

- [Quickstart](quickstart.md) — build the SDK phone emulator image and boot
  OpenPhone on your workstation.
- [Build](BUILD.md) — full `repo` sync, patch, and Pixel 9a build.
- [Emulator](EMULATOR.md) — deeper emulator setup: headless, `scrcpy`
  mirroring, CLI/MCP smoke, OpenClaw runtime smoke.

## Concepts

- [Architecture](ARCHITECTURE.md) — system layers, OS services, agent
  runtime, and current implementation boundaries.
- [Capabilities](CAPABILITIES.md) — named capabilities, risk levels, and
  policy configuration.
- [Agent Runtime](AGENT_RUNTIME_V1.md) — background job model, scheduling,
  and safety posture for durable agent work.

## Integrate

- [Runtime Agent Protocol](runtime/runtime-agent-protocol.md) — the generic
  Phone/OpenClaw/Hermes runtime boundary.
- [Runtime Security Model](runtime/security-model.md) — remote runtime trust
  boundaries, confirmation requirements, identity storage, prompt safety.
- [OpenClaw Integration](runtime/openclaw-integration.md) — Android adapter
  and validation path.
- [Hermes Integration](runtime/hermes-integration.md) — planned adapter
  shape.
- [MCP Bridge](runtime/mcp-bridge.md) — manifest-backed MCP and CLI access to
  OpenPhone tools.

## Devices

- [Device Support](DEVICE_SUPPORT.md) — states, acceptance model, and
  candidate device policy.
- [Device Matrix](devices/MATRIX.md)
- [Pixel 9a Notes](devices/tegu.md)
- [Pixel 9a Boot Chain](TEGU_BOOTCHAIN.md)
- [Google Mobile Services](GMS.md) — local developer sideload notes.

## Contribute

- [Contributing](contribution-guide.md) — terms, security policy, local
  checks.
- [AI-First Engineering](AI_FIRST_ENGINEERING.md) — operating loops we run
  against this repo.
- [Testing](TESTING.md) — repo checks, physical device smoke tests,
  assistant evals, trajectory validation.
- [Release Process](RELEASE_PROCESS.md)

## Reference

- [Releases](releases/README.md) and
  [Changelog](releases/CHANGELOG.md).
- Machine-readable JSON Schema contracts live in
  [../schemas](../schemas). They define payload shapes for action requests,
  model tools, screen context, audit events, trajectories, OTA feeds, and
  agent eval reports.
- Runtime Agent Protocol manifests live in
  [../runtime/protocol](../runtime/protocol).
- [Licensing](LICENSING.md), [Legal](legal/README.md), and
  [Commercial Licensing](legal/COMMERCIAL.md).
