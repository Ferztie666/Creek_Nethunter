#!/usr/bin/env bash
set -euo pipefail

STAGING="${1:?usage: verify-creek-adapter-release.sh <staging> <expected-release> [report]}"
EXPECTED="${2:?expected kernel release is required}"
REPORT="${3:-$PWD/module-release-audit.txt}"

die() { echo "ERROR: $*" >&2; exit 1; }
command -v modinfo >/dev/null 2>&1 || die "modinfo is required for module release audit"
[[ "$EXPECTED" =~ ^[A-Za-z0-9._+-]+$ ]] || die "invalid expected release string: $EXPECTED"
MODROOT=""
for d in "$STAGING"/lib/modules/*; do
  if [[ -d "$d" ]]; then
    [[ -z "$MODROOT" ]] || die "multiple staged module release roots found; refusing ambiguous audit"
    MODROOT="$d"
  fi
done
[[ -n "$MODROOT" ]] || die "no staged module root under $STAGING/lib/modules"
mkdir -p "$(dirname "$REPORT")"
: > "$REPORT"
printf 'expected_release\t%s\n' "$EXPECTED" >> "$REPORT"
count=0
bad=0
while IFS= read -r -d '' module; do
  count=$((count + 1))
  vermagic="$(modinfo -F vermagic "$module" 2>/dev/null | head -n1 || true)"
  release="${vermagic%% *}"
  if [[ -z "$vermagic" ]]; then
    printf '%s\tFAIL_NO_VERMAGIC\t\n' "${module#"$MODROOT"/}" >> "$REPORT"
    bad=$((bad + 1))
  elif [[ "$release" != "$EXPECTED" ]]; then
    printf '%s\tFAIL_RELEASE_MISMATCH\t%s\n' "${module#"$MODROOT"/}" "$vermagic" >> "$REPORT"
    bad=$((bad + 1))
  else
    printf '%s\tPASS\t%s\n' "${module#"$MODROOT"/}" "$vermagic" >> "$REPORT"
  fi
done < <(find "$MODROOT" -type f -name '*.ko' -print0 | sort -z)
[[ "$count" -gt 0 ]] || die "no .ko files found under $MODROOT"
if [[ "$bad" -gt 0 ]]; then
  echo "ERROR: $bad of $count staged modules do not match expected release $EXPECTED" >&2
  grep -E 'FAIL_' "$REPORT" >&2 || true
  exit 1
fi
echo "KERNEL_RELEASE_AUDIT=PASS"
echo "EXPECTED_KERNEL_RELEASE=$EXPECTED"
echo "AUDITED_MODULES=$count"
echo "REPORT=$REPORT"
