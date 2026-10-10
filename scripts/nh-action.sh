#!/system/bin/sh
# KernelSU Manager Action: status only. Loading drivers is always an explicit
# separate command; this action must never alter WLAN state.
set -eu
MODDIR="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)"
if [ ! -x "$MODDIR/nhd" ]; then
  echo "ERROR: nhd helper not found at $MODDIR/nhd" >&2
  exit 1
fi
exec "$MODDIR/nhd" status
