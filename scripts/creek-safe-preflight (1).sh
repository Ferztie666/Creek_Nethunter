#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:?kernel_platform path required}"
REPO_ROOT="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

die(){ echo "ERROR: $*" >&2; exit 1; }
need(){ test -e "$1" || die "missing: $1"; }

echo "== CREEK SAFE PREFLIGHT =="
need "$ROOT/common"
need "$ROOT/msm-kernel"
need "$ROOT/vendor/qcom/opensource/wlan/qcacld-3.0"
need "$ROOT/build/build.sh"

# Never permit known unsafe/stale implementation shortcuts in the actual
# kernel/vendor source tree.  Do NOT scan this repository's audit scripts here: the
# audit itself necessarily contains the strings it is checking for, and historical
# helper scripts may mention them as text without executing them.
UNSAFE_RE='BUT WHO CARES\?|make[[:space:]]+-i([[:space:]]|$)|rmmod[[:space:]]+wlan|insmod[[:space:]].*qca_cld3_wlan.*con_mode=4|ol_txrx_get_mon_vdev_from_pdev|hdd_mon_stop'
for tree in "$ROOT/common" "$ROOT/msm-kernel" "$ROOT/vendor/qcom/opensource/wlan"; do
  if grep -RqsE --exclude-dir=.git --exclude=\*.o --exclude=\*.a --exclude=\*.ko "$UNSAFE_RE" "$tree" 2>/dev/null; then
    die "unsafe/stale kernel or WLAN pattern detected in source: $tree"
  fi
done

# ABI checker must remain authoritative. Do not modify it to ignore ABI/KMI errors.
ABI=""
for f in "$ROOT/build/abi/compare_to_symbol_list" "$ROOT/build/kernel/abi/compare_to_symbol_list"; do
  if [ -f "$f" ]; then ABI="$(readlink -f "$f")"; break; fi
done
if [ -z "$ABI" ]; then
  die "ABI checker not found"
fi
if grep -qs 'BUT WHO CARES?' "$ABI"; then
  die "ABI checker bypass is active"
fi

# Kernel identity must remain the Creek GKI family used by the manifest.
grep -Rqs '5\.15\.167-android13-8' "$ROOT/common/Makefile" "$ROOT/msm-kernel/Makefile" \
  || echo "[warn] kernel release string not found in Makefiles; build will verify final vermagic"

# Current QCACLD monitor implementation must use the current CDP API.
MON="$ROOT/vendor/qcom/opensource/wlan/qcacld-3.0/core/hdd/src/wlan_hdd_rx_monitor.c"
need "$MON"
grep -q 'cdp_get_mon_vdev_from_pdev' "$MON" || die "current QCACLD monitor API not present"
grep -q 'cdp_set_monitor_mode' "$MON" || die "current QCACLD monitor enable API not present"
grep -q 'cdp_reset_monitor_mode' "$MON" || die "current QCACLD monitor reset API not present"

# Required feature source/config evidence.
grep -Rqs 'FEATURE_MONITOR_MODE_SUPPORT' "$ROOT/vendor/qcom/opensource/wlan/qcacld-3.0/configs" \
  || die "QCACLD monitor feature config missing"
grep -Rqs 'FEATURE_FRAME_INJECTION_SUPPORT' "$ROOT/vendor/qcom/opensource/wlan/qcacld-3.0/configs" \
  || die "QCACLD injection feature config missing"

echo "SAFE_PREFLIGHT=PASS"
echo "ABI_CHECKER=$ABI"
echo "QCACLD_MONITOR=PASS"
