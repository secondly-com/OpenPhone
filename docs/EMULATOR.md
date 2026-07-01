# Emulator First Test Path

The OpenPhone SDK phone emulator is the first runnable OS test path. Use it
after `./scripts/check.sh` and before physical Pixel 9a evals when you need to
prove that the OpenPhone product boots, framework services are registered, the
privileged assistant is present, and the local runtime CLI/MCP tooling can
inspect the screen.

The emulator does not replace Pixel 9a hardware validation. It cannot prove
radio, camera, fingerprint, physical button, recovery, OTA, or vendor-firmware
behavior. It is the fastest way to validate the OS/runtime surface before a
flashable device build.

## What To Build

OpenPhone defines two LineageOS SDK phone products:

```text
openphone_sdk_phone_arm64-bp4a-eng
openphone_sdk_phone_x86_64-bp4a-eng
```

Choose the target that matches the workstation that will run the UI:

- Apple Silicon Mac: `--arch arm64`, output device directory `emu64a`.
- Intel Mac or x86_64 Linux workstation: `--arch x86_64`, output directory
  `emu64x`.

The build can run on a Linux Android build host. A build-only EC2 host is
usually useful for producing the image zip, but it is not a good place to view
the UI unless it has a GUI stack and hardware acceleration.

## Build The Image

From a prepared Linux Android build host:

```bash
./scripts/sync.sh
./scripts/apply-patches.sh
./scripts/build-emulator.sh --arch arm64
```

Use `--arch x86_64` instead for an x86_64 workstation. The default build goal
is `droid emu_img_zip`, which creates a portable SDK system image zip:

```text
$OPENPHONE_ANDROID_DIR/out/target/product/emu64a/sdk-repo-linux-system-images.zip
$OPENPHONE_ANDROID_DIR/out/target/product/emu64x/sdk-repo-linux-system-images.zip
```

## Install The Image Locally

Copy the zip to the workstation that will run the emulator. Then install it
under the Android SDK system-image directory. The zip already contains the ABI
directory (`arm64-v8a/` or `x86_64/`).

```bash
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
mkdir -p "$ANDROID_HOME/system-images/android-36.1/lineage"
bsdtar -xf sdk-repo-linux-system-images.zip \
  -C "$ANDROID_HOME/system-images/android-36.1/lineage"
```

The ARM64 image expands to roughly 8 GiB before AVD userdata. Keep at least
15-20 GiB free before first boot.

## Mac Studio Codex Lab Slots

For local agent work, do not sync/build Android on macOS. Use a portable image
zip produced by Linux/GCP, then let the lab scripts create an isolated AVD and
userdata directory per Codex slot.

To produce a Mac-usable image from GCP, run the `GCP Lab` workflow manually with
`arch=arm64` and `export_emulator_image=true`. The uploaded `openphone-gcp-lab`
artifact will contain:

```text
artifacts/emulator-image/openphone-sdk-phone-arm64-eng.zip
artifacts/emulator-image/openphone-sdk-phone-arm64-eng.zip.sha256
```

First run for a slot, with a local zip path or URL:

```bash
scripts/lab/up.sh \
  --slot codex-local-main \
  --arch arm64 \
  --emulator-image /path/to/openphone-sdk-phone-arm64-eng.zip \
  --runtime local \
  --timeout 900
```

After the image is installed in the Android SDK, new or repeated slots can use
the prebuilt path directly:

```bash
scripts/lab/up.sh \
  --slot codex-local-second \
  --arch arm64 \
  --prebuilt \
  --runtime local \
  --timeout 900
```

Each slot writes its own environment under `.worktree/lab/<slot>/env`, including
the emulator serial, AVD home, runtime ports, userdata directory, and artifact
directory. Source it before running CLI/MCP commands manually:

```bash
source .worktree/lab/codex-local-main/env
node integrations/cli/src/index.mjs --serial "$ANDROID_SERIAL" --json runtime status
```

Stop a slot with:

```bash
scripts/lab/down.sh --slot codex-local-main
```

## Create An AVD

Try the normal Android SDK path first:

```bash
"$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager" create avd \
  -n OpenPhone_Emu_ARM64 \
  -k "system-images;android-36.1;lineage;arm64-v8a" \
  -d medium_phone
```

Some SDK Manager versions reject custom `android-36.1` system-image paths even
when the image is installed correctly. In that case, create the AVD config
manually:

```bash
name=OpenPhone_Emu_ARM64
abi=arm64-v8a
cpu_arch=arm64

# For x86_64, use:
# name=OpenPhone_Emu_X86_64
# abi=x86_64
# cpu_arch=x86_64

avd_home="$HOME/.android/avd"
mkdir -p "$avd_home/$name.avd"

cat > "$avd_home/$name.ini" <<EOF
avd.ini.encoding=UTF-8
path=$avd_home/$name.avd
path.rel=avd/$name.avd
target=android-36.1
EOF

cat > "$avd_home/$name.avd/config.ini" <<EOF
AvdId = $name
PlayStore.enabled = false
abi.type = $abi
avd.ini.displayname = OpenPhone Emulator
avd.ini.encoding = UTF-8
disk.dataPartition.size = 6442450944
fastboot.chosenSnapshotFile =
fastboot.forceChosenSnapshotBoot = no
fastboot.forceColdBoot = yes
fastboot.forceFastBoot = no
hw.accelerometer = yes
hw.arc = false
hw.audioInput = yes
hw.battery = yes
hw.camera.back = virtualscene
hw.camera.front = emulated
hw.cpu.arch = $cpu_arch
hw.cpu.ncore = 4
hw.dPad = no
hw.device.hash2 = MD5:3db3250dab5d0d93b29353040181c7e9
hw.device.manufacturer = Generic
hw.device.name = medium_phone
hw.gps = yes
hw.gpu.enabled = yes
hw.gpu.mode = auto
hw.initialOrientation = portrait
hw.keyboard = yes
hw.lcd.density = 420
hw.lcd.height = 2400
hw.lcd.width = 1080
hw.mainKeys = no
hw.ramSize = 2048
hw.sdCard = yes
hw.sensors.orientation = yes
hw.sensors.proximity = yes
hw.trackBall = no
image.sysdir.1 = system-images/android-36.1/lineage/$abi/
runtime.network.latency = none
runtime.network.speed = full
sdcard.size = 512M
showDeviceFrame = no
skin.dynamic = yes
skin.name = 1080x2400
skin.path = _no_skin
skin.path.backup = _no_skin
tag.display = LineageOS
tag.displaynames = LineageOS
tag.id = lineage
tag.ids = lineage
vm.heapSize = 228
EOF
```

## Boot And See The UI

Run the emulator with an explicit port so the ADB serial is predictable:

```bash
"$ANDROID_HOME/emulator/emulator" \
  -avd OpenPhone_Emu_ARM64 \
  -port 5584 \
  -no-snapshot \
  -wipe-data \
  -no-boot-anim
```

The ADB serial will be `emulator-5584`. Wait for Android to finish booting:

```bash
adb -s emulator-5584 wait-for-device
until [ "$(adb -s emulator-5584 shell getprop sys.boot_completed | tr -d '\r')" = "1" ]; do
  sleep 2
done
```

If you are running headless or the emulator window is hard to find, mirror the
screen with `scrcpy`:

```bash
scrcpy --serial emulator-5584 --window-title "OpenPhone Emulator UI" --no-audio
```

## Verify OpenPhone

Run these checks after boot:

```bash
adb -s emulator-5584 shell 'getprop ro.openphone.version'
adb -s emulator-5584 shell 'getprop ro.product.model'
adb -s emulator-5584 shell 'service check openphone_agent'
adb -s emulator-5584 shell 'service list | grep openphone'
adb -s emulator-5584 shell 'pm list packages | grep org.openphone.assistant'
adb -s emulator-5584 exec-out screencap -p > /tmp/openphone-emulator.png
```

Expected signs of a working emulator:

- `sys.boot_completed=1`
- `ro.openphone.version` is set
- model includes `OpenPhone SDK Phone`
- `openphone_agent`, `openphone_assistant_data`, and `openphone_context` are
  registered services
- `org.openphone.assistant` is installed

## CI Smoke

The emulator path is also a CI gate. The
[Emulator workflow](../.github/workflows/emulator.yml) runs on pull requests
that touch runtime, assistant, overlay, patch, integration, or emulator
scripts. It uses a self-hosted `openphone-emulator` runner and calls:

```bash
./scripts/run-emulator-smoke.sh --arch x86_64
```

The smoke harness:

- builds or reuses the OpenPhone SDK phone image;
- boots a wiped headless emulator;
- waits for `sys.boot_completed=1`;
- verifies OpenPhone framework services are registered;
- verifies `org.openphone.assistant` is installed;
- starts the assistant UI;
- runs `runtime status` through the OpenPhone CLI;
- invokes `openphone.screen.get` through the ADB runtime transport;
- runs one local assistant task without provider API keys;
- uploads logcat, screenshot, UI XML, runtime status, screen result, and
  assistant smoke output as workflow artifacts.

This is the fast merge gate for AI-generated runtime and assistant changes. It
does not replace the nightly physical `openphone-device` eval, but it should
catch broken boot, package, service, ADB transport, CLI, and local assistant
paths before code reaches device-only validation.

## CLI And MCP On The Emulator

The local Runtime CLI and MCP server use ADB, so they can target the emulator
the same way they target a USB-connected Pixel. Set `ANDROID_SERIAL` or pass
`--serial` when more than one device is connected.

```bash
node integrations/cli/src/index.mjs \
  --serial emulator-5584 \
  runtime status \
  --json

node integrations/cli/src/index.mjs \
  --serial emulator-5584 \
  tool invoke openphone.screen.get '{"include_screenshot":false}' \
  --json
```

For MCP clients:

```bash
ANDROID_SERIAL=emulator-5584 \
ADB="$ANDROID_HOME/platform-tools/adb" \
node integrations/mcp-server/src/index.mjs
```

Current ADB-backed tools include screen capture/UI text, app search/open, URL
open, tap, swipe, text input, key events, and clipboard set. Commands present
in `runtime/protocol/openphone-commands.json` but not implemented by the ADB
transport return `unsupported_adb_tool`.

## OpenClaw Runtime Smoke

The merged OpenClaw Android adapter and OpenClaw plugin are not physical-device
specific. They run in the emulator as long as the assistant service is present
and the emulator can reach the gateway. For a gateway on the host loopback
address, the smoke script uses `adb reverse` by default:

```bash
ANDROID_SERIAL=emulator-5584 \
OPENPHONE_OPENCLAW_TOKEN="$OPENCLAW_GATEWAY_TOKEN" \
scripts/smoke-test-openclaw-runtime.sh
```

This proves that the emulator connects to OpenClaw as an OpenPhone Android
node, the plugin exposes the approved OpenPhone command surface, and OpenClaw
can invoke `openphone.screen.get`. Use a physical Pixel 9a for hardware
button, radio, camera, fingerprint, OTA, and release acceptance coverage.

## Stop The Emulator

For a normal terminal-launched emulator, close the window or run:

```bash
adb -s emulator-5584 emu kill
```

If you launched it through `launchctl submit`, remove the submitted job:

```bash
launchctl remove com.openphone.emulator.arm64
launchctl remove com.openphone.emulator.scrcpy
```
