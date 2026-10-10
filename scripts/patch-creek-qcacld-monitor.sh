#!/usr/bin/env bash
set -euo pipefail

KP="${1:?usage: patch-creek-qcacld-monitor.sh <kernel_platform> <repo_root>}"
REPO_ROOT="${2:?repository root required}"
WLAN_ROOT="$KP/vendor/qcom/opensource/wlan"
MON="$WLAN_ROOT/qcacld-3.0/core/hdd/src/wlan_hdd_rx_monitor.c"
PATCH="$REPO_ROOT/patches/wlan/qcacld-monitor-vdev-id-signedness.patch"

test -s "$MON" || { echo "ERROR: QCACLD monitor source missing: $MON" >&2; exit 1; }
test -s "$PATCH" || { echo "ERROR: monitor fix patch missing: $PATCH" >&2; exit 1; }

if sed -n '/^int hdd_enable_monitor_mode/,/^int hdd_disable_monitor_mode/p' "$MON" | grep -q '^[[:space:]]*int vdev_id;'; then
  if sed -n '/^int hdd_enable_monitor_mode/,/^int hdd_disable_monitor_mode/p' "$MON" | grep -q '^[[:space:]]*uint8_t vdev_id;'; then
    echo "ERROR: ambiguous vdev_id declaration in monitor enable function" >&2
    exit 1
  fi
  echo "QCACLD monitor vdev_id signedness fix already present"
elif git -C "$WLAN_ROOT" apply --check "$PATCH" >/dev/null 2>&1; then
  git -C "$WLAN_ROOT" apply "$PATCH"
  echo "Applied QCACLD monitor vdev_id signedness fix"
else
  echo "ERROR: monitor source differs from the audited patch context; refusing a fuzzy patch" >&2
  exit 1
fi

sed -n '/^int hdd_enable_monitor_mode/,/^int hdd_disable_monitor_mode/p' "$MON" | grep -q '^[[:space:]]*int vdev_id;' || {
  echo "ERROR: signed vdev_id fix did not verify" >&2
  exit 1
}
if sed -n '/^int hdd_enable_monitor_mode/,/^int hdd_disable_monitor_mode/p' "$MON" | grep -q '^[[:space:]]*uint8_t vdev_id;'; then
  echo "ERROR: unsigned vdev_id remains in monitor enable function" >&2
  exit 1
fi
echo "QCACLD_MONITOR_VDEV_ID_FIX=PASS"
