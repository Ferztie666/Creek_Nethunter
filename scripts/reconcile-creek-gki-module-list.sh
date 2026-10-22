#!/usr/bin/env bash
set -euo pipefail

# Reconcile only a reviewed, explicit set of optional modules that this
# repository intentionally enables. This does not touch ABI/KMI symbol lists.
MODULES_ORDER="${1:?usage: reconcile-creek-gki-module-list.sh <modules.order> <gki_aarch64_modules>}"
ALLOWLIST="${2:?usage: reconcile-creek-gki-module-list.sh <modules.order> <gki_aarch64_modules>}"
REPORT="${3:-$PWD/gki-module-list-reconcile.txt}"
die() { echo "ERROR: $*" >&2; exit 1; }
[[ -s "$MODULES_ORDER" && -s "$ALLOWLIST" ]] || die "modules.order and checked-in allowlist must both exist and be non-empty"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
sort -u "$MODULES_ORDER" > "$tmpdir/order.sorted"
sort -u "$ALLOWLIST" > "$tmpdir/allow.sorted"
[[ "$(wc -l < "$MODULES_ORDER")" -eq "$(wc -l < "$tmpdir/order.sorted")" ]] || die "modules.order contains duplicate entries"
if grep -Ev '^[A-Za-z0-9_./+-]+\.ko$' "$tmpdir/order.sorted" >/dev/null; then
  die "modules.order contains a malformed non-.ko entry"
fi
comm -13 "$tmpdir/allow.sorted" "$tmpdir/order.sorted" > "$tmpdir/additions"
comm -23 "$tmpdir/allow.sorted" "$tmpdir/order.sorted" > "$tmpdir/removals"

# Explicitly reviewed optional targets expected from the NetHunter config
# on the pinned Creek tree. Any unreviewed addition/removal remains fatal.
cat > "$tmpdir/approved-additions" <<'EOF'
drivers/net/can/usb/usb_8dev.ko
drivers/net/can/usb/ems_usb.ko
drivers/net/can/usb/esd_usb2.ko
drivers/net/can/usb/gs_usb.ko
drivers/net/can/usb/kvaser_usb/kvaser_usb.ko
drivers/net/can/usb/peak_usb/peak_usb.ko
drivers/net/can/slcan.ko
drivers/net/wireless/ath/ath.ko
drivers/net/wireless/ath/ath9k/ath9k_common.ko
drivers/net/wireless/ath/ath9k/ath9k_hw.ko
drivers/net/wireless/ath/ath9k/ath9k_htc.ko
drivers/net/wireless/ath/carl9170/carl9170.ko
drivers/net/wireless/zydas/zd1211rw/zd1211rw.ko
drivers/usb/serial/ch341.ko
drivers/usb/serial/cp210x.ko
drivers/usb/serial/ftdi_sio.ko
drivers/usb/serial/pl2303.ko
drivers/w1/slaves/w1_ds2408.ko
drivers/bluetooth/btintel.ko
drivers/bluetooth/btrtl.ko
net/mac80211/mac80211.ko
net/wireless/cfg80211.ko
EOF
sort -u "$tmpdir/approved-additions" > "$tmpdir/approved.sorted"
if ! diff -u "$tmpdir/approved.sorted" "$tmpdir/additions"; then
  die "module allowlist delta contains unreviewed additions; refusing automatic update"
fi
if [[ -s "$tmpdir/removals" ]]; then
  echo "Unapproved removed modules:" >&2
  cat "$tmpdir/removals" >&2
  die "module allowlist delta contains removals; inspect Kconfig before proceeding"
fi

mkdir -p "$(dirname "$REPORT")"
{
  echo "ALLOWLIST_RECONCILIATION=PASS"
  echo "MODE=explicit-reviewed-additions-only"
  echo "ADDITIONS=$(wc -l < "$tmpdir/additions" | tr -d ' ')"
  echo "REMOVALS=0"
  echo "ABI_KMI_SYMBOL_LIST_MODIFIED=NO"
  echo "SOURCE_MODULES_ORDER=$MODULES_ORDER"
  echo "TARGET_ALLOWLIST=$ALLOWLIST"
  echo "--- approved additions ---"
  cat "$tmpdir/additions"
} > "$REPORT"
# Preserve exact upstream order expected by its consistency checker.
cp "$MODULES_ORDER" "$ALLOWLIST"
echo "GKI_MODULE_LIST_RECONCILED=PASS"
cat "$REPORT"
