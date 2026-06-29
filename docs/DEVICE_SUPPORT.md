# Device Support

OpenPhone supports exact device models, not generic Android phones.

OpenPhone uses LineageOS device infrastructure where possible. The official
LineageOS supported-device list is the starting point for candidate ports:
[LineageOS supported-device list](https://wiki.lineageos.org/devices/). A LineageOS-supported device is not
automatically an OpenPhone-supported device; OpenPhone support requires its own
product target, flash notes, hardware validation, agent validation, and release
coverage.

## Device States

```text
candidate
  Device appears technically viable but is not validated.

bringup
  Builds are being attempted; hardware may be broken.

experimental
  Boots and basic hardware works; not suitable for daily users.

supported
  Passes the device acceptance checklist and has release/OTA coverage.

retired
  No longer receiving supported OpenPhone builds.
```

## Acceptance Checklist

```text
boot
recovery
adb
display
touch
Wi-Fi
Bluetooth
cellular data
calls
SMS
IMS/VoLTE where applicable
camera
microphone
speaker
fingerprint/biometric if present
accelerometer/gyroscope
GPS
NFC if present
battery reporting
suspend/resume
encryption
OTA update
factory reset
agent screen read
agent action execution
agent background task
audit log
policy confirmation flow
```

## First Target

The first real target device is Google Pixel 9a, codename `tegu`. It was
selected because it has an unlockable bootloader, active LineageOS support,
available device/kernel/vendor workflows, and a recoverable flashing path.

Current state:

- `openphone_tegu` boots on the physical Pixel 9a.
- The framework `openphone_agent` service and privileged assistant are
  verified.
- Assistant-only APK iteration is validated for UI/model-loop changes.
- Hardware acceptance is incomplete, so the device remains a development
  target rather than a supported daily-driver release.

`openphone_arm64` remains the generic bootstrap product for validating the
OpenPhone product layer without a device-specific flash target.
