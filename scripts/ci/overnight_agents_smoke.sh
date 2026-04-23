#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CTL_PATH="$REPO_ROOT/scripts/debug/dispatch.py"
COMMON_PATH="$REPO_ROOT/scripts/lib/overnight_common.py"

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/dispatch-smoke.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT

repo="$tmpdir/repo"
mkdir -p "$repo/scripts/debug" "$repo/scripts/lib" "$repo/todos" "$repo/.agents/dispatch/projects"
ln -s "$CTL_PATH" "$repo/scripts/debug/dispatch.py"
ln -s "$COMMON_PATH" "$repo/scripts/lib/overnight_common.py"

cd "$repo"
git init -q
git config user.name "Dispatch Smoke"
git config user.email "dispatch-smoke@example.com"

cat >todos/alpha.md <<'EOF'
# Alpha Plan

## Ladder

- [ ] broad roadmap rung
  - acceptance:
    - should not import

## Next Dispatch Batch

- [ ] `first concrete task`
  - owned paths:
    - `runtime/`
    - `ui/`
  - validation:
    - `just pre-commit`
- [ ] `second concrete task`
  - owned paths:
    - `ui/`
  - validation:
    - `just ui-check core`
  - blocked_by:
    - `first concrete task`
EOF

git add .
git commit -qm "test: seed interactive dispatch smoke repo"

python3 "$CTL_PATH" project-init --project alpha --plan todos/alpha.md >/dev/null
python3 "$CTL_PATH" queue-import-plan --project alpha >/dev/null

python3 - <<'PY'
from __future__ import annotations

import json
from pathlib import Path

queue = json.loads(Path(".agents/dispatch/state/projects/alpha/queue.json").read_text())
assert set(queue) == {"project", "tasks"}, queue
assert len(queue["tasks"]) == 2, queue
first, second = queue["tasks"]
assert first["title"] == "first concrete task", first
assert first["state"] == "ready", first
assert first["paths"] == ["runtime/", "ui/"], first
assert first["validation"] == ["just pre-commit"], first
assert "blocked_by" not in first, first
assert second["blocked_by"] == [first["id"]], second
claims = json.loads(Path(".agents/dispatch/state/projects/alpha/claims.json").read_text())
assert claims == {"project": "alpha", "claims": {}}, claims
PY

worker="$tmpdir/alpha-worker"
git worktree add -q -b alpha-worker "$worker" HEAD

first_claim="$(python3 "$CTL_PATH" interactive-next --project alpha --worktree "$worker" --json)"
second_claim="$(python3 "$CTL_PATH" interactive-next --project alpha --worktree "$worker" --json)"

python3 - "$first_claim" "$second_claim" <<'PY'
from __future__ import annotations

import json
import sys

first = json.loads(sys.argv[1])
second = json.loads(sys.argv[2])
assert first["action"] == "claimed", first
assert first["task"]["title"] == "first concrete task", first
assert second["action"] == "resume", second
assert second["task"]["id"] == first["task"]["id"], second
PY

python3 - "$worker" <<'PY'
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

worker = Path(sys.argv[1])
(worker / "note.txt").write_text("done\n", encoding="utf-8")
subprocess.run(["git", "add", "note.txt"], cwd=worker, check=True)
subprocess.run(["git", "commit", "-qm", "test: finish first task"], cwd=worker, check=True)
subprocess.run(["git", "merge", "--ff-only", "alpha-worker"], check=True)
PY

third_claim="$(python3 "$CTL_PATH" interactive-next --project alpha --worktree "$worker" --json)"

python3 - "$third_claim" <<'PY'
from __future__ import annotations

import json
import sys

payload = json.loads(sys.argv[1])
assert payload["action"] == "claimed", payload
assert payload["task"]["title"] == "second concrete task", payload
PY

python3 "$CTL_PATH" interactive-finish --project alpha --worktree "$worker" --state blocked >/dev/null

python3 - <<'PY'
from __future__ import annotations

import json
from pathlib import Path

queue = json.loads(Path(".agents/dispatch/state/projects/alpha/queue.json").read_text())
claims = json.loads(Path(".agents/dispatch/state/projects/alpha/claims.json").read_text())
states = {task["title"]: task["state"] for task in queue["tasks"]}
assert states == {"first concrete task": "done", "second concrete task": "blocked"}, states
assert claims == {"project": "alpha", "claims": {}}, claims
PY
