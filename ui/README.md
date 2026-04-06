# Shadow UI

The UI workspace now supports one shell/app model through two surfaces:

- `shadow-compositor` inside the QEMU VM shell flow
- `shadow-compositor-guest` on the rooted Pixel DRM flow

The only app client that matters is `shadow-blitz-demo`, running in runtime mode for the demo paths.

## Main Commands

From the repo root:

```sh
just ui-check
just ui-smoke
just ui-vm-run
just ui-vm-open counter
```

For the rooted Pixel path:

```sh
just pixel-build
just pixel-prepare-runtime-app-artifacts
just pixel-runtime-app-drm
```

## Controls

- Mouse: hover and click app tiles in the VM shell
- Keyboard: arrow keys or `Tab` to move focus
- Keyboard: `Enter` or `Space` to activate the focused tile
