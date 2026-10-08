#!/usr/bin/env bash
set -euo pipefail

STAGING="${1:?usage: package-creek-adapters.sh <staging> <output-dir>}"
OUT="${2:?usage: package-creek-adapters.sh <staging> <output-dir>}"

MODROOT=""
for d in "$STAGING"/lib/modules/*; do
  if [ -d "$d" ]; then MODROOT="$d"; break; fi
done
[ -n "$MODROOT" ] || { echo "ERROR: no staging kernel module directory found: $STAGING" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT"

declare -A BY_NAME
while IFS= read -r -d '' f; do
  n="${f##*/}"
  n="${n%.ko}"
  BY_NAME["$n"]="$f"
done < <(find "$MODROOT" -type f -name '*.ko' -print0)

echo "ADAPTER_STAGE=${MODROOT}"
echo "TOTAL_STAGED_MODULES=${#BY_NAME[@]}"

declare -A WANT
declare -a QUEUE=()

add_driver_tree() {
  local root="$1"
  [ -d "$root" ] || return 0
  while IFS= read -r -d '' f; do
    local n="${f##*/}"
    n="${n%.ko}"
    WANT["$n"]="driver"
    QUEUE+=("$n")
  done < <(find "$root" -type f -name '*.ko' -print0)
}

# External USB-adapter drivers built by this Creek NetHunter tree.
# Internal Qualcomm QCACLD (wlan0) is deliberately excluded.
add_driver_tree "$MODROOT/extra/nethunter/rtw88"
add_driver_tree "$MODROOT/extra/nethunter/rtl8xxxu"

# Include only MediaTek wireless driver families (mt76/mt7601u/etc.), not
# arbitrary Qualcomm/vendor modules.
add_driver_tree "$MODROOT/kernel/drivers/net/wireless/mediatek"

[ "${#QUEUE[@]}" -gt 0 ] || {
  echo "ERROR: no NetHunter external adapter modules were built" >&2
  echo "Available external module directories:" >&2
  find "$MODROOT" -maxdepth 4 -type d \( -path '*/extra/nethunter/*' -o -path '*/kernel/drivers/net/wireless/*' \) -print 2>/dev/null | sort >&2 || true
  exit 1
}

# Resolve real module dependencies when modinfo is available.
# The resolver only accepts dependencies that are actually present in staging.
if command -v modinfo >/dev/null 2>&1; then
  for ((i=0; i<${#QUEUE[@]}; i++)); do
    n="${QUEUE[$i]}"
    f="${BY_NAME[$n]:-}"
    [ -n "$f" ] || continue
    deps="$(modinfo -F depends "$f" 2>/dev/null || true)"
    IFS=',' read -ra dep_arr <<< "$deps"
    for dep in "${dep_arr[@]}"; do
      [ -n "$dep" ] || continue
      if [ -n "${BY_NAME[$dep]:-}" ] && [ -z "${WANT[$dep]:-}" ]; then
        WANT["$dep"]="dependency"
        QUEUE+=("$dep")
      fi
    done
  done
else
  echo "[warn] modinfo is unavailable; packaging driver modules without dependency expansion" >&2
fi

driver_count=0
dependency_count=0
for n in "${!WANT[@]}"; do
  f="${BY_NAME[$n]:-}"
  [ -n "$f" ] || { echo "ERROR: missing selected module: $n" >&2; exit 1; }
  cp -f "$f" "$OUT/$n.ko"
  case "${WANT[$n]}" in
    driver) driver_count=$((driver_count+1));;
    dependency) dependency_count=$((dependency_count+1));;
    *) echo "ERROR: invalid module class for $n" >&2; exit 1;;
  esac
done

# Never allow the internal Qualcomm WLAN driver into the USB adapter package.
if [ -e "$OUT/qca_cld3_wlan.ko" ]; then
  echo "ERROR: qca_cld3_wlan.ko leaked into adapter package" >&2
  exit 1
fi

actual_count="$(find "$OUT" -maxdepth 1 -type f -name '*.ko' -printf '%f\n' | wc -l)"
expected_count=$((driver_count + dependency_count))
if [ "$actual_count" -ne "$expected_count" ]; then
  echo "ERROR: adapter module count mismatch: actual=$actual_count expected=$expected_count" >&2
  find "$OUT" -maxdepth 1 -type f -name '*.ko' -printf '%f\n' | sort >&2
  exit 1
fi

{
  echo "Creek NetHunter external adapter module package"
  echo "Kernel module tree: ${MODROOT##*/}"
  echo "Driver modules: $driver_count"
  echo "Dependency modules: $dependency_count"
  echo
  echo "[driver]"
  for n in "${!WANT[@]}"; do
    if [ "${WANT[$n]}" = driver ]; then
      printf '%s\\n' "$n.ko"
    fi
  done | sort
  echo
  echo "[dependency]"
  for n in "${!WANT[@]}"; do
    if [ "${WANT[$n]}" = dependency ]; then
      printf '%s\\n' "$n.ko"
    fi
  done | sort
} > "$OUT/MODULE-MANIFEST.txt"

find "$OUT" -maxdepth 1 -type f -name '*.ko' -printf '%f\n' | sort > "$OUT/MODULE-LIST.txt"
printf 'ADAPTER_PACKAGE=PASS\nDRIVER_MODULES=%s\nDEPENDENCY_MODULES=%s\n' "$driver_count" "$dependency_count"
