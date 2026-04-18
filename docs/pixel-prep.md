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

Use an explicit serial whenever more than one phone is plugged in:

```sh
export PIXEL_SERIAL=<serial>
adb devices -l
```

## Android Setup

These steps are manual on a fresh or freshly wiped phone:

1. Boot Android and finish setup.
2. Join Wi-Fi with internet access.
3. Open Settings > About phone, tap Build number seven times to enable
   Developer options.
4. Open Settings > System > Developer options.
5. Enable USB debugging.
6. Enable OEM unlocking. This is required before `fastboot flashing unlock`.
7. When the host prompts for USB debugging authorization, allow it.
8. For a dedicated test phone, set Security > Screen lock to None or Swipe.
9. Disable Screen saver in Settings > Display > Screen saver.
10. Set a long screen timeout, or use Developer options > Stay awake.

After USB debugging is authorized, apply the non-root convenience settings from
the host:

```sh
PIXEL_SERIAL=<serial> just pixel-prep-settings
```

That keeps the display awake while plugged in, sets a 30-minute screen timeout,
turns off Android screen saver activation, wakes the device, and dismisses the
keyguard when Android allows it.

## Bootloader Unlock

Unlocking the bootloader wipes the phone. Do this only after USB debugging is
working and OEM unlocking is enabled:

```sh
adb -s "$PIXEL_SERIAL" reboot bootloader
fastboot -s "$PIXEL_SERIAL" flashing unlock
```

Confirm the unlock on the phone with the volume and power buttons. After the
wipe, boot Android again and repeat the Android setup section because USB
debugging and the convenience settings are reset.

If fastboot reports that unlocking is not allowed, boot Android and enable OEM
unlocking in Developer options.

## Root With Magisk

Once the bootloader is unlocked and Android USB debugging is authorized again:

```sh
sc root-prep
sc -t <serial> root-patch
sc -t <serial> root-flash
```

If `pixel-root-patch` fails, use the manual fallback:

```sh
PIXEL_SERIAL=<serial> scripts/pixel/pixel_root_stage.sh
```

Then patch the staged boot image in the Magisk app on the phone, and run:

```sh
sc -t <serial> root-flash
```

After the patched boot image is flashed, open the Magisk app once if root is not
available yet. Accept any additional setup or environment fix, let the phone
reboot, and verify:

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

## Smoke Test

After root is available:

```sh
PIXEL_SERIAL=<serial> just pixel-stage shell
PIXEL_SERIAL=<serial> just run target=<serial> app=shell
PIXEL_SERIAL=<serial> just shadowctl state -t <serial>
PIXEL_SERIAL=<serial> just stop target=<serial>
```

Use `just stop target=<serial>` after hold-mode or interrupted runs to restore
Android's display stack.
