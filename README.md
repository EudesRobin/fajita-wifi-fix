# fajita-wifi-fix

Workaround for Wi-Fi that refuses to turn on (it switches itself back off after
about 20 seconds) on **LineageOS 22.x for the OnePlus 6T (`fajita`)**. It
probably also applies to the OnePlus 6 (`enchilada`), which shares the same
device tree, but this is untested.

## Symptom

- Turning Wi-Fi on does nothing, or the toggle flips back off after ~20 s.
- The problem persists across reboots. Installing an OTA update sometimes brings
  Wi-Fi back until the next reboot.
- `logcat` shows:

  ```
  android.hardware.wifi-service: Failed to write driver state control param: Invalid argument
  android.hardware.wifi-service: Failed to load WiFi driver
  WifiNative: Failed to start vendor HAL
  ```

- The kernel log (`dmesg`, root needed) shows the real cause during boot:

  ```
  firmware wlan!qca_cld!wlan_mac.bin: firmware_loading_store: map pages failed
  wlan: [..:E:HDD] __wlan_hdd_validate_mac_address: MAC is Multicast (via hdd_open_adapter)
  wlan: [..:E:HDD] hdd_wlan_startup: Failed to open interfaces: -28
  ```

  followed by `Timed-out in wlan_hdd_state_ctrl_param_write` each time Wi-Fi
  is turned on.

## Root cause: a boot race on `wlan_mac.bin`

1. On `post-fs`, the vendor `init.oem.rc` empties
   `/mnt/vendor/persist/wlan_mac.bin`.
2. On `post-fs-data`, `/vendor/bin/wifi-mac-generator` rebuilds that file from
   the NV items `/data/vendor/oemnvitems/4678_0` and `4678_1` (the two WLAN
   MAC addresses). It waits up to ~10 s for each file to appear.
3. On some phones `4678_1` is never created, so the generator always waits
   ~9 s for nothing before falling back to a random address. It then writes
   the file about 16 s after boot.
4. The Wi-Fi driver (qcacld, built into the kernel) starts as soon as the WLAN
   firmware is ready, about 15 s after boot. If the file is still empty, the
   driver gets no valid MAC address and aborts its startup. Because the driver
   is built into the kernel, it cannot be reloaded: Wi-Fi stays dead until the
   next reboot.

The gap is only ~0.5–1 s, so any change in boot timing (a crash, an OTA's first
boot, background work) can flip the result. That fits the "fixed by an OTA,
broken again on the next reboot" pattern, but this explanation of the OTA
effect has not been verified.

## Fix

Create the missing `4678_1` NV item file. The generator then finds both files
immediately and writes `wlan_mac.bin` about 7 s after boot, well before the
driver needs it. The file lives in `/data`, so it survives reboots and OTA
updates. A factory reset removes it. As a side effect, the second Wi-Fi
interface MAC (`Intf1`) stays the same across boots instead of being
randomized at every boot.

### Requirements

- `adb` on a computer, with the phone connected over USB and USB debugging
  enabled.
- **Settings → System → Developer options → Rooted debugging** enabled
  (available on official LineageOS builds; Magisk is not needed).
- A Bash shell: Linux, macOS, or Git Bash on Windows.

### Usage

```bash
./fix-wifi.sh            # diagnose only (default: check)
./fix-wifi.sh apply --reboot
./fix-wifi.sh check      # after the reboot: "Wifi is enabled"
./fix-wifi.sh undo       # remove the file again
```

Add `-s SERIAL` when several devices are connected. Rooted debugging can be
turned off again once the fix is applied.

Without a computer, the same fix can be applied from a root shell on the phone:

```sh
printf '\xAA\xBB\xCC\xFB\xEE\xC0' > /data/vendor/oemnvitems/4678_1   # MAC C0:EE:FB:CC:BB:AA, bytes reversed
chown radio:radio /data/vendor/oemnvitems/4678_1
chmod 0666 /data/vendor/oemnvitems/4678_1
restorecon /data/vendor/oemnvitems/4678_1
```

Then reboot.

## Proper upstream fix

The real fix belongs in the device tree. For example, `wifi-mac-generator`
could stop waiting for an NV item that does not exist, or the generator could
be made to complete before the WLAN driver is allowed to start. The boot log
also shows the generator being denied `getattr` on `wlan_mac.bin`
(`mnt_vendor_file` label), which is harmless here because the file is emptied
at every boot anyway.

## Tested on

| Device | Build | Result |
|---|---|---|
| OnePlus 6T (`fajita`) | LineageOS 22.2-20261006-NIGHTLY | Wi-Fi back after reboot |

## License

MIT
