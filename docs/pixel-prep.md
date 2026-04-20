---
summary: Preparing a Pixel 4a for rooted Shadow hardware testing
read_when:
  - preparing a new Pixel for Shadow
  - rooting or re-rooting a Pixel test device
  - Pixel doctor reports missing root or locked bootloader
---

# Pixel Prep

Shadow's hardware lane expects a dedicated Pixel 4a (`sunfish`) on the supported
Android 13 build:

```text
google/sunfish/sunfish:13/TQ3A.230805.001.S2/12655424:user/release-keys
```

Steps marked **[human]** require physical interaction with the phone. Everything
else is run by the agent from the host.

## 1. Pre-Unlock Setup

**[human]** On a fresh or freshly wiped phone:

1. Boot Android and finish initial setup.
2. Join Wi-Fi with internet access.
3. Settings > About phone — tap Build number seven times.
4. Settings > System > Developer options — enable USB debugging.
5. Settings > System > Developer options — enable OEM unlocking.
6. Authorize the USB debugging prompt when the host connects.

Verify the device appears:

```sh
adb devices -l   # new serial should be listed
```

## 2. Bootloader Unlock

Unlocking wipes the phone. Run from host once the serial is visible:

```sh
adb -s "$PIXEL_SERIAL" reboot bootloader
fastboot -s "$PIXEL_SERIAL" flashing unlock
```

**[human]** On the phone: volume buttons to select "Unlock the bootloader",
power to confirm. After the wipe completes, the phone reboots to a red
"fastboot mode" screen — select "Start" to boot Android.

After the wipe, **[human]** repeat section 1 (initial setup, Wi-Fi, dev
options, USB debugging, authorize host).

If fastboot reports unlocking is not allowed, enable OEM unlocking in Developer
options first.

## 3. Root With Magisk

Run from host once USB debugging is re-authorized after the wipe:

```sh
sc root-prep
sc -t <serial> root-patch
sc -t <serial> root-flash
```

**[human]** If `root-patch` fails, patch manually: open Magisk app on the
phone, patch the staged boot image, then run `sc -t <serial> root-flash` from
host.

**[human]** After flash, open Magisk app once if root is not yet available.
Accept "upgrade to full Magisk" and any additional environment fix prompts —
the phone will reboot. After reboot, the first `su` call from the host triggers
a Magisk superuser permission popup on the phone — grant it.

Verify from host:

```sh
sc -t <serial> root-check
sc -t <serial> doctor
```

Expected ready state:

```text
su_available: yes
display_takeover_loop: maybe
boot_image_loop: maybe
```

## 4. Convenience Settings

Run from host:

```sh
sc -t <serial> prep-settings
```

This disables screen lock, screen saver, sets a 30-minute screen timeout, keeps
the display awake while plugged in, and dismisses the keyguard.

`just pixel-prep-settings` remains as a convenience wrapper around the same
`shadowctl` command.

## 5. Smoke Test

Run from host:

```sh
PIXEL_SERIAL=<serial> just pixel-stage shell
PIXEL_SERIAL=<serial> just run target=<serial> app=shell
PIXEL_SERIAL=<serial> just shadowctl state -t <serial>
PIXEL_SERIAL=<serial> just stop target=<serial>
```

Use `just stop target=<serial>` after hold-mode or interrupted runs to restore
Android's display stack.
