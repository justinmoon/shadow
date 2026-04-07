set export

export CUTTLEFISH_REMOTE_HOST := env_var_or_default("CUTTLEFISH_REMOTE_HOST", "justin@100.73.239.5")
export SHADOW_UI_REMOTE_HOST := env_var_or_default("SHADOW_UI_REMOTE_HOST", CUTTLEFISH_REMOTE_HOST)

# Show available commands
default:
	@just --list

# Run the fast local gate
pre-commit:
	@scripts/pre_commit.sh

# Run the canonical repo verification gate
ci:
	@scripts/ci.sh

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

# Run the minimal Deno Runtime smoke binary on the current host
runtime-deno-runtime-smoke:
	@nix run --accept-flake-config .#deno-runtime-smoke

# Run the host-only Solid TSX compile smoke
runtime-app-compile-smoke:
	@nix develop .#runtime -c scripts/runtime_app_compile_smoke.sh

# Run the first app document payload through the selected host seam
runtime-app-document-smoke backend="deno-core":
	@SHADOW_RUNTIME_HOST_BACKEND="{{backend}}" nix develop .#runtime -c scripts/runtime_app_document_smoke.sh

# Run the first app document payload through the Deno Runtime host seam
runtime-app-document-smoke-deno-runtime:
	@just runtime-app-document-smoke deno-runtime

# Run the first host-dispatched click through the selected bundled app runtime seam
runtime-app-click-smoke backend="deno-core":
	@SHADOW_RUNTIME_HOST_BACKEND="{{backend}}" nix develop .#runtime -c scripts/runtime_app_click_smoke.sh

# Run the first host-dispatched click through the bundled app runtime seam on Deno Runtime
runtime-app-click-smoke-deno-runtime:
	@just runtime-app-click-smoke deno-runtime

# Run the first host-dispatched change event through the selected bundled app runtime seam
runtime-app-input-smoke backend="deno-core":
	@SHADOW_RUNTIME_HOST_BACKEND="{{backend}}" nix develop .#runtime -c scripts/runtime_app_input_smoke.sh

# Run the first host-dispatched change event through the bundled app runtime seam on Deno Runtime
runtime-app-input-smoke-deno-runtime:
	@just runtime-app-input-smoke deno-runtime

# Run the focus -> input -> blur text behavior smoke through the selected bundled app runtime seam
runtime-app-focus-smoke backend="deno-core":
	@SHADOW_RUNTIME_HOST_BACKEND="{{backend}}" nix develop .#runtime -c scripts/runtime_app_focus_smoke.sh

# Run the focus -> input -> blur text behavior smoke through the bundled app runtime seam on Deno Runtime
runtime-app-focus-smoke-deno-runtime:
	@just runtime-app-focus-smoke deno-runtime

# Run the checkbox / boolean form smoke through the selected bundled app runtime seam
runtime-app-toggle-smoke backend="deno-core":
	@SHADOW_RUNTIME_HOST_BACKEND="{{backend}}" nix develop .#runtime -c scripts/runtime_app_toggle_smoke.sh

# Run the checkbox / boolean form smoke through the bundled app runtime seam on Deno Runtime
runtime-app-toggle-smoke-deno-runtime:
	@just runtime-app-toggle-smoke deno-runtime

# Run the text selection metadata smoke through the selected bundled app runtime seam
runtime-app-selection-smoke backend="deno-core":
	@SHADOW_RUNTIME_HOST_BACKEND="{{backend}}" nix develop .#runtime -c scripts/runtime_app_selection_smoke.sh

# Run the text selection metadata smoke through the bundled app runtime seam on Deno Runtime
runtime-app-selection-smoke-deno-runtime:
	@just runtime-app-selection-smoke deno-runtime

# Run the first OS-level Nostr API smoke through the selected bundled app runtime seam
runtime-app-nostr-smoke backend="deno-core":
	@SHADOW_RUNTIME_HOST_BACKEND="{{backend}}" nix develop .#runtime -c scripts/runtime_app_nostr_smoke.sh

# Run the default-backend Nostr cache/persistence smoke through the OS API seam
runtime-app-nostr-cache-smoke:
	@nix develop .#runtime -c scripts/runtime_app_nostr_cache_smoke.sh

# Run the first OS-level Nostr API smoke through the bundled app runtime seam on Deno Runtime
runtime-app-nostr-smoke-deno-runtime:
	@just runtime-app-nostr-smoke deno-runtime

# Run the GM auto-post runtime app through the default host backend
runtime-app-nostr-gm-smoke:
	@nix develop .#runtime -c scripts/runtime_app_nostr_gm_smoke.sh

# Run the fixed-frame Blitz document smoke for app payload swapping
runtime-app-blitz-document-smoke:
	@scripts/runtime_app_blitz_document_smoke.sh

# Run the host-visible runtime demo window on the selected backend
runtime-app-host-run backend="deno-core" renderer="cpu":
	@SHADOW_RUNTIME_HOST_BACKEND="{{backend}}" SHADOW_BLITZ_RENDERER="{{renderer}}" scripts/runtime_app_host_run.sh

# Run the host-visible runtime demo window on Deno Runtime
runtime-app-host-run-deno-runtime:
	@just runtime-app-host-run deno-runtime

# Run the host-visible runtime demo window with the GPU Vello renderer
runtime-app-host-run-gpu backend="deno-core":
	@SHADOW_RUNTIME_HOST_BACKEND="{{backend}}" SHADOW_BLITZ_RENDERER="gpu" scripts/runtime_app_host_run.sh

# Run the host-visible runtime demo with an auto-exit smoke timer on the selected backend
runtime-app-host-smoke backend="deno-core" renderer="cpu":
	@SHADOW_RUNTIME_HOST_BACKEND="{{backend}}" SHADOW_BLITZ_RENDERER="{{renderer}}" scripts/runtime_app_host_smoke.sh

# Run the host-visible runtime demo with an auto-exit smoke timer on Deno Runtime
runtime-app-host-smoke-deno-runtime:
	@just runtime-app-host-smoke deno-runtime

# Run the host-visible runtime demo with the GPU Vello renderer
runtime-app-host-smoke-gpu backend="deno-core":
	@SHADOW_RUNTIME_HOST_BACKEND="{{backend}}" SHADOW_BLITZ_RENDERER="gpu" scripts/runtime_app_host_smoke.sh

# Run the GPU runtime demo as a Wayland client under the Smithay compositor smoke path
runtime-app-compositor-smoke-gpu:
	@scripts/runtime_app_compositor_smoke.sh

# Run the static GPU Blitz demo as a Wayland client under the Smithay compositor smoke path
blitz-demo-compositor-smoke-gpu:
	@scripts/blitz_demo_compositor_smoke.sh

# Run the static GPU Blitz demo as a Wayland client under the guest compositor smoke path
blitz-demo-guest-compositor-smoke-gpu:
	@scripts/blitz_demo_guest_compositor_smoke.sh

# Run the document/click/input/focus smokes on both host backends
runtime-app-backend-parity-smoke:
	@just runtime-app-document-smoke deno-core
	@just runtime-app-click-smoke deno-core
	@just runtime-app-input-smoke deno-core
	@just runtime-app-focus-smoke deno-core
	@just runtime-app-toggle-smoke deno-core
	@just runtime-app-selection-smoke deno-core
	@just runtime-app-nostr-smoke deno-core
	@just runtime-app-document-smoke deno-runtime
	@just runtime-app-click-smoke deno-runtime
	@just runtime-app-input-smoke deno-runtime
	@just runtime-app-focus-smoke deno-runtime
	@just runtime-app-toggle-smoke deno-runtime
	@just runtime-app-selection-smoke deno-runtime
	@just runtime-app-nostr-smoke deno-runtime

# Build the minimal Rusty V8 smoke binary for x86_64 Linux
runtime-rusty-v8-smoke-x86_64-linux-gnu:
	@nix build --accept-flake-config .#rusty-v8-smoke-x86_64-linux-gnu

# Build the minimal Deno Core smoke binary for x86_64 Linux
runtime-deno-core-smoke-x86_64-linux-gnu:
	@nix build --accept-flake-config .#deno-core-smoke-x86_64-linux-gnu

# Build the minimal Deno Runtime smoke binary for x86_64 Linux
runtime-deno-runtime-smoke-x86_64-linux-gnu:
	@nix build --accept-flake-config .#deno-runtime-smoke-x86_64-linux-gnu

# Build the minimal Rusty V8 smoke binary for aarch64 Linux
runtime-rusty-v8-smoke-aarch64-linux-gnu:
	@nix build --accept-flake-config .#rusty-v8-smoke-aarch64-linux-gnu

# Build the minimal Deno Core smoke binary for aarch64 Linux
runtime-deno-core-smoke-aarch64-linux-gnu:
	@nix build --accept-flake-config .#deno-core-smoke-aarch64-linux-gnu

# Build the minimal Deno Runtime smoke binary for aarch64 Linux
runtime-deno-runtime-smoke-aarch64-linux-gnu:
	@nix build --accept-flake-config .#deno-runtime-smoke-aarch64-linux-gnu

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

# Prove the timeline app launches, shelves warm, and reopens in the local UI VM
ui-vm-timeline-smoke:
	@scripts/ui_vm_timeline_smoke.sh

# Ask the compositor to open an app by ID
ui-vm-open app="counter":
	@scripts/shadowctl vm open "{{app}}"

# Ask the compositor to shelf the foreground app and return home
ui-vm-home:
	@scripts/shadowctl vm home

# Query the local UI VM via shadowctl
shadowctl *args='':
	@scripts/shadowctl {{args}}

# Inspect the connected Pixel and report whether the rooted runtime demo can run
pixel-doctor:
	@scripts/pixel_doctor.sh

# Build the rooted Pixel runtime demo artifacts
pixel-build:
	@scripts/pixel_build.sh

# Push the latest Pixel runtime demo artifacts to the connected device
pixel-push:
	@scripts/pixel_push.sh

# Stage the runtime app bundle plus GNU-wrapped helper for Pixel use
pixel-prepare-runtime-app-artifacts:
	@scripts/pixel_prepare_runtime_app_artifacts.sh

# Run the runtime-mode Blitz demo on the rooted Pixel through the guest compositor DRM path
pixel-runtime-app-drm:
	@scripts/pixel_runtime_app_drm.sh

# Run the runtime-mode Blitz demo on the rooted Pixel, keep the panel seized, and leave Android stopped
pixel-runtime-app-drm-hold:
	@scripts/pixel_runtime_app_drm_hold.sh

# Run the tap-driven GM runtime demo on the rooted Pixel through the guest compositor DRM path
pixel-runtime-app-nostr-gm-drm:
	@scripts/pixel_runtime_app_nostr_gm_drm.sh

# Run the tap-driven GM runtime demo on the rooted Pixel, keep the panel seized, and leave Android stopped
pixel-runtime-app-nostr-gm-drm-hold:
	@scripts/pixel_runtime_app_nostr_gm_drm_hold.sh

# Run the timeline runtime demo on the rooted Pixel through the guest compositor DRM path
pixel-runtime-app-nostr-timeline-drm:
	@scripts/pixel_runtime_app_nostr_timeline_drm.sh

# Run the timeline runtime demo on the rooted Pixel, keep the panel seized, and leave Android stopped
pixel-runtime-app-nostr-timeline-drm-hold:
	@scripts/pixel_runtime_app_nostr_timeline_drm_hold.sh

# Run the tap-driven GM runtime app under the current host runtime backend
runtime-app-nostr-gm-smoke:
	@SHADOW_RUNTIME_APP_INPUT_PATH=runtime/app-nostr-gm/app.tsx \
	SHADOW_RUNTIME_APP_CACHE_DIR=build/runtime/app-nostr-gm \
	scripts/runtime_app_nostr_gm_smoke.sh

# Run the timeline runtime app against a local relay and keyboard-driven compose flow
runtime-app-nostr-timeline-smoke:
	@scripts/runtime_app_nostr_timeline_smoke.sh

# Run the English keyboard runtime smoke under the current host runtime backend
runtime-app-keyboard-smoke:
	@SHADOW_RUNTIME_APP_INPUT_PATH=runtime/app-keyboard-smoke/app.tsx \
	SHADOW_RUNTIME_APP_CACHE_DIR=build/runtime/app-keyboard-smoke \
	scripts/runtime_app_keyboard_smoke.sh

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

# Probe the rooted Pixel DRM/KMS nodes and report driver capabilities relevant to Turnip
pixel-drm-probe:
	@scripts/pixel_drm_probe.sh

# Run the minimal Deno Core smoke binary on the rooted Pixel through the GNU runtime envelope
pixel-runtime-deno-core-smoke:
	@PIXEL_RUNTIME_LOG_PREFIX=pixel_runtime_deno_core_smoke PIXEL_RUNTIME_SUCCESS_LABEL='Pixel Deno Core runtime smoke' scripts/pixel_runtime_deno_core_smoke.sh

# Run the minimal Deno Runtime smoke binary on the rooted Pixel through the GNU runtime envelope
pixel-runtime-deno-runtime-smoke:
	@PIXEL_RUNTIME_LOG_PREFIX=pixel_runtime_deno_runtime_smoke PIXEL_RUNTIME_SUCCESS_LABEL='Pixel Deno Runtime smoke' PIXEL_RUNTIME_PACKAGE_ATTR=deno-runtime-smoke-aarch64-linux-gnu PIXEL_RUNTIME_BINARY_NAME=deno-runtime-smoke PIXEL_RUNTIME_MODULE_RELATIVE_PATH=modules/main.js PIXEL_RUNTIME_EXPECT_OUTPUT_PREFIX='deno_runtime ok:' PIXEL_RUNTIME_EXPECT_RESULT='result=HELLO FROM DENO_RUNTIME AND DENO_RUNTIME FILE' scripts/pixel_runtime_deno_core_smoke.sh

# Run the runtime-mode Blitz demo on the rooted Pixel and auto-dispatch one runtime click
pixel-runtime-app-click-drm:
	@scripts/pixel_runtime_app_click_drm.sh

# Detect the rooted Pixel touchscreen and capture one raw touch sequence
pixel-touch-input-smoke:
	@scripts/pixel_touch_input_smoke.sh
