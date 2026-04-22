#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/shadow-pixel-boot-rust-bridge-run.XXXXXX")"
RUN_DIR="$TMP_DIR/run"
INPUT_IMAGE="$TMP_DIR/base.img"
BUILD_ARGS_PATH="$TMP_DIR/build.args"
ONESHOT_ARGS_PATH="$TMP_DIR/oneshot.args"
BUILD_SCRIPT="$TMP_DIR/mock-build.sh"
ONESHOT_SCRIPT="$TMP_DIR/mock-oneshot.sh"
MOCK_BIN_DIR="$TMP_DIR/bin"

cleanup() {
  rm -rf "$TMP_DIR"
}

trap cleanup EXIT

printf 'base image\n' >"$INPUT_IMAGE"
mkdir -p "$MOCK_BIN_DIR"

cat >"$BUILD_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$@" >"$PIXEL_TEST_BUILD_ARGS_PATH"
output=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      output="${2:?missing value for --output}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

mkdir -p "$(dirname "$output")"
printf 'built image\n' >"$output"
printf '{}\n' >"$output.hello-init.json"
EOF
chmod 0755 "$BUILD_SCRIPT"

cat >"$ONESHOT_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$@" >"$PIXEL_TEST_ONESHOT_ARGS_PATH"
output=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      output="${2:?missing value for --output}"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

mkdir -p "$output"
printf '{\"ok\": true}\n' >"$output/status.json"
EOF
chmod 0755 "$ONESHOT_SCRIPT"

cat >"$MOCK_BIN_DIR/adb" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "devices" ]]; then
  cat <<OUT
List of devices attached
TESTSERIAL	device
OUT
  exit 0
fi

exit 0
EOF
chmod 0755 "$MOCK_BIN_DIR/adb"

cat >"$MOCK_BIN_DIR/fastboot" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 0755 "$MOCK_BIN_DIR/fastboot"

assert_contains() {
  local file_path needle
  file_path="$1"
  needle="$2"
  if ! grep -Fq -- "$needle" "$file_path"; then
    echo "pixel_boot_rust_bridge_run_smoke: expected $file_path to contain: $needle" >&2
    cat "$file_path" >&2
    exit 1
  fi
}

assert_json_field() {
  local json_path key expected
  json_path="$1"
  key="$2"
  expected="$3"

  python3 - "$json_path" "$key" "$expected" <<'PY'
import json
import sys

path, key, expected = sys.argv[1:4]
with open(path, "r", encoding="utf-8") as fh:
    payload = json.load(fh)

value = payload[key]
if isinstance(value, bool):
    rendered = "true" if value else "false"
else:
    rendered = str(value)

if rendered != expected:
    raise SystemExit(f"{path}: expected {key}={expected!r}, got {rendered!r}")
PY
}

PATH="$MOCK_BIN_DIR:$PATH" \
PIXEL_SERIAL=TESTSERIAL \
PIXEL_BOOT_RUST_BRIDGE_BUILD_SCRIPT="$BUILD_SCRIPT" \
PIXEL_BOOT_RUST_BRIDGE_ONESHOT_SCRIPT="$ONESHOT_SCRIPT" \
PIXEL_TEST_BUILD_ARGS_PATH="$BUILD_ARGS_PATH" \
PIXEL_TEST_ONESHOT_ARGS_PATH="$ONESHOT_ARGS_PATH" \
scripts/pixel/pixel_boot_rust_bridge_run.sh \
  --input "$INPUT_IMAGE" \
  --output-dir "$RUN_DIR" \
  --shim-mode exec \
  --child-profile std-probe \
  --adb-timeout 45 \
  --boot-timeout 60 \
  --skip-collect \
  --recover-traces-after

[[ -f "$RUN_DIR/rust-bridge.img" ]] || {
  echo "pixel_boot_rust_bridge_run_smoke: missing built image" >&2
  exit 1
}

assert_contains "$BUILD_ARGS_PATH" "--input"
assert_contains "$BUILD_ARGS_PATH" "$INPUT_IMAGE"
assert_contains "$BUILD_ARGS_PATH" "--output"
assert_contains "$BUILD_ARGS_PATH" "$RUN_DIR/rust-bridge.img"
assert_contains "$BUILD_ARGS_PATH" "--shim-mode"
assert_contains "$BUILD_ARGS_PATH" "exec"
assert_contains "$BUILD_ARGS_PATH" "--child-profile"
assert_contains "$BUILD_ARGS_PATH" "std-probe"

assert_contains "$ONESHOT_ARGS_PATH" "--image"
assert_contains "$ONESHOT_ARGS_PATH" "$RUN_DIR/rust-bridge.img"
assert_contains "$ONESHOT_ARGS_PATH" "--output"
assert_contains "$ONESHOT_ARGS_PATH" "$RUN_DIR/device-run"
assert_contains "$ONESHOT_ARGS_PATH" "--adb-timeout"
assert_contains "$ONESHOT_ARGS_PATH" "45"
assert_contains "$ONESHOT_ARGS_PATH" "--boot-timeout"
assert_contains "$ONESHOT_ARGS_PATH" "60"
assert_contains "$ONESHOT_ARGS_PATH" "--skip-collect"
assert_contains "$ONESHOT_ARGS_PATH" "--recover-traces-after"

assert_json_field "$RUN_DIR/status.json" kind "boot_rust_bridge_run"
assert_json_field "$RUN_DIR/status.json" serial "TESTSERIAL"
assert_json_field "$RUN_DIR/status.json" shim_mode "exec"
assert_json_field "$RUN_DIR/status.json" child_profile "std-probe"
assert_json_field "$RUN_DIR/status.json" build_succeeded "true"
assert_json_field "$RUN_DIR/status.json" run_succeeded "true"
