# Build

OpenPhone uses Android's normal `repo` workflow. This repository stays small
and contains only OpenPhone-owned code, manifests, scripts, and patches.

## Prerequisites

- Linux Android build host dependencies installed for full device images.
- macOS can sync, patch, extract blobs, and build host/module validation
  targets, but this Android branch does not emit full phone images on Darwin.
- `repo` available in `PATH`.
- `git-lfs` installed and initialized.
- GNU coreutils on macOS.
- Java version required by the selected Android/Lineage branch.
- Large case-sensitive filesystem required.
- At least several hundred GB of free disk space.

Install `repo` into `~/.local/bin`:

```bash
./scripts/install-repo.sh
```

Install Git LFS on macOS:

```bash
brew install git-lfs
git lfs install
```

Install GNU coreutils on macOS:

```bash
brew install coreutils
```

On macOS, create a case-sensitive APFS sparse image before syncing:

```bash
./scripts/create-macos-build-volume.sh
export OPENPHONE_ANDROID_DIR="$PWD/.worktree/OpenPhoneAndroid/android"
```

For a flashable Pixel 9a build, use a Linux x86_64 host or VM with enough disk
and RAM. Docker Desktop on Apple Silicon can run Linux/amd64 containers, but a
full Android build through emulation is usually too slow and too memory-limited
for practical ROM work.

## Environment

Useful variables:

```bash
OPENPHONE_ANDROID_DIR=/path/to/android/tree
LINEAGE_BRANCH=lineage-23.2
LINEAGE_MANIFEST_URL=https://github.com/LineageOS/android.git
OPENPHONE_LUNCH_TARGET=openphone_arm64-userdebug
```

Defaults:

```text
OPENPHONE_ANDROID_DIR=.worktree/android
LINEAGE_BRANCH=lineage-23.2
LINEAGE_MANIFEST_URL=https://github.com/LineageOS/android.git
OPENPHONE_RELEASE=bp4a
```

## Sync

```bash
./scripts/sync.sh
```

This initializes or updates the Android checkout and installs the OpenPhone
local manifest.

## Apply OpenPhone Overlay and Patches

```bash
./scripts/apply-patches.sh
```

This copies `overlay/` into the Android tree and applies any patch files under
`patches/`.

## Build

Generic OpenPhone ARM64 build:

```bash
./scripts/build.sh openphone_arm64
```

The Pixel 9a target uses the `bp4a` release suffix:

```bash
OPENPHONE_RELEASE=bp4a ./scripts/build.sh openphone_tegu
```

Default build goal:

```text
OPENPHONE_BUILD_GOAL=droid
OPENPHONE_SKIP_SOONG_TESTS=true
```

Build only the assistant module:

```bash
OPENPHONE_BUILD_GOAL=OpenPhoneAssistant ./scripts/build.sh openphone_arm64
```

The assistant module target is `OpenPhoneAssistant`.

Build only the framework service validation target:

```bash
OPENPHONE_BUILD_GOAL=MODULES-IN-frameworks-base-services-core ./scripts/build.sh openphone_arm64
```

This validates the hidden `OpenPhoneAgentManager` framework API,
`OpenPhoneAgentManagerService`, and `SystemServer` startup wiring without
building the full product graph.

## Emulator Build

OpenPhone provides LineageOS SDK phone products for the first runnable OS test
path:

```text
openphone_sdk_phone_x86_64-bp4a-eng
openphone_sdk_phone_arm64-bp4a-eng
```

Choose the image architecture for the workstation that will run the emulator
UI: `arm64` for Apple Silicon and `x86_64` for Intel/x86_64 workstations. The
GCP lab workflow can produce portable image zips from warm Android cache state.
The `eng` variant is the default because ADB is enabled without first
completing emulator-side developer settings.

Build the ARM64 emulator image:

```bash
./scripts/build-emulator.sh --arch arm64
```

Build the x86_64 image instead when the local emulator workstation is x86_64:

```bash
./scripts/build-emulator.sh --arch x86_64
```

By default this builds `droid emu_img_zip`. To only build the runnable Android
image from the same product:

```bash
OPENPHONE_BUILD_GOAL=droid ./scripts/build-emulator.sh --arch arm64
```

After the image is built, run it from the same Android tree:

```bash
./scripts/run-emulator.sh --arch arm64
```

This requires the Android SDK Emulator binary to be installed and available as
`emulator` in `PATH`. The portable artifact is
`out/target/product/<device>/sdk-repo-linux-system-images.zip`, which can be
copied to a workstation and installed into Android Studio/AVD.

The full local install, manual AVD fallback for custom `android-36.1` images,
visible UI launch, `scrcpy` mirror, and post-boot verification commands are in
[EMULATOR.md](EMULATOR.md).

For a headless remote host, pass emulator options after `--`:

```bash
./scripts/run-emulator.sh --arch x86_64 -- -no-window -gpu swiftshader_indirect
```

On LineageOS 21 and newer, `emu_img_zip` writes
`sdk-repo-linux-system-images.zip` under `out/target/product/<device>/` for
use with Android Studio/AVD system image installs.

### GCP Lab Build Host

For remote builds, use the GCP lab scripts or workflow. They create a
disposable VM, attach or restore warm Android cache state, run the build, copy
artifacts back, and delete the VM unless debugging keeps it.

```bash
scripts/lab/gcp/run-smoke.sh \
  --cache-mode snapshot \
  --cache-source-snapshot "$OPENPHONE_GCP_CACHE_SOURCE_SNAPSHOT" \
  --arch x86_64 \
  --runtime local
```

To refresh the warm GCP cache intentionally:

```bash
scripts/lab/gcp/prewarm-cache.sh \
  --cache-disk openphone-cache-x86-64-bp4a \
  --arch x86_64
```

The pre-sync scaffold check may skip the standalone Java check when the full
Android build provides the authoritative compiler/toolchain validation.

Current generic-target status:

- `OPENPHONE_BUILD_GOAL=droid ./scripts/build.sh openphone_arm64` has been
  validated on the prepared macOS build host for host/module graph coverage.
- `OPENPHONE_BUILD_GOAL=MODULES-IN-frameworks-base-services-core ./scripts/build.sh openphone_arm64`
  has been validated for the first OpenPhone framework service patch.
- `OPENPHONE_BUILD_GOAL=OpenPhoneAssistant ./scripts/build.sh openphone_arm64`
  has been validated for the privileged assistant bridge to the framework
  service.
- The generic target validates the OpenPhone product graph and packages, but it
  is not yet a device-flashable OpenPhone release.
- In this branch, `systemimage` is not a valid build goal for the generic
  `openphone_arm64` target. Device-specific image output starts after a real
  device target is added.

Device-specific OpenPhone Pixel 9a build on Linux:

```bash
OPENPHONE_ANDROID_DIR=/path/to/android/tree \
OPENPHONE_RELEASE=bp4a \
OPENPHONE_BUILD_GOAL="target-files-package ota_from_target_files" \
./scripts/build.sh openphone_tegu
```

The Pixel 9a product is `openphone_tegu-bp4a-userdebug`. Native macOS builds
will only build host-side targets because `build/make/core/main.mk` restricts
Darwin to host modules.

For `openphone_tegu` and `openphone_tegu_smoke`, `scripts/build.sh`
automatically prepares the Pixel 9a DTB before target-files/OTA-producing build
goals and verifies the generated `vendor_kernel_boot.img` afterward. The helper
extracts `tegu.dtb` from the upstream prebuilt
`device/google/tegu-kernels/6.1/vendor_kernel_boot.img` and checks it against
the known-good hash documented in [TEGU_BOOTCHAIN.md](TEGU_BOOTCHAIN.md).

To run those steps manually:

```bash
OPENPHONE_ANDROID_DIR=/path/to/android/tree ./scripts/prepare-tegu-dtb.sh
OPENPHONE_ANDROID_DIR=/path/to/android/tree ./scripts/verify-tegu-bootchain.sh openphone_tegu
```

## Fast Assistant Iteration

Use the full OTA path only when a change must be baked into Android partitions:
framework/base patches, privapp permissions, sysconfig, sepolicy, boot/recovery
behavior, or first install on a device. For assistant UI, prompt, policy,
trajectory, and model-adapter work, use the debug harness on an already-booted
userdebug/eng OpenPhone device.

Build only the assistant module on the Linux Android build host:

```bash
OPENPHONE_BUILD_GOAL=OpenPhoneAssistant \
./scripts/build.sh openphone_tegu-bp4a-userdebug
```

Copy the resulting APK back to the host, then push it into `/system_ext` without
recovery. Because `org.openphone.assistant` is a persistent privileged app,
Android rejects normal `adb install -r`; enable Developer Options -> Rooted
debugging once, then use:

```bash
scripts/push-assistant-apk.sh /path/to/OpenPhoneAssistant.apk
```

The device reboots after the push. PackageManager may still show stale
persistent system-app metadata on some builds; verify the mounted APK hash if
that happens. Use full OTA or factory reset only when the mounted APK bytes do
not match, framework/system files changed, or PackageManager state itself is
what you are testing.

Run a task with a direct development OpenAI key:

```bash
mkdir -p .worktree/secrets
printf '%s' "$OPENAI_API_KEY" > .worktree/secrets/openai_api_key
scripts/run-assistant-task.sh --goal "screen" --wait 30
```

The key file path is ignored by git. You can also pass `--api-key-file <path>`,
or set `OPENAI_API_KEY` directly in the shell.

Run without a provider key for local-mode/debug checks:

```bash
scripts/run-assistant-task.sh --local --goal "screen" --wait 10
```

After using Advanced -> Export Trace in the assistant, pull and validate the
newest trajectory:

```bash
scripts/pull-latest-trajectory.sh \
  --output-dir .worktree/evals/latest-assistant-run
```

The harness passes the goal as base64 and uses Android `singleTop` intent
delivery so repeated host-side runs update the existing assistant activity
instead of reusing stale text. Provider keys remain in the assistant's
in-memory development field; use the broker path for publishable evidence.

## Flash

```bash
./scripts/flash.sh /path/to/image-or-ota.zip
```

The flash script currently refuses to guess destructive steps. Device-specific
flash procedures belong in `docs/devices/<codename>.md`.

## Optional User-Supplied Google Services

OpenPhone does not redistribute Google Play Store, Google Play Services, or
Google apps. A user may sideload a compatible package on their own device after
installing OpenPhone.

For the host-side helper and policy boundary, see [GMS.md](GMS.md):

```bash
scripts/download-mindthegapps.sh
scripts/sideload-user-gms.sh \
  --package .worktree/downloads/gms/MindTheGapps-16.0.0-arm64-*.zip
```

For Pixel 9a, run the sideload command after installing the OpenPhone OTA and
entering recovery `Apply update -> Apply from ADB` for additional packages.
After sideload success, the helper waits for Android to boot and grants Google
Play Services the location permissions/app-ops needed by fused/network location
providers.
