# OpenPhone

![OpenPhone GitHub hero](docs/assets/github_hero.png)

[![CI](https://github.com/secondly-com/OpenPhone/actions/workflows/ci.yml/badge.svg)](https://github.com/secondly-com/OpenPhone/actions/workflows/ci.yml)
[![Release](https://github.com/secondly-com/OpenPhone/actions/workflows/release.yml/badge.svg)](https://github.com/secondly-com/OpenPhone/actions/workflows/release.yml)
[![Docs](https://img.shields.io/badge/docs-openphone.secondly.com-black)](https://docs.openphone.secondly.com)
[![Discord](https://img.shields.io/badge/community-Discord-5865F2?logo=discord&logoColor=white)](https://discord.gg/t8hfBH5vb)
![License](https://img.shields.io/badge/license-PolyForm%20Noncommercial-blue)
![Status](https://img.shields.io/badge/status-developer%20preview-orange)

**Docs: [docs.openphone.secondly.com](https://docs.openphone.secondly.com)** |
**Community: [Join the Discord](https://discord.gg/t8hfBH5vb)**

OpenPhone is an AI-native Android OS that turns the phone into an agentic
device: a system-level AI agent that can see the screen, operate apps, remember
commitments, monitor phone events, and continue work in the background with
user review and auditability built into the OS.

This repository is the canonical OpenPhone entry point. It contains the
OpenPhone-owned Android overlay, privileged assistant app, framework patches,
model/tool policy configuration, build scripts, device notes, contracts, and
release tooling. It intentionally does not vendor the full Android source tree.

## AI-Native Phone Runtime

OpenPhone is built around a system-level agent, not a chatbot app. The agent is
installed as a privileged OS component with an always-available system surface
for conversation, realtime voice, approvals, active runs, and proactive state.
Actions are mediated through OpenPhone framework services instead of brittle
app-layer automation.

The agent can read structured phone context and use model-visible tools to work
across apps. Context includes the foreground app, visible UI hierarchy, screen
text and controls, notifications, calls, messages, calendar state, location,
battery, connectivity, active watchers, background runs, and commitments the
user made in conversation. Sensitive actions are reviewable, and behavior can
be inspected through audit logs, trajectories, screenshots, policy decisions,
and release validators.

OpenPhone is also built for proactive work. Heartbeats quietly check whether
anything needs attention. Scheduled jobs run exact workflows. Watchers monitor
phone context such as missed calls, messages, notifications, foreground app
state, visible screen state, calendar changes, location, battery, connectivity,
and commitments the user made in conversation. Background runs keep working
after the current chat turn, while the system surface shows what is running, why
it started, what it last said, and what needs review.

The current developer preview is based on LineageOS 23.2 / Android 16 and
targets Google Pixel 9a (`tegu`) first.

## Use Cases

- "Catch me up on everything important from overnight" - consume missed calls,
  messages, notifications, calendar changes, and reminders, then return a short
  morning gist.
- "Order me an Uber to the office" - open the right app, set the destination,
  select a ride, and stop for review before booking.
- "Play something random on Spotify" - open Spotify, choose music, and continue
  until playback actually starts.
- "If I miss a call from this number, send them 'I'll call you back soon'" -
  create a watcher tied to future call context and message policy.
- "Watch for delivery updates and only bother me if something changes" - turn
  notification noise into a targeted background monitor.
- "Help me finish this screen" - inspect the visible app state, identify the
  next control, and act through OS-mediated taps or text input.
- "Remind me when this conversation becomes relevant" - turn a commitment into
  durable state that can resurface later based on time, app, or phone context.
- "Keep working on this after I leave" - continue a multi-step task as a
  visible background run with approval where needed.

## Repository Layout

```text
.github/       CI, release, eval, contribution, security, issue, and PR files.
docs/          Product docs, device notes, legal docs, releases, and testing.
manifests/     Android repo local manifests.
overlay/       OpenPhone-owned files copied into the Android tree.
patches/       Patch stacks applied on top of upstream LineageOS repos.
schemas/       Machine-readable runtime contracts and release/eval schemas.
scripts/       Sync, patch, build, flash, validation, and release helpers.
services/      Reference services, including the development model broker.
```

Start with [docs/index.md](docs/index.md) for the docs landing, or
[docs/README.md](docs/README.md) for a topic index.

## How It Works

```mermaid
flowchart TB
  User["User<br/>voice, touch, text, volume chord"]
  Surface["OpenPhone system surface<br/>chat, realtime voice, approvals, runs"]
  Assistant["Privileged OpenPhoneAssistant<br/>orchestrator, model adapters, tool loop"]
  Runtime["Proactive runtime<br/>heartbeats, scheduled jobs, watchers, background runs"]
  Context["Phone context<br/>visible UI, foreground app, notifications, calls, messages,<br/>calendar, location, battery, commitments"]
  Services["OpenPhone OS services<br/>openphone_agent, openphone_context, openphone_assistant_data"]
  Policy["Policy, approval, and evidence<br/>capabilities, confirmations, audit logs, trajectories"]
  Android["Android framework<br/>ActivityTaskManager, WindowManager, InputManager, NotificationManager"]
  Apps["Apps and device<br/>Settings, Messages, Spotify, Uber, Pixel 9a"]

  User --> Surface
  Surface --> Assistant
  Assistant --> Runtime
  Assistant --> Services
  Runtime --> Services
  Services --> Context
  Services --> Policy
  Services --> Android
  Android --> Apps
  Apps --> Context
  Policy --> Surface
```

The high-level architecture is documented in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). The capability model is in
[docs/CAPABILITIES.md](docs/CAPABILITIES.md), and machine-readable contracts
live under [schemas](schemas).

## Quick Start

The fastest way to see OpenPhone running is the SDK phone emulator. On a
Linux Android build host:

```bash
./scripts/install-repo.sh          # once, if you don't have `repo`
./scripts/sync.sh
./scripts/apply-patches.sh
./scripts/build-emulator.sh --arch arm64     # or --arch x86_64
```

Then copy the resulting `sdk-repo-linux-system-images.zip` to your
workstation and boot it in a local AVD. The full walkthrough — sync, image
install, AVD creation, boot, and verification — is in
**[docs/quickstart.md](docs/quickstart.md)**.

**Other paths:**

- Flash a Pixel 9a → [docs/BUILD.md](docs/BUILD.md)
- Understand the system → [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- Integrate a runtime → [docs/runtime/runtime-agent-protocol.md](docs/runtime/runtime-agent-protocol.md)
- Port a new device → [docs/DEVICE_SUPPORT.md](docs/DEVICE_SUPPORT.md)
- Contribute → [docs/contribution-guide.md](docs/contribution-guide.md)

Validate the repository at any time with:

```bash
./scripts/check.sh
git diff --check
```

## Device Support

OpenPhone builds on LineageOS device infrastructure, so the broader universe of
potential ports starts with the official LineageOS supported-device list:
[wiki.lineageos.org/devices](https://wiki.lineageos.org/devices/). OpenPhone
support is narrower: a device is only supported after it has an OpenPhone
product target, flash/recovery notes, hardware validation, agent validation, and
release coverage.

The first OpenPhone physical target is Google Pixel 9a (`tegu`). Generic ARM64
builds are useful for product graph validation, but they are not a supported
phone target.

OpenPhone does not redistribute Google apps, Google Mobile Services, vendor
blobs, signing keys, private firmware, or restricted device material. Local
developer GMS sideload notes are in [docs/GMS.md](docs/GMS.md).

See [docs/devices/MATRIX.md](docs/devices/MATRIX.md) and
[docs/devices/tegu.md](docs/devices/tegu.md).

## Community

Join the [OpenPhone Discord](https://discord.gg/t8hfBH5vb) to follow development,
ask build and device-porting questions, share validation results, and meet other
people working on AI-native phones.

Contributions, issues, and device validation reports are welcome under the terms
in [.github/CONTRIBUTING.md](.github/CONTRIBUTING.md).

## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=secondly-com/OpenPhone&type=Date)](https://www.star-history.com/#secondly-com/OpenPhone&Date)

## Commercial Use

OpenPhone-owned materials are source-available for non-commercial use under the
PolyForm Noncommercial License 1.0.0. Commercial use requires a separate written
license from Dafdef, inc.

Contributions are accepted only under terms that allow Dafdef, inc. to own,
modify, sublicense, redistribute, and commercialize the submitted work. See
[.github/CONTRIBUTING.md](.github/CONTRIBUTING.md),
[docs/legal/COMMERCIAL.md](docs/legal/COMMERCIAL.md), [LICENSE](LICENSE),
[docs/legal/LICENSE.noncommercial](docs/legal/LICENSE.noncommercial), and
[docs/legal/THIRD_PARTY_NOTICES.md](docs/legal/THIRD_PARTY_NOTICES.md).
