#!/usr/bin/env bash
set -euo pipefail

AK3_ROOT="${1:?usage: guard-creek-ak3.sh <extracted-ak3-directory>}"
SCRIPT="$AK3_ROOT/anykernel.sh"
test -s "$SCRIPT" || { echo "ERROR: upstream AnyKernel3 installer not found: $SCRIPT" >&2; exit 1; }

python3 - "$SCRIPT" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
original = p.read_text()
marker = "CREEK_NETHTUNTER_FLASH_GATE_V1"
if marker in original:
    if 'CREEK_FLASH_ALLOWED="NO"' in original:
        print("AK3_FLASH_GATE=ALREADY_BLOCKED")
        raise SystemExit(0)
    raise SystemExit("ERROR: AnyKernel3 contains an unexpected or modified Creek flash gate")

guard = """# CREEK_NETHTUNTER_FLASH_GATE_V1
# Candidate-only hard stop: source/KMI and Android 16 stock-module compatibility
# are not device-verified. AnyKernel3 sources this file; a shebang is optional.
CREEK_FLASH_ALLOWED="NO"
if [ "$CREEK_FLASH_ALLOWED" != "YES" ]; then
  echo "Creek NetHunter candidate is NOT cleared to flash." >&2
  echo "Preserve the existing boot/vendor_boot/vendor_dlkm/system_dlkm." >&2
  exit 1
fi

"""

# AnyKernel3's update-binary sources anykernel.sh. Many valid upstream AK3
# scripts intentionally start with comments/properties and have no shebang.
# Preserve an existing interpreter line, otherwise prepend the gate at byte 0.
if original.startswith("#!"):
    first_newline = original.find("\\n")
    if first_newline < 0:
        updated = original + "\\n" + guard
    else:
        updated = original[:first_newline + 1] + guard + original[first_newline + 1:]
else:
    updated = guard + original

p.write_text(updated)
print("AK3_FLASH_GATE=INSERTED_BLOCKED")
PY

sh -n "$SCRIPT"
grep -q 'CREEK_NETHTUNTER_FLASH_GATE_V1' "$SCRIPT"
grep -q 'CREEK_FLASH_ALLOWED="NO"' "$SCRIPT"
echo "AK3_FLASH_GATE=PASS_BLOCKED_UNTIL_DEVICE_COMPATIBILITY_VERIFIED"
