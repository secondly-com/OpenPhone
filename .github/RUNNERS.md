# Self-Hosted Runners

OpenPhone uses GitHub-hosted runners for lightweight repository checks and
self-hosted runners for work that needs a full Android tree or a physical
phone.

Do not document private hostnames, SSH key names, public IP addresses, API
keys, signing key paths, or device secrets in this file. Keep environment-
specific operator notes outside the public repository.

## Runner Labels

| Label | Used by | Purpose |
| --- | --- | --- |
| `openphone-build` | `release.yml` | Builds Pixel/device artifacts on a large Linux Android build host. |
| `openphone-emulator` | `emulator.yml` | Builds or reuses an OpenPhone SDK phone image, boots it in the Android emulator, and runs fast runtime smoke checks. |
| `openphone-device` | `eval.yml` | Runs evals against an authorized Android device connected over USB. |

## `openphone-build`

The build runner needs:

- Linux x86_64 host.
- Full Android build dependencies for the selected LineageOS branch.
- Several hundred GB of free disk space.
- Java version required by the Android branch.
- `repo`, `git-lfs`, `python3`, `bash`, and standard Android build tools.
- Repository checkout with `.worktree/android` or `OPENPHONE_ANDROID_DIR`
  pointing at the synced Android tree.

Register the runner with labels similar to:

```bash
./config.sh \
  --url https://github.com/<org>/<repo> \
  --token <registration-token> \
  --labels self-hosted,openphone-build \
  --name openphone-build-<host>
```

Install it as a service according to GitHub's self-hosted runner instructions
for the host OS.

## `openphone-emulator`

The emulator runner needs:

- Linux x86_64 or macOS host with hardware acceleration suitable for Android
  Emulator.
- Full Android build dependencies for the selected LineageOS branch.
- Android SDK Platform Tools and Emulator on `PATH`.
- `adb`, `emulator`, `node`, `python3`, `bash`, `git-lfs`, and `repo`.
- Repository checkout with `.worktree/android` or `OPENPHONE_ANDROID_DIR`
  pointing at the synced Android tree.
- Enough disk for the Android tree, incremental build outputs, emulator system
  image, and wiped userdata.

Prefer setting `OPENPHONE_ANDROID_DIR` to a persistent path outside the Actions
checkout. The workflow disables checkout cleaning to avoid deleting
`.worktree/android`, but keeping the Android tree outside the repository
workspace is easier to reason about on long-lived runners.

Register the runner with labels similar to:

```bash
./config.sh \
  --url https://github.com/<org>/<repo> \
  --token <registration-token> \
  --labels self-hosted,openphone-emulator \
  --name openphone-emulator-<host>
```

The workflow runs `scripts/run-emulator-smoke.sh`. On pull requests, it only
runs for same-repository branches because self-hosted runners must not execute
untrusted fork code with local Android build state.

## `openphone-device`

The device runner needs:

- `adb` on `PATH`.
- A physical supported device connected over USB and authorized for ADB.
- The current OpenPhone development build installed on the device.
- Any provider keys or broker tokens stored only in ignored local paths or
  GitHub Actions secrets.
- Enough local disk to collect trajectory, screenshot, audit, and eval reports.

Register the runner with labels similar to:

```bash
./config.sh \
  --url https://github.com/<org>/<repo> \
  --token <registration-token> \
  --labels self-hosted,openphone-device \
  --name openphone-device-<host>
```

## Why GitHub-Hosted Runners Are Not Enough

- Android source checkouts and build output are too large for standard
  GitHub-hosted runner disk limits.
- Headless emulator boot with OpenPhone system images needs a prepared Android
  tree, SDK Emulator, acceleration, and enough local disk.
- Physical evals require a real phone connected over USB.

The normal CI workflow in `ci.yml` stays on `ubuntu-latest` and only runs
repository checks such as `scripts/check.sh`.
