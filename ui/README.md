# Shadow UI

The UI workspace now supports one shell/app model through two supported surfaces:

- local QEMU VM shell/home plus app launch
- rooted Pixel shell/home plus app launch

`shadow-compositor` backs the VM loop. `shadow-compositor-guest` backs VM guest and rooted-Pixel sessions. The app client that matters for the supported shell/app path is `shadow-blitz-demo` in runtime mode.

## Main Commands

From the repo root:

```sh
just ui-check
just run target=vm app=shell
just vm-open app=counter
just stop target=vm
just vm-smoke
```

For the rooted Pixel path:

```sh
just pixel-doctor
just pixel-build
just run target=pixel app=shell
just stop target=pixel
just pixel-shell-timeline-smoke
```

Older `vm-*` / `ui-vm-*` names and lower-level runtime/probe commands still exist, but they are no longer the preferred front door.

## Controls

- Mouse: hover and click app tiles in the VM shell
- Keyboard: arrow keys or `Tab` to move focus
- Keyboard: `Enter` or `Space` to activate the focused tile
