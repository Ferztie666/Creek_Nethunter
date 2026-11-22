#!/usr/bin/env bash
set -euo pipefail

STAGING="${1:?usage: verify-creek-adapter-release.sh <msm-staging> <expected-gki-release> [report] [gki-staging]}"
EXPECTED="${2:?expected GKI kernel release is required}"
REPORT="${3:-$PWD/module-release-audit.txt}"
GKI_STAGING="${4:-}"

die() { echo "ERROR: $*" >&2; exit 1; }
command -v modinfo >/dev/null 2>&1 || die "modinfo is required for module release audit"
[[ "$EXPECTED" =~ ^[A-Za-z0-9._+-]+$ ]] || die "invalid expected release string: $EXPECTED"
BASE_RELEASE="${EXPECTED%%-*}"
[[ -n "$BASE_RELEASE" && "$BASE_RELEASE" != "$EXPECTED" ]] || die "expected a full Android/GKI release, got: $EXPECTED"

declare -a MODULE_ROOTS=() MODULE_DOMAINS=() MODULE_EXPECTED=()
if [[ -n "$GKI_STAGING" ]]; then
  for d in "$GKI_STAGING"/lib/modules/*; do
    [[ -d "$d" ]] || continue
    MODULE_ROOTS+=("$d")
    MODULE_DOMAINS+=("GKI")
    MODULE_EXPECTED+=("$EXPECTED")
  done
fi
for d in "$STAGING"/lib/modules/*; do
  [[ -d "$d" ]] || continue
  MODULE_ROOTS+=("$d")
  MODULE_DOMAINS+=("MSM_VENDOR")
  MODULE_EXPECTED+=("$BASE_RELEASE")
done
[[ "${#MODULE_ROOTS[@]}" -gt 0 ]] || die "no module roots under $STAGING or $GKI_STAGING"
mkdir -p "$(dirname "$REPORT")"
printf 'domain\troot\texpected_release\tmodule\tstatus\tvermagic\tmetadata_parser\n' > "$REPORT"

count=0
bad=0
gki_count=0
msm_count=0
for i in "${!MODULE_ROOTS[@]}"; do
  root="${MODULE_ROOTS[$i]}"
  domain="${MODULE_DOMAINS[$i]}"
  expected_domain="${MODULE_EXPECTED[$i]}"
  while IFS= read -r -d '' module; do
    count=$((count + 1))
    if [[ "$domain" == "GKI" ]]; then gki_count=$((gki_count + 1)); else msm_count=$((msm_count + 1)); fi

    vermagic_raw="$(modinfo -F vermagic "$module" 2>/dev/null || true)"
    vermagic="${vermagic_raw%%$'\n'*}"
    parser="modinfo"
    relpath="${module#"$root"/}"

    # Cross-check the same embedded ELF metadata with readelf if modinfo
    # cannot decode it. Missing metadata remains a hard failure.
    if [[ -z "$vermagic" ]] && command -v readelf >/dev/null 2>&1; then
      section_dump="$(readelf -p .modinfo "$module" 2>/dev/null || true)"
      vermagic="$(printf '%s\n' "$section_dump" | sed -n 's/.*vermagic=//p' | head -n1)"
      [[ -n "$vermagic" ]] && parser="readelf"
    fi
    release="${vermagic%% *}"

    if [[ -z "$vermagic" ]]; then
      printf '%s\t%s\t%s\t%s\tFAIL_NO_VERMAGIC\t\tNONE\n' "$domain" "$root" "$expected_domain" "$relpath" >> "$REPORT"
      {
        echo "---- MODULE METADATA DIAGNOSTIC: $module"
        file "$module" 2>&1 || true
        readelf -h "$module" 2>&1 || true
        readelf -S "$module" 2>&1 || true
        readelf -p .modinfo "$module" 2>&1 || true
      } >> "$REPORT"
      bad=$((bad + 1))
    elif [[ "$release" != "$expected_domain" ]]; then
      printf '%s\t%s\t%s\t%s\tFAIL_RELEASE_MISMATCH\t%s\t%s\n' "$domain" "$root" "$expected_domain" "$relpath" "$vermagic" "$parser" >> "$REPORT"
      bad=$((bad + 1))
    else
      printf '%s\t%s\t%s\t%s\tPASS\t%s\t%s\n' "$domain" "$root" "$expected_domain" "$relpath" "$vermagic" "$parser" >> "$REPORT"
    fi
  done < <(find "$root" -type f -name '*.ko' -print0 | sort -z)
done

[[ "$count" -gt 0 ]] || die "no .ko files found under audited module roots: ${MODULE_ROOTS[*]}"
if [[ "$bad" -gt 0 ]]; then
  echo "ERROR: $bad of $count staged modules failed their domain-specific release check" >&2
  grep -E -A24 'FAIL_NO_VERMAGIC' "$REPORT" >&2 || true
  grep -E 'FAIL_RELEASE_MISMATCH' "$REPORT" >&2 || true
  exit 1
fi

echo "KERNEL_RELEASE_AUDIT=PASS_DOMAIN_AWARE"
echo "EXPECTED_GKI_RELEASE=$EXPECTED"
echo "EXPECTED_MSM_VENDOR_RELEASE=$BASE_RELEASE"
echo "GKI_MODULES=$gki_count"
echo "MSM_VENDOR_MODULES=$msm_count"
echo "AUDITED_MODULES=$count"
echo "REPORT=$REPORT"
