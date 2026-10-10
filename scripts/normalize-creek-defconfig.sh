#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:?kernel_platform path required}"
MSM="$ROOT/msm-kernel"
CONFIGS="$MSM/arch/arm64/configs"
BUILD_CONFIG="$MSM/build.config.msm.creek"

test -d "$CONFIGS" || { echo "ERROR: MSM arm64 config tree missing: $CONFIGS" >&2; exit 1; }
test -f "$BUILD_CONFIG" || { echo "ERROR: Creek build config missing: $BUILD_CONFIG" >&2; exit 1; }
test -d "$MSM/drivers" || { echo "ERROR: MSM drivers tree missing; cannot audit XLOGCHAR normalization" >&2; exit 1; }

# Read the DEFCONFIG selected by the actual Creek build config. Do not assume
# the vendor/creek-gki_defconfig path exists across source snapshots.
DEFCONFIG_REL="$(sed -n 's/^[[:space:]]*DEFCONFIG[[:space:]]*=[[:space:]]*//p' "$BUILD_CONFIG" | tail -n1 | tr -d '"' | tr -d "'" | xargs || true)"
if [ -z "$DEFCONFIG_REL" ]; then
  echo "ERROR: build.config.msm.creek does not declare DEFCONFIG; refusing to edit a guessed file" >&2
  exit 1
fi
DEFCONFIG="$CONFIGS/$DEFCONFIG_REL"
if [ ! -f "$DEFCONFIG" ]; then
  echo "ERROR: build.config.msm.creek selects '$DEFCONFIG_REL' but that file is absent." >&2
  echo "Available likely Creek/GKI defconfigs:" >&2
  find "$CONFIGS" -maxdepth 3 -type f \( -iname '*creek*defconfig' -o -path '*/gki_defconfig' \) -print | sort >&2
  echo "Refusing to edit an unrelated defconfig; check source manifest/build-config pairing." >&2
  exit 1
fi

if ! grep -RqsE '^[[:space:]]*config[[:space:]]+XLOGCHAR([[:space:]]|$)' "$MSM/drivers" --include='Kconfig*'; then
  echo "ERROR: XLOGCHAR symbol declaration not found; refusing to normalize defconfig" >&2
  exit 1
fi

# Only remove the exact redundant setting shown in the savedefconfig diff and
# its section-label comments. No other CONFIG_* value is changed.
if grep -qx 'CONFIG_XLOGCHAR=m' "$DEFCONFIG"; then
  sed -i '/^CONFIG_XLOGCHAR=m$/d' "$DEFCONFIG"
  echo "[defconfig] removed explicit CONFIG_XLOGCHAR=m from $DEFCONFIG_REL"
fi
sed -i -e '/^# BEGIN Audio_Xlog$/d' -e '/^# END Audio_Xlog$/d' "$DEFCONFIG"
echo "[defconfig] normalized only redundant XLOGCHAR metadata in $DEFCONFIG_REL"
