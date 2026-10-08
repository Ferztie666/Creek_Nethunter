#!/usr/bin/env bash
set -euo pipefail

STAGING="${1:?usage: package-creek-adapters.sh <staging> <output-dir>}"
OUT="${2:?usage: package-creek-adapters.sh <staging> <output-dir>}"

MODROOT=""
for d in "$STAGING"/lib/modules/*; do
  if [ -d "$d" ]; then MODROOT="$d"; break; fi
done
[ -n "$MODROOT" ] || { echo "ERROR: no staging kernel module directory found" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT"

declare -A BY_NAME
while IFS= read -r -d '' f; do
  n="${f##*/}"
  n="${n%.ko}"
  BY_NAME["$n"]="$f"
done < <(find "$MODROOT" -type f -name '*.ko' -print0)

declare -A WANT
QUEUE=()

# Only these trees are adapter drivers. Qualcomm internal WLAN is deliberately
# excluded from this package.
while IFS= read -r -d '' f; do
  n="${f##*/}"
  n="${n%.ko}"
  WANT["$n"]="driver"
  QUEUE+=("$n")
done < <(
  find "$MODROOT/extra/nethunter/rtw88" "$MODROOT/extra/nethunter/rtl8xxxu"     -maxdepth 1 -type f -name '*.ko' -print0 2>/dev/null
)

[ "${#QUEUE[@]}" -gt 0 ] || {
  echo "ERROR: no NetHunter external adapter modules were built" >&2
  exit 1
}

# Resolve only actual ELF module dependencies recorded in the built .ko files.
# This normally adds generic mac80211/cfg80211 dependencies, not unrelated
# Qualcomm vendor modules.
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

for n in "${!WANT[@]}"; do
  f="${BY_NAME[$n]:-}"
  [ -n "$f" ] || { echo "ERROR: missing module dependency: $n" >&2; exit 1; }
  cp -f "$f" "$OUT/$n.ko"
done

# Never allow the internal Qualcomm WLAN driver into the USB adapter package.
if [ -e "$OUT/qca_cld3_wlan.ko" ]; then
  echo "ERROR: qca_cld3_wlan.ko leaked into adapter package" >&2
  exit 1
fi

driver_count=0
dependency_count=0
for n in "${!WANT[@]}"; do
  case "${WANT[$n]}" in
    driver) driver_count=$((driver_count+1));;
    dependency) dependency_count=$((dependency_count+1));;
  esac
done

{
  echo "Creek NetHunter external adapter module package"
  echo "Kernel module tree: ${MODROOT##*/}"
  echo "Driver modules: $driver_count"
  echo "Dependency modules: $dependency_count"
  echo
  echo "[driver]"
  for n in "${!WANT[@]}"; do
    [ "${WANT[$n]}" = driver ] && echo "$n.ko"
  done | sort
  echo
  echo "[dependency]"
  for n in "${!WANT[@]}"; do
    [ "${WANT[$n]}" = dependency ] && echo "$n.ko"
  done | sort
} > "$OUT/MODULE-MANIFEST.txt"

# Keep this package self-auditing.
find "$OUT" -maxdepth 1 -type f -name '*.ko' -printf '%f\n' | sort > "$OUT/MODULE-LIST.txt"
test "$(wc -l < "$OUT/MODULE-LIST.txt")" -eq "$((driver_count+dependency_count))"

echo "ADAPTER_PACKAGE=PASS"
echo "DRIVER_MODULES=$driver_count"
echo "DEPENDENCY_MODULES=$dependency_count"
