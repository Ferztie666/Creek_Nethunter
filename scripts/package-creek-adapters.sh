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
  n="$(printf '%s' "$n" | tr '-' '_')"
  BY_NAME["$n"]="$f"
done < <(find "$MODROOT" -type f -name '*.ko' -print0)

echo "ADAPTER_STAGE=${MODROOT}"
echo "TOTAL_STAGED_MODULES=${#BY_NAME[@]}"

declare -A WANT
declare -a QUEUE=()
TARGETS="$SCRIPT_ROOT/config/creek-adapter-module-targets.txt"
[ -r "$TARGETS" ] || { echo "ERROR: module target inventory missing: $TARGETS" >&2; exit 1; }
STATUS="$OUT/MODULE-STATUS.txt"
: > "$STATUS"

while IFS= read -r line; do
  line="${line%%#*}"
  line="$(printf '%s' "$line" | tr -d '[:space:]' | tr '-' '_')"
  [ -n "$line" ] || continue
  if [ "$line" = qca_cld3_wlan ]; then
    printf '%s\t%s\t%s\n' "$line.ko" "SKIPPED_RISK" "Internal Qualcomm wlan0 driver; ABI/KMI and runtime recovery are not device-verified" >> "$STATUS"
    continue
  fi
  if [ -n "${BY_NAME[$line]:-}" ]; then
    WANT["$line"]="driver"
    QUEUE+=("$line")
    printf '%s\t%s\t%s\n' "$line.ko" "STAGED_TARGET" "Will package and verify vermagic/dependencies" >> "$STATUS"
  else
    printf '%s\t%s\t%s\n' "$line.ko" "NOT_BUILT_OR_NOT_IN_SOURCE" "Not present in kernel staging; not fabricated" >> "$STATUS"
  fi
done < "$TARGETS"

[ "${#QUEUE[@]}" -gt 0 ] || {
  echo "ERROR: none of the requested adapter targets were built" >&2
  cat "$STATUS" >&2
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
      dep="$(printf '%s' "$dep" | tr '-' '_')"
      if [ -n "${BY_NAME[$dep]:-}" ] && [ -z "${WANT[$dep]:-}" ]; then
        WANT["$dep"]="dependency"
        QUEUE+=("$dep")
        printf '%s\t%s\t%s\n' "$dep.ko" "DEPENDENCY" "Required by modinfo dependency closure" >> "$STATUS"
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
  cp -f "$f" "$OUT/${f##*/}"
  case "${WANT[$n]}" in
    driver) driver_count=$((driver_count+1));;
    dependency) dependency_count=$((dependency_count+1));;
    *) echo "ERROR: invalid module class for $n" >&2; exit 1;;
  esac
done

# Final per-target status: no target silently disappears from the ZIP. The
# internal Qualcomm wlan0 module is intentionally separated into the audit ZIP.
: > "$OUT/MODULE-STATUS.txt"
while IFS= read -r line; do
  line="${line%%#*}"
  line="$(printf '%s' "$line" | tr -d '[:space:]' | tr '-' '_')"
  [ -n "$line" ] || continue
  if [ "$line" = qca_cld3_wlan ]; then
    printf '%s\t%s\t%s\n' "$line.ko" "SKIPPED_RISK" "Internal wlan0 driver remains in separate audit-only ZIP pending device ABI/recovery validation" >> "$OUT/MODULE-STATUS.txt"
  elif find "$OUT" -maxdepth 1 -type f -name '*.ko' -printf '%f\n' | sed 's/\.ko$//' | tr '-' '_' | grep -qx "$line"; then
    printf '%s\t%s\t%s\n' "$line.ko" "PACKAGED" "Present in adapter ZIP; not yet tested on physical adapter" >> "$OUT/MODULE-STATUS.txt"
  else
    printf '%s\t%s\t%s\n' "$line.ko" "NOT_BUILT_OR_BUILTIN" "No loadable .ko with this module name in staging/package; see adapter-config-status.txt" >> "$OUT/MODULE-STATUS.txt"
  fi
done < "$TARGETS"
sort -u "$OUT/MODULE-STATUS.txt" -o "$OUT/MODULE-STATUS.txt"

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
  echo "Requested targets: $(grep -Ev '^[[:space:]]*(#|$)' "$TARGETS" | wc -l)"
  echo "Status report: MODULE-STATUS.txt"
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
sort -u "$STATUS" -o "$STATUS"
printf 'ADAPTER_PACKAGE=PASS\nDRIVER_MODULES=%s\nDEPENDENCY_MODULES=%s\n' "$driver_count" "$dependency_count"
