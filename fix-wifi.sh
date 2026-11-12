#!/usr/bin/env bash
# fix-wifi.sh — work around the Wi-Fi boot race on LineageOS for OnePlus 6T (fajita)
# and OnePlus 6 (enchilada), over adb, from a computer.
#
# Usage: ./fix-wifi.sh [check|apply|undo] [--reboot] [-s SERIAL]
#   check   (default) diagnose only, change nothing
#   apply   create /data/vendor/oemnvitems/4678_1 so the MAC is written before the driver loads
#   undo    remove that file
#   --reboot  reboot the phone after apply/undo
#
# Requires: adb, "Rooted debugging" enabled in Developer options (LineageOS userdebug builds).
set -euo pipefail
export MSYS_NO_PATHCONV=1   # Git Bash on Windows: don't rewrite /data/... paths

MODE=check REBOOT=0 SERIAL=""
while [ $# -gt 0 ]; do
    case "$1" in
        check|apply|undo) MODE=$1 ;;
        --reboot) REBOOT=1 ;;
        -s) SERIAL=$2; shift ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

ADB=(adb); [ -n "$SERIAL" ] && ADB=(adb -s "$SERIAL")
sh_() { "${ADB[@]}" shell "$@" | tr -d '\r'; }

NV1=/data/vendor/oemnvitems/4678_1
MACFILE=/mnt/vendor/persist/wlan_mac.bin

# --- connect as root -------------------------------------------------------
"${ADB[@]}" get-state >/dev/null 2>&1 || { echo "no adb device found" >&2; exit 1; }
if [ "$(sh_ id -u)" != 0 ]; then
    out=$("${ADB[@]}" root 2>&1 || true)
    case "$out" in *disabled*) echo "enable Settings > System > Developer options > Rooted debugging" >&2; exit 1 ;; esac
    "${ADB[@]}" wait-for-device
    [ "$(sh_ id -u)" = 0 ] || { echo "adb root failed: $out" >&2; exit 1; }
fi

DEVICE=$(sh_ getprop ro.lineage.device)
echo "device: $DEVICE  build: $(sh_ getprop ro.lineage.version)"
case "$DEVICE" in fajita|enchilada) ;; *) echo "warning: only tested on fajita" >&2 ;; esac

# --- diagnosis -------------------------------------------------------------
diagnose() {
    echo "wifi: $(sh_ 'cmd wifi status | head -1')"
    echo "wlan_mac.bin: $(sh_ "wc -c < $MACFILE") bytes"
    if sh_ "[ -f $NV1 ] && echo y" | grep -q y; then
        echo "4678_1: present ($(sh_ "xxd -p $NV1"))  -> fix applied"
    else
        echo "4678_1: missing  -> MAC generator waits ~9 s at boot (race with the Wi-Fi driver)"
    fi
    local kmsg; kmsg=$(sh_ dmesg)
    if grep -q 'hdd_wlan_startup.*Failed to open interfaces' <<<"$kmsg"; then
        echo "kernel: driver startup FAILED this boot (no valid MAC when it loaded)"
    elif grep -q 'Timed-out in wlan_hdd_state_ctrl_param_write' <<<"$kmsg"; then
        echo "kernel: Wi-Fi enable timed out this boot"
    fi
}

case "$MODE" in
check)
    diagnose ;;
apply)
    if sh_ "[ -f $NV1 ] && echo y" | grep -q y; then
        echo "already applied"
    else
        # Reuse the current Intf1 MAC when valid, else a random one with the OnePlus prefix.
        mac=$(sh_ "sed -n 's/^Intf1MacAddress=\([0-9A-F]\{12\}\)$/\1/p' $MACFILE")
        [ -n "$mac" ] || mac=C0EEFB$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n' | tr a-f A-F)
        # The generator reads this file byte-reversed: store the MAC bytes in reverse order.
        esc=$(awk -v m="$mac" 'BEGIN { for (i = 11; i > 0; i -= 2) printf "%s", substr(m, i, 2) }' | sed 's/../\\x&/g')
        sh_ "printf '$esc' > $NV1 && chown radio:radio $NV1 && chmod 0666 $NV1 && restorecon $NV1 >/dev/null 2>&1"
        echo "created $NV1 (Intf1 MAC $mac): $(sh_ "xxd -p $NV1")"
        [ "$REBOOT" = 1 ] || echo "reboot the phone to bring Wi-Fi back (the driver only loads at boot)"
    fi ;;
undo)
    sh_ "rm -f $NV1"; echo "removed $NV1" ;;
esac

if [ "$REBOOT" = 1 ] && [ "$MODE" != check ]; then
    echo "rebooting..."; "${ADB[@]}" reboot
fi
