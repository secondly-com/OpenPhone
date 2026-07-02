# Pixel 9a Boot Chain Notes

These notes document the Pixel 9a `tegu` boot-chain behavior found during the
first OpenPhone smoke install.

## Relevant Partitions

The Pixel 9a uses A/B slots. The first OpenPhone smoke OTA installed to slot
`_b` during bringup.

Partitions involved in the current boot path:

- `boot`
- `init_boot`
- `vendor_boot`
- `vendor_kernel_boot`
- `dtbo`
- `vbmeta`
- `vbmeta_system`
- `vbmeta_vendor`
- dynamic partitions: `system`, `system_ext`, `product`, `vendor`,
  `system_dlkm`, `vendor_dlkm`

## What Failed

OpenPhone userspace was valid enough to boot, but the generated
`vendor_kernel_boot.img` was not. With the OpenPhone-generated
`vendor_kernel_boot_b`, the phone fell back to fastboot before Android started.

The failure did not produce useful Android userspace logs because the kernel
never reached normal boot.

## Isolation Result

Starting from a working slot `_b` with OpenPhone dynamic partitions and the
official Lineage boot chain:

- OpenPhone `boot_b`: booted
- OpenPhone `init_boot_b`: booted
- OpenPhone `vendor_boot_b`: booted
- OpenPhone `vendor_kernel_boot_b`: fell back to fastboot

This isolated the failure to `vendor_kernel_boot`.

## DTB Packaging Issue

`device/google/zumapro/BoardConfig-common.mk` configures:

```make
BOARD_PREBUILT_DTBIMAGE_DIR := $(TARGET_KERNEL_DIR)
```

Android's target-files packaging creates `dtb.img` by concatenating:

```make
$(wildcard $(BOARD_PREBUILT_DTBIMAGE_DIR)/*.dtb)
```

For the `tegu` prebuilts observed during bringup,
`device/google/tegu-kernels/6.1/` did not contain any standalone `*.dtb`
files. It did contain a prebuilt `vendor_kernel_boot.img` with the DTB embedded.
The target-files build also requires a prebuilt `boot.img` in the same kernel
directory because upstream zumapro board config adds `boot` to
`AB_OTA_PARTITIONS` and points `BOARD_PREBUILT_BOOTIMAGE` at
`$(TARGET_KERNEL_DIR)/boot.img`.

Result: target-files generated `VENDOR_KERNEL_BOOT/dtb` as a zero-byte file,
then built a `vendor_kernel_boot.img` with DTB size `0`.

## Build Fix

`scripts/prepare-tegu-device-repos.sh` extracts the required `boot.img`,
`vendor_kernel_boot.img`, `dtbo.img`, and kernel modules from the Lineage OTA.
`scripts/build.sh` then handles the DTB flow automatically for
`openphone_tegu` and `openphone_tegu_smoke` when the build goal produces
target-files or an OTA. It fails fast if `boot.img` is missing, builds
`unpack_bootimg` if needed, extracts the DTB from the prebuilt image, and
verifies the generated `vendor_kernel_boot.img` after the Android build.

The manual equivalent is:

```bash
cd /path/to/OpenPhone
OPENPHONE_ANDROID_DIR=/path/to/android/tree ./scripts/prepare-tegu-dtb.sh
```

Expected DTB SHA-256:

```text
f1aed2bc4c07d3cb1e610f5227a566f22e995dfe05341ca6bf14805be6928688
```

Then build target-files and the OTA.

## Validation

After rebuilding, inspect the generated image manually with:

```bash
cd /path/to/OpenPhone
OPENPHONE_ANDROID_DIR=/path/to/android/tree ./scripts/verify-tegu-bootchain.sh openphone_tegu
```

Expected result:

- DTB size: `1546258`
- DTB SHA-256:
  `f1aed2bc4c07d3cb1e610f5227a566f22e995dfe05341ca6bf14805be6928688`

## Open Question

The product variable `PRODUCT_BUILD_VENDOR_KERNEL_BOOT_IMAGE := false` was
tried in the OpenPhone product overlay but did not prevent target-files from
rebuilding `vendor_kernel_boot.img`. Treat that variable as insufficient for
this branch until proven otherwise.
