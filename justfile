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

# Run the nested compositor and runtime app under a headless Linux host
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
