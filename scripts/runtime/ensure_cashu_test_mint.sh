#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${SHADOW_CASHU_TEST_MINT_BIN:-}" ]]; then
  printf '%s\n' "$SHADOW_CASHU_TEST_MINT_BIN"
  exit 0
fi

CDK_REPO="${SHADOW_CASHU_CDK_REPO:-$HOME/code/oss/cdk}"
TARGET_DIR="${SHADOW_CASHU_CDK_TARGET_DIR:-$CDK_REPO/target/shadow-cashu-fakewallet}"
BINARY_PATH="$TARGET_DIR/release/cdk-mintd"

if [[ ! -d "$CDK_REPO" ]]; then
  echo "ensure_cashu_test_mint.sh: missing CDK repo at $CDK_REPO" >&2
  exit 1
fi

if [[ ! -x "$BINARY_PATH" ]]; then
  nix develop --accept-flake-config "$CDK_REPO#stable" -c bash -lc "
    set -euo pipefail
    cd '$CDK_REPO'
    export CARGO_TARGET_DIR='$TARGET_DIR'
    cargo build --release -p cdk-mintd --bin cdk-mintd --no-default-features --features fakewallet,sqlite
  " >&2
fi

if [[ ! -x "$BINARY_PATH" ]]; then
  echo "ensure_cashu_test_mint.sh: expected binary at $BINARY_PATH" >&2
  exit 1
fi

printf '%s\n' "$BINARY_PATH"
