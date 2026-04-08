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

# Run the English keyboard runtime smoke on the bundled host runtime seam
runtime-app-keyboard-smoke:
	@SHADOW_RUNTIME_APP_INPUT_PATH=runtime/app-keyboard-smoke/app.tsx \
	SHADOW_RUNTIME_APP_CACHE_DIR=build/runtime/app-keyboard-smoke \
	scripts/runtime_app_keyboard_smoke.sh

# Run the tap-driven GM runtime app on the bundled host runtime seam
runtime-app-nostr-gm-smoke:
	@SHADOW_RUNTIME_APP_INPUT_PATH=runtime/app-nostr-gm/app.tsx \
	SHADOW_RUNTIME_APP_CACHE_DIR=build/runtime/app-nostr-gm \
	scripts/runtime_app_nostr_gm_smoke.sh

# Run the timeline runtime app against a local relay and keyboard-driven compose flow
runtime-app-nostr-timeline-smoke:
	@scripts/runtime_app_nostr_timeline_smoke.sh

# Run the Cashu wallet runtime app against a local fakewallet mint and prove fund/send/receive/pay flows
runtime-app-cashu-wallet-smoke:
	@scripts/runtime_app_cashu_wallet_smoke.sh

# Run the currently supported bundled host runtime smokes
runtime-app-host-smokes:
	@just runtime-app-keyboard-smoke
	@just runtime-app-nostr-gm-smoke
	@just runtime-app-nostr-timeline-smoke
	@just runtime-app-cashu-wallet-smoke

# Run the static GPU Blitz demo as a Wayland client under the guest compositor smoke path
blitz-demo-guest-compositor-smoke-gpu:
	@scripts/blitz_demo_guest_compositor_smoke.sh

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

# Primary operator entrypoint.
# target=desktop runs the Linux desktop host when available, otherwise the local VM fallback
# target=vm runs the local Linux VM shell
# target=pixel runs the rooted Pixel shell/home scene
# app=shell is the default operator entrypoint
# target=<serial> implies Pixel and exports PIXEL_SERIAL automatically
ui-run target="desktop" app="shell" hold="1":
	@scripts/ui_run.sh "{{target}}" "{{app}}" "{{hold}}"

# Alias for ui-run
run target="desktop" app="shell" hold="1":
	@just ui-run "{{target}}" "{{app}}" "{{hold}}"

# Run the nested compositor and demo app under a headless Linux host
ui-smoke:
	@scripts/ui_smoke.sh

# Run the local Linux UI VM in a native macOS window
ui-vm-run:
	@scripts/ui_vm_run.sh

# Alias for the local Linux UI VM runner
vm-run:
	@just ui-vm-run

# Stop the selected UI target.
# target=vm stops the VM
# target=pixel restores Android after a hold-mode takeover
ui-stop target="desktop":
	@scripts/ui_stop.sh "{{target}}"

# Alias for ui-stop
stop target="desktop":
	@just ui-stop "{{target}}"

# Stop the local Linux UI VM
ui-vm-stop:
	@scripts/ui_vm_stop.sh

# Alias for the local Linux UI VM stop command
vm-stop:
	@just ui-vm-stop

# SSH into the local Linux UI VM
ui-vm-ssh *args='':
	@scripts/ui_vm_ssh.sh {{args}}

# Alias for ui-vm-ssh
vm-ssh *args='':
	@just ui-vm-ssh {{args}}

# Show the guest compositor session log
ui-vm-logs:
	@scripts/ui_vm_logs.sh

# Alias for ui-vm-logs
vm-logs:
	@just ui-vm-logs

# Show guest smoke status and relevant Shadow UI processes
ui-vm-status:
	@scripts/ui_vm_status.sh

# Alias for ui-vm-status
vm-status:
	@just ui-vm-status

# Show guest greetd and smoke-service journal output
ui-vm-journal:
	@scripts/ui_vm_journal.sh

# Alias for ui-vm-journal
vm-journal:
	@just ui-vm-journal

# Diagnose the local UI VM via shadowctl
ui-vm-doctor:
	@scripts/shadowctl vm doctor

# Alias for ui-vm-doctor
vm-doctor:
	@just ui-vm-doctor

# Show machine-readable UI VM state
ui-vm-state:
	@scripts/shadowctl vm state --json

# Alias for ui-vm-state
vm-state:
	@just ui-vm-state

# Wait for the UI VM session to reach steady state
ui-vm-wait-ready:
	@scripts/shadowctl vm wait-ready

# Alias for ui-vm-wait-ready
vm-wait-ready:
	@just ui-vm-wait-ready

# Save a screenshot of the local UI VM window via QMP
ui-vm-screenshot output="build/ui-vm/shadow-ui-vm.ppm":
	@scripts/shadowctl vm screenshot "{{output}}"

# Alias for ui-vm-screenshot
vm-screenshot output="build/ui-vm/shadow-ui-vm.ppm":
	@just ui-vm-screenshot "{{output}}"

# Prove the timeline app launches, shelves warm, and reopens in the local UI VM
ui-vm-timeline-smoke:
	@scripts/ui_vm_timeline_smoke.sh

# Alias for ui-vm-timeline-smoke
vm-timeline-smoke:
	@just ui-vm-timeline-smoke

# Ask the compositor to open an app by ID
ui-vm-open app="counter":
	@scripts/shadowctl vm open "{{app}}"

# Alias for ui-vm-open
vm-open app="counter":
	@just ui-vm-open "{{app}}"

# Ask the compositor to shelf the foreground app and return home
ui-vm-home:
	@scripts/shadowctl vm home

# Alias for ui-vm-home
vm-home:
	@just ui-vm-home

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

# Stage the counter + timeline runtime bundles plus GNU-wrapped helper for Pixel shell use
pixel-prepare-shell-runtime-artifacts:
	@scripts/pixel_prepare_shell_runtime_artifacts.sh

# Run the runtime-mode Blitz demo on the rooted Pixel through the guest compositor DRM path
pixel-runtime-app-drm:
	@scripts/pixel_runtime_app_drm.sh

# Run the shell/home scene on the rooted Pixel through the guest compositor DRM path
pixel-shell-drm:
	@scripts/pixel_shell_drm.sh

# Run the shell/home scene on the rooted Pixel, keep the panel seized, and leave Android stopped
pixel-shell-drm-hold:
	@scripts/pixel_shell_drm_hold.sh

# Send control requests to the rooted Pixel shell compositor
pixel-shellctl *args='':
	@scripts/pixel_shellctl.sh {{args}}

# Prove timeline launch, home, and reopen on the rooted Pixel shell lane
pixel-shell-timeline-smoke:
	@scripts/pixel_shell_timeline_smoke.sh

# Run one rooted-Pixel runtime direct-gpu probe case with the selected backend profile
pixel-runtime-app-drm-gpu-probe profile="vulkan_kgsl_first":
	@PIXEL_RUNTIME_GPU_RENDERER=gpu scripts/pixel_runtime_app_drm_gpu_probe.sh "{{profile}}"

# Run the rooted-Pixel runtime direct-gpu probe matrix across the current default profiles
pixel-runtime-app-drm-gpu-matrix:
	@PIXEL_RUNTIME_GPU_RENDERER=gpu scripts/pixel_runtime_app_drm_gpu_matrix.sh

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

# Run the timeline runtime demo on the rooted Pixel and auto-dispatch one quick-gm click
pixel-runtime-app-nostr-timeline-click-drm:
	@scripts/pixel_runtime_app_nostr_timeline_click_drm.sh

# Warm the rooted Pixel timeline GPU artifacts and device-side runtime cache without taking over the display
pixel-runtime-app-nostr-timeline-gpu-warm:
	@PIXEL_RUNTIME_APP_RENDERER=gpu_softbuffer scripts/pixel_gpu_warm.sh

# Run the timeline runtime demo on the rooted Pixel through the proven GPU lane and auto-dispatch one quick-gm click
pixel-runtime-app-nostr-timeline-gpu-smoke:
	@PIXEL_RUNTIME_APP_RENDERER=gpu_softbuffer scripts/pixel_runtime_app_nostr_timeline_click_drm.sh

# Run the timeline runtime demo on the rooted Pixel, keep the panel seized, and leave Android stopped
pixel-runtime-app-nostr-timeline-drm-hold:
	@scripts/pixel_runtime_app_nostr_timeline_drm_hold.sh

# Warm Pixel GPU artifacts without launching the device session
pixel-gpu-warm:
	@just pixel-runtime-app-nostr-timeline-gpu-warm

# Run the runtime audio API smoke under the current host runtime backend
runtime-app-sound-smoke:
	@SHADOW_RUNTIME_APP_INPUT_PATH=runtime/app-sound-smoke/app.tsx \
	SHADOW_RUNTIME_APP_CACHE_DIR=build/runtime/app-sound-smoke \
	scripts/runtime_app_sound_smoke.sh

# Run the simple podcast-player runtime audio smoke under the current host runtime backend
runtime-app-podcast-player-smoke:
	@scripts/runtime_app_podcast_player_smoke.sh

# Run the runtime sound demo on the rooted Pixel through the guest compositor DRM path
pixel-runtime-app-sound-drm:
	@scripts/pixel_runtime_app_sound_drm.sh

# Run the simple podcast-player runtime app on the rooted Pixel through the guest compositor DRM path
pixel-runtime-app-podcast-player-drm:
	@scripts/pixel_runtime_app_podcast_player_drm.sh

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

# Run one static rooted-Pixel GPU probe case with the selected backend profile
pixel-blitz-demo-static-drm-gpu-probe profile="gl":
	@PIXEL_STATIC_GPU_PROFILE="{{profile}}" scripts/pixel_blitz_demo_static_drm_gpu_probe.sh

# Run the static rooted-Pixel GPU probe matrix across the current default profiles
pixel-blitz-demo-static-drm-gpu-matrix:
	@scripts/pixel_blitz_demo_static_drm_gpu_probe.sh

# Run the minimal Deno Core smoke binary on the rooted Pixel through the GNU runtime envelope
pixel-runtime-deno-core-smoke:
	@PIXEL_RUNTIME_LOG_PREFIX=pixel_runtime_deno_core_smoke PIXEL_RUNTIME_SUCCESS_LABEL='Pixel Deno Core runtime smoke' scripts/pixel_runtime_deno_core_smoke.sh

# Run the minimal Deno Runtime smoke binary on the rooted Pixel through the GNU runtime envelope
pixel-runtime-deno-runtime-smoke:
	@PIXEL_RUNTIME_LOG_PREFIX=pixel_runtime_deno_runtime_smoke PIXEL_RUNTIME_SUCCESS_LABEL='Pixel Deno Runtime smoke' PIXEL_RUNTIME_PACKAGE_ATTR=deno-runtime-smoke-aarch64-linux-gnu PIXEL_RUNTIME_BINARY_NAME=deno-runtime-smoke PIXEL_RUNTIME_MODULE_RELATIVE_PATH=modules/main.js PIXEL_RUNTIME_EXPECT_OUTPUT_PREFIX='deno_runtime ok:' PIXEL_RUNTIME_EXPECT_RESULT='result=HELLO FROM DENO_RUNTIME AND DENO_RUNTIME FILE' scripts/pixel_runtime_deno_core_smoke.sh

# Run the first rooted-Pixel Linux-direct audio output spike through the GNU runtime envelope
pixel-linux-audio-spike:
	@scripts/pixel_linux_audio_spike.sh

# Run the runtime-mode Blitz demo on the rooted Pixel and auto-dispatch one runtime click
pixel-runtime-app-click-drm:
	@scripts/pixel_runtime_app_click_drm.sh

# Detect the rooted Pixel touchscreen and capture one raw touch sequence
pixel-touch-input-smoke:
	@scripts/pixel_touch_input_smoke.sh
