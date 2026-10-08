#!/usr/bin/env bash
set -euo pipefail
KP="${1:?kernel_platform}"
OUT="${2:?out}"
DIST="${3:?dist}"
LOGDIR="${4:?logdir}"
mkdir -p "$LOGDIR"

die(){ echo "ERROR: $*" | tee -a "$LOGDIR/final-gate.txt" >&2; exit 1; }

# Image must exist and be non-empty.
IMG=""
for f in "$DIST/Image" "$DIST/Image.gz" "$DIST/Image.lz4"; do
  if [ -s "$f" ]; then IMG="$f"; break; fi
done
test -n "$IMG" || die "no kernel image in dist"

# Required image set for this build flow.
test -s "$DIST/vendor_boot.img" || die "vendor_boot.img missing"
test -s "$DIST/vendor_dlkm.img" || die "vendor_dlkm.img missing"

# Kernel identity and architecture.
file "$IMG" | tee "$LOGDIR/image-file.txt"
strings "$IMG" | grep -q 'Linux version 5.15.167-android13-8' \
  || echo "[warn] release string not directly visible in compressed image"

# Do not recursively grep the whole synced kernel tree: each repo contains
# .git objects/history and generated files, so that can produce false positives
# from historical patch text. Audit the tracked source trees instead.
# Audit executable/source patterns by file type. Documentation and historical notes can
# legitimately mention commands such as "rmmod wlan" or "con_mode=4"; those are
# not evidence that the build tree executes them. Stale QCACLD API names, however,
# are checked only in C/H source where their presence would affect compilation.
UNSAFE_SOURCE_RE='ol_txrx_get_mon_vdev_from_pdev|hdd_mon_stop'
UNSAFE_RUNTIME_RE='rmmod[[:space:]]+wlan|insmod[[:space:]].*qca_cld3_wlan.*con_mode=4'
for tree in "$KP/common" "$KP/msm-kernel" "$KP/vendor/qcom/opensource/wlan"; do
  [ -d "$tree" ] || die "required source tree missing: $tree"
  if ! git -C "$tree" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    die "not a git work tree: $tree"
  fi
  MATCH="$(git -C "$tree" grep -n -E "$UNSAFE_SOURCE_RE" -- '*.c' '*.h' '*.cc' '*.cpp' '*.S' 2>/dev/null || true)"
  if [ -n "$MATCH" ]; then
    echo "$MATCH" >&2
    die "stale QCACLD API pattern detected in C/H source: $tree"
  fi
  MATCH="$(git -C "$tree" grep -n -E "$UNSAFE_RUNTIME_RE" -- '*.sh' '*.rc' 2>/dev/null || true)"
  if [ -n "$MATCH" ]; then
    echo "$MATCH" >&2
    die "unsafe runtime WLAN switching pattern detected in scripts: $tree"
  fi
done

# The ABI checker is a real build input, so check its active file explicitly.
ABI=""
for f in "$KP/build/abi/compare_to_symbol_list" "$KP/build/kernel/abi/compare_to_symbol_list"; do
  if [ -f "$f" ]; then ABI="$(readlink -f "$f")"; break; fi
done
[ -n "$ABI" ] || die "ABI checker not found"
if grep -qs 'BUT WHO CARES?' "$ABI"; then
  die "ABI checker bypass is active"
fi

# Module ABI metadata must be present and tied to the build.
SYMVERS=""
for f in "$OUT/msm-kernel/Module.symvers" "$OUT/gki_kernel/common/Module.symvers" "$OUT/gki_kernel/dist/vmlinux.symvers"; do
  if [ -s "$f" ]; then SYMVERS="$f"; break; fi
done
test -n "$SYMVERS" || die "no Module.symvers/vmlinux.symvers produced"

# Vendor WLAN module is required; do not accept a generic renamed replacement.
WLAN=""
while IFS= read -r f; do
  WLAN="$f"; break
done < <(find "$OUT/staging" -type f -name 'qca_cld3_wlan.ko' 2>/dev/null)
test -n "$WLAN" || die "qca_cld3_wlan.ko not built"

# Every built module must report the same kernel release/CRC metadata.
modinfo_bin="$(command -v modinfo || true)"
if [ -n "$modinfo_bin" ]; then
  find "$OUT/staging" -type f -name '*.ko' -print0 |
    xargs -0 -r -n1 "$modinfo_bin" -F vermagic 2>/dev/null |
    sort -u > "$LOGDIR/module-vermagic.txt" || true
fi

# Generated normal/recovery lists must not contain unbuilt module basenames.
ALL="$(mktemp)"
trap 'rm -f "$ALL"' EXIT
find "$OUT/staging" -type f -name '*.ko' -printf '%f\n' | sort -u > "$ALL"
for list in "$DIST/vendor_boot.modules.load" "$DIST/vendor_boot.modules.load.recovery"; do
  [ -f "$list" ] || continue
  while IFS= read -r m; do
    [ -z "$m" ] && continue
    n="${m##*/}"
    grep -Fxq "$n" "$ALL" || die "module list references unbuilt module: $n"
  done < <(sed '/^[[:space:]]*#/d;/^[[:space:]]*$/d' "$list")
done

# Ensure the kernel output is not accidentally a debug/intermediate artifact.
test ! -e "$DIST/vmlinux" || die "vmlinux leaked into release dist"
echo "FINAL_GATE=PASS" | tee "$LOGDIR/final-gate.txt"
echo "IMAGE=$IMG" | tee -a "$LOGDIR/final-gate.txt"
echo "WLAN=$WLAN" | tee -a "$LOGDIR/final-gate.txt"
echo "SYMVERS=$SYMVERS" | tee -a "$LOGDIR/final-gate.txt"
