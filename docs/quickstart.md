# Quickstart

The fastest way to see OpenPhone running is the SDK phone emulator. You'll
build a portable system image on a Linux Android build host, install it into
a local AVD on your workstation, and boot the OpenPhone UI.

If you just want to read about the system, jump to
[Architecture](/docs/ARCHITECTURE). If you want to flash an actual Pixel 9a,
see [Build](/docs/BUILD).

## What you get

After this quickstart you will have:

- A booted OpenPhone Android image running on your workstation.
- The privileged assistant app installed and reachable via ADB.
- The framework services registered (`openphone_agent`, `openphone_context`,
  `openphone_assistant_data`).
- A working CLI/MCP surface you can poke against.

You will not get: radio, camera, fingerprint, physical buttons, recovery,
OTA, or vendor firmware behavior. Those need physical Pixel 9a hardware.

## Before you start

You need two machines (or one machine acting as both):

**A build host** — Linux, with the Android build toolchain, a case-sensitive
filesystem, and several hundred GB of free disk. This produces the image.

**A workstation** — macOS or Linux with the Android SDK emulator. This runs
the UI. Apple Silicon needs the `arm64` image; Intel/x86_64 needs `x86_64`.

The same machine can do both if it meets both requirements.

You also need:

- `repo` (install with `./scripts/install-repo.sh`).
- `git-lfs` installed and initialized.
- On macOS: `brew install coreutils` for GNU coreutils.

## 1. Sync and patch on the build host

Clone this repo, then from the repo root:

```bash
./scripts/sync.sh
./scripts/apply-patches.sh
```

This initializes the Android checkout with the OpenPhone local manifest and
applies OpenPhone's overlay and patch stack. Expect this to take a while on
first run.

On macOS you'll want a case-sensitive APFS sparse image first:

```bash
./scripts/create-macos-build-volume.sh
export OPENPHONE_ANDROID_DIR="$PWD/.worktree/OpenPhoneAndroid/android"
```

## 2. Build the emulator image

Pick the ABI that matches your workstation:

```bash
# Apple Silicon
./scripts/build-emulator.sh --arch arm64

# Intel / x86_64
./scripts/build-emulator.sh --arch x86_64
```

The output is a portable SDK system-image zip:

```text
$OPENPHONE_ANDROID_DIR/out/target/product/emu64a/sdk-repo-linux-system-images.zip
```

(or `emu64x/` for x86_64).

## 3. Install the image on your workstation

Copy the zip over, then unpack it under your Android SDK:

```bash
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
mkdir -p "$ANDROID_HOME/system-images/android-36.1/lineage"
bsdtar -xf sdk-repo-linux-system-images.zip \
  -C "$ANDROID_HOME/system-images/android-36.1/lineage"
```

The image expands to ~8 GiB. Keep 15-20 GiB free before first boot.

## 4. Create the AVD

Pick the ABI variables that match the image you built:

```bash
# Apple Silicon
avd_name=OpenPhone_Emu_ARM64
abi=arm64-v8a

# Intel / x86_64
# avd_name=OpenPhone_Emu_X86_64
# abi=x86_64

"$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager" create avd \
  -n "$avd_name" \
  -k "system-images;android-36.1;lineage;$abi" \
  -d medium_phone
```

Some SDK Manager versions reject the custom system-image path. If that
happens, the manual `config.ini` template is in
[Emulator](/docs/EMULATOR#create-an-avd).

## 5. Boot it

```bash
"$ANDROID_HOME/emulator/emulator" \
  -avd "$avd_name" \
  -port 5584 \
  -no-snapshot \
  -wipe-data \
  -no-boot-anim
```

The ADB serial is `emulator-5584`. Wait for boot:

```bash
adb -s emulator-5584 wait-for-device
until [ "$(adb -s emulator-5584 shell getprop sys.boot_completed | tr -d '\r')" = "1" ]; do
  sleep 2
done
```

## 6. Verify OpenPhone is really there

```bash
adb -s emulator-5584 shell 'getprop ro.openphone.version'
adb -s emulator-5584 shell 'service list | grep openphone'
adb -s emulator-5584 shell 'pm list packages | grep org.openphone.assistant'
```

You should see an OpenPhone version string, the three framework services,
and the assistant package.

## What next

- **Poke at the runtime** — see [Runtime Agent Protocol](/docs/runtime/runtime-agent-protocol)
  and [MCP Bridge](/docs/runtime/mcp-bridge).
- **Understand what the agent is allowed to do** —
  [Capabilities](/docs/CAPABILITIES).
- **Read the deeper emulator guide** — [Emulator](/docs/EMULATOR) covers
  headless setups, `scrcpy` mirroring, screenshot capture, CLI/MCP smoke,
  and OpenClaw runtime validation.
- **Build for real hardware** — [Build](/docs/BUILD) for the Pixel 9a target.
