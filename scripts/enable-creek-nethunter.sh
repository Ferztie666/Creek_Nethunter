#!/usr/bin/env bash
set -euo pipefail

ROOT=${1:?kernel_platform path is required}
# Optional explicit repository root. This is required when this script is copied
# to RUNNER_TEMP, because dirname(BASH_SOURCE) is then no longer the checkout.
if [ "${2:-}" != "" ]; then
  REPO_ROOT="$(cd "$2" && pwd)"
else
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
if [ ! -d "$REPO_ROOT/patches/common" ]; then
  echo "ERROR: repository root does not contain patches/common: $REPO_ROOT" >&2
  exit 1
fi
COMMON="$ROOT/common"
MSM="$ROOT/msm-kernel"
PATCH_DIR="$REPO_ROOT/patches/common"

# BBG builds a host helper with clang-14. Some GitHub runner images do not
# expose an unversioned `ld` in PATH, even when binutils/lld are installed.
# Provide one before BBG setup so flask header generation succeeds.
HOST_TOOLS="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/nethunter-host-tools"
mkdir -p "$HOST_TOOLS"
if command -v ld.lld >/dev/null 2>&1; then
  ln -sf "$(command -v ld.lld)" "$HOST_TOOLS/ld"
elif command -v ld.bfd >/dev/null 2>&1; then
  ln -sf "$(command -v ld.bfd)" "$HOST_TOOLS/ld"
elif command -v ld >/dev/null 2>&1; then
  ln -sf "$(command -v ld)" "$HOST_TOOLS/ld"
else
  echo "ERROR: no host linker (ld.lld, ld.bfd, or ld) found" >&2
  exit 1
fi
export PATH="$HOST_TOOLS:$PATH"
# build.sh later prepends its hermetic tool directories, so place the alias
# there as well. BBG's clang invocation must find `ld` during mrproper.
for host_bin in \
  "$ROOT/build/kernel/build-tools/path/linux-x86" \
  "$ROOT/prebuilts/kernel-build-tools/linux-x86/bin"; do
  if [ -d "$host_bin" ]; then
    ln -sf "$(command -v ld.lld || command -v ld.bfd)" "$host_bin/ld"
  fi
done

if [ ! -d "$COMMON" ]; then
  echo "ERROR: common kernel source not found: $COMMON" >&2
  exit 1
fi
if [ ! -x "$COMMON/scripts/config" ]; then
  echo "ERROR: scripts/config not found or not executable in common source" >&2
  exit 1
fi

apply_patch_file() {
  local tree=$1
  local patch_file=$2
  local name
  name=$(basename "$patch_file")
  if git -C "$tree" apply --check "$patch_file" >/dev/null 2>&1; then
    echo "[nethunter] applying $name"
    git -C "$tree" apply "$patch_file"
  elif git -C "$tree" apply --reverse --check "$patch_file" >/dev/null 2>&1; then
    echo "[nethunter] $name already applied"
  else
    echo "[nethunter] git apply failed for $name; allowing only zero-fuzz patch application"
    if (cd "$tree" && patch --fuzz=0 -p1 --dry-run < "$patch_file" >/dev/null); then
      (cd "$tree" && patch --fuzz=0 -p1 < "$patch_file")
    elif (cd "$tree" && patch --fuzz=0 -R -p1 --dry-run < "$patch_file" >/dev/null); then
      echo "[nethunter] $name already applied"
    else
      echo "ERROR: $name does not apply with exact context to $tree" >&2
      exit 1
    fi
  fi
}

for patch in \
  "$PATCH_DIR/gki-ptrace.patch" \
  "$PATCH_DIR/droidspaces-sysvipc-kabi-6-7-8.patch" \
  "$PATCH_DIR/droidspaces-cgroup-prefix.patch"; do
  test -f "$patch"
  apply_patch_file "$COMMON" "$patch"
done

# Baseband Guard (BBG): source is injected into common/security as an LSM.
echo "[nethunter] setting up Baseband Guard"
(
  cd "$COMMON"
  if ! curl -fsSL https://github.com/vc-teahouse/Baseband-guard/raw/main/setup.sh | bash -s main; then
    echo "ERROR: Baseband Guard setup failed" >&2
    exit 1
  fi
)

COMMON_DEFCONFIG="$COMMON/arch/arm64/configs/gki_defconfig"
NETHUNTER_CONFIG="$COMMON/arch/arm64/configs/nethunter.config"
test -f "$COMMON_DEFCONFIG"

# Keep the common GKI module allow-list in sync with modules selected by the
# common fragment below. MSM-only drivers are deliberately excluded: they are
# built from msm-kernel and belong to the vendor module staging flow.
GKI_MODULES_LIST="$COMMON/android/gki_aarch64_modules"
if [ -f "$GKI_MODULES_LIST" ]; then
  # Remove stale MSM-only entries left by older NetHunter revisions.
  sed -i \
    -e '/^drivers\/net\/wireless\/mediatek\//d' \
    -e '/^drivers\/net\/wireless\/realtek\//d' \
    "$GKI_MODULES_LIST"
  # Do not add advanced TCP congestion modules: Creek's pinned GKI defconfig
  # has CONFIG_TCP_CONG_ADVANCED disabled. Enabling it introduces the
  # tcp_cong_avoid_ai export, which is absent from this revision's approved KMI
  # symbol list and correctly fails the upstream ABI gate.
fi

# Do not modify build.config.gki.aarch64 to weaken KMI enforcement.
# TRIM_NONLISTED_KMI and KMI_SYMBOL_LIST_STRICT_MODE remain controlled by the
# pinned upstream source. If a requested external module fails the real KMI
# gate, treat that as a compatibility failure and resolve it explicitly rather
# than disabling the gate or broadening exports speculatively.
: > "$NETHUNTER_CONFIG"
CFG="$COMMON/scripts/config --file $NETHUNTER_CONFIG"

# DroidSpaces/container support + ABI-safe SYSVIPC patches above.
$CFG \
  -d CONFIG_LOCALVERSION_AUTO \
  --set-str CONFIG_LOCALVERSION "" \
  -e CONFIG_SYSVIPC \
  -e CONFIG_DEVTMPFS \
  -e CONFIG_PID_NS \
  -e CONFIG_POSIX_MQUEUE \
  -e CONFIG_USER_NS \
  -e CONFIG_TMPFS_XATTR \
  -e CONFIG_TMPFS_POSIX_ACL \
  -e CONFIG_FW_CACHE

# Baseband Guard LSM.
$CFG -e CONFIG_BBG \
  --set-str CONFIG_LSM "landlock,lockdown,yama,loadpin,safesetid,integrity,selinux,smack,tomoyo,apparmor,bpf,baseband_guard"
sed -i '/^[[:space:]]*config[[:space:]]\+LSM$/,/^[[:space:]]*help[[:space:]]*$/{ /^[[:space:]]*default/ { /baseband_guard/! s/selinux/selinux,baseband_guard/ } }' "$COMMON/security/Kconfig"

# Preserve the pinned Creek GKI TCP ABI baseline. Explicitly disable advanced
# congestion control in the NetHunter fragment so this layer cannot introduce
# tcp_cong_avoid_ai into the exported symbol table. The upstream ABI/KMI gate
# remains authoritative; if the stock defconfig still enables this symbol, the
# build must fail for investigation rather than modifying the symbol list.
$CFG \
  -d CONFIG_TCP_CONG_ADVANCED \
  -d CONFIG_TCP_CONG_BBR \
  -d CONFIG_TCP_CONG_BBR3 \
  -e CONFIG_NET_SCH_FQ \
  -e CONFIG_NET_SCH_FQ_CODEL \
  -e CONFIG_NET_SCH_CAKE \
  -e CONFIG_NET_SCH_PIE \
  -e CONFIG_NET_SCH_FQ_PIE

# NetHunter: Bluetooth USB, SDR, CAN, USB serial, TTL, IP set.
# VXLAN in the MSM module set references this GKI-exported L3-master helper.
$CFG \
  -e CONFIG_RFKILL \
  -e CONFIG_NET_L3_MASTER_DEV \
# USB_F_GSI has unresolved references to the RNDIS helper API in this pinned 5.15 tree.
# RNDIS itself remains enabled; disable only the optional GSI gadget function to
# prevent depmod from accepting a module with unknown symbols.
$CFG -d CONFIG_USB_F_GSI
$CFG \
  -e CONFIG_USB_F_RNDIS \
  -m CONFIG_USB_U_ETHER \
  -e CONFIG_BT_HCIBTUSB \
  -e CONFIG_BT_HCIBTUSB_BCM \
  -e CONFIG_BT_HCIBTUSB_RTL \
  -e CONFIG_BT_HCIVHCI \
  -e CONFIG_BT_HCIBCM203X \
  -e CONFIG_BT_HCIBPA10X \
  -e CONFIG_BT_HCIBFUSB \
  -e CONFIG_USB_AIRSPY \
  -e CONFIG_USB_HACKRF \
  -e CONFIG_CAN \
  -e CONFIG_CAN_DEV \
  -e CONFIG_CAN_CALC_BITTIMING \
  -e CONFIG_CAN_LEDS \
  -e CONFIG_CAN_VCAN \
  -e CONFIG_CAN_GRCAN \
  -e CONFIG_CAN_XILINXCAN \
  -e CONFIG_CAN_C_CAN \
  -e CONFIG_CAN_C_CAN_PLATFORM \
  -e CONFIG_CAN_C_CAN_PCI \
  -e CONFIG_CAN_CC770 \
  -e CONFIG_CAN_CC770_ISA \
  -e CONFIG_CAN_CC770_PLATFORM \
  -e CONFIG_CAN_M_CAN \
  -e CONFIG_CAN_M_CAN_PCI \
  -e CONFIG_CAN_M_CAN_PLATFORM \
  -e CONFIG_CAN_M_CAN_TCAN4X5X \
  -e CONFIG_CAN_HI311X \
  -e CONFIG_CAN_MCP251X \
  -e CONFIG_CAN_8DEV_USB \
  -e CONFIG_CAN_EMS_USB \
  -e CONFIG_CAN_ESD_USB2 \
  -e CONFIG_CAN_GS_USB \
  -e CONFIG_CAN_KVASER_USB \
  -e CONFIG_CAN_PEAK_USB \
  -e CONFIG_NETLINK_DIAG \
  -e CONFIG_VSOCKETS \
  -e CONFIG_NET_SCHED \
  -e CONFIG_NET_EMATCH_CANID \
  -e CONFIG_USB_SERIAL \
  -e CONFIG_USB_SERIAL_CONSOLE \
  -e CONFIG_USB_SERIAL_GENERIC \
  -e CONFIG_USB_SERIAL_CH341 \
  -e CONFIG_USB_SERIAL_FTDI_SIO \
  -e CONFIG_USB_SERIAL_PL2303 \
  -e CONFIG_IP_NF_TARGET_TTL \
  -e CONFIG_IP6_NF_TARGET_HL \
  -e CONFIG_IP6_NF_MATCH_HL \
  -e CONFIG_IP_SET \
  --set-val CONFIG_IP_SET_MAX 65534 \
  -e CONFIG_IP_SET_BITMAP_IP \
  -e CONFIG_IP_SET_BITMAP_IPMAC \
  -e CONFIG_IP_SET_BITMAP_PORT \
  -e CONFIG_IP_SET_HASH_IP \
  -e CONFIG_IP_SET_HASH_IPMARK \
  -e CONFIG_IP_SET_HASH_IPPORT \
  -e CONFIG_IP_SET_HASH_IPPORTIP \
  -e CONFIG_IP_SET_HASH_IPPORTNET \
  -e CONFIG_IP_SET_HASH_IPMAC \
  -e CONFIG_IP_SET_HASH_MAC \
  -e CONFIG_IP_SET_HASH_NETPORTNET \
  -e CONFIG_IP_SET_HASH_NET \
  -e CONFIG_IP_SET_HASH_NETNET \
  -e CONFIG_IP_SET_HASH_NETPORT \
  -e CONFIG_IP_SET_HASH_NETIFACE \
  -e CONFIG_IP_SET_LIST_SET

# Preserve the pinned GKI panic policy. CONFIG_PANIC_ON_OOPS and CONFIG_PANIC_TIMEOUT
# are intentionally not overridden: disabling panic-on-oops is not a recovery fix and
# can let a corrupted kernel continue running after a fatal driver bug.

# Requested Creek NetHunter built-in capabilities.
# olddefconfig resolves dependencies; final values are audited in the workflow.
# Unsupported symbols are reported, never fabricated as .ko files.
$CFG \
  -e CONFIG_CFG80211_INTERNAL_REGDB \
  -d CONFIG_CFG80211_CRDA_SUPPORT \
  -e CONFIG_MAC80211_MESH \
  -e CONFIG_NFC \
  -e CONFIG_NFC_NCI \
  -e CONFIG_NFC_LLCP \
  -e CONFIG_NFC_DIGITAL \
  -e CONFIG_NFC_HCI \
  -e CONFIG_MEDIA_SUPPORT \
  -e CONFIG_MEDIA_SDR_SUPPORT \
  -e CONFIG_LIRC \
  -e CONFIG_RC_CORE \
  -e CONFIG_IR_LIRC_CODEC \
  -e CONFIG_USB_SERIAL_CP210X \
  -e CONFIG_W1 \
  -e CONFIG_W1_MASTER_DS2490 \
  -e CONFIG_W1_SLAVE_THERM \
  -e CONFIG_W1_SLAVE_DS2431 \
  -e CONFIG_W1_SLAVE_DS2433 \
  -e CONFIG_W1_SLAVE_DS2408 \
  -e CONFIG_BFQ_GROUP_IOSCHED \
  -e CONFIG_LZ4_COMPRESS \
  -e CONFIG_LOCKUP_DETECTOR \
  -e CONFIG_SOFTLOCKUP_DETECTOR \
  -e CONFIG_HARDLOCKUP_DETECTOR \
  -e CONFIG_WQ_WATCHDOG \
  -e CONFIG_THERMAL_GOV_POWER_ALLOCATOR \
  -e CONFIG_CPU_FREQ_GOV_SCHEDUTIL \
  -e CONFIG_BT_HS \
  -e CONFIG_BT_6LOWPAN

# Request the five additional in-tree USB Wi-Fi drivers only when the
# pinned common source actually defines their Kconfig symbols. Some Android GKI
# snapshots prune upstream drivers; scripts/config accepts unknown symbols, but
# olddefconfig silently drops them. Record unsupported targets instead of making
# one absent driver abort the entire kernel build.
ADAPTER_WIFI_SPECS=(
  "ATH9K_HTC:drivers/net/wireless/ath/ath9k/ath9k_htc.ko:ATH"
  "CARL9170:drivers/net/wireless/ath/carl9170/carl9170.ko:ATH"
  "RT2800USB:drivers/net/wireless/ralink/rt2x00/rt2800usb.ko:RALINK"
  "RT73USB:drivers/net/wireless/ralink/rt2x00/rt73usb.ko:RALINK"
  "ZD1211RW:drivers/net/wireless/zydas/zd1211rw/zd1211rw.ko:ZYDAS"
)
for spec in "${ADAPTER_WIFI_SPECS[@]}"; do
  symbol="${spec%%:*}"
  rest="${spec#*:}"
  vendor="${rest##*:}"
  if grep -RqsE "^[[:space:]]*(menuconfig|config)[[:space:]]+${symbol}([[:space:]]|$)" "$COMMON/drivers/net/wireless"; then
    case "$vendor" in
      ATH) vendor_symbol=WLAN_VENDOR_ATH ;;
      RALINK) vendor_symbol=WLAN_VENDOR_RALINK ;;
      ZYDAS) vendor_symbol=WLAN_VENDOR_ZYDAS ;;
      *) echo "ERROR: invalid adapter vendor key: $vendor" >&2; exit 1 ;;
    esac
    if grep -RqsE "^[[:space:]]*(menuconfig|config)[[:space:]]+${vendor_symbol}([[:space:]]|$)" "$COMMON/drivers/net/wireless"; then
      "$COMMON/scripts/config" --file "$NETHUNTER_CONFIG" -e "CONFIG_${vendor_symbol}"
    fi
    "$COMMON/scripts/config" --file "$NETHUNTER_CONFIG" -d CONFIG_MAC80211_LEDS -m "CONFIG_${symbol}"
    echo "[nethunter] requested optional USB Wi-Fi driver CONFIG_${symbol}=m"
  else
    echo "[nethunter] optional USB Wi-Fi driver CONFIG_${symbol} is absent from pinned common Kconfig; it will be reported NOT_BUILT"
  fi
done

# The pinned common tree's SDR/media selection adds these exact tuner modules
# to common/modules.order. Keep the checked-in GKI module allow-list explicit and
# deterministic so the upstream list consistency check remains meaningful.
# This is not generated from build output and does not weaken ABI/KMI checks.
if grep -qx 'CONFIG_MEDIA_SUPPORT=y' "$NETHUNTER_CONFIG" &&
   grep -qx 'CONFIG_MEDIA_SDR_SUPPORT=y' "$NETHUNTER_CONFIG"; then
  MEDIA_SDR_GKI_MODULES=(
    drivers/media/tuners/tuner-xc2028.ko
    drivers/media/tuners/tuner-simple.ko
    drivers/media/tuners/tuner-types.ko
    drivers/media/tuners/mt20xx.ko
    drivers/media/tuners/tda8290.ko
    drivers/media/tuners/tea5767.ko
    drivers/media/tuners/tea5761.ko
    drivers/media/tuners/tda9887.ko
    drivers/media/tuners/tda827x.ko
    drivers/media/tuners/tda18271.ko
    drivers/media/tuners/xc5000.ko
    drivers/media/tuners/xc4000.ko
    drivers/media/tuners/msi001.ko
    drivers/media/tuners/mt2060.ko
    drivers/media/tuners/mt2063.ko
    drivers/media/tuners/mt2266.ko
    drivers/media/tuners/qt1010.ko
    drivers/media/tuners/mt2131.ko
    drivers/media/tuners/mxl5005s.ko
    drivers/media/tuners/mxl5007t.ko
    drivers/media/tuners/mc44s803.ko
    drivers/media/tuners/max2165.ko
    drivers/media/tuners/tda18218.ko
    drivers/media/tuners/tda18212.ko
    drivers/media/tuners/e4000.ko
    drivers/media/tuners/fc2580.ko
    drivers/media/tuners/tua9001.ko
    drivers/media/tuners/si2157.ko
    drivers/media/tuners/fc0011.ko
    drivers/media/tuners/fc0012.ko
    drivers/media/tuners/fc0013.ko
    drivers/media/tuners/it913x.ko
    drivers/media/tuners/r820t.ko
    drivers/media/tuners/mxl301rf.ko
    drivers/media/tuners/qm1d1c0042.ko
    drivers/media/tuners/qm1d1b0004.ko
    drivers/media/tuners/m88rs6000t.ko
    drivers/media/tuners/tda18250.ko
  )
  for module in "${MEDIA_SDR_GKI_MODULES[@]}"; do
    if ! grep -qxF "$module" "$GKI_MODULES_LIST"; then
      printf '%s\n' "$module" >> "$GKI_MODULES_LIST"
    fi
  done
  echo "[nethunter] explicit SDR GKI module allow-list entries added: ${#MEDIA_SDR_GKI_MODULES[@]}"
fi

# NFS client + server. Keep Kerberos disabled for simple sec=sys Android use.
$CFG \
  -e CONFIG_NETWORK_FILESYSTEMS \
  -e CONFIG_NFS_FS \
  -e CONFIG_NFS_V3 \
  -e CONFIG_NFS_V3_ACL \
  -e CONFIG_NFS_V4 \
  -e CONFIG_NFS_V4_1 \
  -e CONFIG_NFS_V4_2 \
  -e CONFIG_NFSD \
  -e CONFIG_NFSD_V3 \
  -e CONFIG_NFSD_V3_ACL \
  -e CONFIG_NFSD_V4 \
  -d CONFIG_RPCSEC_GSS_KRB5

# Do not mutate MSM gki_defconfig: Creek's merged-defconfig check requires
# the stock baseline to remain unchanged. MSM WLAN/adapter options are added
# later by enable-creek-adapter-configs.sh as a post-check config fragment.
VENDOR_BUILD_CONFIG="$MSM/build.config.msm.creek"
if [ ! -f "$VENDOR_BUILD_CONFIG" ]; then
  echo "ERROR: Creek vendor build config not found: $VENDOR_BUILD_CONFIG" >&2
  exit 1
fi

# VARIANT=gki makes the vendor build invoke a second, inner GKI build through
# GKI_BUILD_CONFIG. The fragment must be added to that inner config, not to
# the vendor/MSM config.
GKI_CONFIG_REF=$(sed -n 's/^[[:space:]]*GKI_BUILD_CONFIG[[:space:]]*=[[:space:]]*//p' "$VENDOR_BUILD_CONFIG" | tail -n1 | tr -d '"' | tr -d "'" | xargs || true)
if [ -n "$GKI_CONFIG_REF" ] && [ -f "$ROOT/$GKI_CONFIG_REF" ]; then
  GKI_BUILD_CONFIG_FILE="$ROOT/$GKI_CONFIG_REF"
elif [ -n "$GKI_CONFIG_REF" ] && [ -f "$COMMON/$GKI_CONFIG_REF" ]; then
  GKI_BUILD_CONFIG_FILE="$COMMON/$GKI_CONFIG_REF"
else
  GKI_BUILD_CONFIG_FILE=$(find "$COMMON" -maxdepth 1 -type f -name 'build.config.gki*' | sort | head -n1)
fi
if [ -z "${GKI_BUILD_CONFIG_FILE:-}" ] || [ ! -f "$GKI_BUILD_CONFIG_FILE" ]; then
  echo "ERROR: unable to locate inner GKI build config" >&2
  exit 1
fi

# Keep DEFCONFIG as a single filename: Creek's check_defconfig treats the
# value as a path. Run the stock check first, then merge our fragment before
# compilation through POST_DEFCONFIG_CMDS.
sed -i '/^[[:space:]]*DEFCONFIG=/d' "$GKI_BUILD_CONFIG_FILE"
sed -i '/^[[:space:]]*POST_DEFCONFIG_CMDS=/d' "$GKI_BUILD_CONFIG_FILE"
cat >> "$GKI_BUILD_CONFIG_FILE" <<'EOF_GKI_NETHUNTER'

DEFCONFIG="gki_defconfig"
merge_nethunter_config() {
  echo "[nethunter] merging nethunter.config after check_defconfig (preserve stock built-ins)"
  local config_file="${OUT_DIR}/.config"
  local fragment="$(cd "${KERNEL_DIR}" && pwd)/arch/arm64/configs/nethunter.config"
  test -s "${config_file}" || { echo "ERROR: GKI .config missing before NetHunter merge" >&2; return 1; }
  test -s "${fragment}" || { echo "ERROR: NetHunter fragment missing: ${fragment}" >&2; return 1; }
  (cd "${KERNEL_DIR}" && KCONFIG_CONFIG="${config_file}" scripts/kconfig/merge_config.sh -y -m "${config_file}" "${fragment}")

  # Resolve the requested USB Wi-Fi driver dependency chain before compilation.
  # The module allow-list is updated only after all five final values are verified.

  # Disable both spellings in common/GKI. In this pinned source the GSI
  # gadget can be selected through CONFIG_USB_CONFIGFS_F_GSI rather than
  # CONFIG_USB_F_GSI; disabling only one name left usb_f_gsi.ko in the build
  # and depmod then failed on unresolved rndis_* symbols. Keep RNDIS itself
  # available; only disable the optional GSI function.
  "${KERNEL_DIR}/scripts/config" --file "${config_file}" -d CONFIG_USB_F_GSI -d CONFIG_USB_CONFIGFS_F_GSI

  local -a nh_tool_args=() nh_make_args=()
  read -r -a nh_tool_args <<< "${TOOL_ARGS:-}"
  read -r -a nh_make_args <<< "${MAKE_ARGS:-}"
  (cd "${KERNEL_DIR}" && make "${nh_tool_args[@]}" O="${OUT_DIR}" "${nh_make_args[@]}" olddefconfig)

  # Keep the GKI allow-list tied to the FINAL resolved config. Optional
  # upstream drivers are enabled only if this pinned source contains their
  # Kconfig symbol and olddefconfig preserves CONFIG_*=m. Unsupported optional
  # drivers are reported, not fabricated and not allowed to break unrelated
  # kernel features. Any driver that does build still faces the normal KMI gate.
  local module_list="${KERNEL_DIR}/android/gki_aarch64_modules"
  test -f "$module_list" || { echo "ERROR: GKI module allow-list missing: $module_list" >&2; return 1; }
  local -a adapter_specs=(
    "ATH9K_HTC:drivers/net/wireless/ath/ath9k/ath9k_htc.ko"
    "CARL9170:drivers/net/wireless/ath/carl9170/carl9170.ko"
    "RT2800USB:drivers/net/wireless/ralink/rt2x00/rt2800usb.ko"
    "RT73USB:drivers/net/wireless/ralink/rt2x00/rt73usb.ko"
    "ZD1211RW:drivers/net/wireless/zydas/zd1211rw/zd1211rw.ko"
  )
  local resolved_wifi=0
  for spec in "${adapter_specs[@]}"; do
    local symbol="${spec%%:*}"
    local module_path="${spec#*:}"
    if grep -qx "CONFIG_${symbol}=m" "$config_file"; then
      if ! grep -qxF "$module_path" "$module_list"; then
        printf '%s\n' "$module_path" >> "$module_list"
      fi
      echo "[nethunter] OPTIONAL_DRIVER=RESOLVED CONFIG_${symbol}=m path=${module_path}"
      resolved_wifi=$((resolved_wifi + 1))
    else
      echo "[nethunter] OPTIONAL_DRIVER=NOT_BUILT CONFIG_${symbol}; source/dependencies do not provide a loadable module"
    fi
  done
  echo "[nethunter] optional USB Wi-Fi modules resolved: $resolved_wifi/5"

  # Validate the FINAL resolved GKI .config, not only nethunter.config. The
  # previous tcp_cong_avoid_ai KMI failure demonstrates why fragment-only checks
  # are insufficient: defaults/dependencies can re-enable ABI-sensitive options.
  for symbol in TCP_CONG_ADVANCED TCP_CONG_BBR TCP_CONG_BBR3 DEFAULT_BBR3; do
    if grep -Eq "^CONFIG_${symbol}=(y|m)$" "${config_file}"; then
      echo "ERROR: CONFIG_${symbol} is enabled in final GKI .config and may change the pinned Creek KMI export set" >&2
      grep -n "^CONFIG_${symbol}=" "${config_file}" >&2 || true
      return 1
    fi
  done
  echo "[nethunter] final GKI KMI-sensitive TCP options verified disabled"

  # An absent symbol is not enabled. Fail only if common/GKI explicitly
  # resolves it to y or m; absence can mean it belongs to the MSM Kconfig tree.
  if grep -Eq '^CONFIG_USB_F_GSI=(y|m)$' "${config_file}"; then
    echo "ERROR: CONFIG_USB_F_GSI is enabled in final GKI config" >&2
    grep -n '^CONFIG_USB_F_GSI=' "${config_file}" >&2 || true
    return 1
  fi
  if grep -qx '# CONFIG_USB_F_GSI is not set' "${config_file}"; then
    echo "[nethunter] verified CONFIG_USB_F_GSI disabled in final GKI config"
  else
    echo "[nethunter] CONFIG_USB_F_GSI absent from common/GKI .config; MSM config is checked separately"
  fi
}
POST_DEFCONFIG_CMDS="check_defconfig; merge_nethunter_config"
EOF_GKI_NETHUNTER
echo "[nethunter] inner GKI config: $GKI_BUILD_CONFIG_FILE"
echo "[nethunter] using config fragment: $NETHUNTER_CONFIG"

# Helpful build snapshots.
mkdir -p "$ROOT/nethunter-debug"
{
  echo "# Creek NetHunter config additions"
  grep -E 'CONFIG_(BBG|TCP_CONG_BBR3|DEFAULT_BBR3|DEFAULT_TCP_CONG|SYSVIPC|PID_NS|USER_NS|POSIX_MQUEUE|NFS|NFSD|USB_AIRSPY|USB_HACKRF|IP_SET|NET_SCH_CAKE|NET_SCH_PIE|NET_SCH_FQ_PIE)=' "$NETHUNTER_CONFIG" || true
} > "$ROOT/nethunter-debug/nethunter-config-summary.txt"

echo "[nethunter] Creek NetHunter common patches/configs enabled"
