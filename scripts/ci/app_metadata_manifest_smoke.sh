#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SHADOWCTL_SCRIPT="$SCRIPT_DIR/shadowctl"
TMP_FILES=()

cleanup() {
  if ((${#TMP_FILES[@]})); then
    rm -f "${TMP_FILES[@]}"
  fi
}
trap cleanup EXIT

fail() {
  echo "app_metadata_manifest_smoke: $*" >&2
  exit 1
}

mktemp_tracked() {
  local path
  path="$(mktemp "${TMPDIR:-/tmp}/app-metadata-manifest.XXXXXX")"
  TMP_FILES+=("$path")
  printf '%s\n' "$path"
}

check_output_case() {
  local name="$1"
  local expected_status="$2"
  local expected_stdout_substring="$3"
  local expected_stderr_substring="$4"
  shift 4

  local stdout_path stderr_path status stdout stderr
  stdout_path="$(mktemp_tracked)"
  stderr_path="$(mktemp_tracked)"

  set +e
  (cd "$REPO_ROOT" && "$@") >"$stdout_path" 2>"$stderr_path"
  status=$?
  set -e

  stdout="$(cat "$stdout_path")"
  stderr="$(cat "$stderr_path")"

  [[ "$status" -eq "$expected_status" ]] || fail "$name status=$status expected=$expected_status stderr=$stderr"
  [[ "$stdout" == *"$expected_stdout_substring"* ]] || fail "$name stdout missing substring: $expected_stdout_substring"
  [[ "$stderr" == *"$expected_stderr_substring"* ]] || fail "$name stderr missing substring: $expected_stderr_substring"
}

write_profile_fixture() {
  local manifest_path
  manifest_path="$(mktemp_tracked)"
  python3 - "$manifest_path" <<'PY'
import json
import sys

manifest_path = sys.argv[1]
manifest = {
    "schemaVersion": 1,
    "shell": {
        "id": "home-shell",
        "waylandAppId": "dev.shadow.home-shell",
    },
    "apps": [
        {
            "id": "pixel-only",
            "title": "Pixel Only",
            "iconLabel": "PO",
            "subtitle": "Pixel lane",
            "lifecycleHint": "Pixel only app.",
            "binaryName": "shadow-blitz-demo",
            "waylandAppId": "dev.shadow.pixel-only",
            "windowTitle": "Pixel Only",
            "runtime": {
                "bundleEnv": "SHADOW_RUNTIME_APP_PIXEL_ONLY_BUNDLE_PATH",
                "bundleFilename": "runtime-app-pixel-only-bundle.js",
                "inputPath": "runtime/app-counter/app.tsx",
                "cacheDirs": {
                    "pixel-shell": "build/runtime/pixel-only",
                },
                "config": None,
            },
            "profiles": ["pixel-shell"],
            "ui": {"iconColor": "ICON_CYAN"},
        },
        {
            "id": "vm-only",
            "title": "VM Only",
            "iconLabel": "VO",
            "subtitle": "VM lane",
            "lifecycleHint": "VM only app.",
            "binaryName": "shadow-blitz-demo",
            "waylandAppId": "dev.shadow.vm-only",
            "windowTitle": "VM Only",
            "runtime": {
                "bundleEnv": "SHADOW_RUNTIME_APP_VM_ONLY_BUNDLE_PATH",
                "bundleFilename": "runtime-app-vm-only-bundle.js",
                "inputPath": "runtime/app-camera/app.tsx",
                "cacheDirs": {
                    "vm-shell": "build/runtime/vm-only",
                },
                "config": None,
            },
            "profiles": ["vm-shell"],
            "ui": {"iconColor": "ICON_ORANGE"},
        },
        {
            "id": "shared",
            "title": "Shared",
            "iconLabel": "SH",
            "subtitle": "Shared lane",
            "lifecycleHint": "Shared app.",
            "binaryName": "shadow-blitz-demo",
            "waylandAppId": "dev.shadow.shared",
            "windowTitle": "Shared",
            "runtime": {
                "bundleEnv": "SHADOW_RUNTIME_APP_SHARED_BUNDLE_PATH",
                "bundleFilename": "runtime-app-shared-bundle.js",
                "inputPath": "runtime/app-counter/app.tsx",
                "cacheDirs": {
                    "pixel-shell": "build/runtime/pixel-shared",
                    "vm-shell": "build/runtime/vm-shared",
                },
                "config": None,
            },
            "profiles": ["vm-shell", "pixel-shell"],
            "ui": {"iconColor": "ICON_GREEN"},
        },
    ],
}
with open(manifest_path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2)
    handle.write("\n")
PY
  printf '%s\n' "$manifest_path"
}

write_duplicate_env_fixture() {
  local manifest_path
  manifest_path="$(mktemp_tracked)"
  python3 - "$manifest_path" <<'PY'
import json
import sys

manifest_path = sys.argv[1]
manifest = {
    "schemaVersion": 1,
    "shell": {
        "id": "shell",
        "waylandAppId": "dev.shadow.shell",
    },
    "apps": [
        {
            "id": "one",
            "title": "One",
            "iconLabel": "01",
            "subtitle": "One",
            "lifecycleHint": "One",
            "binaryName": "shadow-blitz-demo",
            "waylandAppId": "dev.shadow.one",
            "windowTitle": "One",
            "runtime": {
                "bundleEnv": "SHADOW_RUNTIME_APP_DUPLICATE_BUNDLE_PATH",
                "bundleFilename": "runtime-app-one-bundle.js",
                "inputPath": "runtime/app-counter/app.tsx",
                "cacheDirs": {
                    "vm-shell": "build/runtime/one",
                },
                "config": None,
            },
            "profiles": ["vm-shell"],
            "ui": {"iconColor": "ICON_CYAN"},
        },
        {
            "id": "two",
            "title": "Two",
            "iconLabel": "02",
            "subtitle": "Two",
            "lifecycleHint": "Two",
            "binaryName": "shadow-blitz-demo",
            "waylandAppId": "dev.shadow.two",
            "windowTitle": "Two",
            "runtime": {
                "bundleEnv": "SHADOW_RUNTIME_APP_DUPLICATE_BUNDLE_PATH",
                "bundleFilename": "runtime-app-two-bundle.js",
                "inputPath": "runtime/app-camera/app.tsx",
                "cacheDirs": {
                    "vm-shell": "build/runtime/two",
                },
                "config": None,
            },
            "profiles": ["vm-shell"],
            "ui": {"iconColor": "ICON_ORANGE"},
        },
    ],
}
with open(manifest_path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2)
    handle.write("\n")
PY
  printf '%s\n' "$manifest_path"
}

write_duplicate_filename_fixture() {
  local manifest_path
  manifest_path="$(mktemp_tracked)"
  python3 - "$manifest_path" <<'PY'
import json
import sys

manifest_path = sys.argv[1]
manifest = {
    "schemaVersion": 1,
    "shell": {
        "id": "shell",
        "waylandAppId": "dev.shadow.shell",
    },
    "apps": [
        {
            "id": "one",
            "title": "One",
            "iconLabel": "01",
            "subtitle": "One",
            "lifecycleHint": "One",
            "binaryName": "shadow-blitz-demo",
            "waylandAppId": "dev.shadow.one",
            "windowTitle": "One",
            "runtime": {
                "bundleEnv": "SHADOW_RUNTIME_APP_ONE_BUNDLE_PATH",
                "bundleFilename": "runtime-app-duplicate-bundle.js",
                "inputPath": "runtime/app-counter/app.tsx",
                "cacheDirs": {
                    "vm-shell": "build/runtime/one",
                },
                "config": None,
            },
            "profiles": ["vm-shell"],
            "ui": {"iconColor": "ICON_CYAN"},
        },
        {
            "id": "two",
            "title": "Two",
            "iconLabel": "02",
            "subtitle": "Two",
            "lifecycleHint": "Two",
            "binaryName": "shadow-blitz-demo",
            "waylandAppId": "dev.shadow.two",
            "windowTitle": "Two",
            "runtime": {
                "bundleEnv": "SHADOW_RUNTIME_APP_TWO_BUNDLE_PATH",
                "bundleFilename": "runtime-app-duplicate-bundle.js",
                "inputPath": "runtime/app-camera/app.tsx",
                "cacheDirs": {
                    "vm-shell": "build/runtime/two",
                },
                "config": None,
            },
            "profiles": ["vm-shell"],
            "ui": {"iconColor": "ICON_ORANGE"},
        },
    ],
}
with open(manifest_path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2)
    handle.write("\n")
PY
  printf '%s\n' "$manifest_path"
}

profile_manifest="$(write_profile_fixture)"
duplicate_env_manifest="$(write_duplicate_env_fixture)"
duplicate_filename_manifest="$(write_duplicate_filename_fixture)"
rust_out="$(mktemp_tracked)"

scripts/runtime/generate_app_metadata.py --manifest "$profile_manifest" --rust-out "$rust_out" >/dev/null
python3 - "$rust_out" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")

def array_body(name: str) -> str:
    marker = f"pub const {name}:"
    start = text.index(marker)
    start = text.index("[\n", start) + 2
    end = text.index("];", start)
    return text[start:end]

all_apps = array_body("DEMO_APPS")
vm_shell_apps = array_body("VM_SHELL_DEMO_APPS")
pixel_shell_apps = array_body("PIXEL_SHELL_DEMO_APPS")

if "VM_ONLY_APP" not in all_apps or "PIXEL_ONLY_APP" not in all_apps or "SHARED_APP" not in all_apps:
    raise SystemExit("app_metadata_manifest_smoke: generated DEMO_APPS is missing fixture apps")
if "VM_ONLY_APP" not in vm_shell_apps or "SHARED_APP" not in vm_shell_apps or "PIXEL_ONLY_APP" in vm_shell_apps:
    raise SystemExit("app_metadata_manifest_smoke: generated VM_SHELL_DEMO_APPS is not profile filtered")
if "PIXEL_ONLY_APP" not in pixel_shell_apps or "SHARED_APP" not in pixel_shell_apps or "VM_ONLY_APP" in pixel_shell_apps:
    raise SystemExit("app_metadata_manifest_smoke: generated PIXEL_SHELL_DEMO_APPS is not profile filtered")
PY

check_output_case \
  shadowctl_vm_accepts_vm_only \
  0 \
  "command=$SCRIPT_DIR/vm/ui_vm_run.sh --app vm-only" \
  "" \
  env SHADOW_APP_METADATA_MANIFEST="$profile_manifest" "$SHADOWCTL_SCRIPT" run --dry-run -t vm --app vm-only

check_output_case \
  shadowctl_pixel_rejects_vm_only \
  1 \
  "" \
  "unsupported app 'vm-only'" \
  env SHADOW_APP_METADATA_MANIFEST="$profile_manifest" "$SHADOWCTL_SCRIPT" run --dry-run -t TESTSERIAL --app vm-only

check_output_case \
  shadowctl_pixel_accepts_pixel_only \
  0 \
  "command=$SCRIPT_DIR/pixel/pixel_shell_drm_hold.sh --app pixel-only" \
  "" \
  env SHADOW_APP_METADATA_MANIFEST="$profile_manifest" "$SHADOWCTL_SCRIPT" run --dry-run -t TESTSERIAL --app pixel-only

check_output_case \
  shadowctl_vm_rejects_pixel_only \
  1 \
  "" \
  "unsupported app 'pixel-only'" \
  env SHADOW_APP_METADATA_MANIFEST="$profile_manifest" "$SHADOWCTL_SCRIPT" run --dry-run -t vm --app pixel-only

check_output_case \
  shadowctl_uses_manifest_shell_id \
  0 \
  "command=$SCRIPT_DIR/vm/ui_vm_run.sh" \
  "" \
  env SHADOW_APP_METADATA_MANIFEST="$profile_manifest" "$SHADOWCTL_SCRIPT" run --dry-run -t vm --app home-shell

check_output_case \
  session_apps_helper_uses_manifest_shell_id \
  0 \
  "shell-ok" \
  "" \
  env SHADOW_APP_METADATA_MANIFEST="$profile_manifest" SHADOW_SESSION_APP_PROFILE=vm-shell \
    bash -lc 'cd "$0" && source scripts/lib/session_apps.sh && shadow_session_app_is_shell home-shell && printf "shell-ok\n"' "$REPO_ROOT"

check_output_case \
  pixel_common_filters_pixel_shell_apps \
  0 \
  "$(printf 'pixel-only\nshared')" \
  "" \
  env SHADOW_APP_METADATA_MANIFEST="$profile_manifest" \
    bash -lc 'cd "$0" && source scripts/lib/pixel_common.sh && pixel_runtime_shell_app_ids' "$REPO_ROOT"

check_output_case \
  generate_app_metadata_rejects_duplicate_bundle_env \
  1 \
  "" \
  "duplicate bundleEnv" \
  scripts/runtime/generate_app_metadata.py --manifest "$duplicate_env_manifest" --rust-out "$rust_out"

check_output_case \
  runtime_build_artifacts_rejects_duplicate_bundle_env \
  1 \
  "" \
  "duplicate runtime.bundleEnv" \
  env SHADOW_APP_METADATA_MANIFEST="$duplicate_env_manifest" \
    deno run --quiet --allow-env --allow-read --allow-write --allow-run \
      scripts/runtime/runtime_build_artifacts.ts --profile vm-shell

check_output_case \
  generate_app_metadata_rejects_duplicate_bundle_filename \
  1 \
  "" \
  "duplicate bundleFilename" \
  scripts/runtime/generate_app_metadata.py --manifest "$duplicate_filename_manifest" --rust-out "$rust_out"

check_output_case \
  runtime_build_artifacts_rejects_duplicate_bundle_filename \
  1 \
  "" \
  "duplicate runtime.bundleFilename" \
  env SHADOW_APP_METADATA_MANIFEST="$duplicate_filename_manifest" \
    deno run --quiet --allow-env --allow-read --allow-write --allow-run \
      scripts/runtime/runtime_build_artifacts.ts --profile vm-shell

printf 'app_metadata_manifest_smoke: ok\n'
