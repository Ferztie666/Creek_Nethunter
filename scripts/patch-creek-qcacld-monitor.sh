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
for label, body in (("enable", enable), ("disable", disable)):
    for required in ("if (!dev)", "if (!soc)", "int vdev_id;"):
        if required not in body:
            raise SystemExit(f"ERROR: {label} monitor prologue missing {required}")
    if "uint8_t vdev_id;" in body:
        raise SystemExit(f"ERROR: {label} monitor prologue still uses unsigned vdev_id")

print("QCACLD_MONITOR_NULL_GUARDS=PASS")
print("QCACLD_MONITOR_VDEV_ID_SIGNEDNESS=PASS")
print("NOTE: source-level checks do not replace physical monitor-mode/recovery testing")
PY
