# Google Pixel 9a

## Identity

| Field | Value |
| --- | --- |
| Device | Google Pixel 9a |
| Codename | `tegu` |
| OpenPhone product | `openphone_tegu` |
| Verified model/SKU | `GTF7P` |
| Verified hardware revision | `MP1.0` |
| Upstream branch | LineageOS `lineage-23.2` |
| Android release | Android 16 / `bp4a` |
| Bringup state | unlocked, Lineage booted, full OpenPhone OTA booted |

Observed stock build on first OpenPhone device:

```text
google/tegu/tegu:16/BP4A.260105.004.E1/14587043:user/release-keys
```

## Sources

- Device tree: downloaded by Lineage `breakfast tegu`.
- Kernel source: downloaded by Lineage `breakfast tegu`.
- Vendor blobs: extract from a matching Lineage installable zip or from a
  device already running the matching Lineage branch.
- Lineage build docs:
  [Build LineageOS for Google Pixel 9a](https://wiki.lineageos.org/devices/tegu/build/)
- Lineage install docs:
  [Install LineageOS on Google Pixel 9a](https://wiki.lineageos.org/devices/tegu/install/)

## Host Checks

From the OpenPhone repository:

```bash
adb devices -l
adb shell getprop ro.product.model
adb shell getprop ro.product.device
adb shell getprop ro.boot.hardware.sku
adb shell getprop ro.build.fingerprint
adb shell getprop ro.boot.flash.locked
```

Expected before unlock:

```text
model: Pixel 9a
device: tegu
sku: GTF7P
flash locked: 1
```

## Prepare Device Repositories

After syncing and applying the OpenPhone overlay/patches:

```bash
export OPENPHONE_ANDROID_DIR="$PWD/.worktree/OpenPhoneAndroid/android"
cd "$OPENPHONE_ANDROID_DIR"
source build/envsetup.sh
breakfast tegu
```

If proprietary vendor files are missing, extract them according to the upstream
Lineage `tegu` instructions.

## Build

From the OpenPhone repository:

```bash
OPENPHONE_ANDROID_DIR="$PWD/.worktree/OpenPhoneAndroid/android" \
./scripts/apply-patches.sh

OPENPHONE_ANDROID_DIR="$PWD/.worktree/OpenPhoneAndroid/android" \
OPENPHONE_BUILD_GOAL="target-files-package ota_from_target_files" \
./scripts/build.sh openphone_tegu
```

For Pixel 9a OTA-producing build goals,
`scripts/prepare-tegu-device-repos.sh` prepares the required kernel prebuilts
including `device/google/tegu-kernels/6.1/boot.img`, and `scripts/build.sh`
automatically prepares `tegu.dtb` from the upstream prebuilt
`vendor_kernel_boot.img`. The build fails fast if `boot.img` is missing and
verifies the generated `vendor_kernel_boot.img` contains the known-good DTB.
The same checks can be run manually with:

```bash
OPENPHONE_ANDROID_DIR="$PWD/.worktree/OpenPhoneAndroid/android" \
./scripts/prepare-tegu-dtb.sh

OPENPHONE_ANDROID_DIR="$PWD/.worktree/OpenPhoneAndroid/android" \
./scripts/verify-tegu-bootchain.sh openphone_tegu
```

Expected output directory:

```text
.worktree/OpenPhoneAndroid/android/out/target/product/tegu/
```

Expected release artifacts after a successful device build:

```text
boot.img
vendor_boot.img
obj/PACKAGING/target_files_intermediates/openphone_tegu-target_files.zip
```

The GitHub release workflow turns the target-files package into an
`openphone_tegu-<version>-ota.zip` artifact with `scripts/stage-release-ota.sh`.

## Unlock and Flash

Unlocking the bootloader wipes the device.

Before unlocking:

- Finish initial Android setup.
- Enable Developer Options.
- Enable `OEM unlocking`.
- Enable `USB debugging`.
- Verify `adb devices -l` shows `device:tegu`.

Reboot to bootloader:

```bash
adb reboot bootloader
fastboot devices -l
```

Unlock:

```bash
fastboot flashing unlock
```

Confirm the unlock on the device with the hardware buttons. The device will
wipe data.

Flashing instructions currently follow the upstream Lineage `tegu` install flow
until OpenPhone has its own release package and installer documentation.

## Optional User-Supplied Google Apps

OpenPhone does not ship Google Play Store, Google Play Services, or Google
apps. Users who want Google Play on their own Pixel 9a can sideload a
compatible user-supplied Google apps package after installing the OpenPhone OTA.
See [../GMS.md](../GMS.md) for the project policy and compatibility
notes.

Install the package immediately after the OpenPhone OTA, before first normal
boot, unless the package's own instructions say otherwise.

Typical recovery flow:

```text
1. Sideload the OpenPhone OTA.
2. If recovery asks "Install additional packages?", choose Yes.
3. If recovery says it must reboot recovery first, choose Yes.
4. Return to Apply update -> Apply from ADB.
5. From the host, run:
   scripts/download-mindthegapps.sh
   scripts/sideload-user-gms.sh \
     --package .worktree/downloads/gms/MindTheGapps-16.0.0-arm64-*.zip
6. If recovery reports success, choose Reboot system now. The host helper then
   waits for Android and repairs Google Play Services location grants for
   fused/network location providers.
```

The sideload helper only runs `adb sideload` against a local ZIP. It does not
download, bundle, validate, or license Google packages. The download helper
fetches a public MindTheGapps GitHub release into ignored local worktree state
and verifies the release-provided SHA-256 before sideloading.

## Bringup Notes

The first OpenPhone smoke OTA installed and produced valid OpenPhone userspace,
but its generated `vendor_kernel_boot.img` had a zero-byte DTB and fell back to
fastboot before Android could start. The DTB-fixed OpenPhone smoke OTA booted
successfully on slot `_a`. See
[../TEGU_BOOTCHAIN.md](../TEGU_BOOTCHAIN.md) for the root cause and
the DTB extraction fix.

The first full `openphone_tegu` OTA booted far enough to expose full product
identity but crashed during `system_server` startup because SELinux denied
registration of the new `openphone_agent` Binder service. The fix is captured in
`patches/system_sepolicy/0001-OpenPhone-label-agent-manager-service.patch`.

The SELinux-fixed full OTA boots to lock screen and reports:

```text
ro.product.model=OpenPhone Pixel 9a
ro.openphone.version=0.1.0-dev
ro.openphone.smoke_build=
sys.boot_completed=1
dev.bootcomplete=1
```

OpenPhone runtime verification:

```text
pm list packages -> package:org.openphone.assistant
service list -> openphone_agent: [android.openphone.IOpenPhoneAgentService]
service check openphone_agent -> found
dumpsys activity services -> org.openphone.assistant/.OpenPhoneAssistantService running
```

Current assistant development baseline:

```text
assistant manifest version: derive from overlay/packages/apps/OpenPhoneAssistant/AndroidManifest.xml
on-device package version: verify with scripts/verify-tegu-device.sh
OTA artifact and SHA-256: record in release notes for each published artifact
```

The assistant-only APK / OTA iteration loop is built on a Linux Android build
host, pushed or sideloaded to the physical Pixel 9a, and validated for:

- app launch after reboot,
- chat-style home screen,
- profile icon opening the advanced surface,
- keyboard-aware composer positioning,
- mic-to-send icon state after text entry,
- outside-tap keyboard dismissal, and
- absence of recent `FATAL EXCEPTION` / `AndroidRuntime` logcat signatures.

## Recovery and ADB Notes

After a clean data wipe or recovery `Format data / factory reset`, Android may
boot to first-run onboarding with stale host-side ADB visibility:

```text
adb devices -l -> device
adb get-state -> device
adb shell -> error: closed
adb logcat -> waiting for device
adb install -> abb_exec failed: closed
```

Treat this as an authorization/onboarding state, not proof that Android failed
to boot. Complete or skip onboarding until the home screen, then re-enable
Developer Options and USB debugging. Accept the USB debugging prompt on the
phone before running package or service verification.

Useful post-onboarding verification:

```bash
./scripts/verify-tegu-device.sh
```

The script runs the ADB shell probe, device identity checks, framework service
check, assistant package diagnostics, accessibility settings, and recent
OpenPhone logs. The underlying manual commands are:

```bash
adb shell 'getprop sys.boot_completed'
adb shell 'service check openphone_agent'
adb shell 'dumpsys package org.openphone.assistant | grep -E "versionCode|versionName|OpenPhoneAccessibilityService" -n'
adb shell 'settings get secure enabled_accessibility_services'
adb shell 'settings get secure accessibility_enabled'
```

For the current repository manifest, the assistant APK should report the
`versionCode` and `versionName` from
`overlay/packages/apps/OpenPhoneAssistant/AndroidManifest.xml`, plus
`.OpenPhoneAccessibilityService`. Trust `scripts/verify-tegu-device.sh` over
stale example output. The script derives the expected assistant package version
from the repository manifest and fails if PackageManager still reports stale
metadata.

## Acceptance Checklist

Run the automated portion of the hardware checklist with:

```bash
./scripts/smoke-test-tegu-hardware.sh
```

The script writes an evidence report under `.worktree/reports/`. Automated
service probes are not enough to mark user-facing hardware as passing; fill in
the manual sections for calls/SMS, microphone/speaker, camera capture,
fingerprint enrollment, reboot stability, and factory reset before moving those
rows out of `pending`.

| Area | Status |
| --- | --- |
| USB detection | pass |
| ADB authorization | pass |
| Exact codename | pass |
| Model/SKU | pass |
| Bootloader unlock | pass |
| Device repositories | pass |
| Vendor blobs | pass |
| OpenPhone device build | pass |
| Recovery boot | pass |
| OpenPhone install | pass |
| First boot | pass |
| Wi-Fi | pending |
| Bluetooth | pending |
| Cellular data | pending |
| Calls/SMS | pending |
| Camera | pending |
| Microphone/speaker | pending |
| Fingerprint | pending |
| GPS | pending |
| Encryption | pending |
| OpenPhone assistant | pass |
| Framework agent service | pass |
| Action execution | partial pass |
| Audit log | partial pass |
| Policy confirmation | partial pass |

## Known Issues

- Play Integrity behavior is expected to change after bootloader unlock.
- Production OTA/release signing is not implemented yet for public preview
  artifacts.
- Privileged assistant APK push is validated for assistant-only iteration, but
  framework, sepolicy, Settings/SystemUI, boot-chain, and first-install changes
  still require full target-files/OTA builds.
- Pixel 9a OpenPhone target-files/OTA builds rely on the automated DTB
  extraction and verification in `scripts/build.sh`.
- Full product boot requires the OpenPhone `system/sepolicy` service label for
  `openphone_agent`.
- After a data wipe, ADB may list the device before shell/logcat/install
  channels work. Finish onboarding and re-authorize USB debugging before
  treating `adb shell: error: closed` as a lower-level transport failure.
- A development OTA can update
  `/system_ext/priv-app/OpenPhoneAssistant/OpenPhoneAssistant.apk` while
  PackageManager still reports an older assistant `versionCode` from persisted
  package metadata. Verify both the APK hash and PackageManager version after
  each OTA. If PackageManager stays stale after onboarding, wipe data from
  recovery and verify again before running agent evals.
