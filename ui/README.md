# Shadow UI

Desktop prototype for the Shadow mobile shell.

Workspace layout:

- `shadow-ui-core` for reusable shell and scene state
- `shadow-ui-wgpu` for the shared low-level wgpu + glyphon renderer/text stack
- `shadow-ui-desktop` for the current winit + wgpu host
- `shadow-compositor` for the Linux/Wayland Smithay host
- `shadow-counter` for the demo app: winit/wgpu on desktop hosts, Wayland-native SCTK on Linux
- `shadow-cog-demo` for the browser-engine prototype
- `shadow-blitz-demo` for the Blitz renderer + Deno logic prototype

## Run

The repo default shell stays pointed at `bootimg` so the existing bring-up workflow does not change.

Use the UI shell explicitly:

```sh
nix develop --accept-flake-config .#ui
cd ui
cargo run -p shadow-ui-desktop
```

On Linux/Wayland you can also run:

```sh
cargo run -p shadow-compositor
```

The compositor auto-launches `shadow-counter` when it can find it. Desktop and compositor hosts both resolve app launches from the shared app registry in `shadow-ui-core`, so shell state does not hard-code process launch details.

The counter app itself is intentionally split by host:

- macOS and other non-Linux desktop paths keep the fast `winit` + `wgpu` loop
- Linux uses `smithay-client-toolkit` + `wl_shm` so the first demo app is a real Wayland client

The two newer demos keep the same shell/compositor launch seam while swapping renderer strategy:

- `shadow-cog-demo` execs a minimal browser binary against bundled HTML/CSS/JS assets to prove the browser-engine path
- `shadow-blitz-demo` keeps state in a Deno TypeScript process and applies returned HTML/CSS to a native Blitz document

The Blitz demo is intentionally pre-incremental today: TypeScript owns the state, polls a simple event mailbox for native clicks, and emits full HTML/CSS swaps back over stdout. That is enough to prove the control path before it proves a finer-grained mutation protocol.

## Local VM

On macOS, the preferred compositor loop is the local VM:

```sh
just ui-vm-run
```

That launches a Linux guest in a native macOS window using `microvm.nix` with QEMU/HVF and a Cocoa display backend. QEMU is the chosen host path here because it gives us both a native window on macOS and a simple 9p live share of this repo into the guest, which keeps the compositor loop tight while the codebase is still moving quickly. The guest shares this live worktree into `/work/shadow`, autologins through `greetd`, starts a dedicated `weston` session, rotates the virtual output into portrait mode so the phone shell fits cleanly, and runs `shadow-ui-desktop` as a normal Wayland client inside that session.

The VM recreates its writable `/nix/store` overlay on each boot. Guest persistence lives in `.shadow-vm/shadow-ui-state.img`, which keeps the Cargo target dir, app state, and guest logs warm across restarts. The guest session runs `cargo run --locked --manifest-path ui/Cargo.toml -p shadow-ui-desktop` directly inside the shared repo; it does not shell into a nested guest `nix develop`.

To stop it cleanly from another terminal:

```sh
just ui-vm-stop
```

To inspect or debug the guest:

```sh
just ui-vm-ssh
just ui-vm-logs
just ui-vm-status
just ui-vm-journal
just ui-vm-cog-run
just ui-vm-blitz-run
```

The first guest boot or the first launch after dependency changes can spend some time compiling the compositor, shell, and demo apps inside the VM before the UI appears.

Each worktree now gets its own VM identity: process name, SSH port, QMP socket, and `shadowctl` state are all scoped to the current checkout, so you can run two `ui-vm-run` sessions concurrently from different worktrees without cross-talk.

The expected Linux flow is now:

- VM boots into a portrait `weston` session with the home shell visible
- click `Web`, `Blitz`, `Counter`, or `Status` to open a demo app
- the direct guest launch helpers can also start `shadow-cog-demo` and `shadow-blitz-demo` without going through the shell
- app windows are ordinary Wayland clients in the same `weston` session; there is no compositor control socket in this demo path

If the shell is still compiling or you want to bypass it entirely, the guest launch recipes above start the two prototype apps directly against the running compositor using the same cached Cargo target dir and runtime library environment as the main guest session.

## Nested Compositor

The next bridge step keeps `weston` as the stable outer guest compositor and runs `shadow-compositor` as a nested Wayland client inside it.

Start the nested compositor:

```sh
just ui-vm-shadow-run
just ui-vm-shadow-status
just ui-vm-shadow-logs
```

Then launch a simple app into the nested compositor:

```sh
just ui-vm-shadow-counter-run
just ui-vm-shadow-status-run
```

That path writes a second guest env file at `/var/lib/shadow-ui/shadow-compositor-session-env.sh` with the nested `WAYLAND_DISPLAY` and compositor control socket. `ui-vm-shadow-stop` stops just the nested compositor without rebooting the VM.

In the current Nix guest this browser-engine prototype uses `epiphany` (WebKitGTK). `nixpkgs` ships an unrelated Grafana CLI as `cog`, so the Igalia Cog/WPE launcher is not available out of the box in this environment.

Fastest guest debug loop:

```sh
just ui-vm-status
just ui-vm-doctor
just ui-vm-logs
just ui-vm-journal
just ui-vm-screenshot
just ui-vm-shadow-doctor
scripts/shadowctl shadow status
just ui-vm-ssh 'ps -ef | grep shadow-'
```

`scripts/shadowctl` is a branch-local VM inspector copied from the root repo tooling and adapted for this worktree. Use `scripts/shadowctl vm status`, `scripts/shadowctl vm screenshot`, `scripts/shadowctl shadow status`, and `scripts/shadowctl shadow doctor` when you need a single CLI for the outer Weston session plus the nested `shadow-compositor` path.

## Controls

- Mouse: hover and click app tiles
- Keyboard: arrow keys or `Tab` to move focus
- Keyboard: `Enter` or `Space` to activate the focused tile
