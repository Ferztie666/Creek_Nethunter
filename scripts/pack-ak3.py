#!/usr/bin/env python3
"""
Pack Creek-Nethunter v2 ke satu AnyKernel3 zip.
Berdasarkan analisis stock module lists dari device creek Android 15.

Distribusi modul yang benar:
- vendor_boot modules  → /vendor/lib/modules/ (via vendor ramdisk, first-stage)
- vendor_dlkm modules  → /vendor_dlkm/lib/modules/ (second-stage, partisi terpisah)
- NetHunter modules    → /vendor_dlkm/lib/modules/ (vermagic match, dimuat setelah boot)
- system_dlkm modules  → dibiarkan di partisinya, tidak perlu di-pack

PENTING: qca_cld3_wlan.ko yang patched harus menggantikan yang di vendor_dlkm,
bukan di vendor ramdisk. cfg80211.ko ada di vendor_dlkm, bukan GKI built-in.
"""
import sys, os, shutil, subprocess, glob, stat
from datetime import datetime

DIST_DIR = sys.argv[1]
OUT_DIR  = sys.argv[2]
ARTS_DIR = sys.argv[3]
REPO_DIR = sys.argv[4] if len(sys.argv) > 4 else ""

AK3_DIR = "/tmp/ak3_build"
if os.path.exists(AK3_DIR):
    shutil.rmtree(AK3_DIR)
os.makedirs(AK3_DIR, exist_ok=True)
os.makedirs(ARTS_DIR, exist_ok=True)

print("=== Clone AnyKernel3 ===")
subprocess.run([
    "git", "clone", "--depth=1",
    "https://github.com/osm0sis/AnyKernel3", AK3_DIR
], check=True)

# ── Kernel image ──────────────────────────────────────────────────────────────
print("\n=== Kernel image ===")
image_copied = False
for img in ["Image.gz", "Image", "Image.lz4"]:
    src = os.path.join(DIST_DIR, img)
    if os.path.isfile(src):
        if img == "Image":
            dst = os.path.join(AK3_DIR, "Image.gz")
            with open(dst, "wb") as out:
                subprocess.run(["gzip", "-c", src], stdout=out, check=True)
            print(f"Image.gz made from Image")
        else:
            shutil.copy2(src, os.path.join(AK3_DIR, img))
            print(f"{img} copied from {src}")
        image_copied = True
        break

if not image_copied:
    print("ERROR: No kernel image found in", DIST_DIR)
    print("Contents:", os.listdir(DIST_DIR) if os.path.isdir(DIST_DIR) else "DIR NOT FOUND")
    sys.exit(1)

# ── Struktur modul ────────────────────────────────────────────────────────────
# vendor_boot → /vendor/lib/modules/ (first-stage, sudah di ramdisk stock)
# vendor_dlkm → /vendor_dlkm/lib/modules/ (second-stage, partisi vendor_dlkm)
# NetHunter   → /vendor_dlkm/lib/modules/ (dimuat setelah boot)

vboot_mods_dir = os.path.join(AK3_DIR, "modules/vendor/lib/modules")
vdlkm_mods_dir = os.path.join(AK3_DIR, "modules/vendor_dlkm/lib/modules")
os.makedirs(vboot_mods_dir, exist_ok=True)
os.makedirs(vdlkm_mods_dir, exist_ok=True)

# Modul yang masuk vendor_boot (first-stage, dari modules.load stock)
VENDOR_BOOT_MODS = {
    "miev.ko","smp2p.ko","qcom-apcs-ipc-mailbox.ko","qcom-mpm.ko","glink_probe.ko",
    "qcom_glink_rpm.ko","qcom_glink_smem.ko","rpm-smd-regulator.ko","rpm-smd.ko",
    "qcom_smd.ko","qcom_glink.ko","qcom_wdt_core.ko","qcom_soc_wdt.ko","minidump.ko",
    "qcom_logbuf_vh.ko","qcom_cpu_vendor_hooks.ko","clk-smd-rpm.ko","gcc-khaje.ko",
    "gcc-scuba.ko","gcc-sm6115.ko","qnoc-scuba.ko","qcom-cpufreq-hw.ko",
    "qcom_ipc_logging.ko","clk-dummy.ko","clk-qcom.ko","cqhci.ko","dcc_v2.ko",
    "debug-regulator.ko","gdsc-regulator.ko","icc-rpm.ko","icc-debug.ko",
    "iommu-logger.ko","memory_dump_v2.ko","mem_buf_dev.ko","mem_buf.ko",
    "msm_dma_iommu_mapping.ko","pinctrl-khaje.ko","pinctrl-bengal.ko","pinctrl-scuba.ko",
    "goodix_fp.ko","silead_fp.ko","qnoc-bengal.ko","nvmem_qfprom.ko",
    "nvmem_qcom-spmi-sdam.ko","phy-qcom-ufs.ko","phy-qcom-ufs-qmp-v4-khaje.ko",
    "phy-qcom-ufs-qmp-v3-660.ko","phy-qcom-ufs-qrbtc-sdm845.ko","pinctrl-msm.ko",
    "proxy-consumer.ko","qcom-dcvs.ko","qpnp-power-on.ko","msm-poweroff.ko",
    "qcom_dma_heaps.ko","qcom_hwspinlock.ko","qcom_iommu_util.ko","qcom-spmi-pmic.ko",
    "spmi-pmic-arb.ko","qcom-scm.ko","qnoc-qos-rpm.ko","qrtr.ko",
    "qti-regmap-debugfs.ko","regmap-spmi.ko","sched-walt.ko","secure_buffer.ko",
    "smem.ko","socinfo.ko","stub-regulator.ko","ufs_qcom.ko","arm_smmu.ko",
    "mem-offline.ko","sdhci-msm.ko","sdhci-msm-scaling.ko","rproc_qcom_common.ko",
    "qcom_glink_spss.ko","usbpd.ko","crypto-qti-tz.ko","crypto-qti-common.ko",
    "ufshcd-crypto-qti.ko","slim-qcom-ngd-ctrl.ko","bam_dma.ko","pdr_interface.ko",
    "qmi_helpers.ko","slimbus.ko","qcom-pmu-lib.ko","mi_memory.ko","simtray.ko",
    "nfc_i2c.ko","perf_helper.ko","mi_thermal_interface.ko","panel_event_notifier.ko",
    "zram.ko","zsmalloc.ko","binder_prio.ko","qseecom_dlkm.ko","qrng_dlkm.ko",
    "bootinfo.ko","swinfo.ko",
}

# Modul yang ada di vendor_dlkm stock (second-stage)
VENDOR_DLKM_STOCK = {
    "cfg80211.ko","qca_cld3_wlan.ko","msm_drm.ko","msm_kgsl.ko","camera.ko",
    "ipam.ko","ipanetm.ko","rndisipam.ko","ipa_clientsm.ko","rmnet_core.ko",
    "rmnet_ctl.ko","rmnet_wlan.ko","hdcp_qseecom_dlkm.ko","smcinvoke_dlkm.ko",
    "lct_tp.ko","btpower.ko","bt_fm_slim.ko","binder_gki.ko","hardwareinfo.ko",
    "tz_log_dlkm.ko","qcedev-mod_dlkm.ko","qcrypto-msm_dlkm.ko","qce50_dlkm.ko",
    "wlan_firmware_service.ko","cnss_nl.ko","cnss_prealloc.ko","cnss_utils.ko",
    "icnss2.ko","msm_sysstats.ko","msm-mmrm.ko",
}

print("\n=== Collecting modules ===")
total_vboot = 0
total_vdlkm = 0
total_nh    = 0

search_roots = [
    os.path.join(OUT_DIR, "staging"),
    os.path.join(OUT_DIR, "gki_kernel", "common"),
    os.path.join(OUT_DIR, "msm-kernel"),
    DIST_DIR,
]

for root in search_roots:
    if not os.path.isdir(root):
        continue
    for dirpath, _, files in os.walk(root):
        for fname in files:
            if not fname.endswith(".ko"):
                continue
            src = os.path.join(dirpath, fname)

            if fname in VENDOR_BOOT_MODS:
                # Stock vendor_boot modul → vendor ramdisk
                shutil.copy2(src, os.path.join(vboot_mods_dir, fname))
                total_vboot += 1
            elif fname in VENDOR_DLKM_STOCK:
                # Stock vendor_dlkm modul (termasuk qca_cld3_wlan patched)
                shutil.copy2(src, os.path.join(vdlkm_mods_dir, fname))
                total_vdlkm += 1
            else:
                # NetHunter modul baru → vendor_dlkm juga
                shutil.copy2(src, os.path.join(vdlkm_mods_dir, fname))
                total_nh += 1

print(f"vendor_boot modules: {total_vboot}")
print(f"vendor_dlkm stock modules: {total_vdlkm}")
print(f"NetHunter new modules: {total_nh}")
print(f"Total vendor_dlkm: {len(os.listdir(vdlkm_mods_dir))}")

# Verifikasi qca_cld3_wlan.ko (yang patched) masuk vendor_dlkm
wlan_dst = os.path.join(vdlkm_mods_dir, "qca_cld3_wlan.ko")
if os.path.isfile(wlan_dst):
    size = os.path.getsize(wlan_dst)
    print(f"\nqca_cld3_wlan.ko (patched): {size/1024/1024:.1f} MB → vendor_dlkm OK")
else:
    print("\nWARN: qca_cld3_wlan.ko tidak ditemukan di output build")

# ── anykernel.sh ──────────────────────────────────────────────────────────────
print("\n=== Writing anykernel.sh ===")
ak_sh = """properties() { '
kernel.string=Creek-Nethunter v2 Unified by dr1408+Ferztie666
do.devicecheck=1
do.modules=1
do.systemmodules=1
do.cleanup=1
do.cleanuponabort=0
device.name1=creek
supported.versions=13-15
'; }
block=/dev/block/bootdevice/by-name/boot;
is_slot_device=1;
ramdisk_compression=auto;
. tools/ak3-core.sh;
dump_boot;
write_boot;
ui_print " ";
ui_print "Creek-Nethunter v2 Unified";
ui_print " ";
ui_print "- Installing vendor_boot modules...";
copy_ak modules/vendor/lib/modules/ /vendor/lib/modules/;
set_perm_recursive /vendor/lib/modules root root 644 755;
ui_print "- Installing vendor_dlkm modules (NH + patched wlan)...";
copy_ak modules/vendor_dlkm/lib/modules/ /vendor_dlkm/lib/modules/;
set_perm_recursive /vendor_dlkm/lib/modules root root 644 755;
ui_print "- Installing NHD daemon...";
copy_ak system/bin/nhd /system/bin/nhd;
set_perm /system/bin/nhd root root 0755;
ui_print " ";
ui_print "- Done! Reboot to apply.";
"""
with open(os.path.join(AK3_DIR, "anykernel.sh"), "w") as f:
    f.write(ak_sh)
print("anykernel.sh written")

# ── NHD daemon ────────────────────────────────────────────────────────────────
print("\n=== Writing NHD daemon ===")
nhd_dir = os.path.join(AK3_DIR, "system/bin")
os.makedirs(nhd_dir, exist_ok=True)
nhd_script = r"""#!/system/bin/sh
LOG=/data/nhsystem/nhd.log
KO_MON=/vendor_dlkm/lib/modules/qca_cld3_wlan.ko
KO_STOCK=/vendor_dlkm/lib/modules/qca_cld3_wlan.ko
SYSFS_CH=/sys/devices/platform/soc/c800000.qcom,icnss/net/wlan0/monitor_mode_channel
SYSFS_TYPE=/sys/class/net/wlan0/type
MOD=/vendor_dlkm/lib/modules
mkdir -p /data/nhsystem
log_nhd() { echo "[$(date '+%H:%M:%S')] $1" >> "$LOG"; }
ismon() { [ "$(cat $SYSFS_TYPE 2>/dev/null)" = "803" ]; }
usb_load() {
  VID=$(cat /sys/bus/usb/devices/$1/idVendor 2>/dev/null)
  PID=$(cat /sys/bus/usb/devices/$1/idProduct 2>/dev/null)
  [ -z "$VID" ] && return
  log_nhd "USB: ${VID}:${PID}"
  case "${VID}:${PID}" in
    0bda:8812) insmod $MOD/rtw_core.ko 2>/dev/null; insmod $MOD/rtw_usb.ko 2>/dev/null; insmod $MOD/rtw_8812au.ko 2>/dev/null; log_nhd "rtw_8812au loaded" ;;
    0bda:c811) insmod $MOD/rtw_core.ko 2>/dev/null; insmod $MOD/rtw_8821cu.ko 2>/dev/null; log_nhd "rtw_8821cu loaded" ;;
    0bda:8179) insmod $MOD/rtl8xxxu.ko 2>/dev/null; log_nhd "rtl8xxxu loaded" ;;
    0cf3:9271) insmod $MOD/ath9k_htc.ko 2>/dev/null; log_nhd "ath9k_htc loaded" ;;
    148f:7601) insmod $MOD/mt76.ko 2>/dev/null; insmod $MOD/mt7601u.ko 2>/dev/null; log_nhd "mt7601u loaded" ;;
    148f:761a|148f:7612) insmod $MOD/mt76.ko 2>/dev/null; insmod $MOD/mt76x2u.ko 2>/dev/null; log_nhd "mt76x2u loaded" ;;
    1d50:6089) insmod $MOD/hackrf.ko 2>/dev/null; log_nhd "hackrf loaded" ;;
    1d50:60a1) insmod $MOD/airspy.ko 2>/dev/null; log_nhd "airspy loaded" ;;
    0bda:2838) insmod $MOD/rtl2832.ko 2>/dev/null; insmod $MOD/rtl2832_sdr.ko 2>/dev/null; log_nhd "rtl-sdr loaded" ;;
    10c4:ea60) insmod $MOD/cp210x.ko 2>/dev/null; log_nhd "cp210x loaded" ;;
    067b:2303) insmod $MOD/pl2303.ko 2>/dev/null; log_nhd "pl2303 loaded" ;;
    072f:2200) insmod $MOD/pn533.ko 2>/dev/null; insmod $MOD/pn533_usb.ko 2>/dev/null; log_nhd "pn533 loaded" ;;
    04b4:0004) insmod $MOD/wire.ko 2>/dev/null; insmod $MOD/ds2490.ko 2>/dev/null; log_nhd "ds2490 loaded" ;;
    2d2d:504d) log_nhd "Proxmark3 detected" ;;
    *) log_nhd "USB unknown: ${VID}:${PID}" ;;
  esac
}
wifi_mon_on() {
  ismon && return 0
  log_nhd "wlan0 -> monitor"
  svc wifi disable; sleep 3
  rmmod wlan 2>/dev/null; sleep 1
  insmod "$KO_MON" con_mode=4; sleep 8
  ip link set wlan0 up
  echo "${1:-6} 0" > "$SYSFS_CH"
  log_nhd "monitor ON ch${1:-6}"
}
wifi_man_on() {
  ! ismon && return 0
  log_nhd "wlan0 -> managed"
  rmmod wlan 2>/dev/null; sleep 2
  insmod "$KO_STOCK"; sleep 5
  svc wifi enable
  log_nhd "managed ON"
}
case "$1" in
  mon)     wifi_mon_on "${2:-6}" ;;
  managed) wifi_man_on ;;
  ch)      ismon && echo "${2:-6} 0" > "$SYSFS_CH" ;;
  status)  ismon && echo "MONITOR (803)" || echo "MANAGED (1)" ;;
  *)
    log_nhd "NHD v2 started"
    PREV=""
    while true; do
      CUR=$(ls /sys/bus/usb/devices/ 2>/dev/null | sort | tr '\n' ':')
      if [ "$CUR" != "$PREV" ]; then
        for dev in /sys/bus/usb/devices/*/idVendor; do
          dir=$(dirname "$dev"); name=$(basename "$dir")
          flag="$dir/.nhd"; [ -f "$flag" ] && continue
          touch "$flag"; usb_load "$name" &
        done
        PREV="$CUR"
      fi
      sleep 5
    done ;;
esac
"""
nhd_path = os.path.join(nhd_dir, "nhd")
with open(nhd_path, "w") as f:
    f.write(nhd_script)
os.chmod(nhd_path, 0o755)
print("NHD daemon written")

# ── Pack zip ──────────────────────────────────────────────────────────────────
print("\n=== Packing AK3 zip ===")
ts = datetime.now().strftime("%Y%m%d-%H%M")
zipname = f"Creek-Nethunter-v2-Unified-{ts}.zip"
zippath = os.path.join(ARTS_DIR, zipname)

result = subprocess.run(
    ["zip", "-r9", zippath, ".", "-x", "*.git*"],
    cwd=AK3_DIR, capture_output=True, text=True
)
if result.returncode != 0:
    print("zip stderr:", result.stderr[-500:])
    sys.exit(1)

size = os.path.getsize(zippath)
print(f"ZIP ready: {zipname} ({size/1024/1024:.1f} MB)")
print(f"Path: {zippath}")
