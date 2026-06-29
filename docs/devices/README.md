# Devices

OpenPhone device support is tracked per exact model and codename.

Candidate ports usually start from the official LineageOS supported-device
list: [LineageOS devices](https://wiki.lineageos.org/devices/). OpenPhone only marks a device as
supported after OpenPhone-specific bringup and validation.

The first physical bringup target is Google Pixel 9a / `tegu`. The current
bootstrap target is the generic `openphone_arm64` product under
`overlay/vendor/openphone`.

Add a device file when bringup starts:

```text
docs/devices/<codename>.md
```

Each file must include:

- Device name and codename.
- Bootloader unlock status.
- Upstream Lineage branch.
- Device tree source.
- Kernel source.
- Vendor blob policy.
- Flash instructions.
- Acceptance checklist status.
- Known issues.
