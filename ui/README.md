# Shadow UI

The UI workspace is the seam between early boot bring-up and the eventual phone shell.

It currently has three layers:

- `crates/shadow-ui-core`: reusable shell state, scene graph, palette, and app metadata
- `crates/shadow-ui-desktop`: fast `winit + wgpu + glyphon` desktop host for iteration
- `crates/shadow-compositor`: Smithay-based nested compositor host for Linux

## Run The Desktop Host

The repo default shell stays pointed at `bootimg` so the existing bring-up workflow does not change.

Use the UI shell explicitly:

```sh
nix develop .#ui
cargo run --manifest-path ui/Cargo.toml -p shadow-ui-desktop
```

Or from the repo root:

```sh
just ui-run
```

## Run The Compositor

On Linux hosts:

```sh
nix develop .#ui
cargo run --manifest-path ui/Cargo.toml -p shadow-compositor
```

Or from the repo root:

```sh
just compositor-run
```

## Controls

- Mouse: hover and click app tiles
- Keyboard: arrow keys or `Tab` to move focus
- Keyboard: `Enter` or `Space` to activate the focused tile
