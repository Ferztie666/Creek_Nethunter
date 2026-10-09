#!/system/bin/sh
set -eu
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)"
# In a flat unpacked test directory, use colocated modules. In the installable
# Magisk package, keep modules in a dedicated non-boot-loaded directory so no
# stock module path or module-load list is overwritten.
if [ -r "$SCRIPT_DIR/MODULE-LIST.txt" ]; then
  BASE="$SCRIPT_DIR"
elif [ -r "$SCRIPT_DIR/modules/MODULE-LIST.txt" ]; then
  BASE="$SCRIPT_DIR/modules"
else
  echo "ERROR: adapter module payload not found" >&2
  exit 1
fi
DEPMAP="$BASE/MODULE-DEPENDS.txt"
MODLIST="$BASE/MODULE-LIST.txt"
[ -r "$MODLIST" ] || { echo "ERROR: MODULE-LIST.txt missing" >&2; exit 1; }
[ -r "$BASE/KERNEL-RELEASE" ] || { echo "ERROR: KERNEL-RELEASE missing" >&2; exit 1; }
[ "$(id -u)" = 0 ] || { echo "ERROR: run from a root shell (su)" >&2; exit 1; }
EXPECTED="$(cat "$BASE/KERNEL-RELEASE")"
CURRENT="$(uname -r)"
[ "$CURRENT" = "$EXPECTED" ] || {
  echo "ERROR: kernel mismatch: running=$CURRENT package=$EXPECTED" >&2
  echo "Refusing to load modules built for another kernel." >&2; exit 1;
}
INS="$(command -v insmod 2>/dev/null || true)"
[ -n "$INS" ] || { [ ! -x /vendor/bin/insmod ] || INS=/vendor/bin/insmod; }
[ -n "$INS" ] || { [ ! -x /system/bin/insmod ] || INS=/system/bin/insmod; }
[ -n "$INS" ] || { echo "ERROR: insmod not found" >&2; exit 1; }
norm(){ printf '%s' "$1" | tr '-' '_'; }
loaded(){ n="$(norm "$1")"; [ -d "/sys/module/$n" ] && return 0; awk -v n="$n" '{m=$1;gsub(/-/,"_",m);if(m==n)f=1}END{exit !f}' /proc/modules 2>/dev/null; }
module_path(){
 n="$(norm "$1")"
 while IFS= read -r line; do
   case "$line" in ""|\#*) continue;; esac
   name="${line%.ko}"
   if [ "$(norm "$name")" = "$n" ]; then printf '%s/%s\n' "$BASE" "$line"; return 0; fi
 done < "$MODLIST"
 return 1
}
present(){ module_path "$1" >/dev/null 2>&1; }
deps(){
 n="$(norm "$1")"
 [ ! -r "$DEPMAP" ] || awk -F: -v n="$n" '{key=$1;gsub(/-/,"_",key);if(key==n){print $2;f=1}}END{if(!f)exit 0}' "$DEPMAP"
}
SEEN=" "
load_one(){
 n="$(norm "$1")"
 if loaded "$n"; then echo "ALREADY_LOADED=$n"; return 0; fi
 present "$n" || { echo "ERROR: module not packaged: $n" >&2; return 1; }
 case "$SEEN" in *" $n "*) echo "ERROR: dependency cycle at $n" >&2; return 1;; esac
 SEEN="$SEEN$n "
 for d in $(deps "$n"); do
   d="$(norm "$d")"; [ -n "$d" ] || continue
   if loaded "$d"; then continue; fi
   if present "$d"; then load_one "$d"; else
     echo "ERROR: dependency $d for $n is neither loaded nor packaged" >&2; return 1
   fi
 done
 module_file="$(module_path "$n")"
 "$INS" "$module_file"
 loaded "$n" || echo "WARNING: insmod succeeded but module visibility is delayed: $n" >&2
 echo "LOADED=$n"
 SEEN="$(printf '%s' "$SEEN" | sed "s/ $n / /")"
}
status(){
 echo "Kernel running: $CURRENT"; echo "Package kernel: $EXPECTED"
 echo "No boot-time module loading is configured by this package."
 while IFS= read -r line; do case "$line" in ""|\#*) continue;; esac
   n="${line%.ko}"; if loaded "$n"; then echo "loaded  $n"; else echo "unloaded $n"; fi
 done < "$MODLIST"
}
family(){
 fam="$1"; count=0
 while IFS= read -r line; do case "$line" in ""|\#*) continue;; esac
   n="$(norm "${line%.ko}")"
   case "$fam:$n" in
     rtw88:rtw_core|rtw88:rtw_usb|rtw88:rtw_*u|rtl8xxxu:rtl8xxxu|mt76:mt76|mt76:mt76_usb|mt76:mt76_connac_lib|mt76:mt76x0u|mt76:mt76x2u|mt76:mt7601u|mt76:mt7663u|mt76:mt7663_usb)
       SEEN=" "; load_one "$n"; count=$((count+1));;
   esac
 done < "$MODLIST"
 [ "$count" -gt 0 ] || { echo "ERROR: no packaged modules matched '$fam'" >&2; exit 1; }
}
case "${1:-}" in
 status) status;;
 load) [ "$#" -eq 2 ] || { echo "Usage: nhd load MODULE_NAME" >&2; exit 2; }; load_one "$2";;
 load-family) [ "$#" -eq 2 ] || { echo "Usage: nhd load-family rtw88|rtl8xxxu|mt76" >&2; exit 2; }; case "$2" in rtw88|rtl8xxxu|mt76) family "$2";; *) echo "ERROR: unsupported family: $2" >&2; exit 2;; esac;;
 run)
   [ "$#" -ge 4 ] && [ "$3" = "--" ] || { echo "Usage: nhd run MODULE_NAME -- COMMAND [ARGS...]" >&2; exit 2; }
   load_one "$2"
   shift 3
   exec "$@"
   ;;
 run-family)
   [ "$#" -ge 4 ] && [ "$3" = "--" ] || { echo "Usage: nhd run-family rtw88|rtl8xxxu|mt76 -- COMMAND [ARGS...]" >&2; exit 2; }
   case "$2" in rtw88|rtl8xxxu|mt76) family "$2";; *) echo "ERROR: unsupported family: $2" >&2; exit 2;; esac
   shift 3
   exec "$@"
   ;;
 *) echo "Usage: nhd status | load MODULE_NAME | load-family FAMILY | run MODULE -- COMMAND | run-family FAMILY -- COMMAND" >&2; exit 2;;
esac
