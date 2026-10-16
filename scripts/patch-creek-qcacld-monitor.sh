#!/usr/bin/env bash
set -euo pipefail

KP="${1:?usage: patch-creek-qcacld-monitor.sh <kernel_platform> <repo_root>}"
REPO_ROOT="${2:?repository root required}"
WLAN_ROOT="$KP/vendor/qcom/opensource/wlan"
MON="$WLAN_ROOT/qcacld-3.0/core/hdd/src/wlan_hdd_rx_monitor.c"
PATCH="$REPO_ROOT/patches/wlan/qcacld-monitor-vdev-id-signedness.patch"

test -s "$MON" || { echo "ERROR: QCACLD monitor source missing: $MON" >&2; exit 1; }
test -s "$PATCH" || { echo "ERROR: monitor safety patch missing: $PATCH" >&2; exit 1; }

enable_fn() {
  sed -n '/^int hdd_enable_monitor_mode/,/^int hdd_disable_monitor_mode/p' "$MON"
}
disable_fn() {
  sed -n '/^int hdd_disable_monitor_mode/,$p' "$MON"
}
is_fully_patched() {
  enable_fn | grep -q '^[[:space:]]*int vdev_id;' &&
  ! enable_fn | grep -q '^[[:space:]]*uint8_t vdev_id;' &&
  enable_fn | grep -q 'if (!dev)' &&
  enable_fn | grep -q 'if (!soc)' &&
  disable_fn | grep -q '^[[:space:]]*int vdev_id;' &&
  disable_fn | grep -q 'if (!dev)' &&
  disable_fn | grep -q 'if (!soc)'
}

if is_fully_patched; then
  echo "QCACLD monitor NULL guards and signed vdev_id fix already present"
elif git -C "$WLAN_ROOT" apply --check "$PATCH" >/dev/null 2>&1; then
  git -C "$WLAN_ROOT" apply "$PATCH"
  echo "Applied QCACLD monitor NULL guards and signed vdev_id fix"
else
  echo "ERROR: monitor source is neither unpatched audited source nor the complete expected fix; refusing a fuzzy/partial patch" >&2
  exit 1
fi

is_fully_patched || {
  echo "ERROR: QCACLD monitor safety fix did not verify completely" >&2
  exit 1
}
echo "QCACLD_MONITOR_NULL_GUARDS=PASS"
echo "QCACLD_MONITOR_VDEV_ID_SIGNEDNESS=PASS"
echo "NOTE: source-level guard does not replace physical monitor-mode/recovery testing"
