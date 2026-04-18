#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SHADOWCTL_SCRIPT="$SCRIPT_DIR/shadowctl"
TMP_FILES=()

cleanup() {
  if ((${#TMP_FILES[@]})); then
    rm -rf "${TMP_FILES[@]}"
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
            "model": "typescript",
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
            "model": "typescript",
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
            "model": "typescript",
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
            "model": "typescript",
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
            "model": "typescript",
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
            "model": "typescript",
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
            "model": "typescript",
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

check_runtime_session_env_case() {
  local name="$1"
  local manifest_path="$2"
  local expected_apps_csv="$3"
  local artifact_root env_output_path
  artifact_root="$(mktemp -d "${TMPDIR:-/tmp}/app-metadata-runtime-artifacts.XXXXXX")"
  TMP_FILES+=("$artifact_root")
  env_output_path="$(mktemp_tracked)"

  (
    cd "$REPO_ROOT"
    env SHADOW_APP_METADATA_MANIFEST="$manifest_path" \
      scripts/runtime/runtime_prepare_host_session_env.sh \
        --runtime-host-binary-path /tmp/shadow-runtime-host \
        --artifact-root "$artifact_root" \
        --artifact-guest-root /opt/shadow-runtime \
        >"$env_output_path"
  )

  python3 - "$artifact_root" "$env_output_path" "$expected_apps_csv" <<'PY'
import json
import sys
from pathlib import Path

artifact_root = Path(sys.argv[1])
env_output_path = Path(sys.argv[2])
expected_apps = {app_id for app_id in sys.argv[3].split(",") if app_id}

manifest_path = artifact_root / "artifact-manifest.json"
if not manifest_path.is_file():
    raise SystemExit(f"missing runtime artifact manifest {manifest_path}")

with manifest_path.open("r", encoding="utf-8") as handle:
    manifest = json.load(handle)

if manifest.get("schemaVersion") != 1:
    raise SystemExit("runtime artifact manifest schemaVersion must be 1")
if manifest.get("profile") != "vm-shell":
    raise SystemExit("runtime artifact manifest profile must be vm-shell")
if manifest.get("artifactGuestRoot") != "/opt/shadow-runtime":
    raise SystemExit("runtime artifact manifest guest root mismatch")

apps = manifest.get("apps")
if not isinstance(apps, dict):
    raise SystemExit("runtime artifact manifest apps must be an object")
actual_apps = set(apps)
if actual_apps != expected_apps:
    raise SystemExit(
        f"runtime artifact manifest app set mismatch: expected {sorted(expected_apps)!r}, got {sorted(actual_apps)!r}"
    )

env_text = env_output_path.read_text(encoding="utf-8")
if "export SHADOW_SESSION_APP_PROFILE='vm-shell'" not in env_text:
    raise SystemExit("session env missing SHADOW_SESSION_APP_PROFILE")
if "export SHADOW_RUNTIME_HOST_BINARY_PATH='/tmp/shadow-runtime-host'" not in env_text:
    raise SystemExit("session env missing SHADOW_RUNTIME_HOST_BINARY_PATH")

if expected_apps:
    if "export SHADOW_RUNTIME_APP_BUNDLE_PATH=" not in env_text:
        raise SystemExit("session env missing SHADOW_RUNTIME_APP_BUNDLE_PATH")
else:
    if "export SHADOW_RUNTIME_APP_BUNDLE_PATH=" in env_text:
        raise SystemExit("session env unexpectedly exports SHADOW_RUNTIME_APP_BUNDLE_PATH")
PY
}

write_rust_fixture() {
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
            "id": "rust-notes",
            "model": "rust",
            "title": "Rust Notes",
            "iconLabel": "RN",
            "subtitle": "Rust lane",
            "lifecycleHint": "Rust app placeholder.",
            "binaryName": "shadow-rust-demo",
            "waylandAppId": "dev.shadow.rust-notes",
            "windowTitle": "Rust Notes",
            "profiles": ["vm-shell"],
            "ui": {"iconColor": "ICON_PURPLE"},
        },
    ],
}
with open(manifest_path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2)
    handle.write("\n")
PY
  printf '%s\n' "$manifest_path"
}

write_invalid_rust_pixel_fixture() {
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
            "id": "rust-pixel",
            "model": "rust",
            "title": "Rust Pixel",
            "iconLabel": "RP",
            "subtitle": "Invalid pixel rust lane",
            "lifecycleHint": "Invalid Rust app profile.",
            "binaryName": "shadow-rust-demo",
            "waylandAppId": "dev.shadow.rust-pixel",
            "windowTitle": "Rust Pixel",
            "profiles": ["vm-shell", "pixel-shell"],
            "ui": {"iconColor": "ICON_PURPLE"},
        },
    ],
}
with open(manifest_path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2)
    handle.write("\n")
PY
  printf '%s\n' "$manifest_path"
}

write_mixed_model_fixture() {
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
            "id": "mixed-ts",
            "model": "typescript",
            "title": "Mixed TS",
            "iconLabel": "MT",
            "subtitle": "TypeScript lane",
            "lifecycleHint": "TypeScript app in mixed profile.",
            "binaryName": "shadow-blitz-demo",
            "waylandAppId": "dev.shadow.mixed-ts",
            "windowTitle": "Mixed TS",
            "runtime": {
                "bundleEnv": "SHADOW_RUNTIME_APP_MIXED_TS_BUNDLE_PATH",
                "bundleFilename": "runtime-app-mixed-ts-bundle.js",
                "inputPath": "runtime/app-counter/app.tsx",
                "cacheDirs": {
                    "pixel-shell": "build/runtime/pixel-mixed-ts",
                    "vm-shell": "build/runtime/vm-mixed-ts",
                },
                "config": None,
            },
            "profiles": ["vm-shell", "pixel-shell"],
            "ui": {"iconColor": "ICON_CYAN"},
        },
        {
            "id": "mixed-rust",
            "model": "rust",
            "title": "Mixed Rust",
            "iconLabel": "MR",
            "subtitle": "Rust lane",
            "lifecycleHint": "Rust app in mixed profile.",
            "binaryName": "shadow-rust-demo",
            "waylandAppId": "dev.shadow.mixed-rust",
            "windowTitle": "Mixed Rust",
            "profiles": ["vm-shell"],
            "ui": {"iconColor": "ICON_PURPLE"},
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
rust_manifest="$(write_rust_fixture)"
invalid_rust_pixel_manifest="$(write_invalid_rust_pixel_fixture)"
mixed_model_manifest="$(write_mixed_model_fixture)"
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

scripts/runtime/generate_app_metadata.py --manifest "$rust_manifest" --rust-out "$rust_out" >/dev/null
python3 - "$rust_out" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")

if 'pub const RUST_NOTES_MODEL: AppModel = AppModel::Rust;' not in text:
    raise SystemExit("app_metadata_manifest_smoke: rust app model was not generated")
if "typescript_runtime: None" not in text:
    raise SystemExit("app_metadata_manifest_smoke: rust app should not get TypeScript runtime metadata")
PY

check_output_case \
  rust_pixel_profile_rejected \
  1 \
  "" \
  "rust apps must not declare pixel-shell" \
  scripts/runtime/generate_app_metadata.py --manifest "$invalid_rust_pixel_manifest" --rust-out "$rust_out"

scripts/runtime/generate_app_metadata.py --manifest "$mixed_model_manifest" --rust-out "$rust_out" >/dev/null
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

vm_shell_apps = array_body("VM_SHELL_DEMO_APPS")
pixel_shell_apps = array_body("PIXEL_SHELL_DEMO_APPS")

if "MIXED_TS_APP" not in vm_shell_apps or "MIXED_RUST_APP" not in vm_shell_apps:
    raise SystemExit("app_metadata_manifest_smoke: generated VM_SHELL_DEMO_APPS should include both mixed-model VM apps")
if "MIXED_TS_APP" not in pixel_shell_apps or "MIXED_RUST_APP" in pixel_shell_apps:
    raise SystemExit("app_metadata_manifest_smoke: generated PIXEL_SHELL_DEMO_APPS should only include launchable mixed-model apps")
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
  shadowctl_vm_accepts_mixed_rust_session_app \
  0 \
  "command=$SCRIPT_DIR/vm/ui_vm_run.sh --app mixed-rust" \
  "" \
  env SHADOW_APP_METADATA_MANIFEST="$mixed_model_manifest" "$SHADOWCTL_SCRIPT" run --dry-run -t vm --app mixed-rust

check_output_case \
  shadowctl_vm_accepts_mixed_typescript_session_app \
  0 \
  "command=$SCRIPT_DIR/vm/ui_vm_run.sh --app mixed-ts" \
  "" \
  env SHADOW_APP_METADATA_MANIFEST="$mixed_model_manifest" "$SHADOWCTL_SCRIPT" run --dry-run -t vm --app mixed-ts

check_output_case \
  session_apps_helper_filters_mixed_launchable_apps \
  0 \
  "$(printf 'shell\nmixed-ts\nmixed-rust')" \
  "" \
  env SHADOW_APP_METADATA_MANIFEST="$mixed_model_manifest" SHADOW_SESSION_APP_PROFILE=vm-shell \
    bash -lc 'cd "$0" && source scripts/lib/session_apps.sh && shadow_load_session_apps && printf "%s\n" "${shadow_session_apps[@]}"' "$REPO_ROOT"

check_output_case \
  pixel_common_filters_mixed_launchable_apps \
  0 \
  "mixed-ts" \
  "" \
  env SHADOW_APP_METADATA_MANIFEST="$mixed_model_manifest" \
    bash -lc 'cd "$0" && source scripts/lib/pixel_common.sh && pixel_session_shell_app_ids' "$REPO_ROOT"

check_output_case \
  pixel_common_filters_mixed_runtime_apps \
  0 \
  "mixed-ts" \
  "" \
  env SHADOW_APP_METADATA_MANIFEST="$mixed_model_manifest" \
    bash -lc 'cd "$0" && source scripts/lib/pixel_common.sh && pixel_runtime_shell_app_ids' "$REPO_ROOT"

check_output_case \
  runtime_build_artifacts_accepts_mixed_model_profile \
  0 \
  "\"mixed-ts\"" \
  "" \
  env SHADOW_APP_METADATA_MANIFEST="$mixed_model_manifest" \
    deno run --quiet --allow-env --allow-read --allow-write --allow-run \
      scripts/runtime/runtime_build_artifacts.ts --profile vm-shell

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

check_output_case \
  runtime_build_artifacts_rejects_rust_app_model \
  1 \
  "" \
  "uses model rust; runtime_build_artifacts only supports typescript apps" \
  env SHADOW_APP_METADATA_MANIFEST="$rust_manifest" \
    deno run --quiet --allow-env --allow-read --allow-write --allow-run \
      scripts/runtime/runtime_build_artifacts.ts --profile vm-shell --include-app rust-notes

check_output_case \
  runtime_build_artifacts_rejects_mixed_profile_rust_include \
  1 \
  "" \
  "uses model rust; runtime_build_artifacts only supports typescript apps" \
  env SHADOW_APP_METADATA_MANIFEST="$mixed_model_manifest" \
    deno run --quiet --allow-env --allow-read --allow-write --allow-run \
      scripts/runtime/runtime_build_artifacts.ts --profile vm-shell --include-app mixed-rust

check_runtime_session_env_case \
  runtime_prepare_host_session_env_supports_rust_only_profile \
  "$rust_manifest" \
  ""

check_runtime_session_env_case \
  runtime_prepare_host_session_env_tracks_mixed_profile_typescript_apps \
  "$mixed_model_manifest" \
  "mixed-ts"

printf 'app_metadata_manifest_smoke: ok\n'
