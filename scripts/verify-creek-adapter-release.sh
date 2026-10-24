#!/usr/bin/env bash
set -euo pipefail

STAGING="${1:?usage: verify-creek-adapter-release.sh <staging> <expected-release> [report] [gki-staging]}"
EXPECTED="${2:?expected kernel release is required}"
REPORT="${3:-$PWD/module-release-audit.txt}"
GKI_STAGING="${4:-}"

die() { echo "ERROR: $*" >&2; exit 1; }
command -v modinfo >/dev/null 2>&1 || die "modinfo is required for module release audit"
[[ "$EXPECTED" =~ ^[A-Za-z0-9._+-]+$ ]] || die "invalid expected release string: $EXPECTED"
declare -a MODULE_ROOTS=()
if [[ -n "$GKI_STAGING" ]]; then
  for d in "$GKI_STAGING"/lib/modules/*; do
    [[ -d "$d" ]] && MODULE_ROOTS+=("$d")
  done
fi
for d in "$STAGING"/lib/modules/*; do
  [[ -d "$d" ]] && MODULE_ROOTS+=("$d")
done
[[ "${#MODULE_ROOTS[@]}" -gt 0 ]] || die "no module roots under $STAGING or $GKI_STAGING"
mkdir -p "$(dirname "$REPORT")"
: > "$REPORT"
printf 'expected_release\t%s\n' "$EXPECTED" >> "$REPORT"
count=0
bad=0
for root in "${MODULE_ROOTS[@]}"; do
  while IFS= read -r -d '' module; do
    count=$((count + 1))
    vermagic="$(modinfo -F vermagic "$module" 2>/dev/null | head -n1 || true)"
    release="${vermagic%% *}"
    relpath="${module#"$root"/}"
    if [[ -z "$vermagic" ]]; then
      printf '%s\tFAIL_NO_VERMAGIC\t\n' "$relpath" >> "$REPORT"
      bad=$((bad + 1))
    elif [[ "$release" != "$EXPECTED" ]]; then
      printf '%s\tFAIL_RELEASE_MISMATCH\t%s\n' "$relpath" "$vermagic" >> "$REPORT"
      bad=$((bad + 1))
    else
      printf '%s\tPASS\t%s\n' "$relpath" "$vermagic" >> "$REPORT"
    fi
  done < <(find "$root" -type f -name '*.ko' -print0 | sort -z)
done
[[ "$count" -gt 0 ]] || die "no .ko files found under any audited module root: ${MODULE_ROOTS[*]}"
if [[ "$bad" -gt 0 ]]; then
  echo "ERROR: $bad of $count staged modules do not match expected release $EXPECTED" >&2
  grep -E 'FAIL_' "$REPORT" >&2 || true
  exit 1
fi
echo "KERNEL_RELEASE_AUDIT=PASS"
echo "EXPECTED_KERNEL_RELEASE=$EXPECTED"
echo "AUDITED_MODULES=$count"
echo "REPORT=$REPORT"
