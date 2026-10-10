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
# kernel/vendor source tree. Do NOT scan this repository's audit scripts here:
# the audit itself necessarily contains the strings it is checking for.
#
# Use git grep instead of recursive grep. The synced WLAN tree contains
# firmware/binary blobs and other non-source artifacts; recursive grep can
# report a binary match even when no source file contains the pattern.
# git grep searches the tracked source tree and gives us the exact file/line
# if a real stale implementation is present.
UNSAFE_RE='rmmod[[:space:]]+wlan|insmod[[:space:]].*qca_cld3_wlan.*con_mode=4|hdd_mon_stop'
for tree in "$ROOT/msm-kernel" "$ROOT/vendor/qcom/opensource/wlan"; do
  if ! git -C "$tree" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    die "not a git work tree: $tree"
  fi
  MATCH="$(git -C "$tree" grep -n -E "$UNSAFE_RE" -- . 2>/dev/null || true)"
  if [ -n "$MATCH" ]; then
    echo "$MATCH" >&2
    die "unsafe/stale kernel or WLAN source pattern detected in: $tree"
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
# cdp_get_mon_vdev_from_pdev returns a signed status/ID value. Keeping this
# local as uint8_t turns a negative failure result into 255 and defeats the
# existing < 0 guard before cdp_set_monitor_mode().
ENABLE_MON="$(sed -n '/^int hdd_enable_monitor_mode/,/^int hdd_disable_monitor_mode/p' "$MON")"
printf '%s\n' "$ENABLE_MON" | grep -q '^[[:space:]]*int vdev_id;' || die "monitor vdev_id must be signed int"
if printf '%s\n' "$ENABLE_MON" | grep -q '^[[:space:]]*uint8_t vdev_id;'; then
  die "unsigned monitor vdev_id can bypass negative-ID error handling"
fi

# Required feature source/config evidence.
grep -Rqs 'FEATURE_MONITOR_MODE_SUPPORT' "$ROOT/vendor/qcom/opensource/wlan/qcacld-3.0/configs" \
  || die "QCACLD monitor feature config missing"
grep -Rqs 'FEATURE_FRAME_INJECTION_SUPPORT' "$ROOT/vendor/qcom/opensource/wlan/qcacld-3.0/configs" \
  || die "QCACLD injection feature config missing"

echo "SAFE_PREFLIGHT=PASS"
echo "ABI_CHECKER=$ABI"
echo "QCACLD_MONITOR=PASS"
