#!/usr/bin/env python3

from __future__ import annotations

import contextlib
import fcntl
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path
from typing import Any, Iterator

VALID_TASK_STATES = {"backlog", "ready", "running", "done", "blocked"}
TASK_ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")


def run(
    args: list[str],
    *,
    cwd: Path | None = None,
    check: bool = True,
    capture_output: bool = True,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args,
        cwd=str(cwd) if cwd else None,
        check=check,
        capture_output=capture_output,
        text=True,
    )


def git_output(args: list[str], *, cwd: Path) -> str:
    return run(["git", *args], cwd=cwd).stdout.strip()


def repo_root(cwd: Path | None = None) -> Path:
    override = os.environ.get("SHADOW_REPO_ROOT_OVERRIDE")
    if override:
        return Path(override).resolve()
    output = git_output(["rev-parse", "--show-toplevel"], cwd=cwd or Path.cwd())
    return Path(output).resolve()


def repo_common_root(cwd: Path | None = None) -> Path:
    override = os.environ.get("SHADOW_REPO_COMMON_ROOT")
    if override:
        return Path(override).resolve()
    target = cwd or Path.cwd()
    common_dir = git_output(["rev-parse", "--git-common-dir"], cwd=target)
    common_path = Path(common_dir)
    if not common_path.is_absolute():
        common_path = (target / common_path).resolve()
    return common_path.parent.resolve()


def checked_in_root(cwd: Path | None = None) -> Path:
    return repo_root(cwd) / ".agents" / "dispatch"


def runtime_root(common_root: Path) -> Path:
    return common_root / ".agents" / "dispatch" / "state"


def project_defs_dir(cwd: Path | None = None) -> Path:
    return checked_in_root(cwd) / "projects"


def project_def_path(cwd: Path | None, project_id: str) -> Path:
    return project_defs_dir(cwd) / f"{project_id}.json"


def runtime_project_dir(common_root: Path, project_id: str) -> Path:
    return runtime_root(common_root) / "projects" / project_id


def queue_path(common_root: Path, project_id: str) -> Path:
    return runtime_project_dir(common_root, project_id) / "queue.json"


def claims_path(common_root: Path, project_id: str) -> Path:
    return runtime_project_dir(common_root, project_id) / "claims.json"


def project_lock_path(common_root: Path, project_id: str) -> Path:
    return runtime_project_dir(common_root, project_id) / "project.lock"


def ensure_runtime_layout(common_root: Path, project_id: str | None = None) -> None:
    runtime_root(common_root).mkdir(parents=True, exist_ok=True)
    (runtime_root(common_root) / "projects").mkdir(parents=True, exist_ok=True)
    if project_id:
        runtime_project_dir(common_root, project_id).mkdir(parents=True, exist_ok=True)


def load_json(path: Path, default: Any) -> Any:
    if not path.exists():
        return default
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", delete=False, dir=path.parent, encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2)
        handle.write("\n")
        temp_path = Path(handle.name)
    temp_path.replace(path)


@contextlib.contextmanager
def locked_file(path: Path) -> Iterator[None]:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a+", encoding="utf-8") as handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def slugify(text: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return slug or "task"


def discover_project_ids(cwd: Path | None = None) -> list[str]:
    if not project_defs_dir(cwd).exists():
        return []
    return sorted(path.stem for path in project_defs_dir(cwd).glob("*.json"))


def load_project(cwd: Path | None, project_id: str) -> dict[str, Any]:
    payload = load_json(project_def_path(cwd, project_id), None)
    if payload is None or not payload.get("plan_path"):
        raise SystemExit(f"dispatch: missing project definition for {project_id}")
    return {"project": project_id, "plan_path": str(payload["plan_path"])}


def save_project(cwd: Path | None, project_id: str, payload: dict[str, Any]) -> None:
    if not payload.get("plan_path"):
        raise SystemExit(f"dispatch: project {project_id} is missing plan_path")
    write_json(project_def_path(cwd, project_id), {"plan_path": str(payload["plan_path"])})


def empty_queue(project_id: str) -> dict[str, Any]:
    return {"project": project_id, "task_states": {}}


def normalize_task(task: dict[str, Any]) -> dict[str, Any]:
    normalized: dict[str, Any] = {
        "id": str(task.get("id", "")).strip(),
        "title": str(task.get("title", "")).strip(),
        "state": str(task.get("state", "backlog")).strip() or "backlog",
        "priority": int(task.get("priority", 100)),
        "plan_ref": str(task.get("plan_ref", "")).strip() or None,
        "paths": [str(item).strip() for item in task.get("paths") or [] if str(item).strip()],
        "validation": [str(item).strip() for item in task.get("validation") or [] if str(item).strip()],
    }
    blockers = [str(item).strip() for item in task.get("blocked_by") or [] if str(item).strip()]
    if blockers:
        normalized["blocked_by"] = blockers
    if normalized["state"] not in VALID_TASK_STATES:
        normalized["state"] = "backlog"
    return normalized


def normalize_task_state(value: Any) -> str:
    state = str(value or "backlog").strip()
    return state if state in VALID_TASK_STATES else "backlog"


def normalize_queue_state(project_id: str, payload: dict[str, Any]) -> dict[str, Any]:
    task_states: dict[str, str] = {}
    legacy_by_id: dict[str, dict[str, Any]] = {}

    for task_id, state in (payload.get("task_states") or {}).items():
        task_id = str(task_id).strip()
        if task_id:
            task_states[task_id] = normalize_task_state(state)

    # Backward compatibility for pre-plan-backed queue.json files.
    for task in payload.get("tasks") or []:
        normalized = normalize_task(task)
        if not normalized["id"] or not normalized["title"]:
            continue
        task_states[normalized["id"]] = normalized["state"]
        legacy_by_id[normalized["id"]] = normalized

    for task in payload.get("legacy_tasks") or []:
        normalized = normalize_task(task)
        if not normalized["id"] or not normalized["title"]:
            continue
        task_states.setdefault(normalized["id"], normalized["state"])
        legacy_by_id[normalized["id"]] = normalized

    payload_out: dict[str, Any] = {
        "project": payload.get("project", project_id),
        "task_states": task_states,
    }
    if legacy_by_id:
        payload_out["legacy_tasks"] = list(legacy_by_id.values())
    return payload_out


def plan_default_state(item: dict[str, Any]) -> str:
    if item.get("state") in VALID_TASK_STATES:
        return item["state"]
    mark = str(item.get("mark", " ")).strip().lower()
    if mark == "x":
        return "done"
    if mark == "~":
        return "blocked"
    return "ready" if "next dispatch batch" in str(item.get("section", "")).lower() else "backlog"


def plan_state_is_explicit(item: dict[str, Any]) -> bool:
    mark = str(item.get("mark", " ")).strip().lower()
    return item.get("state") in VALID_TASK_STATES or mark in {"x", "~"}


def resolve_plan_blockers(tasks: list[dict[str, Any]], blockers: list[str]) -> list[str]:
    known_ids = {task["id"] for task in tasks}
    title_to_ids: dict[str, list[str]] = {}
    for task in tasks:
        title_to_ids.setdefault(task["title"], []).append(task["id"])
    resolved: list[str] = []
    for blocker in blockers:
        if blocker in title_to_ids:
            title_ids = title_to_ids[blocker]
            if len(title_ids) > 1:
                raise SystemExit(f"dispatch: ambiguous blocker title {blocker!r}; use task_id instead")
            resolved.append(title_ids[0])
            continue
        if blocker in known_ids:
            resolved.append(blocker)
            continue
        raise SystemExit(f"dispatch: unknown blocker {blocker!r}")
    return list(dict.fromkeys(resolved))


def materialize_plan_queue(cwd: Path | None, project_id: str, state_payload: dict[str, Any]) -> dict[str, Any]:
    project = load_project(cwd, project_id)
    plan_path = (repo_root(cwd) / project["plan_path"]).resolve()
    imported = parse_plan_checklist(plan_path)
    legacy_tasks = [normalize_task(task) for task in state_payload.get("legacy_tasks") or []]
    legacy_title_to_id = {task["title"]: task["id"] for task in legacy_tasks if task.get("title") and task.get("id")}

    staged: list[dict[str, Any]] = []
    taken_ids: set[str] = set()
    for item in imported:
        task_id = str(item.get("task_id") or "").strip()
        if not task_id:
            task_id = legacy_title_to_id.get(item["title"], "")
        if not task_id:
            task_id = next_task_id(staged, project_id, item["title"])
        if not TASK_ID_RE.fullmatch(task_id):
            raise SystemExit(f"dispatch: invalid task id {task_id!r} in {project['plan_path']}:{item['line']}")
        if task_id in taken_ids:
            raise SystemExit(f"dispatch: duplicate task id {task_id!r} in {project['plan_path']}")
        taken_ids.add(task_id)
        staged.append({"id": task_id, "title": item["title"]})

    tasks: list[dict[str, Any]] = []
    overrides = state_payload.get("task_states", {})
    for order, item in enumerate(imported, start=1):
        task_id = staged[order - 1]["id"]
        default_state = plan_default_state(item)
        override_state = overrides.get(task_id)
        if override_state == "running" or (override_state and not plan_state_is_explicit(item)):
            state = override_state
        else:
            state = default_state
        task: dict[str, Any] = {
            "id": task_id,
            "title": item["title"],
            "state": state,
            "priority": int(item.get("priority", (10 if "next dispatch batch" in item["section"].lower() else 100) + order)),
            "plan_ref": f"{project['plan_path']}:{item['line']}",
            "paths": item.get("paths", []),
            "validation": item.get("validation", []),
            "source": "plan",
            "_default_state": default_state,
        }
        blockers = resolve_plan_blockers(staged, item.get("blocked_by", []))
        if blockers:
            task["blocked_by"] = blockers
        tasks.append(task)

    plan_ids = {task["id"] for task in tasks}
    for legacy in legacy_tasks:
        if legacy["id"] in plan_ids:
            continue
        legacy["state"] = overrides.get(legacy["id"], legacy["state"])
        legacy["source"] = "legacy"
        tasks.append(legacy)

    return {"project": project_id, "tasks": tasks}


def load_queue(common_root: Path, project_id: str, cwd: Path | None = None) -> dict[str, Any]:
    ensure_runtime_layout(common_root, project_id)
    state_payload = normalize_queue_state(project_id, load_json(queue_path(common_root, project_id), empty_queue(project_id)))
    return materialize_plan_queue(cwd, project_id, state_payload)


def save_queue(common_root: Path, project_id: str, payload: dict[str, Any]) -> None:
    task_states: dict[str, str] = {}
    legacy_tasks: list[dict[str, Any]] = []
    for task in payload.get("tasks", []):
        normalized = normalize_task(task)
        if not normalized["id"]:
            continue
        if task.get("source") == "plan":
            default_state = str(task.get("_default_state") or "")
            if normalized["state"] != default_state:
                task_states[normalized["id"]] = normalized["state"]
        elif task.get("source") == "legacy":
            legacy_tasks.append(normalized)
    state_payload: dict[str, Any] = {"project": project_id, "task_states": task_states}
    if legacy_tasks:
        state_payload["legacy_tasks"] = legacy_tasks
    write_json(queue_path(common_root, project_id), state_payload)


def empty_claims(project_id: str) -> dict[str, Any]:
    return {"project": project_id, "claims": {}}


def normalize_claims(project_id: str, payload: dict[str, Any]) -> dict[str, Any]:
    claims_in = payload.get("claims", {})
    if isinstance(claims_in, list):
        claims_in = {item.get("worktree"): item for item in claims_in if item.get("worktree")}
    claims_out: dict[str, dict[str, str]] = {}
    for worktree, claim in claims_in.items():
        task_id = str(claim.get("task_id", "")).strip()
        if not task_id:
            continue
        normalized = {"task_id": task_id}
        branch = str(claim.get("branch", "")).strip()
        if branch:
            normalized["branch"] = branch
        claimed_head = str(claim.get("claimed_head", "")).strip()
        if claimed_head:
            normalized["claimed_head"] = claimed_head
        claims_out[str(Path(worktree).resolve())] = normalized
    return {"project": payload.get("project", project_id), "claims": claims_out}


def load_claims(common_root: Path, project_id: str) -> dict[str, Any]:
    ensure_runtime_layout(common_root, project_id)
    return normalize_claims(project_id, load_json(claims_path(common_root, project_id), empty_claims(project_id)))


def save_claims(common_root: Path, project_id: str, payload: dict[str, Any]) -> None:
    write_json(claims_path(common_root, project_id), normalize_claims(project_id, payload))


def git_head(cwd: Path, ref: str = "HEAD") -> str:
    return git_output(["rev-parse", ref], cwd=cwd)


def git_branch(cwd: Path) -> str:
    return git_output(["rev-parse", "--abbrev-ref", "HEAD"], cwd=cwd)


def git_status_lines(cwd: Path) -> list[str]:
    output = git_output(["status", "--porcelain"], cwd=cwd)
    return [line for line in output.splitlines() if line.strip()]


def git_is_ancestor(cwd: Path, maybe_ancestor: str, maybe_descendant: str) -> bool:
    result = run(
        ["git", "merge-base", "--is-ancestor", maybe_ancestor, maybe_descendant],
        cwd=cwd,
        check=False,
    )
    return result.returncode == 0


def next_task_id(existing_tasks: list[dict[str, Any]], project_id: str, title: str) -> str:
    base = f"{project_id}-{slugify(title)[:48]}".strip("-")
    taken = {task.get("id") for task in existing_tasks}
    if base not in taken:
        return base
    for number in range(2, 10_000):
        candidate = f"{base}-{number}"
        if candidate not in taken:
            return candidate
    raise SystemExit(f"dispatch: could not allocate task id for {title!r}")


def queue_task(queue: dict[str, Any], task_id: str) -> dict[str, Any]:
    for task in queue.get("tasks", []):
        if task.get("id") == task_id:
            return task
    raise SystemExit(f"dispatch: missing task {task_id!r}")


def claim_record(claims: dict[str, Any], worktree: Path) -> dict[str, str] | None:
    return claims.get("claims", {}).get(str(worktree.resolve()))


def task_unmet_blockers(queue: dict[str, Any], task: dict[str, Any]) -> list[str]:
    done_ids = {item.get("id") for item in queue.get("tasks", []) if item.get("state") == "done"}
    return [task_id for task_id in task.get("blocked_by", []) if task_id not in done_ids]


def task_is_available(queue: dict[str, Any], task: dict[str, Any]) -> bool:
    return task.get("state") == "ready" and not task_unmet_blockers(queue, task)


def availability_counts(queue: dict[str, Any]) -> dict[str, int]:
    counts = {"available": 0, "waiting": 0}
    for task in queue.get("tasks", []):
        if task.get("state") != "ready":
            continue
        if task_unmet_blockers(queue, task):
            counts["waiting"] += 1
        else:
            counts["available"] += 1
    return counts


def parse_plan_checklist(plan_path: Path) -> list[dict[str, Any]]:
    field_names = {"owned paths": "paths", "validation": "validation", "blocked_by": "blocked_by"}
    scalar_field_names = {"task_id": "task_id", "task id": "task_id", "priority": "priority", "state": "state"}

    def strip_ticks(value: str) -> str:
        text = value.strip()
        if len(text) >= 2 and text.startswith("`") and text.endswith("`"):
            return text[1:-1].strip()
        return text

    items: list[dict[str, Any]] = []
    lines = plan_path.read_text(encoding="utf-8").splitlines()
    section = ""
    index = 0
    while index < len(lines):
        raw_line = lines[index].rstrip()
        heading = re.match(r"^(#+)\s+(.*)$", raw_line)
        if heading:
            section = heading.group(2).strip()
            index += 1
            continue

        match = re.match(r"^(?P<indent>\s*)[-*]\s+\[(?P<mark>[ xX~])\]\s+(?P<title>.+?)\s*$", raw_line)
        if not match:
            index += 1
            continue

        indent = len(match.group("indent"))
        item: dict[str, Any] = {
            "line": index + 1,
            "section": section,
            "mark": match.group("mark"),
            "title": strip_ticks(match.group("title")),
        }
        active_field: str | None = None
        sub_index = index + 1
        while sub_index < len(lines):
            sub_line = lines[sub_index].rstrip()
            if re.match(r"^(#+)\s+(.*)$", sub_line):
                break
            sibling = re.match(r"^(?P<indent>\s*)[-*]\s+\[[ xX~]\]\s+(?P<title>.+?)\s*$", sub_line)
            if sibling and len(sibling.group("indent")) <= indent:
                break
            if not sub_line.strip():
                sub_index += 1
                continue
            sub_indent = len(sub_line) - len(sub_line.lstrip())
            stripped = sub_line.strip()
            field_match = re.match(r"^-\s+(owned paths|validation|blocked_by):\s*(.*)$", stripped)
            if field_match:
                active_field = field_names[field_match.group(1)]
                rest = strip_ticks(field_match.group(2))
                if rest and rest.lower() != "none":
                    item.setdefault(active_field, []).append(rest)
                sub_index += 1
                continue
            scalar_match = re.match(r"^-\s+(task_id|task id|priority|state):\s*(.*)$", stripped)
            if scalar_match:
                active_field = None
                field = scalar_field_names[scalar_match.group(1)]
                value = strip_ticks(scalar_match.group(2))
                if field == "priority":
                    try:
                        item[field] = int(value)
                    except ValueError:
                        raise SystemExit(f"dispatch: invalid priority {value!r} in {plan_path}:{sub_index + 1}") from None
                elif field == "state":
                    if value not in VALID_TASK_STATES:
                        raise SystemExit(f"dispatch: invalid state {value!r} in {plan_path}:{sub_index + 1}")
                    item[field] = value
                elif value:
                    item[field] = value
                sub_index += 1
                continue
            if re.match(r"^-\s+[^:]+:\s*(.*)$", stripped):
                active_field = None
                sub_index += 1
                continue
            list_match = re.match(r"^-\s+(.+?)\s*$", stripped)
            if active_field and list_match and sub_indent > indent:
                item.setdefault(active_field, []).append(strip_ticks(list_match.group(1)))
                sub_index += 1
                continue
            active_field = None
            sub_index += 1

        if (
            "next dispatch batch" in section.lower()
            or item.get("task_id")
            or any(item.get(field) for field in field_names.values())
        ):
            items.append(item)
        index = sub_index
    return items
