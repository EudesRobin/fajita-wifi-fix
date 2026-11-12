# fajita-wifi-fix

Fixes Wi-Fi that won't turn on (the toggle flips back off after ~20 s) on
**LineageOS 22.x for the OnePlus 6T (`fajita`)**. The OnePlus 6 (`enchilada`)
shares the same device tree and is probably affected too (untested).

## Symptom

`logcat` shows, each time Wi-Fi is turned on:

```
android.hardware.wifi-service: Failed to load WiFi driver
WifiNative: Failed to start vendor HAL
```

and `dmesg` (root) shows the cause, at boot:

```
firmware wlan!qca_cld!wlan_mac.bin: firmware_loading_store: map pages failed
wlan: [..:E:HDD] hdd_wlan_startup: Failed to open interfaces: -28
```

## Cause

A boot race on `/mnt/vendor/persist/wlan_mac.bin`:

1. `init.oem.rc` empties the file at every boot.
2. `wifi-mac-generator` rewrites it from the NV items
   `/data/vendor/oemnvitems/4678_0` and `4678_1`, waiting up to ~9 s for each.
   On some phones `4678_1` never appears, so the file is written ~16 s after
   boot.
3. The Wi-Fi driver, built into the kernel, loads at ~15 s. If the file is
   still empty, it has no valid MAC address and aborts. It can't be reloaded,
   so Wi-Fi stays dead until the next reboot.

The margin is under a second, so boot timing decides the outcome. This may be
why an OTA update sometimes brings Wi-Fi back until the next reboot (not
verified).

## Fix

Create the missing `4678_1` file. The generator then writes `wlan_mac.bin`
~7 s after boot, before the driver needs it. The file lives in `/data`: it
survives reboots and OTA updates, but not a factory reset. The second Wi-Fi
MAC (`Intf1`) also stops changing at every boot.

Requirements: `adb`, a Bash shell (Linux, macOS, Git Bash on Windows), and
**Developer options → Rooted debugging** enabled on the phone.

```bash
./fix-wifi.sh                 # diagnose only
./fix-wifi.sh apply --reboot  # apply, then reboot
./fix-wifi.sh undo            # remove the file
```

Add `-s SERIAL` if several devices are connected. Rooted debugging can be
turned off once the fix is applied.

From a root shell on the phone instead (example MAC `C0:EE:FB:CC:BB:AA`,
bytes stored in reverse order), then reboot:

```sh
f=/data/vendor/oemnvitems/4678_1
printf '\xAA\xBB\xCC\xFB\xEE\xC0' > $f
chown radio:radio $f && chmod 0666 $f && restorecon $f
```

## Upstream

The proper fix belongs in the LineageOS device tree: `wifi-mac-generator`
should not wait for an NV item that may not exist, or should finish before the
Wi-Fi driver starts.

## License

MIT
