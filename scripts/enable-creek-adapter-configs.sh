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
test -f "$NH_CONFIG"
test -f "$MSM_CONFIG"
REPORT="${2:-$PWD/adapter-config-status.txt}"
python3 - "$COMMON" "$MSM" "$NH_CONFIG" "$MSM_CONFIG" "$REPORT" <<'PY'
from pathlib import Path
import re, subprocess, sys
common, msm, nhcfg, msmcfg, report = map(Path, sys.argv[1:])
# Module basename -> Kconfig symbol. Symbols not listed here are derived from
# the module name; this map handles names whose Kconfig symbols differ.
aliases = {
 "mac80211":"MAC80211", "rtw_core":"RTW88_CORE", "rtw_usb":"RTW88_USB",
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
            m=re.match(r"\s*(?:menuconfig|config)\s+([A-Z0-9_]+)\s*$",line)
            if m: current=m.group(1); out.setdefault(current,[]).append((p,[])); continue
            if current and out[current]:
                path, body=out[current][-1]
                body.append(line)
                if re.match(r"\s*(?:menuconfig|config)\s+",line): current=None
    return out
csyms=symbols_in(common); msyms=symbols_in(msm)
rows=[]
for name in sorted(set(names)):
    sym=aliases.get(name, name.upper())
    # Candidate aliases for in-tree wireless/driver naming differences.
    candidates=[sym]
    if name.startswith("rtw_"): candidates += [name.upper(), "RTW88"]
    if name.startswith("mt76"): candidates += [name.upper()]
    found=None; tree=None
    for candidate in candidates:
        if candidate in msyms: found=(candidate,msyms[candidate]); tree="msm"; break
        if candidate in csyms: found=(candidate,csyms[candidate]); tree="common"; break
    if not found:
        if name == "rtl8xxxu" or name.startswith("rtw_"):
            rows.append((name+".ko","EXTERNAL_BUILD_TARGET",
                         "handled by scripts/creek-external-modules.mk; actual module availability is decided from staged build output"))
        else:
            rows.append((name+".ko","NO_KCONFIG_SYMBOL",
                         "no matching Kconfig symbol in the pinned common/MSM source scan; verify source availability in MODULE-STATUS.txt"))
        continue
    symbol, defs=found
    # Use first definition and its type; bool symbols must be built-in.
    body="\n".join(defs[0][1])
    tristate=bool(re.search(r"^\s*tristate\b",body,re.M))
    typ="-m" if tristate else "-e"
    cfg=msmcfg if tree=="msm" else nhcfg
    config_tool=(msm/"scripts/config") if tree=="msm" else (common/"scripts/config")
    if not config_tool.exists():
        rows.append((name+".ko","CONFIG_TOOL_MISSING",str(config_tool))); continue
    subprocess.run([str(config_tool),"--file",str(cfg),typ,"CONFIG_"+symbol],check=True)
    rows.append((name+".ko","REQUESTED_"+("MODULE" if tristate else "BUILTIN"),f"CONFIG_{symbol} in {tree} tree"))
report.write_text("module\tstatus\tdetail\n"+"".join("\t".join(r)+"\n" for r in rows))
print(f"[adapter-config] requested={len(rows)} report={report}")
for row in rows:
    if row[1] in ("NO_KCONFIG_SYMBOL","CONFIG_TOOL_MISSING"): print("\t".join(row))
PY
