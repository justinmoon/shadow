set export

export CUTTLEFISH_REMOTE_HOST := env_var_or_default("CUTTLEFISH_REMOTE_HOST", "justin@100.73.239.5")
export SHADOW_UI_REMOTE_HOST := env_var_or_default("SHADOW_UI_REMOTE_HOST", CUTTLEFISH_REMOTE_HOST)

# Show available commands
default:
	@just --list

# Boot stock Cuttlefish on Hetzner
cf-stock:
	@scripts/cf_stock.sh

# Fetch and cache the stock boot artifacts locally
artifacts-fetch:
	@scripts/artifacts_fetch.sh

# Rebuild init_boot.img without changing behavior
init-boot-repack:
	@scripts/init_boot_repack.sh

# Build the Rust init wrapper binary
build-init-wrapper:
	@scripts/build_init_wrapper.sh

# Build the early DRM demo binary
build-drm-rect:
	@scripts/build_drm_rect.sh

# Build the late-start guest session binary
build-shadow-session:
	@scripts/build_shadow_session.sh

# Rebuild init_boot.img with the Rust chainloading wrapper
init-boot-wrapper:
	@scripts/init_boot_wrapper.sh

# Rebuild init_boot.img with the Rust wrapper plus drm-rect payload (experimental)
init-boot-drm-rect:
	@scripts/init_boot_drm_rect.sh

# Rebuild init_boot.img with the Rust wrapper plus the guest compositor/client payloads (experimental)
init-boot-guest-ui:
	@scripts/init_boot_guest_ui.sh

# Boot Cuttlefish with the repacked init_boot image
cf-repacked-initboot:
	@scripts/cf_repacked_initboot.sh

# Boot Cuttlefish with the Rust chainloading wrapper as /init
cf-init-wrapper:
	@scripts/cf_init_wrapper.sh

# Boot stock Cuttlefish, then launch shadow-session + drm-rect via adb root
cf-drm-rect:
	@scripts/cf_drm_rect.sh

# Boot stock Cuttlefish, then launch the guest compositor/client via adb root and save the captured frame artifact
cf-guest-ui-smoke:
	@scripts/cf_guest_ui_smoke.sh

# Boot stock Cuttlefish, then launch the guest compositor/client with DRM presentation enabled
cf-guest-ui-drm-smoke:
	@SHADOW_GUEST_COMPOSITOR_ENABLE_DRM=1 scripts/cf_guest_ui_smoke.sh

# Prune stale Cuttlefish instances on the remote host
cf-prune:
	@scripts/cf_prune.sh

# Show launcher, kernel, and console logs for the active instance
cf-logs kind="all":
	@scripts/cf_logs.sh --kind "{{kind}}"

# Follow logs for the active instance
cf-logs-follow kind="kernel":
	@scripts/cf_logs.sh --follow --kind "{{kind}}"

# Destroy the active instance on Hetzner
cf-kill:
	@scripts/cf_kill.sh

# Run UI formatting, tests, and compile checks
ui-check:
	@scripts/ui_check.sh

# Enter the Nix shell for the runtime / V8 exploration lane
runtime-shell:
	@nix develop .#runtime

# Run the minimal Rusty V8 smoke binary on the current host
runtime-rusty-v8-smoke:
	@nix run --accept-flake-config .#rusty-v8-smoke

# Run the minimal Deno Core smoke binary on the current host
runtime-deno-core-smoke:
	@nix run --accept-flake-config .#deno-core-smoke

# Run the host-only Solid TSX compile smoke
runtime-app-compile-smoke:
	@nix develop .#runtime -c scripts/runtime_app_compile_smoke.sh

# Run the first app document payload through the Deno Core host seam
runtime-app-document-smoke:
	@nix develop .#runtime -c scripts/runtime_app_document_smoke.sh

# Run the first host-dispatched click through the bundled app runtime seam
runtime-app-click-smoke:
	@nix develop .#runtime -c scripts/runtime_app_click_smoke.sh

# Run the first host-dispatched change event through the bundled app runtime seam
runtime-app-input-smoke:
	@nix develop .#runtime -c scripts/runtime_app_input_smoke.sh

# Run the fixed-frame Blitz document smoke for app payload swapping
runtime-app-blitz-document-smoke:
	@scripts/runtime_app_blitz_document_smoke.sh

# Run the host-visible runtime demo window
runtime-app-host-run:
	@scripts/runtime_app_host_run.sh

# Run the host-visible runtime demo with an auto-exit smoke timer
runtime-app-host-smoke:
	@scripts/runtime_app_host_smoke.sh

# Build the minimal Rusty V8 smoke binary for x86_64 Linux
runtime-rusty-v8-smoke-x86_64-linux-gnu:
	@nix build --accept-flake-config .#rusty-v8-smoke-x86_64-linux-gnu

# Build the minimal Deno Core smoke binary for x86_64 Linux
runtime-deno-core-smoke-x86_64-linux-gnu:
	@nix build --accept-flake-config .#deno-core-smoke-x86_64-linux-gnu

# Build the minimal Rusty V8 smoke binary for aarch64 Linux
runtime-rusty-v8-smoke-aarch64-linux-gnu:
	@nix build --accept-flake-config .#rusty-v8-smoke-aarch64-linux-gnu

# Build the minimal Deno Core smoke binary for aarch64 Linux
runtime-deno-core-smoke-aarch64-linux-gnu:
	@nix build --accept-flake-config .#deno-core-smoke-aarch64-linux-gnu

# Run the Shadow desktop UI host
ui-run:
	@nix develop .#ui -c cargo run --manifest-path ui/Cargo.toml -p shadow-ui-desktop

# Run the nested compositor and demo app under a headless Linux host
ui-smoke:
	@scripts/ui_smoke.sh

# Run the local Linux UI VM in a native macOS window
ui-vm-run:
	@scripts/ui_vm_run.sh

# Stop the local Linux UI VM
ui-vm-stop:
	@scripts/ui_vm_stop.sh

# SSH into the local Linux UI VM
ui-vm-ssh *args='':
	@scripts/ui_vm_ssh.sh {{args}}

# Show the guest compositor session log
ui-vm-logs:
	@scripts/ui_vm_logs.sh

# Show guest smoke status and relevant Shadow UI processes
ui-vm-status:
	@scripts/ui_vm_status.sh

# Show guest greetd and smoke-service journal output
ui-vm-journal:
	@scripts/ui_vm_journal.sh

# Diagnose the local UI VM via shadowctl
ui-vm-doctor:
	@scripts/shadowctl vm doctor

# Show machine-readable UI VM state
ui-vm-state:
	@scripts/shadowctl vm state --json

# Wait for the UI VM session to reach steady state
ui-vm-wait-ready:
	@scripts/shadowctl vm wait-ready

# Save a screenshot of the local UI VM window via QMP
ui-vm-screenshot output="build/ui-vm/shadow-ui-vm.ppm":
	@scripts/shadowctl vm screenshot "{{output}}"

# Ask the compositor to open an app by ID
ui-vm-open app="counter":
	@scripts/shadowctl vm open "{{app}}"

# Ask the compositor to shelf the foreground app and return home
ui-vm-home:
	@scripts/shadowctl vm home

# Query the local UI VM via shadowctl
shadowctl *args='':
	@scripts/shadowctl {{args}}

# Launch a cargo package inside the running UI VM compositor session
ui-vm-app-run package:
	@scripts/ui_vm_app_run.sh {{package}}

# Launch the counter app inside the running UI VM compositor session
ui-vm-counter-run:
	@scripts/ui_vm_app_run.sh shadow-counter

# Inspect the connected Pixel and report whether the post-boot loop can run
pixel-doctor:
	@scripts/pixel_doctor.sh

# Build arm64 device artifacts for the Pixel loop
pixel-build:
	@scripts/pixel_build.sh

# Build the arm64 Blitz demo artifact for the rooted Pixel path
pixel-build-blitz-demo:
	@scripts/pixel_build_blitz_demo.sh

# Push the latest arm64 device artifacts to the connected Pixel
pixel-push:
	@scripts/pixel_push.sh

# Run the post-boot guest compositor plus counter demo on the connected Pixel
pixel-run:
	@scripts/pixel_run.sh

# Verify the latest Pixel run artifacts or the provided run directory
pixel-verify run_dir="":
	@PIXEL_RUN_DIR="{{run_dir}}" scripts/pixel_verify.sh

# Retry the Pixel post-boot loop until it succeeds or hits the configured limit
pixel-loop:
	@scripts/pixel_loop.sh

# Stop the Android display stack on the rooted Pixel and run the direct DRM takeover proof
pixel-drm-rect:
	@scripts/pixel_drm_rect.sh

# Stop the Android display stack on the rooted Pixel, run the direct DRM takeover proof, and leave Android stopped
pixel-drm-rect-hold:
	@PIXEL_TAKEOVER_RESTORE_ANDROID= SHADOW_DRM_RECT_HOLD_SECS=600 scripts/pixel_drm_rect.sh

# Stop the Android display stack on the rooted Pixel and run the guest compositor plus client on the real panel
pixel-guest-ui-drm:
	@scripts/pixel_guest_ui_drm.sh

# Stop the Android display stack on the rooted Pixel and run the guest compositor DRM self-test on the real panel
pixel-guest-ui-drm-selftest:
	@scripts/pixel_guest_ui_drm_selftest.sh

# Stop the Android display stack on the rooted Pixel and run a full-screen guest client pattern on the real panel
pixel-guest-ui-drm-fullscreen:
	@scripts/pixel_guest_ui_drm_fullscreen.sh

# Stop the Android display stack on the rooted Pixel and run a centered 384x720 guest client pattern on the real panel
pixel-guest-ui-drm-blitz-size:
	@scripts/pixel_guest_ui_drm_blitz_size.sh

# Stop the Android display stack on the rooted Pixel, run the guest compositor plus client on the real panel, and leave Android stopped
pixel-guest-ui-drm-hold:
	@PIXEL_TAKEOVER_RESTORE_ANDROID= scripts/pixel_guest_ui_drm.sh

# Stop the Android display stack on the rooted Pixel, run the guest compositor DRM self-test on the real panel, and leave Android stopped
pixel-guest-ui-drm-selftest-hold:
	@PIXEL_TAKEOVER_RESTORE_ANDROID= PIXEL_GUEST_SESSION_TIMEOUT_SECS= PIXEL_GUEST_COMPOSITOR_EXIT_ON_FIRST_FRAME= scripts/pixel_guest_ui_drm_selftest.sh

# Stop the Android display stack on the rooted Pixel, run a full-screen guest client pattern on the real panel, and leave Android stopped
pixel-guest-ui-drm-fullscreen-hold:
	@PIXEL_TAKEOVER_RESTORE_ANDROID= PIXEL_GUEST_SESSION_TIMEOUT_SECS= PIXEL_GUEST_COMPOSITOR_EXIT_ON_FIRST_FRAME= PIXEL_GUEST_CLIENT_EXIT_ON_CONFIGURE= scripts/pixel_guest_ui_drm_fullscreen.sh

# Stop the Android display stack on the rooted Pixel, run a centered 384x720 guest client pattern on the real panel, and leave Android stopped
pixel-guest-ui-drm-blitz-size-hold:
	@PIXEL_TAKEOVER_RESTORE_ANDROID= PIXEL_GUEST_SESSION_TIMEOUT_SECS= PIXEL_GUEST_COMPOSITOR_EXIT_ON_FIRST_FRAME= PIXEL_GUEST_CLIENT_EXIT_ON_CONFIGURE= scripts/pixel_guest_ui_drm_blitz_size.sh

# Run the static Blitz demo on the rooted Pixel through the guest compositor DRM path
pixel-blitz-demo-drm:
	@scripts/pixel_blitz_demo_drm.sh

# Run the static-only Blitz demo on the rooted Pixel through the guest compositor DRM path
pixel-blitz-demo-static-drm:
	@scripts/pixel_blitz_demo_static_drm.sh

# Run the static Blitz demo on the rooted Pixel through the guest compositor DRM path and leave Android stopped
pixel-blitz-demo-drm-hold:
	@PIXEL_TAKEOVER_RESTORE_ANDROID= PIXEL_GUEST_SESSION_TIMEOUT_SECS= PIXEL_BLITZ_EXIT_DELAY_MS=600000 scripts/pixel_blitz_demo_drm.sh

# Run the static-only Blitz demo on the rooted Pixel through the guest compositor DRM path and leave Android stopped
pixel-blitz-demo-static-drm-hold:
	@PIXEL_TAKEOVER_RESTORE_ANDROID= PIXEL_GUEST_SESSION_TIMEOUT_SECS= PIXEL_BLITZ_EXIT_DELAY_MS= scripts/pixel_blitz_demo_static_drm.sh

# Restore the Android display stack after a hold-mode rooted takeover run
pixel-restore-android:
	@scripts/pixel_restore_android.sh

# Download/cache the official Pixel 4a OTA, extract boot.img, and fetch the latest Magisk APK
pixel-root-prep:
	@scripts/pixel_root_prep.sh

# Reboot to recovery and sideload the cached official Pixel 4a OTA once the phone enters adb sideload mode
pixel-ota-sideload:
	@scripts/pixel_ota_sideload.sh

# Run Magisk's boot patcher non-interactively on the device and pull the patched boot image locally
pixel-root-patch:
	@scripts/pixel_root_patch.sh

# Manual fallback: install Magisk on the phone and push the exact stock boot.img into Downloads for patching
pixel-root-stage:
	@scripts/pixel_root_stage.sh

# Flash the locally prepared patched boot image and reboot back to Android
pixel-root-flash:
	@scripts/pixel_root_flash.sh

# Verify whether root is active on the connected Pixel
pixel-root-check:
	@scripts/pixel_root_check.sh

# Run the minimal Deno Core smoke binary on the rooted Pixel through the GNU runtime envelope
pixel-runtime-deno-core-smoke:
	@scripts/pixel_runtime_deno_core_smoke.sh

# Stage the runtime app bundle plus GNU-wrapped deno_core helper for Pixel use
pixel-prepare-runtime-app-artifacts:
	@scripts/pixel_prepare_runtime_app_artifacts.sh

# Run the runtime-mode Blitz demo on the rooted Pixel through the guest compositor DRM path
pixel-runtime-app-drm:
	@scripts/pixel_runtime_app_drm.sh

# Run the runtime-mode Blitz demo on the rooted Pixel and auto-dispatch one runtime click
pixel-runtime-app-click-drm:
	@scripts/pixel_runtime_app_click_drm.sh

# Run the nested Smithay compositor host on Linux
compositor-run:
	@nix develop .#ui -c cargo run --manifest-path ui/Cargo.toml -p shadow-compositor

# Run the fast local verification gate
pre-commit:
	@scripts/pre_commit.sh

# Run the full verification gate, including Hetzner boot smokes
ci:
	@scripts/ci.sh
