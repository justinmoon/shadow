#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/shadow-vm-smoke-logical-inputs.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

TEMP_ROOT="$TMP_DIR/root"
TEMP_WORKTREE="$TMP_DIR/worktree"
FAKE_BIN_DIR="$TMP_DIR/bin"
FAKE_NIX_LOG="$TMP_DIR/nix.log"

temp_git() {
  env \
    -u GIT_DIR \
    -u GIT_WORK_TREE \
    -u GIT_INDEX_FILE \
    -u GIT_PREFIX \
    -u GIT_COMMON_DIR \
    -u GIT_OBJECT_DIRECTORY \
    -u GIT_ALTERNATE_OBJECT_DIRECTORIES \
    git "$@"
}

mkdir -p "$TEMP_ROOT/scripts/ci" "$TEMP_ROOT/scripts/lib" "$FAKE_BIN_DIR"
cp "$REPO_ROOT/scripts/ci/required_vm_smoke.sh" "$TEMP_ROOT/scripts/ci/required_vm_smoke.sh"
cp "$REPO_ROOT/scripts/lib/shadow_common.sh" "$TEMP_ROOT/scripts/lib/shadow_common.sh"
cp "$REPO_ROOT/scripts/lib/ci_vm_smoke_common.sh" "$TEMP_ROOT/scripts/lib/ci_vm_smoke_common.sh"

temp_git init -b master "$TEMP_ROOT" >/dev/null
temp_git -C "$TEMP_ROOT" config user.name "Shadow Smoke"
temp_git -C "$TEMP_ROOT" config user.email "shadow-smoke@example.com"
temp_git -C "$TEMP_ROOT" add scripts
temp_git -C "$TEMP_ROOT" commit -m "init" >/dev/null
temp_git -C "$TEMP_ROOT" worktree add -b logical-inputs-smoke "$TEMP_WORKTREE" >/dev/null

cat >"$FAKE_BIN_DIR/nix" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"$FAKE_NIX_LOG"

if [[ "${1:-}" == "path-info" && "${2:-}" == "--accept-flake-config" && "${3:-}" == "--derivation" ]]; then
  printf '/nix/store/test-shadow-vm-smoke-inputs.drv\n'
  exit 0
fi

if [[ "${1:-}" == "build" ]]; then
  echo "unexpected nix build invocation: $*" >&2
  exit 99
fi

echo "unexpected nix invocation: $*" >&2
exit 98
EOF
chmod 0755 "$FAKE_BIN_DIR/nix"

output="$(
  cd "$TEMP_WORKTREE"
  env \
    -u GIT_DIR \
    -u GIT_WORK_TREE \
    -u GIT_INDEX_FILE \
    -u GIT_PREFIX \
    -u GIT_COMMON_DIR \
    -u GIT_OBJECT_DIRECTORY \
    -u GIT_ALTERNATE_OBJECT_DIRECTORIES \
    FAKE_NIX_LOG="$FAKE_NIX_LOG" \
    PATH="$FAKE_BIN_DIR:$PATH" \
    bash "$TEMP_WORKTREE/scripts/ci/required_vm_smoke.sh"
)"

grep -Fq "pre-merge: skip vm smoke; logical inputs match root master" <<<"$output"

if grep -Fq "build --accept-flake-config --no-link --print-out-paths" "$FAKE_NIX_LOG"; then
  echo "vm-smoke logical-inputs smoke: unexpectedly ran nix build before skip" >&2
  cat "$FAKE_NIX_LOG" >&2
  exit 1
fi
