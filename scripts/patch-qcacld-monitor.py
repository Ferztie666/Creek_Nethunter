#!/usr/bin/env python3
"""
Patch qcacld-3.0 untuk fix kernel panic saat monitor mode.
Dipanggil oleh workflow: python3 scripts/patch-qcacld-monitor.py <qcacld_root>
"""
import sys
import os

qcacld = sys.argv[1]
qdf_file = os.path.join(qcacld, "qdf/src/qdf_event.c")
hdd_file = os.path.join(qcacld, "core/hdd/src/wlan_hdd_main.c")

def patch_file(path, old, new, name):
    if not os.path.isfile(path):
        print(f"SKIP: {name} not found at {path}")
        return False
    with open(path, 'r') as f:
        content = f.read()
    if old in content:
        with open(path, 'w') as f:
            f.write(content.replace(old, new))
        print(f"OK: {name} patched")
        return True
    else:
        print(f"SKIP: {name} pattern not found (may already be patched)")
        return False

# Patch 1: QDF_BUG -> return error (cegah kernel panic)
patch_file(
    qdf_file,
    'QDF_BUG(qdf_event->cookie == COOKIE_READY_TO_WAIT);',
    ('if (qdf_event->cookie != COOKIE_READY_TO_WAIT) {\n'
     '\t\tQDF_TRACE(QDF_MODULE_ID_QDF, QDF_TRACE_LEVEL_ERROR,\n'
     '\t\t\t  "%s: event not ready", __func__);\n'
     '\t\treturn QDF_STATUS_E_FAILURE;\n'
     '\t}'),
    "qdf_event QDF_BUG fix"
)

# Patch 2: NULL pointer guard di hdd_disable_monitor_mode
patch_file(
    hdd_file,
    'vdev = ol_txrx_get_mon_vdev_from_pdev(pdev);\n\thdd_mon_stop(vdev);',
    ('vdev = ol_txrx_get_mon_vdev_from_pdev(pdev);\n'
     '\tif (!vdev) {\n'
     '\t\thdd_err("mon vdev NULL, safely skipping disable");\n'
     '\t\treturn -EINVAL;\n'
     '\t}\n'
     '\thdd_mon_stop(vdev);'),
    "hdd_main NULL pointer guard"
)

print("qcacld monitor mode patch done")
