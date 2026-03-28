#!/usr/bin/env bash
set -euo pipefail

exec ssh \
  -p 2222 \
  -o LogLevel=ERROR \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  shadow@127.0.0.1 \
  "$@"
