# Shadow Product Boot Mode

Living plan. Revise it as we learn. Do not treat this as a fixed contract.

## Intent

Make the owned Shadow boot path serve two worlds from one codebase:

- Lab mode: current proof, probe, watchdog, recovery, and forced-reboot behavior stays available for hardware experiments and CI.
- Product mode: a Pixel boots into Shadow, stays running unplugged, recovers local crashes, supports basic device controls, and can be carried as a conference demo without a laptop.

The first product target is a conference-ready Pixel 4a that boots to the Shadow home screen, has all demo apps installed, connects to Wi-Fi from credentials staged before flashing, can turn the screen off in a pocket, recovers compositor crashes, and leaves stock Android available on the other A/B slot for recovery.

## Scope

In scope:

- Split `hello-init.rs` into focused Rust modules without changing lab behavior first.
- Add an explicit runtime boot profile, defaulting existing configs to lab mode.
- Add product PID1 behavior that does not reboot on success, timeout, or compositor crash.
- Supervise `shadow-session` / compositor and restart it with backoff when it crashes.
- Support short power-button press as screen on/off.
- Add a `just` product-flash command that delegates to `sc` and flashes a persistent conference-ready boot image.
- Keep stock Android on the non-Shadow slot.
- Stage Wi-Fi credentials from the host before flashing for the conference path.

Out of scope for the first product seam:

- Removing lab proof/recovery features.
- Forking separate lab and product init binaries.
- Compiling out lab code with a Cargo feature as the primary mode split.
- Productizing camera HAL probes.
- Replacing the whole runtime service model before the conference demo works.
- Long-press power shutdown.
- Rust settings app Wi-Fi credential management.
- Live battery/Wi-Fi status in the shell.

## Decisions

- Use one `hello-init` binary with runtime mode selection, e.g. `boot_mode=lab|product`.
- Existing configs default to `lab`.
- Product images opt in to `product`.
- Keep proof, probe, watchdog, and reboot policy under lab ownership.
- Use `just product-flash ...` as the public operator command; it should call the underlying `sc -t pixel product flash ...` implementation.
- Product mode boots to the home screen, not directly into Timeline.
- Product payload installs all current demo apps.
- Conference Wi-Fi credentials are staged from the host before flashing, reusing the current boot-owned credential mechanism where practical.
- A Rust settings app for Wi-Fi and poweroff is Part 2 product work, not a conference blocker.
- The physical power button only toggles screen state for now.

## Part 1: Conference Demo

Goal: one command prepares a Pixel that can be carried around unplugged, boots to Shadow home, keeps running, reconnects Wi-Fi from staged credentials, turns the screen off/on, and recovers compositor crashes without a laptop.

### 1. Refactor First, Preserve Lab

[ ] Move `rust/init-wrapper/src/bin/hello-init.rs` into a small binary plus library modules.

Initial module boundaries:

- `entry`: PID1 top-level flow and mode dispatch.
- `config`: typed config structs, parser, defaults, and validation.
- `log`: kmsg/pmsg/stdout logging helpers.
- `mounts`: `/dev`, `/proc`, `/sys`, tmpfs, and mount helpers.
- `devices`: device node, binder, DRI, input, and block-device setup.
- `payload`: logical partition, liblp, dm-linear, archive expansion.
- `metadata`: metadata mounts, breadcrumbs, and runtime file helpers.
- `process`: child spawning, waiting, restart policy, and watchdog primitives.
- `firmware`: firmware helper setup.
- `network`: Wi-Fi helper graph, DHCP, DNS, and runtime network state.
- `lab`: current probe modes, proof summaries, watchdog classification, held observation, and forced reboot.
- `product`: non-rebooting supervisor, product status, and later settings/control hooks.
- `reboot`: raw reboot, halt, poweroff, and bootloader transitions.

Acceptance:

- Existing lab boot configs produce the same observable behavior.
- Current smoke/proof checks still pass.
- Active sibling worktrees have smaller future conflict surfaces than the current single-file init.

### 2. Add Boot Profiles

[ ] Add `boot_mode=lab|product` to `shadow-init.cfg` parsing.

Acceptance:

- Missing `boot_mode` means `lab`.
- Invalid mode fails early with a clear log message.
- Lab mode preserves existing `orange_gpu_mode`, watchdog, timeout action, proof, and reboot semantics.
- Product mode rejects or ignores lab-only proof/watchdog settings deliberately, not accidentally.

### 3. Product PID1 Runtime

[ ] Implement product mode as a long-running supervisor.

Behavior:

- Mount and bootstrap the same shared OS substrate as lab mode.
- Expand/use the same Shadow payload.
- Bring up runtime Wi-Fi services when configured.
- Launch `shadow-session` with a product startup config.
- Restart `shadow-session` after unexpected exit, with bounded backoff and crash logging.
- Keep running indefinitely.
- Do not call lab forced-reboot paths.

Acceptance:

- Killing the compositor/session causes restart without fastboot, USB, or Android recovery.
- Product mode can run unplugged without watchdog reboot.
- Basic product status logs remain available through kmsg/pmsg.

### 4. Product Display And Power Controls

[ ] Add physical power-button short press handling in the compositor input path.

Behavior:

- Short press toggles screen off/on.
- Long press has no shutdown action in the conference version.
- Poweroff from the Shadow settings app is deferred to Part 2.

Implementation notes:

- Generalize the current media-key reader to handle system keys including Linux `KEY_POWER`.
- Add KMS display on/off support, preferring DRM/KMS blanking over backlight-only fallback.

Acceptance:

- Screen can be turned off while Shadow keeps running.
- Screen resumes cleanly on the next short power press.

### 5. Product Flash Command

[ ] Add a public `just product-flash ...` command that calls `sc -t pixel product flash ...`.

Behavior:

- Build product boot image.
- Stage/install full Shadow payload and all current apps.
- Stage Wi-Fi credentials from a host file or environment before activating the Shadow slot.
- Flash the inactive slot and activate it.
- Preserve stock Android on the other slot.
- Print the Android recovery slot and the Shadow slot clearly.
- Avoid proof recovery as the success condition.

Implementation notes:

- Reuse the current host-staged credential path for the conference version.
- The product command may require the phone to be in Android/rooted adb mode before flashing so credentials can be staged once.

Acceptance:

- One command can prepare a conference-ready Pixel.
- The command refuses to overwrite the active Android slot without an explicit override.
- Existing lab `fastboot boot` and flashed-slot probe scripts keep their current semantics.
- Timeline can fetch live Nostr notes after boot when credentials were staged.

## Part 2: Product Settings And Live Status

Goal: remove host-side configuration assumptions and make the product self-managing after the conference demo path is reliable.

### 6. Settings App And Privileged Control

[ ] Add a Rust settings app path for Wi-Fi credentials and poweroff.

Behavior:

- User can set SSID/passphrase on device.
- Product boot consumes persisted credentials and reconnects automatically.
- User can power off from settings.

Implementation notes:

- Do not make the UI app write `/metadata` or boot config directly.
- Add a small privileged settings service or PID1 control API to validate and persist Wi-Fi config and accept shutdown requests.
- Keep the existing lab one-shot credential staging available for probes.

Acceptance:

- Product image can be configured once on device, rebooted, and reconnect without host staging.
- Poweroff from settings shuts down cleanly.
- Lab Wi-Fi proof mode remains unchanged.

### 7. Replace Demo-Shaped Runtime State

[ ] Replace static shell battery/Wi-Fi demo values with product status.

Implementation notes:

- Product PID1 or a small system service should read `/sys/class/power_supply/*` periodically.
- Publish battery, charging, network, and crash/restart status to a runtime file or socket.
- Shell/system chrome should consume live status instead of `ShellStatus::demo`.

Acceptance:

- Shell shows real battery state on device.
- Wi-Fi status reflects product runtime network state.

## Validation

[ ] Refactor gate: `cargo check --manifest-path rust/init-wrapper/Cargo.toml --bin hello-init`.
[ ] Fast local gate: `just pre-commit`.
[ ] Lab regression: current orange GPU / shell-session boot smokes still pass.
[ ] Product smoke: build a product config and verify it does not select lab watchdog/reboot behavior.
[ ] Part 1 hardware product run: persistent flash to inactive slot, unplug, boot to Shadow home, screen off/on, reconnect Wi-Fi from staged credentials, open Timeline, kill compositor and observe restart, recover Android from the other slot.
[ ] Part 2 hardware product run: configure Wi-Fi on device, reboot and reconnect without host staging, power off from settings, show real battery/Wi-Fi status.

## Implementation Notes

- Sibling worktrees are actively changing `hello-init.rs` for demo app, camera, and Wi-Fi work. The module split should happen before adding much product behavior.
- Camera remains lab/probe-only for the first product seam.
- The current full-demo runner is useful as a source of payload/profile requirements, but product success must not depend on held observation or recovered proof artifacts.
- Settings app Wi-Fi and live shell status are product-quality improvements, but they should not block the conference demo.
- Avoid renaming every `orange_gpu` key in the first pass; stabilize behavior first, then clean up naming with compatibility shims.
