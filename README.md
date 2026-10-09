# Creek_Nethunter

GitHub Actions builder for the Redmi/Xiaomi Creek stock GKI mixed build.

It uses:

- Google GKI `common` for the kernel image and GKI/system_dlkm modules.
- Xiaomi `msm-kernel` as the vendor/device kernel for external modules.
- Xiaomi Creek device-tree and QCOM vendor module sources.
- The stock Creek vendor_boot module lists captured from the device.
- The qcacld monitor-mode/frame-injection port, applied after source sync.

The workflow builds `boot.img`, `vendor_boot.img`, `vendor_dlkm.img`,
`system_dlkm.img`, DTB/DTBO outputs, and all Xiaomi external modules. It also
runs a placement check and uploads the build log and module-placement report.

The stock module lists are under `stock-modules/`. Modules selected by the
vendor_boot lists are staged for first-stage loading; remaining built modules
are placed in vendor_dlkm by the Xiaomi build system. A stock vendor_boot
image itself is not committed to this repository.

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

The workflow retains the complete requested target inventory of 139 distinct names in
`config/creek-adapter-module-targets.txt`. The list is a **request/inventory**,
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

## Kernel ZIP status

The current workflow output named `Creek-Nethunter-gki-candidate.zip` is a
**candidate image bundle**, not the requested full AnyKernel3 ZIP. It currently
contains the built kernel image and release gate files, not the complete
AnyKernel3 layout with `anykernel.sh`, `META-INF`, and the requested tools.
Do not rename it to `Creek-Nethunter-gki-AK3.zip` or flash it as an installer.
The AK3 packaging step must be implemented and audited separately before it can
be considered ready for installation.
