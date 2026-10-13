#!/usr/bin/env bash
# Enable requested in-tree adapter/support modules only when their Kconfig
# symbols actually exist in the checked-out Creek source. Missing symbols are
# reported, never fabricated. Modules remain unloaded unless explicitly asked.
set -euo pipefail
KP="${1:?kernel_platform}"
COMMON="$KP/common"
MSM="$KP/msm-kernel"
NH_CONFIG="$COMMON/arch/arm64/configs/nethunter.config"
MSM_CONFIG="$MSM/arch/arm64/configs/gki_defconfig"
MSM_FRAGMENT="$MSM/arch/arm64/configs/creek-nethunter-adapters.config"
test -f "$NH_CONFIG"
test -f "$MSM_CONFIG"
REPORT="${2:-$PWD/adapter-config-status.txt}"
python3 - "$COMMON" "$MSM" "$NH_CONFIG" "$MSM_CONFIG" "$MSM_FRAGMENT" "$REPORT" <<'PY'
from pathlib import Path
import re, subprocess, sys
common, msm, nhcfg, msmcfg, fragment, report = map(Path, sys.argv[1:])
# Module basename -> Kconfig symbol. Symbols not listed here are derived from
# the module name; this map handles names whose Kconfig symbols differ.
aliases = {
 "mac80211":"MAC80211", "mt76":"MT76_CORE", "mt76_usb":"MT76_USB", "mt76_connac_lib":"MT76_CONNAC_LIB",
 "mt76x0_common":"MT76x0_COMMON", "mt76x0u":"MT76x0U", "mt76x02_lib":"MT76x02_LIB", "mt76x02_usb":"MT76x02_USB",
 "mt76x2_common":"MT76x2_COMMON", "mt76x2u":"MT76x2U", "mt7601u":"MT7601U", "mt7603e":"MT7603E",
 "mt7615e":"MT7615E", "mt7615_common":"MT7615_COMMON", "mt7663u":"MT7663U",
 "mt7663_usb_sdio_common":"MT7663_USB_SDIO_COMMON", "mt7915e":"MT7915E", "mt7921e":"MT7921E",
 "rtw_core":"RTW88_CORE", "rtw_usb":"RTW88_USB",
 "rtw_sdio":"RTW88_SDIO", "rtw_pci":"RTW88_PCI",
 "hackrf":"USB_HACKRF", "airspy":"USB_AIRSPY", "rtl2832":"DVB_RTL2832",
 "rtl2830":"DVB_RTL2830", "mn88473":"DVB_MN88473",
 "rtl2832_sdr":"DVB_RTL2832_SDR", "dvb_usb_rtl28xxu":"DVB_USB_RTL28XXU",
 "cp210x":"USB_SERIAL_CP210X", "usb_wwan":"USB_WWAN",
 "nfc":"NFC", "nfc_nci":"NFC_NCI", "nfc_llcp":"NFC_LLCP",
 "nfc_digital":"NFC_DIGITAL", "nfc_hci":"NFC_HCI", "nfc_shdlc":"NFC_SHDLC",
 "pn533":"NFC_PN533", "pn533_usb":"NFC_PN533_USB",
 "rc_core":"RC_CORE", "lirc_dev":"LIRC", "ir_lirc_codec":"IR_LIRC_CODEC",
 "wire":"W1", "ds2490":"W1_MASTER_DS2490", "w1_therm":"W1_SLAVE_THERM",
 "w1_ds2431":"W1_SLAVE_DS2431", "w1_ds2433":"W1_SLAVE_DS2433",
 "w1_ds2408":"W1_SLAVE_DS2408", "can_isotp":"CAN_ISOTP",
 "can_j1939":"CAN_J1939", "slcan":"CAN_SLCAN", "can_gw":"CAN_GW",
 "vcan":"CAN_VCAN", "usb_f_hid":"USB_CONFIGFS_F_HID",
 "usb_f_mass_storage":"USB_CONFIGFS_MASS_STORAGE",
 "usb_f_serial":"USB_CONFIGFS_F_SERIAL", "usb_f_ecm":"USB_CONFIGFS_ECM",
 "g_multi":"USB_G_MULTI", "uinput":"INPUT_UINPUT", "evdev":"INPUT_EVDEV",
 "dummy":"DUMMY", "ifb":"IFB", "macvlan":"MACVLAN", "ipvlan":"IPVLAN",
 "vxlan":"VXLAN", "geneve":"GENEVE", "ip6_tunnel":"IPV6_TUNNEL",
 "sit":"INET6_TUNNEL", "batman_adv":"BATMAN_ADV",
 "nf_conntrack":"NF_CONNTRACK", "xt_conntrack":"NETFILTER_XT_MATCH_CONNTRACK",
 "nf_tables":"NF_TABLES", "openvswitch":"OPENVSWITCH", "usbmon":"USB_MON",
 "nlmon":"NETLINK_DIAG", "pktgen":"NET_PKTGEN", "fuse":"FUSE_FS",
 "cls_u32":"NET_CLS_U32", "cls_flower":"NET_CLS_FLOWER",
 "cls_bpf":"NET_CLS_BPF", "act_mirred":"NET_ACT_MIRRED",
 "act_bpf":"NET_ACT_BPF", "sch_netem":"NET_SCH_NETEM",
 "sch_tbf":"NET_SCH_TBF", "packet_diag":"PACKET_DIAG",
 "bt_6lowpan":"BT_6LOWPAN", "bt_hs":"BT_HS", "mac802154":"MAC802154",
 "ieee802154_6lowpan":"IEEE802154_6LOWPAN", "wpan_phy":"IEEE802154",
 "af_alg":"AF_ALG", "algif_hash":"CRYPTO_USER_API_HASH",
 "algif_skcipher":"CRYPTO_USER_API_SKCIPHER",
 "algif_aead":"CRYPTO_USER_API_AEAD", "algif_rng":"CRYPTO_USER_API_RNG",
 "crypto_user":"CRYPTO_USER", "cpu_boost":"CPU_FREQ_BOOST",
}
targets = Path("config/creek-adapter-module-targets.txt")
names = []
for line in targets.read_text().splitlines():
    line=line.split("#",1)[0].strip()
    if line and line != "qca_cld3_wlan":
        names.append(line.replace("-", "_"))
def symbols_in(root):
    out={}
    for p in root.rglob("Kconfig*"):
        if not p.is_file(): continue
        try: lines=p.read_text(errors="ignore").splitlines()
        except OSError: continue
        current=None
        for line in lines:
            m=re.match(r"\s*(?:menuconfig|config)\s+([A-Za-z0-9_]+)\s*$",line)
            if m: current=m.group(1); out.setdefault(current,[]).append((p,[])); continue
            if current and out[current]:
                path, body=out[current][-1]
                body.append(line)
                if re.match(r"\s*(?:menuconfig|config)\s+",line): current=None
    return out
csyms=symbols_in(common); msyms=symbols_in(msm)
rows=[]
fragment_symbols={}
# This optional Qualcomm gadget function is broken in the pinned source: usb_f_gsi.ko
# references RNDIS exports that are absent from the resolved module set. Keep it disabled.
# Disable the broken optional GSI gadget function in both config domains
# unconditionally. The source's symbol scanner can miss symbols hidden behind
# sourced Kconfig files; the final generated .config is verified below.
for gsi_symbol in ("USB_F_GSI", "USB_CONFIGFS_F_GSI"):
    fragment_symbols[gsi_symbol] = "n"
    if gsi_symbol in csyms:
        subprocess.run([str(common/"scripts/config"), "--file", str(nhcfg), "-d", "CONFIG_"+gsi_symbol], check=True)
# The target file is an INVENTORY, not proof that every driver can link against
# Creek's pinned mixed-tree KMI. Previous attempts enabled every discovered
# symbol in msm-kernel, which built unrelated upstream drivers as vendor modules
# and caused mass MODPOST unresolved-symbol failures. Only the wireless framework
# needed by the separately-built USB Wi-Fi adapter path is enabled here.
safe_msm = {
    "MAC80211": "m",
    "MAC80211_LEDS": "n",       # led_trigger_blink is not exported by this GKI KMI
    "MAC80211_RC_MINSTREL": "y",
    "WLAN_VENDOR_REALTEK": "y", # does not enable a driver by itself
}
if "MAC80211" not in msyms:
    raise SystemExit("ERROR: pinned MSM source has no MAC80211 Kconfig symbol; cannot enable the audited USB Wi-Fi framework")
for symbol, value in safe_msm.items():
    if symbol in msyms:
        fragment_symbols[symbol] = value
    elif symbol == "MAC80211":
        raise SystemExit("ERROR: MAC80211 is required but absent from msm-kernel Kconfig")

# Explicitly defer optional modules already proven incompatible with this KMI.
# Keep the stock NFC core untouched; do not build NFC child modules as separate
# vendor modules while their core exports are absent from the approved KMI.
blocked_symbols = (
    "NET_NSH", "OPENVSWITCH", "VXLAN", "GENEVE", "BATMAN_ADV",
    "NFC_DIGITAL", "NFC_NCI", "NFC_HCI", "NFC_SHDLC", "NFC_LLCP",
    "NFC_PN533", "NFC_PN533_USB",
)
for symbol in blocked_symbols:
    if symbol in msyms:
        fragment_symbols[symbol] = "n"

# Do not turn the 139-name request inventory into a 139-module enable list.
# Record each target's source location and disposition without overriding either
# tree's Kconfig. Common/GKI options explicitly requested by enable-creek-nethunter.sh
# remain there; they must not be duplicated in the MSM/vendor .config.
nh_text = nhcfg.read_text()
stock_msm_text = msmcfg.read_text()

def config_value(text, symbol):
    m = re.search(r"^CONFIG_" + re.escape(symbol) + r"=(y|m)$", text, re.M)
    return m.group(1) if m else ("n" if re.search(r"^# CONFIG_" + re.escape(symbol) + r" is not set$", text, re.M) else None)

external_targets = {"rtl8xxxu"}
external_nfc = {"nfc_nci", "nfc_llcp", "nfc_digital", "nfc_hci", "nfc_shdlc", "pn533", "pn533_usb"}
blocked_names = {
    "nsh", "openvswitch", "vxlan", "geneve", "batman_adv",
    "nfc_nci", "nfc_llcp", "nfc_digital", "nfc_hci", "nfc_shdlc", "pn533", "pn533_usb",
}
for name in sorted(set(names)):
    symbol = aliases.get(name, name.upper())
    candidates = [symbol]
    if name.startswith("rtw_"):
        candidates += [name.upper(), "RTW88"]
    if name.startswith("mt76"):
        candidates += [name.upper()]
    found = None
    tree = None
    for candidate in candidates:
        if candidate in csyms:
            found = (candidate, csyms[candidate])
            tree = "common"
            break
        if candidate in msyms:
            found = (candidate, msyms[candidate])
            tree = "msm"
            break
    if not found:
        if name in external_targets or name.startswith("rtw_"):
            rows.append((name + ".ko", "EXTERNAL_BUILD_TARGET",
                         "built only by the separately audited external-module stage; package status comes from actual staged output"))
        else:
            rows.append((name + ".ko", "NO_KCONFIG_SYMBOL",
                         "no matching Kconfig symbol in pinned common/MSM scan; no placeholder or invented module is created"))
        continue

    symbol, defs = found
    if name == "mac80211":
        rows.append((name + ".ko", "ENABLED_MSM_BASELINE",
                     "CONFIG_MAC80211=m; MAC80211_LEDS=n to avoid the known missing led_trigger_blink export"))
        continue
    if name in external_targets:
        rows.append((name + ".ko", "EXTERNAL_BUILD_TARGET",
                     "built from the repository's rtl/ source only; in-tree duplicate is not auto-enabled"))
        continue
    if name in blocked_names:
        rows.append((name + ".ko", "DEFERRED_KMI_AUDIT",
                     "known unresolved or non-KMI dependency; not enabled in the MSM/vendor module fragment"))
        continue

    # Preserve the existing GKI fragment and stock MSM defconfig as the sources
    # of truth. Never activate an extra driver merely because a matching Kconfig
    # symbol happens to exist in one or both source trees.
    common_value = config_value(nh_text, symbol)
    msm_value = config_value(stock_msm_text, symbol)
    if common_value in ("y", "m"):
        rows.append((name + ".ko", "REQUESTED_IN_GKI_FRAGMENT",
                     f"CONFIG_{symbol}={common_value} is already requested in common/nethunter.config; do not duplicate it in MSM"))
    elif msm_value in ("y", "m"):
        rows.append((name + ".ko", "PRESERVED_STOCK_MSM_CONFIG",
                     f"CONFIG_{symbol}={msm_value} already comes from stock msm-kernel/gki_defconfig"))
    elif name.startswith("nfc") or name.startswith("pn533"):
        rows.append((name + ".ko", "DEFERRED_KMI_AUDIT",
                     "NFC child module would depend on core NFC exports not approved for this vendor KMI"))
    else:
        rows.append((name + ".ko", "DEFERRED_KMI_AUDIT",
                     f"CONFIG_{symbol} exists in {tree}, but is not in the verified enable allowlist; no automatic activation"))

# Preserve known-failing families as disabled even if a future vendor defconfig
# starts selecting them by default. Never relax MODPOST or ABI/KMI enforcement.
for symbol in blocked_symbols:
    if symbol in msyms:
        fragment_symbols[symbol] = "n"
fragment.write_text("# Creek NetHunter adapter requests; only audited MSM baseline enabled.\n" +
                    "".join(f"CONFIG_{sym}={value}\n" for sym, value in sorted(fragment_symbols.items())))
report.write_text("module\tstatus\tdetail\n"+"".join("\t".join(r)+"\n" for r in rows))
print(f"[adapter-config] requested={len(rows)} report={report} msm_symbols={len(fragment_symbols)} fragment={fragment}")
for row in rows:
    if row[1] in ("NO_KCONFIG_SYMBOL","CONFIG_TOOL_MISSING"): print("\t".join(row))
PY

MSM_BUILD_CONFIG="$MSM/build.config.msm.creek"
test -f "$MSM_BUILD_CONFIG" || { echo "ERROR: MSM build config not found: $MSM_BUILD_CONFIG" >&2; exit 1; }
python3 - "$MSM_BUILD_CONFIG" <<'PY_BUILD_CONFIG'
import re, sys
from pathlib import Path
p=Path(sys.argv[1])
s=p.read_text()
old_post=[]
for line in s.splitlines():
    m=re.match(r'^\s*POST_DEFCONFIG_CMDS\s*=\s*"?(.+?)"?\s*$', line)
    if m: old_post.append(m.group(1))
s=re.sub(r'^\s*DEFCONFIG\s*=.*$', '', s, flags=re.M)
s=re.sub(r'^\s*POST_DEFCONFIG_CMDS\s*=.*$', '', s, flags=re.M)
# Keep only upstream post-defconfig commands. Do not inject a new check_defconfig: the
# pinned Creek source already owns its validation policy, and an extra check can
# reject the generated config before the deferred adapter fragment is applied.
post='; '.join(old_post + ['creek_nethunter_apply_adapter_config'])
s += """

# Preserve stock defconfig validation, then apply adapter requests. merge_config -y
# prevents an existing built-in (=y) option from being demoted to a module.
DEFCONFIG="gki_defconfig"
creek_nethunter_apply_adapter_config() {
  local config_file="${OUT_DIR}/.config"
  local kernel_dir
  kernel_dir="$(cd "${KERNEL_DIR}" && pwd)"
  local fragment="${kernel_dir}/arch/arm64/configs/creek-nethunter-adapters.config"
  test -s "${config_file}" || { echo "ERROR: MSM .config missing before adapter merge" >&2; return 1; }
  test -s "${fragment}" || { echo "ERROR: adapter fragment missing: ${fragment}" >&2; return 1; }
  KCONFIG_CONFIG="${config_file}" "${kernel_dir}/scripts/kconfig/merge_config.sh" -y -m "${config_file}" "${fragment}"
  # Force-disable the optional GSI function after all fragments. The pinned
  # usb_f_gsi.ko has unresolved RNDIS API references and makes depmod fatal.
  "${kernel_dir}/scripts/config" --file "${config_file}" -d CONFIG_USB_F_GSI -d CONFIG_USB_CONFIGFS_F_GSI
  local -a adapter_tool_args=() adapter_make_args=()
  read -r -a adapter_tool_args <<< "${TOOL_ARGS:-}"
  read -r -a adapter_make_args <<< "${MAKE_ARGS:-}"
  make -C "${kernel_dir}" "${adapter_tool_args[@]}" O="${OUT_DIR}" "${adapter_make_args[@]}" olddefconfig
  if grep -Eq "^CONFIG_(USB_F_GSI|USB_CONFIGFS_F_GSI)=(y|m)$" "${config_file}"; then
    echo "ERROR: broken GSI gadget remains enabled after config merge" >&2
    grep -E "^CONFIG_(USB_F_GSI|USB_CONFIGFS_F_GSI)=" "${config_file}" >&2 || true
    return 1
  fi
  echo "[creek-nethunter] adapter fragment merged; broken GSI gadget disabled"
}
POST_DEFCONFIG_CMDS="__POST_COMMANDS__"
"""
s=s.replace("__POST_COMMANDS__", post)
p.write_text(s)
PY_BUILD_CONFIG
