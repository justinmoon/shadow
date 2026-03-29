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

# Rebuild init_boot.img with the Rust chainloading wrapper
init-boot-wrapper:
	@scripts/init_boot_wrapper.sh

# Boot Cuttlefish with the repacked init_boot image
cf-repacked-initboot:
	@scripts/cf_repacked_initboot.sh

# Boot Cuttlefish with the Rust chainloading wrapper as /init
cf-init-wrapper:
	@scripts/cf_init_wrapper.sh

# Show launcher, kernel, and console logs for the active instance
cf-logs kind="all":
	@scripts/cf_logs.sh --kind "{{kind}}"

# Follow logs for the active instance
cf-logs-follow kind="kernel":
	@scripts/cf_logs.sh --follow --kind "{{kind}}"

# Destroy the active instance on Hetzner
cf-kill:
	@scripts/cf_kill.sh

# Run UI formatting and compile checks inside the UI shell
ui-check:
	@scripts/ui_check.sh

# Run the Shadow UI prototype inside the UI shell
ui-run:
	@nix develop --accept-flake-config .#ui -c cargo run --manifest-path ui/Cargo.toml -p shadow-ui-desktop

# Run the nested Smithay compositor host (Linux/Wayland only)
ui-compositor-run:
	@nix develop --accept-flake-config .#ui -c cargo run --manifest-path ui/Cargo.toml -p shadow-compositor

# Run the demo counter app directly
ui-counter-run:
	@nix develop --accept-flake-config .#ui -c cargo run --manifest-path ui/Cargo.toml -p shadow-counter

# Run the Blitz + Deno demo app directly
ui-blitz-run:
	@nix develop --accept-flake-config .#ui -c cargo run --manifest-path ui/Cargo.toml -p shadow-blitz-demo

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

# Diagnose the guest session and compositor state
ui-vm-doctor:
	@scripts/shadowctl vm doctor

# Show guest greetd and smoke-service journal output
ui-vm-journal:
	@scripts/ui_vm_journal.sh

# Capture a QEMU framebuffer screenshot for UI inspection
ui-vm-screenshot output="build/ui-vm/shadow-ui-vm.ppm":
	@scripts/shadowctl vm screenshot "{{output}}"

# Launch the native-renderer + Deno prototype inside the guest compositor
ui-vm-blitz-run:
	@scripts/ui_vm_app_run.sh shadow-blitz-demo

# Launch the nested Smithay compositor inside the guest weston session
ui-vm-shadow-run:
	@scripts/ui_vm_shadow_run.sh

# Stop the nested Smithay compositor inside the guest weston session
ui-vm-shadow-stop:
	@scripts/ui_vm_shadow_stop.sh

# Show the nested Smithay compositor log
ui-vm-shadow-logs:
	@scripts/ui_vm_shadow_logs.sh

# Show the nested Smithay compositor status and app processes
ui-vm-shadow-status:
	@scripts/ui_vm_shadow_status.sh

# Diagnose the nested Smithay compositor state
ui-vm-shadow-doctor:
	@scripts/shadowctl shadow doctor

# Launch the counter app inside the nested Smithay compositor
ui-vm-shadow-counter-run:
	@scripts/ui_vm_shadow_app_run.sh shadow-counter

# Launch the status app inside the nested Smithay compositor
ui-vm-shadow-status-run:
	@scripts/ui_vm_shadow_app_run.sh shadow-status

# Launch the Blitz + Deno demo inside the nested Smithay compositor
ui-vm-shadow-blitz-run:
	@scripts/ui_vm_shadow_app_run.sh shadow-blitz-demo

# Run the fast local verification gate
pre-commit:
	@scripts/pre_commit.sh

# Run the full verification gate, including Hetzner boot smokes
ci:
	@scripts/ci.sh
