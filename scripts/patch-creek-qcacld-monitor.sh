#!/usr/bin/env bash
set -euo pipefail

KP="${1:?usage: patch-creek-qcacld-monitor.sh <kernel_platform> <repo_root>}"
REPO_ROOT="${2:?repository root required}"
WLAN_ROOT="$KP/vendor/qcom/opensource/wlan"
MON="$WLAN_ROOT/qcacld-3.0/core/hdd/src/wlan_hdd_rx_monitor.c"

test -s "$MON" || { echo "ERROR: QCACLD monitor source missing: $MON" >&2; exit 1; }

# Patch only the two known function prologues. The previous unified diff
# depended on exact hunk context and failed against the pinned creek-injection
# source despite the function being the audited target. No fuzzy patching:
# Python requires exactly one occurrence of each known prologue.
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
#ifdef FEATURE_FRAME_INJECTION_SUPPORT
\tstruct hdd_adapter *adapter = WLAN_HDD_GET_PRIV_PTR(dev);
#endif

\thdd_enter_dev(dev);"""

enable_new = """int hdd_enable_monitor_mode(struct net_device *dev)
{
\tvoid *soc;
\tint vdev_id;
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

disable_old = """int hdd_disable_monitor_mode(struct net_device *dev)
{
\tvoid *soc = cds_get_context(QDF_MODULE_ID_SOC);
\tint vdev_id;
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

def replace_exact(text, old, new, label):
    count = text.count(old)
    if count == 1:
        return text.replace(old, new, 1)
    # Idempotency: accept the exact fully patched prologue only.
    if count == 0 and text.count(new) == 1:
        return text
    raise SystemExit(f"ERROR: {label}: expected exactly one known old or patched prologue; old_count={count}, patched_count={text.count(new)}")

s = replace_exact(s, enable_old, enable_new, "enable_monitor_mode")
s = replace_exact(s, disable_old, disable_new, "disable_monitor_mode")

# Recovery fix: always attempt the PDEV reset on disable. The old early return
# on an unresolved monitor vdev skipped cdp_reset_monitor_mode() and could leave
# wlan0 stuck after a failed monitor transition.
old_disable_lookup = """\tvdev_id = cdp_get_mon_vdev_from_pdev(soc, OL_TXRX_PDEV_ID);
\tif (vdev_id < 0)
\t\treturn -EINVAL;

#ifdef FEATURE_FRAME_INJECTION_SUPPORT"""
new_disable_lookup = """\t/* Always attempt PDEV monitor reset even if no monitor vdev resolves. */
#ifdef FEATURE_FRAME_INJECTION_SUPPORT"""
disable_start = s.find("int hdd_disable_monitor_mode(")
if disable_start < 0:
    raise SystemExit("ERROR: missing hdd_disable_monitor_mode while applying recovery fix")
prefix, disable_src = s[:disable_start], s[disable_start:]
count = disable_src.count(old_disable_lookup)
if count == 1:
    disable_src = disable_src.replace(old_disable_lookup, new_disable_lookup, 1)
elif count == 0 and disable_src.count(new_disable_lookup) == 1:
    pass
else:
    raise SystemExit(f"ERROR: disable monitor recovery block ambiguous; old_count={count}, new_count={disable_src.count(new_disable_lookup)}")
s = prefix + disable_src

if s != original:
    p.write_text(s)

# Verify both functions independently; fail closed on partial or ambiguous edits.
def function_body(text, start, end=None):
    a = text.find(start)
    if a < 0:
        raise SystemExit(f"ERROR: missing function {start}")
    b = text.find(end, a + len(start)) if end else len(text)
    if end and b < 0:
        raise SystemExit(f"ERROR: missing function boundary {end}")
    return text[a:b]

enable = function_body(s, "int hdd_enable_monitor_mode(", "int hdd_disable_monitor_mode(")
disable = function_body(s, "int hdd_disable_monitor_mode(")
if "cdp_reset_monitor_mode(soc, OL_TXRX_PDEV_ID, false)" not in disable:
    raise SystemExit("ERROR: disable monitor recovery path no longer attempts PDEV reset")
if "cdp_get_mon_vdev_from_pdev" in disable or "vdev_id < 0" in disable:
    raise SystemExit("ERROR: disable monitor path still has an early return before PDEV reset")
for label, body in (("enable", enable), ("disable", disable)):
    for required in ("if (!dev)", "if (!soc)"):
        if required not in body:
            raise SystemExit(f"ERROR: {label} monitor prologue missing {required}")
    if "uint8_t vdev_id;" in body:
        raise SystemExit(f"ERROR: {label} monitor prologue still uses unsigned vdev_id")
if "int vdev_id;" not in enable:
    raise SystemExit("ERROR: enable monitor prologue must use signed int vdev_id")
if "vdev_id" in disable:
    raise SystemExit("ERROR: disable monitor path should not depend on monitor vdev lookup")

print("QCACLD_MONITOR_NULL_GUARDS=PASS")
print("QCACLD_MONITOR_VDEV_ID_SIGNEDNESS=PASS")
print("QCACLD_MONITOR_DISABLE_PDEV_RESET=PASS")
print("NOTE: source-level checks do not replace physical monitor-mode/recovery testing")
PY
