#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:?kernel_platform path required}"
MSM="$ROOT/msm-kernel"
EXPECTED="$MSM/arch/arm64/configs/vendor/creek-gki_defconfig"

test -d "$MSM" || { echo "ERROR: MSM source tree missing: $MSM" >&2; exit 1; }
if ! grep -RqsE '^[[:space:]]*config[[:space:]]+XLOGCHAR([[:space:]]|$)' "$MSM" --include='Kconfig*'; then
  echo "ERROR: XLOGCHAR symbol declaration not found; refusing to normalize defconfig" >&2
  exit 1
fi

# Prefer the exact Creek defconfig named by the upstream check. If this source
# snapshot stores it elsewhere, identify the unique defconfig containing the
# exact redundant lines seen in savedefconfig output. Never edit a guessed
# gki_defconfig or a file that does not contain those exact markers.
if [ -f "$EXPECTED" ]; then
  DEFCONFIG="$EXPECTED"
else
  mapfile -t CANDIDATES < <(
    find "$ROOT" -type f -name '*defconfig' -print0 |
      xargs -0 -r grep -lF 'CONFIG_XLOGCHAR=m' 2>/dev/null |
      while IFS= read -r f; do
        if grep -qF '# BEGIN Audio_Xlog' "$f" || grep -qF '# END Audio_Xlog' "$f"; then
          printf '%s\n' "$f"
        fi
      done | sort -u
  )
  if [ "${#CANDIDATES[@]}" -ne 1 ]; then
    echo "ERROR: expected defconfig absent and could not identify exactly one file containing the reported redundant XLOGCHAR metadata." >&2
    echo "Expected: $EXPECTED" >&2
    echo "Matching defconfigs: ${#CANDIDATES[@]}" >&2
    printf '  %s\n' "${CANDIDATES[@]:-<none>}" >&2
    echo "Refusing to edit an unrelated configuration." >&2
    exit 1
  fi
  DEFCONFIG="${CANDIDATES[0]}"
fi

# Change only the exact lines reported by savedefconfig. The real upstream
# check_defconfig/ABI/KMI gates remain enabled and will catch other mismatches.
sed -i -e '/^CONFIG_XLOGCHAR=m$/d' \
       -e '/^# BEGIN Audio_Xlog$/d' \
       -e '/^# END Audio_Xlog$/d' "$DEFCONFIG"

echo "[defconfig] normalized only redundant XLOGCHAR metadata in: $DEFCONFIG"
