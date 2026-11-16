#!/usr/bin/env bash
set -euo pipefail
KP="${1:?usage: patch-creek-qcacld-monitor.sh <kernel_platform> <repo_root>}"
REPO_ROOT="${2:?repository root required}"
MON="$KP/vendor/qcom/opensource/wlan/qcacld-3.0/core/hdd/src/wlan_hdd_rx_monitor.c"
test -s "$MON" || { echo "ERROR: QCACLD monitor source missing: $MON" >&2; exit 1; }
python3 - "$MON" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
original = s
enable_old = """int hdd_enable_monitor_mode(struct net_device *dev)
{
\tvoid *soc = cds_get_context(QDF_MODULE_ID_SOC);
\tuint8_t vdev_id;
\tint ret;
\tstruct hdd_adapter *adapter = WLAN_HDD_GET_PRIV_PTR(dev);

\thdd_enter_dev(dev);"""
enable_new = """int hdd_enable_monitor_mode(struct net_device *dev)
{
\tvoid *soc;
\tint vdev_id;
\tint ret;
\tstruct hdd_adapter *adapter;

\tif (!dev)
\t\treturn -EINVAL;
\tsoc = cds_get_context(QDF_MODULE_ID_SOC);
\tif (!soc)
\t\treturn -EINVAL;
\tadapter = WLAN_HDD_GET_PRIV_PTR(dev);
\tif (!adapter)
\t\treturn -EINVAL;

\thdd_enter_dev(dev);"""
disable_old = """int hdd_disable_monitor_mode(struct net_device *dev)
{
\tvoid *soc = cds_get_context(QDF_MODULE_ID_SOC);
\tuint8_t vdev_id;
\tint ret;
#ifdef FEATURE_FRAME_INJECTION_SUPPORT
\tstruct hdd_adapter *adapter = WLAN_HDD_GET_PRIV_PTR(dev);
#endif

\thdd_enter_dev(dev);"""
disable_new = """int hdd_disable_monitor_mode(struct net_device *dev)
{
\tvoid *soc;
\tint ret;
#ifdef FEATURE_FRAME_INJECTION_SUPPORT
\tstruct hdd_adapter *adapter;
#endif

\tif (!dev)
\t\treturn -EINVAL;
\tsoc = cds_get_context(QDF_MODULE_ID_SOC);
\tif (!soc)
\t\treturn -EINVAL;
#ifdef FEATURE_FRAME_INJECTION_SUPPORT
\tadapter = WLAN_HDD_GET_PRIV_PTR(dev);
#endif

\thdd_enter_dev(dev);"""
def replace_one(text, old, new, label):
    n = text.count(old)
    if n == 1: return text.replace(old, new, 1)
    if n == 0 and text.count(new) == 1: return text
    raise SystemExit(f"ERROR: {label}: expected one exact prologue; old={n}, patched={text.count(new)}")
s = replace_one(s, enable_old, enable_new, "enable monitor prologue")
s = replace_one(s, disable_old, disable_new, "disable monitor prologue")
start = s.find("int hdd_disable_monitor_mode(")
if start < 0: raise SystemExit("ERROR: disable monitor function missing")
prefix, body = s[:start], s[start:]
lookup_old = """\tvdev_id = cdp_get_mon_vdev_from_pdev(soc, OL_TXRX_PDEV_ID);
\tif (vdev_id == (uint8_t)-EINVAL)
\t\treturn -EINVAL;
\tret = cdp_reset_monitor_mode(soc, OL_TXRX_PDEV_ID, false);
\thdd_warn("VIFDIAG monitor reset vdev=%u status=%d", vdev_id, ret);"""
lookup_new = """\t/* Always attempt PDEV reset, even if monitor-vdev lookup failed. */
\tret = cdp_reset_monitor_mode(soc, OL_TXRX_PDEV_ID, false);
\thdd_warn("VIFDIAG monitor reset status=%d", ret);"""
body = replace_one(body, lookup_old, lookup_new, "disable monitor recovery")
s = prefix + body
a, b = s.find("int hdd_enable_monitor_mode("), s.find("int hdd_disable_monitor_mode(")
enable, disable = s[a:b], s[b:]
if "cdp_reset_monitor_mode(soc, OL_TXRX_PDEV_ID, false)" not in disable: raise SystemExit("ERROR: PDEV reset absent")
if "cdp_get_mon_vdev_from_pdev" in disable or "vdev_id" in disable: raise SystemExit("ERROR: disable still depends on monitor-vdev lookup")
for name, fn in (("enable", enable), ("disable", disable)):
    if "if (!dev)" not in fn or "if (!soc)" not in fn: raise SystemExit(f"ERROR: {name} null guards absent")
if "if (!adapter)" not in enable: raise SystemExit("ERROR: adapter null guard absent")
if "uint8_t vdev_id;" in enable or "int vdev_id;" not in enable: raise SystemExit("ERROR: vdev_id must be signed")
if s != original: p.write_text(s)
print("QCACLD_MONITOR_NULL_GUARDS=PASS")
print("QCACLD_MONITOR_VDEV_ID_SIGNEDNESS=PASS")
print("QCACLD_MONITOR_DISABLE_PDEV_RESET=PASS")
print("NOTE: physical monitor-mode and wlan0 recovery testing remains required")
PY
