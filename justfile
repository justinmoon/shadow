# Show the supported operator surface by default
default: help

# Show the supported VM/QEMU, rooted-Pixel, and branch-gate surface
help:
	@printf '%s\n' \
	'Shadow public just API' \
	'' \
	'Branch gates:' \
	'  just pre-commit' \
	'  just pre-merge' \
	'  just land' \
	'' \
	'Target sessions:' \
	'  just run target=vm [app=shell|counter|timeline|camera|podcast|cashu]' \
	'  just run target=pixel [app=shell|counter|timeline|camera|podcast|cashu] [hold=0|1]' \
	'  just stop target=vm' \
	'  just stop target=pixel' \
	'  just smoke target=vm' \
	'' \
	'Target control:' \
	'  sc devices' \
	'  sc -t vm status' \
	'  sc -t vm open timeline' \
	'  sc -t vm ssh' \
	'  sc -t pixel state' \
	'  sc -t pixel open camera' \
	'  just shadowctl ...    # same CLI without relying on devshell PATH' \
	'' \
	'Pixel CI and setup:' \
	'  just pixel-prep-settings' \
	'  sc -t pixel ci [quick|shell|timeline|camera|nostr|sound|audio|podcast|runtime|full]' \
	'  sc -t pixel stage <suite>' \
	'  sc root-prep' \
	'  sc -t pixel root-check' \
	'  sc -t pixel root-patch' \
	'  sc -t pixel root-flash' \
	'  sc -t pixel ota-sideload' \
	'  just pixel-ci <suite>       # convenience wrapper around sc ci' \
	'  just pixel-stage <suite>    # convenience wrapper around sc stage' \
	'  just pixel-run <suite>      # convenience wrapper around sc ci --run-only' \
	'' \
	'Runtime/app development:' \
	'  just ui-check' \
	'  just runtime-build-artifacts [args...]' \
	'  just runtime-app-host-smokes' \
	'  just runtime-shell' \
	'  just android-shell' \
	'' \
	'Historical probes and one-off bring-up lanes live as scripts, not public just recipes.' \
	'Run `just help-all` for the public recipe list.'

# Show the public recipe list
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
	@if [ -n "${SHADOWCTL_JUST_DRY_RUN:-}" ]; then \
		exec scripts/shadowctl ci --dry-run {{args}}; \
	fi; \
	exec scripts/shadowctl ci {{args}}

# Stage rooted-Pixel artifacts without executing the suite. Examples: `just pixel-stage sound`
pixel-stage *args='':
	@if [ -n "${SHADOWCTL_JUST_DRY_RUN:-}" ]; then \
		exec scripts/shadowctl stage --dry-run {{args}}; \
	fi; \
	exec scripts/shadowctl stage {{args}}

# Execute a rooted-Pixel suite against already-staged artifacts. Examples: `just pixel-run sound`
pixel-run *args='':
	@if [ -n "${SHADOWCTL_JUST_DRY_RUN:-}" ]; then \
		exec scripts/shadowctl ci --run-only --dry-run {{args}}; \
	fi; \
	exec scripts/shadowctl ci --run-only {{args}}

# Apply non-root Android convenience settings for a dedicated Pixel test device
pixel-prep-settings:
	@scripts/pixel_prep_settings.sh

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

# Run the currently supported bundled host runtime smokes
runtime-app-host-smokes:
	@SHADOW_RUNTIME_APP_INPUT_PATH=runtime/app-keyboard-smoke/app.tsx \
	SHADOW_RUNTIME_APP_CACHE_DIR=build/runtime/app-keyboard-smoke \
	scripts/runtime_app_keyboard_smoke.sh
	@nix develop .#runtime -c scripts/runtime_app_camera_smoke.sh
	@SHADOW_RUNTIME_APP_INPUT_PATH=runtime/app-nostr-gm/app.tsx \
	SHADOW_RUNTIME_APP_CACHE_DIR=build/runtime/app-nostr-gm \
	scripts/runtime_app_nostr_gm_smoke.sh
	@scripts/runtime_app_nostr_timeline_smoke.sh
	@scripts/runtime_app_cashu_wallet_smoke.sh

# Build runtime app artifacts with the shared host-side bundler
runtime-build-artifacts *args='':
	@scripts/runtime_build_artifacts.sh {{args}}

# Run a target shell session
run *args='':
	@target_arg="vm"; app_arg="shell"; hold_arg="1"; \
	for arg in {{args}}; do \
		case "$arg" in \
			target=*) target_arg="${arg#target=}" ;; \
			app=*) app_arg="${arg#app=}" ;; \
			hold=*) hold_arg="${arg#hold=}" ;; \
			*) echo "just run: expected target=..., app=..., or hold=...; got $arg" >&2; exit 2 ;; \
		esac; \
	done; \
	if [ -n "${SHADOWCTL_JUST_DRY_RUN:-}" ]; then \
		exec scripts/shadowctl run --dry-run -t "$target_arg" --app "$app_arg" --hold "$hold_arg"; \
	fi; \
	exec scripts/shadowctl run -t "$target_arg" --app "$app_arg" --hold "$hold_arg"

# Run a target smoke subset.
smoke *args='':
	@target_arg="vm"; \
	for arg in {{args}}; do \
		case "$arg" in \
			target=*) target_arg="${arg#target=}" ;; \
			*) echo "just smoke: expected target=...; got $arg" >&2; exit 2 ;; \
		esac; \
	done; \
	case "$target_arg" in \
		vm) exec scripts/ui_vm_smoke.sh ;; \
		*) echo "just smoke: supported targets: vm" >&2; exit 2 ;; \
	esac

# Run the shared VM/Pixel operator CLI
shadowctl *args='':
	@scripts/shadowctl {{args}}

# Stop a target shell session
stop *args='':
	@target_arg="vm"; \
	for arg in {{args}}; do \
		case "$arg" in \
			target=*) target_arg="${arg#target=}" ;; \
			*) echo "just stop: expected target=...; got $arg" >&2; exit 2 ;; \
		esac; \
	done; \
	if [ -n "${SHADOWCTL_JUST_DRY_RUN:-}" ]; then \
		exec scripts/shadowctl stop --dry-run -t "$target_arg"; \
	fi; \
	exec scripts/shadowctl stop -t "$target_arg"
