#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="${1:?repository root required}"
ARTIFACT_ROOT="${2:?artifact root required}"
OUT_REPORT="${3:?report path required}"

die() { echo "ERROR: $*" >&2; exit 1; }
mkdir -p "$(dirname "$OUT_REPORT")"
test -s "$REPO_ROOT/stock-modules/README.md" || die "stock module provenance missing"
test -s "$REPO_ROOT/stock-modules/vendor_boot.modules.load" || die "normal stock vendor_boot list missing"
test -s "$REPO_ROOT/stock-modules/vendor_boot.modules.load.recovery" || die "recovery stock vendor_boot list missing"
test -s "$ARTIFACT_ROOT/Creek-Nethunter-gki-candidate.zip" || die "kernel candidate ZIP missing"
test -s "$ARTIFACT_ROOT/Creek-Nethunter-adapters-modules.zip" || die "adapter ZIP missing"

candidate_list="$(mktemp)"
adapter_list="$(mktemp)"
trap 'rm -f "$candidate_list" "$adapter_list"' EXIT
unzip -Z1 "$ARTIFACT_ROOT/Creek-Nethunter-gki-candidate.zip" | sort > "$candidate_list"
unzip -Z1 "$ARTIFACT_ROOT/Creek-Nethunter-adapters-modules.zip" | sort > "$adapter_list"

# Candidate kernel bundle must not contain replacement stock partitions or .ko payloads.
if grep -Eq '(^|/)(vendor_boot\.img|vendor_dlkm\.img|system_dlkm\.img|qca_cld3_wlan\.ko)$|\.ko(\.(xz|gz|zst))?$' "$candidate_list"; then
  cat "$candidate_list" >&2
  die "kernel candidate contains a stock partition image or a replacement .ko"
fi
if grep -Eq '(^|/)qca_cld3_wlan\.ko$' "$adapter_list"; then
  die "internal Qualcomm wlan0 module leaked into USB adapter package"
fi
if grep -Eq '(^|/)(service\.sh|post-fs-data\.sh)$' "$adapter_list"; then
  die "adapter package contains a boot-time module hook"
fi

{
  echo "Creek stock-module coexistence policy audit"
  echo "stock_snapshot_device=creek"
  echo "stock_snapshot_android=15"
  echo "stock_snapshot_kernel=5.15.167-android13-8-gbf0a81a7f319"
  echo "user_current_stock_android=16"
  echo "user_current_stock_kernel=5.15.194-android13-8-00019-gf4321180a397-ab15212794"
  echo "repository_kernel_family=5.15.167-android13-8"
  echo "known_release_mismatch=YES"
  echo "stock_module_strategy=preserve_installed_vendor_boot_vendor_dlkm_system_dlkm; never fabricate or overwrite proprietary modules"
  echo "kernel_candidate_contains_stock_partition_images=NO"
  echo "kernel_candidate_contains_replacement_ko=NO"
  echo "adapter_package_contains_internal_qcacld=NO"
  echo "boot_time_adapter_module_loading=NO"
  echo "dynamic_stock_module_reuse=NOT_IMPLEMENTED_IN_AK3_YET"
  echo "FLASH_ALLOWED=NO"
  echo
  echo "[known source-missing stock modules: normal vendor_boot]"
  printf '%s\n' bootinfo.ko mi_memory.ko mi_thermal_interface.ko qrng_dlkm.ko qseecom_dlkm.ko swinfo.ko
  echo
  echo "[known source-missing stock modules: recovery vendor_boot]"
  printf '%s\n' bootinfo.ko hdcp_qseecom_dlkm.ko lct_tp.ko mi_memory.ko mi_thermal_interface.ko msm-mmrm.ko msm_drm.ko qseecom_dlkm.ko smcinvoke_dlkm.ko swinfo.ko
  echo
  echo "[known source-missing stock modules: vendor_dlkm]"
  printf '%s\n' ipam.ko ipanetm.ko ipa_clientsm.ko rndisipam.ko rmnet_core.ko rmnet_ctl.ko rmnet_wlan.ko
  echo
  echo "IMPORTANT: stock lists in this repository were captured on Android 15."
  echo "They are reference-only and must not reconstruct or replace Android 16 stock partitions."
  echo "Current Android 16 stock kernel release differs from repository kernel baseline."
  echo "Any installer must preserve installed vendor_boot, vendor_dlkm, and system_dlkm and verify KMI/vermagic before reuse."
  echo "No forced module loading, symbol-version bypass, module replacement, or fabricated module is permitted."
} > "$OUT_REPORT"

echo "STOCK_MODULE_POLICY_AUDIT=PASS_WITH_FLASH_BLOCKED"
