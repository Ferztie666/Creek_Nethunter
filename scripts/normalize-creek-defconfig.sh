#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:?kernel_platform path required}"
DEFCONFIG="$ROOT/msm-kernel/arch/arm64/configs/vendor/creek-gki_defconfig"
KCONFIG="$ROOT/msm-kernel/drivers/char/Kconfig"

test -f "$DEFCONFIG" || { echo "ERROR: Creek vendor defconfig missing: $DEFCONFIG" >&2; exit 1; }
test -f "$KCONFIG" || { echo "ERROR: drivers/char/Kconfig missing; cannot audit XLOGCHAR normalization" >&2; exit 1; }

# The failed savedefconfig diff showed that this source snapshot carries an
# explicit CONFIG_XLOGCHAR=m plus human-only Audio_Xlog section markers which
# Kconfig savedefconfig drops. Remove only those non-semantic/redundant lines;
# leave all actual CONFIG_* settings and every other defconfig line untouched.
# The upstream check_defconfig remains enabled in build.config.msm.creek and
# will still fail if any other effective configuration mismatch remains.
if ! grep -Eq '^[[:space:]]*config[[:space:]]+XLOGCHAR([[:space:]]|$)' "$KCONFIG"; then
  echo "ERROR: XLOGCHAR symbol declaration not found; refusing to normalize defconfig" >&2
  exit 1
fi

if grep -qx 'CONFIG_XLOGCHAR=m' "$DEFCONFIG"; then
  sed -i '/^CONFIG_XLOGCHAR=m$/d' "$DEFCONFIG"
  echo "[defconfig] removed explicit CONFIG_XLOGCHAR=m (savedefconfig treats it as default)"
fi
sed -i   -e '/^# BEGIN Audio_Xlog$/d'   -e '/^# END Audio_Xlog$/d'   "$DEFCONFIG"

echo "[defconfig] removed only Audio_Xlog section markers; upstream check_defconfig remains active"
