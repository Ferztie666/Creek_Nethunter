#!/usr/bin/env bash
set -euo pipefail

STAGING="${1:?usage: package-creek-adapters.sh <staging> <output-dir>}"
OUT="${2:?usage: package-creek-adapters.sh <staging> <output-dir>}"
SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

# Emit a dependency map for on-demand loading. The Android-side helper
# loads dependencies recursively only when a user/tool explicitly requests a
# driver; it is never installed as a boot-time service.
: > "$OUT/MODULE-DEPENDS.txt"
for n in "${!WANT[@]}"; do
  f="${BY_NAME[$n]:-}"
  [ -n "$f" ] || continue
  deps=""
  if command -v modinfo >/dev/null 2>&1; then
    deps="$(modinfo -F depends "$f" 2>/dev/null | tr ',' ' ' || true)"
  fi
  printf '%s: %s\n' "$n" "$deps" >> "$OUT/MODULE-DEPENDS.txt"
done
sort -o "$OUT/MODULE-DEPENDS.txt" "$OUT/MODULE-DEPENDS.txt"
cp "$SCRIPT_ROOT/scripts/nhd" "$OUT/nhd"
cp "$SCRIPT_ROOT/scripts/nh-load.sh" "$OUT/nh-load.sh"
# Bind the package to the exact release string embedded in the built modules.
# The staging directory name may omit the Android release suffix, so do not
# use MODROOT's basename as a substitute for vermagic.
command -v modinfo >/dev/null 2>&1 || {
  echo "ERROR: modinfo is required to verify adapter module vermagic" >&2
  exit 1
}
KERNEL_RELEASE=""
for n in "${!WANT[@]}"; do
  f="${BY_NAME[$n]:-}"
  [ -n "$f" ] || continue
  vm="$(modinfo -F vermagic "$f" 2>/dev/null | awk 'NR==1 {print $1}')"
  [ -n "$vm" ] || { echo "ERROR: missing vermagic for $n" >&2; exit 1; }
  if [ -z "$KERNEL_RELEASE" ]; then
    KERNEL_RELEASE="$vm"
  elif [ "$KERNEL_RELEASE" != "$vm" ]; then
    echo "ERROR: mixed adapter vermagic: $n has $vm, expected $KERNEL_RELEASE" >&2
    exit 1
  fi
done
[ -n "$KERNEL_RELEASE" ] || { echo "ERROR: no module vermagic found" >&2; exit 1; }
printf '%s\n' "$KERNEL_RELEASE" > "$OUT/KERNEL-RELEASE"
chmod 0755 "$OUT/nhd" "$OUT/nh-load.sh"
cat > "$OUT/ON-DEMAND-LOADING.txt" <<'EOF_ON_DEMAND'
Creek NetHunter adapter modules: KernelSU-compatible on-demand payload
=======================================================================
The CI packages these files into a KernelSU module ZIP. Install it through
the KernelSU Manager app (not custom recovery). No service.sh or
post-fs-data.sh is included, so this module does not load drivers at boot.
The helper and module payload stay inside the module directory; no /system
overlay or metamodule is needed.

After installation, check state:
  su -c '/data/adb/modules/creek_nethunter_adapters/nhd status'
Load a specific adapter driver only when needed:
  su -c '/data/adb/modules/creek_nethunter_adapters/nhd load rtw_8812au'
Load a supported family on demand:
  su -c '/data/adb/modules/creek_nethunter_adapters/nhd load-family rtw88'
  su -c '/data/adb/modules/creek_nethunter_adapters/nhd load-family rtl8xxxu'
  su -c '/data/adb/modules/creek_nethunter_adapters/nhd load-family mt76'
The helper checks the running kernel release and loads packaged dependencies
first. It does not load or unload internal Qualcomm wlan0 or force monitor
mode. Compatibility with each physical adapter still needs device testing.
EOF_ON_DEMAND

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
      printf '%s\n' "$n.ko"
    fi
  done | sort
  echo
  echo "[dependency]"
  for n in "${!WANT[@]}"; do
    if [ "${WANT[$n]}" = dependency ]; then
      printf '%s\n' "$n.ko"
    fi
  done | sort
} > "$OUT/MODULE-MANIFEST.txt"

find "$OUT" -maxdepth 1 -type f -name '*.ko' -printf '%f\n' | sort > "$OUT/MODULE-LIST.txt"
printf 'ADAPTER_PACKAGE=PASS\nDRIVER_MODULES=%s\nDEPENDENCY_MODULES=%s\n' "$driver_count" "$dependency_count"
