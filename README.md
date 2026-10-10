# Creek_Nethunter

GitHub Actions builder for the Redmi/Xiaomi Creek stock GKI mixed build.

It uses:

- Google GKI `common` for the kernel image and GKI/system_dlkm modules.
- Xiaomi `msm-kernel` as the vendor/device kernel for external modules.
- Xiaomi Creek device-tree and QCOM vendor module sources.
- The stock Creek vendor_boot module lists captured from the device.
- The qcacld monitor-mode/frame-injection port, applied after source sync.

The workflow applies a narrowly scoped QCACLD fix before preflight: the monitor
enable path stores a potentially negative monitor-vdev lookup result in a signed
`int`, so the existing `vdev_id < 0` failure check cannot be bypassed by an
unsigned conversion. The patch is applied only when the expected source context
matches; otherwise the workflow fails rather than fuzzily patching the driver.
This addresses a source-level error path but does not replace physical monitor
mode stability testing.


The workflow builds `boot.img`, `vendor_boot.img`, `vendor_dlkm.img`,
`system_dlkm.img`, DTB/DTBO outputs, and all Xiaomi external modules. It also
runs a placement check and uploads the build log and module-placement report.

The stock module lists are under `stock-modules/`. Modules selected by the
vendor_boot lists are staged for first-stage loading; remaining built modules
are placed in vendor_dlkm by the Xiaomi build system. A stock vendor_boot
image itself is not committed to this repository.

## Missing proprietary stock modules: preservation policy

Do not recreate, stub, rename, or replace a missing closed-source Xiaomi module.
The only safe default is to preserve the device's already-installed stock
`vendor_boot`, `vendor_dlkm`, and `system_dlkm` module payloads and their
original load lists. A future AnyKernel3 installer must patch only the intended
kernel/boot target and must not flash generated replacement vendor module
images. Stock module reuse is permitted only after the exact running kernel
release, vermagic, exported symbols/KMI, dependency closure, and device runtime
compatibility are verified; never force-load an incompatible module.

Important provenance mismatch found during this audit:

- The repository's captured stock module lists and ramdisk were extracted from
  Android 15 / kernel `5.15.167-android13-8-gbf0a81a7f319`.
- The user's current Android 16 stock boot was previously identified as kernel
  `5.15.194-android13-8-00019-gf4321180a397-ab15212794`.
- The current manifest still builds the `5.15.167-android13-8` family.

Therefore, those committed Android 15 lists are historical references only;
they must not be used to reconstruct or overwrite the current Android 16 stock
module partitions. The new workflow audit emits
`artifacts/logs/stock-module-coexistence.txt`, asserts that the candidate ZIP
contains no replacement `.ko` files or vendor/system module images, and
keeps `FLASH_ALLOWED=NO` while this release/KMI mismatch remains.

**Dynamic stock-module borrowing is not yet implemented in the requested AK3
installer**—the repo still outputs a candidate bundle, not a flashable AK3 zip.
The safety policy and artifact audit are in place, but I will not claim the
installer automatically reuses the phone's current stock modules until that
runtime behavior is implemented and verified.

## Modules not available from the current sources

The following stock Xiaomi modules are currently missing from the build because
their matching vendor source is not available in this tree.

Normal `vendor_boot`:

```text
bootinfo.ko
mi_memory.ko
mi_thermal_interface.ko
qrng_dlkm.ko
qseecom_dlkm.ko
swinfo.ko
```

Recovery `vendor_boot`:

```text
bootinfo.ko
hdcp_qseecom_dlkm.ko
lct_tp.ko
mi_memory.ko
mi_thermal_interface.ko
msm-mmrm.ko
msm_drm.ko
qseecom_dlkm.ko
smcinvoke_dlkm.ko
swinfo.ko
```

Additional `vendor_dlkm` modules not currently built:

```text
ipam.ko
ipanetm.ko
ipa_clientsm.ko
rndisipam.ko
rmnet_core.ko
rmnet_ctl.ko
rmnet_wlan.ko
```

## NetHunter adapter module inventory and packaging status

The workflow retains the requested target inventory in
`config/creek-adapter-module-targets.txt` (the file itself is authoritative for the exact count). The list is a **request/inventory**,
not a promise that all targets exist in the pinned Linux 5.15.167 sources.
The adapter package is generated only from actual staged `.ko` files; it never
creates placeholder modules. Inspect `MODULE-STATUS.txt`,
`MODULE-MANIFEST.txt`, and `adapter-module-status.txt` in the Actions artifact
for every requested target and its build/package status. At the current baseline,
only the modules actually staged by the kernel build are shipped; the historical
51-driver/2-dependency package did **not** contain all 139 requested targets.

`qca_cld3_wlan.ko` is deliberately kept out of the USB-adapter package and
provided separately as an audit-only payload until exact Android 16 ABI/KMI,
vermagic, symbol dependencies, and recovery behavior are checked on-device.
No module package should load wireless, SDR, CAN, USB-gadget, serial, or other
optional drivers at boot. They must remain unloaded until explicitly requested.
This avoids unsolicited module activation, but does not itself prove that every
driver is safe or compatible when loaded; physical adapter testing is still
required.

## KernelSU root integration gate

The adapter ZIP is packaged as a KernelSU-compatible userspace module, but that
does **not** prove that the kernel image itself has KernelSU built-in or that a
KernelSU LKM can load on the exact device build. The current workflow and
repository scripts do not contain an explicit KernelSU kernel-source integration
step. Keep the kernel candidate non-flashable until the user's current KernelSU
mode (built-in versus LKM) and compatibility with this exact kernel build are
verified. Do not label the kernel image as KernelSU-enabled based only on the
adapter module's `module.prop`.

The adapter package includes a KernelSU Manager Action (`action.sh`) that only
reports module status. It deliberately does not load modules or change Wi-Fi
state. Adapter modules remain manually/on-demand loaded through `nhd`; no
boot-time service hook is included.

## Kernel ZIP status

The current workflow output named `Creek-Nethunter-gki-candidate.zip` is a **candidate image bundle**, not a flashable installer. The original developer's AK3 archive is a separate reference and uses `block=boot`, device `creek`, and Android versions 15–16; those facts do not establish compatibility of a newly built Image.gz with the user's current Android 16 build. A reproducible AK3 packaging step must reuse the known AnyKernel3 layout, replace only `Image.gz`, test ZIP contents, and retain a clear no-flash gate until boot image, AVB, KernelSU mode, ABI/KMI, and device tests pass.
