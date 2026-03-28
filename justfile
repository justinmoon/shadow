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

# Run the nested Smithay compositor host on Linux
compositor-run:
	@nix develop .#ui -c cargo run --manifest-path ui/Cargo.toml -p shadow-compositor

# Run the fast local verification gate
pre-commit:
	@scripts/pre_commit.sh

# Run the full verification gate, including Hetzner boot smokes
ci:
	@scripts/ci.sh
