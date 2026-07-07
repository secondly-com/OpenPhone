# OpenPhone iOS

OpenPhone iOS brings the OpenPhone agent to iPhone as a phone-resident runtime.
The design mirrors the Android side of this repository: the phone owns the
agent, not a host computer. A launchd daemon on the device owns task state,
tool execution, autonomy policy, memory, watchers, background jobs, audit, and
trajectories. Host-side tools exist only for install, debug, and recovery.

This is experimental proof-of-concept work, not a supported product. It targets
an owned device that already exposes a rootless runtime prefix at `/var/jb`;
reaching that state is the owner's responsibility and out of scope here.

## Layout

```text
agentd/      Phone-resident daemon and companion tweaks (Theos rootless build).
contracts/   iOS command/event/capability contracts and JSON schemas.
shared/      Platform-neutral contracts shared with the Android agent.
tools/       macOS install / debug / validation tooling (not the runtime).
```

## agentd

`openphone-agentd` is the runtime authority. It listens on a phone-local Unix
domain socket and serves the Android-shaped command surface (tasks, screen,
actions, memory, context, commitments, watchers, background jobs, providers,
and the model loop). Companion tweaks provide a SpringBoard hardware trigger and
in-process app UI introspection. See [agentd/README.md](agentd/README.md) for
the command list, build, and on-device debug notes.

Build the rootless package (requires Theos on the build host):

```sh
cd ios/agentd
make package
```

## Contracts

`contracts/` holds the iOS command, event, and capability definitions plus the
action/audit/trajectory JSON schemas. `shared/contracts/` is the deduplicated
set both iOS and Android are meant to build against: the model tool registry,
the model decision schema, and the canonical capability/risk list. The daemon
is the source of truth for the tool surface; keep the shared files in sync when
the daemon tool surface changes.

## Tools

`tools/mac/` installs, restarts, inspects, and validates the daemon over SSH or
a USB-forwarded tunnel. These are development and recovery tools and never run
the agent on the host. Connection details are supplied through environment
variables (`OPENPHONE_IOS_HOST`, `OPENPHONE_IOS_USER`, and so on); no device
identifiers or credentials are committed. See
[tools/mac/agentd/README.md](tools/mac/agentd/README.md).

## Runtime dependencies

At runtime the daemon assumes the device provides `OpenSSH` (for host tooling),
a Substrate-compatible tweak loader (for the SpringBoard tweak), a preference
loader (for the settings pane), the rootless prefix `/var/jb`, and `launchd`
(which runs the daemon from `/var/jb/Library/LaunchDaemons`). This project does
not provide or bundle those components.
