set export

export CUTTLEFISH_REMOTE_HOST := env_var_or_default("CUTTLEFISH_REMOTE_HOST", "justin@100.73.239.5")
export SHADOW_UI_REMOTE_HOST := env_var_or_default("SHADOW_UI_REMOTE_HOST", CUTTLEFISH_REMOTE_HOST)

# Show the supported operator surface by default
default: help

# Show the supported VM/QEMU and rooted-Pixel operator surface
help:
	@printf '%s\n' \
	'Shadow supported operator surface' \
	'' \
	'Core:' \
	'  just pre-commit' \
	'  just ui-check' \
	'  just pre-merge' \
	'  just land' \
	'' \
	'VM / QEMU:' \
	'  just run target=vm [app=shell|counter|timeline|camera|podcast|cashu]' \
	'  just stop target=vm' \
	'  just vm-doctor' \
	'  just vm-status' \
	'  just vm-logs' \
	'  just vm-journal' \
	'  just vm-wait-ready' \
	'  just vm-open app=<app>' \
	'  just vm-home' \
	'  just vm-screenshot' \
	'  just vm-smoke' \
	'' \
	'Rooted Pixel:' \
		'  just pixel-doctor' \
		'  just pixel-build' \
		'  just pixel-stage shell' \
		'  just run target=pixel [app=shell|counter|timeline|camera|podcast|cashu]' \
		'  just pixel-shell-drm-hold' \
		'  just stop target=pixel' \
		'  just shadowctl state|open <app>|home|switcher -t pixel' \
		'  just pixel-ci [quick|shell|timeline|camera|nostr|sound|podcast|runtime|full]' \
		'  just pixel-runtime-app-nostr-timeline-local-smoke [--target <serial>]' \
	'' \
	'Shared CLI:' \
	'  just shadowctl <subcommand> -t vm' \
	'  just shadowctl <subcommand> -t pixel' \
	'' \
	'Preferred public session entrypoints are `just run target=...` and `just stop target=...`.' \
	'Older `vm-*` and `ui-vm-*` names remain for compatibility.' \
	'Historical, probe, and one-off recipes still exist but are not the front door.' \
	'Run `just help-all` for the full recipe list.'

# Show the full recipe list, including historical bring-up and probe lanes
help-all:
	@just --list --unsorted

# Run the fast local gate
pre-commit:
	@scripts/pre_commit.sh

# Run the required branch gate
pre-merge:
	@scripts/pre_merge.sh

# Run the rooted-Pixel CI lane. Examples: `just pixel-ci`, `just pixel-ci camera`, `just pixel-ci --target <serial>`
pixel-ci *args='':
	@scripts/pixel_ci.sh {{args}}

# Prove the rooted-Pixel Nostr timeline runtime against a host-local relay over USB
pixel-runtime-app-nostr-timeline-local-smoke *args='':
	@scripts/pixel_runtime_app_nostr_timeline_local_smoke.sh {{args}}

# Stage rooted-Pixel artifacts without executing the suite. Examples: `just pixel-stage sound`
pixel-stage *args='':
	@scripts/pixel_ci.sh --stage-only {{args}}

# Execute a rooted-Pixel suite against already-staged artifacts. Examples: `just pixel-run sound`
pixel-run *args='':
	@scripts/pixel_ci.sh --run-only {{args}}

# Rebase this worktree branch onto root master, run pre-merge, and fast-forward root master if green
land:
	@scripts/land.sh

# Run UI formatting, tests, and compile checks
ui-check:
	@scripts/ui_check.sh

# Enter the Nix shell for the runtime / V8 exploration lane
runtime-shell:
	@nix develop .#runtime

# Enter the Nix shell for Android-native helper work
android-shell:
	@nix develop .#android

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
	@just runtime-app-camera-smoke
	@just runtime-app-nostr-gm-smoke
	@just runtime-app-nostr-timeline-smoke
	@just runtime-app-cashu-wallet-smoke
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

# Run the camera OS API smoke through the bundled app runtime seam
runtime-app-camera-smoke:
	@nix develop .#runtime -c scripts/runtime_app_camera_smoke.sh

# Run the default-backend Nostr cache/persistence smoke through the OS API seam
runtime-app-nostr-cache-smoke:
	@nix develop .#runtime -c scripts/runtime_app_nostr_cache_smoke.sh

# Run the first OS-level Nostr API smoke through the bundled app runtime seam on Deno Runtime
runtime-app-nostr-smoke-deno-runtime:
	@just runtime-app-nostr-smoke deno-runtime

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

# Compatibility operator entrypoint for the older shell-script path.
# target=desktop runs the Linux desktop host when available, otherwise the local VM fallback
# target=vm runs the local Linux VM shell
# target=pixel runs the rooted Pixel shell/home scene
# app=shell is the default operator entrypoint
# app=counter, app=timeline, app=camera, app=podcast, or app=cashu asks the shell to foreground that app after launch
# target=<serial> implies Pixel and exports PIXEL_SERIAL automatically
ui-run target="desktop" app="shell" hold="1":
	@scripts/ui_run.sh "{{target}}" "{{app}}" "{{hold}}"

# Primary target-aware shell/session entrypoint.
# target=vm runs the local Linux VM shell.
# target=pixel runs the rooted Pixel shell/home scene.
# target=<serial> implies Pixel and exports PIXEL_SERIAL via shadowctl.
# target=desktop remains a compatibility alias and now routes to the VM path.
run target="vm" app="shell" hold="1":
	@if [ -n "${SHADOW_UI_RUN_ECHO_EXEC-}" ]; then \
		exec scripts/shadowctl --dry-run start "{{target}}" "{{app}}" "{{hold}}"; \
	else \
		exec scripts/shadowctl start "{{target}}" "{{app}}" "{{hold}}"; \
	fi

# Run the nested compositor and demo app under a headless Linux host
ui-smoke:
	@scripts/ui_smoke.sh

# Run the local VM smoke used by pre-merge
ui-vm-smoke:
	@scripts/ui_vm_smoke.sh

# Alias for ui-vm-smoke
vm-smoke:
	@just ui-vm-smoke

# Run the local Linux UI VM in a native macOS window
ui-vm-run:
	@scripts/shadowctl start vm

# Alias for the local Linux UI VM runner
vm-run:
	@just ui-vm-run

# Compatibility stop path for the older shell-script wrapper.
# target=vm stops the VM
# target=pixel restores Android after a hold-mode takeover
ui-stop target="desktop":
	@scripts/ui_stop.sh "{{target}}"

# Primary target-aware stop entrypoint.
# target=desktop remains a compatibility alias and now routes to the VM path.
stop target="vm":
	@if [ -n "${SHADOW_UI_STOP_ECHO_EXEC-}" ]; then \
		exec scripts/shadowctl --dry-run stop "{{target}}"; \
	else \
		exec scripts/shadowctl stop "{{target}}"; \
	fi

# Stop the local Linux UI VM
ui-vm-stop:
	@scripts/shadowctl stop vm

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
	@scripts/shadowctl logs -t vm

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
	@scripts/shadowctl doctor -t vm

# Alias for ui-vm-doctor
vm-doctor:
	@just ui-vm-doctor

# Show machine-readable UI VM state
ui-vm-state:
	@scripts/shadowctl state -t vm --json

# Alias for ui-vm-state
vm-state:
	@just ui-vm-state

# Wait for the UI VM session to reach steady state
ui-vm-wait-ready:
	@scripts/shadowctl wait-ready -t vm

# Alias for ui-vm-wait-ready
vm-wait-ready:
	@just ui-vm-wait-ready

# Save a screenshot of the local UI VM window via QMP
ui-vm-screenshot output="build/ui-vm/shadow-ui-vm.ppm":
	@scripts/shadowctl screenshot -t vm "{{output}}"

# Alias for ui-vm-screenshot
vm-screenshot output="build/ui-vm/shadow-ui-vm.ppm":
	@just ui-vm-screenshot "{{output}}"

# Prove the timeline app launches, shelves warm, and reopens in the local UI VM
ui-vm-timeline-smoke:
	@scripts/ui_vm_timeline_smoke.sh

# Alias for ui-vm-timeline-smoke
vm-timeline-smoke:
	@just ui-vm-timeline-smoke

# Prove the camera app can boot as the initial foreground app in the local UI VM
ui-vm-camera-smoke:
	@scripts/ui_vm_camera_smoke.sh

# Alias for ui-vm-camera-smoke
vm-camera-smoke:
	@just ui-vm-camera-smoke

# Ask the compositor to open an app by ID
ui-vm-open app="counter":
	@scripts/shadowctl open "{{app}}" -t vm

# Alias for ui-vm-open
vm-open app="counter":
	@just ui-vm-open "{{app}}"

# Ask the compositor to shelf the foreground app and return home
ui-vm-home:
	@scripts/shadowctl home -t vm

# Alias for ui-vm-home
vm-home:
	@just ui-vm-home

# Run the shared VM/Pixel operator CLI
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

# Build, push, and run the Android-native Rust camera helper under su on the rooted Pixel
pixel-camera-rs-run *args='':
	@scripts/pixel_camera_rs_run.sh {{args}}

# Run the Android-native Rust camera helper during rooted display takeover while keeping gralloc alive
pixel-camera-rs-takeover *args='capture':
	@scripts/pixel_camera_rs_takeover.sh {{args}}

# Run the runtime-mode camera app on the rooted Pixel through the guest compositor DRM path
pixel-runtime-app-camera-drm:
	@scripts/pixel_runtime_app_camera_drm.sh

# Run the runtime-mode camera app on the rooted Pixel and auto-dispatch one capture click
pixel-runtime-app-camera-click-drm:
	@scripts/pixel_runtime_app_camera_click_drm.sh

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
	@scripts/shadowctl -t pixel {{args}}

# Prove timeline launch, home, and reopen on the rooted Pixel shell lane
pixel-shell-timeline-smoke:
	@scripts/pixel_shell_timeline_smoke.sh

# Prove camera launch and one live capture on the rooted Pixel shell lane
pixel-shell-camera-smoke:
	@scripts/pixel_shell_camera_smoke.sh

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
