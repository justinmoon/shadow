# Shadow UI

The UI workspace now supports one shell/app model through two supported surfaces:

- local QEMU VM shell/home plus app launch
- rooted Pixel shell/home plus app launch

`shadow-compositor` backs the nested Linux VM loop. `shadow-compositor-guest` backs direct-display rooted-Pixel sessions. Shared shell/control logic should stay in shared crates instead of diverging by target. The app client that matters for the supported shell/app path is `shadow-blitz-demo` in runtime mode.

## Main Commands

From the repo root:

```sh
just ui-check
just run target=vm app=shell
sc -t vm open counter
just stop target=vm
just smoke target=vm
```

For the rooted Pixel path:

```sh
sc -t pixel prep-settings
sc -t pixel doctor
sc -t pixel stage shell
just run target=pixel app=shell
just stop target=pixel
sc -t pixel ci timeline
```

`just pixel-prep-settings` remains as a convenience wrapper. Rooting/setup commands also live under `sc`: use `sc root-prep` for host-side OTA/Magisk assets and `sc -t pixel root-check`, `root-patch`, `root-flash`, or `ota-sideload` for device-specific setup/recovery.

VM control uses `sc -t vm <subcommand>` in the devshell, or `just shadowctl ...` when `sc` is not on `PATH`. Old `ui-vm-*` / `vm-*` compatibility wrappers have been removed.

## Controls

- Mouse: hover and click app tiles in the VM shell
- Keyboard: arrow keys or `Tab` to move focus
- Keyboard: `Enter` or `Space` to activate the focused tile
