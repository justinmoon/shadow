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

# Query the local UI VM via shadowctl
shadowctl *args='':
	@scripts/shadowctl {{args}}

# Launch a cargo package inside the running UI VM compositor session
ui-vm-app-run package:
	@scripts/ui_vm_app_run.sh {{package}}

# Launch the counter app inside the running UI VM compositor session
ui-vm-counter-run:
	@scripts/ui_vm_app_run.sh shadow-counter

# Run the nested Smithay compositor host on Linux
compositor-run:
	@nix develop .#ui -c cargo run --manifest-path ui/Cargo.toml -p shadow-compositor

# Run the fast local verification gate
pre-commit:
	@scripts/pre_commit.sh

# Run the full verification gate, including Hetzner boot smokes
ci:
	@scripts/ci.sh
