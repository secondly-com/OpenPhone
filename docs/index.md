# OpenPhone

OpenPhone is an AI-native Android OS. Instead of a chatbot app bolted onto a
phone, OpenPhone runs a system-level agent as a privileged OS component that
can see the screen, operate apps, remember commitments, watch phone events,
and continue work in the background — with user review and auditability built
into the OS.

The current developer preview is based on LineageOS 23.2 / Android 16 and
targets Google Pixel 9a (`tegu`) first.

## What can you do with it

- "Catch me up on everything important from overnight" — consume missed
  calls, messages, notifications, and calendar changes, then return a short
  morning gist.
- "Order me an Uber to the office" — open the right app, set the
  destination, select a ride, and stop for review before booking.
- "If I miss a call from this number, send them 'I'll call you back soon'" —
  create a watcher tied to future call context and message policy.
- "Watch for delivery updates and only bother me if something changes" —
  turn notification noise into a targeted background monitor.
- "Keep working on this after I leave" — continue a multi-step task as a
  visible background run with approval where needed.

More context on the runtime model is in
[Architecture](/docs/ARCHITECTURE) and
[Agent Runtime](/docs/AGENT_RUNTIME_V1).

## Pick a path

**I want to try it.** The fastest path is the SDK phone emulator. It boots
OpenPhone on your workstation and lets you smoke-test the framework services,
the assistant app, and the CLI/MCP surface without flashing a device.
→ [Quickstart](/docs/quickstart)

**I want to build for hardware.** OpenPhone builds a full Android image for
Pixel 9a via the standard `repo` workflow. This needs a Linux build host and
several hundred GB of disk. → [Build](/docs/BUILD)

**I want to understand how it works.** Start with
[Architecture](/docs/ARCHITECTURE), then read
[Capabilities](/docs/CAPABILITIES) (what the agent is allowed to do) and
[Agent Runtime](/docs/AGENT_RUNTIME_V1) (how background jobs work).

**I want to integrate a runtime or tools.** OpenPhone exposes the phone as a
protocol endpoint. Adapters like OpenClaw and Hermes map remote agent
runtimes onto the same phone tool surface. Start with the
[Runtime Agent Protocol](/docs/runtime/runtime-agent-protocol).

**I want to port it to a new device.** Read
[Device Support](/docs/DEVICE_SUPPORT) for the acceptance model, then the
[Pixel 9a notes](/docs/devices/tegu) as a working example.

**I want to contribute.** Read the
[Contribution guide](/docs/contribution-guide) and the
[AI-First Engineering](/docs/AI_FIRST_ENGINEERING) loops we run against the
repo.

## What's in this repo

This repository is the canonical OpenPhone entry point. It contains the
OpenPhone-owned Android overlay, the privileged assistant app, framework
patches, model/tool policy configuration, build scripts, device notes,
machine-readable contracts, and release tooling. It does not vendor the full
Android source tree — the standard `repo` workflow does that.

```text
docs/          Product docs, device notes, legal, releases, testing.
manifests/     Android repo local manifests.
overlay/       OpenPhone-owned files copied into the Android tree.
patches/       Patch stacks applied on top of upstream LineageOS repos.
schemas/       Machine-readable runtime contracts and eval schemas.
scripts/       Sync, patch, build, flash, validation, and release helpers.
services/      Reference services, including the development model broker.
runtime/       Runtime Agent Protocol manifests.
```

## License

OpenPhone-owned materials are source-available for non-commercial use under
the PolyForm Noncommercial License 1.0.0. Commercial use requires a separate
written license from Dafdef, inc. See [Licensing](/docs/LICENSING).
