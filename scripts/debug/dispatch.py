#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import sys
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator

LIB_DIR = Path(__file__).resolve().parents[1] / "lib"
if str(LIB_DIR) not in sys.path:
    sys.path.insert(0, str(LIB_DIR))

from overnight_common import (  # noqa: E402
    availability_counts,
    claim_record,
    claims_path,
    discover_project_ids,
    empty_claims,
    empty_queue,
    ensure_runtime_layout,
    git_branch,
    git_head,
    git_is_ancestor,
    git_status_lines,
    load_claims,
    load_project,
    load_queue,
    locked_file,
    next_task_id,
    parse_plan_checklist,
    project_def_path,
    project_lock_path,
    project_defs_dir,
    queue_path,
    queue_task,
    repo_common_root,
    repo_root,
    save_claims,
    save_project,
    save_queue,
    task_is_available,
    task_unmet_blockers,
    write_json,
)


def dump(payload: dict[str, Any], *, as_json: bool) -> None:
    if as_json:
        print(json.dumps(payload, indent=2))
        return
    if payload.get("action") == "idle":
        print("idle")
        return
    if payload.get("action") == "claimed":
        print(f"claimed {payload['task']['id']}")
        return
    if payload.get("action") == "resume":
        print(f"resume {payload['task']['id']}")
        return
    print(json.dumps(payload, indent=2))


def state_counts(queue: dict[str, Any]) -> dict[str, int]:
    counts = {state: 0 for state in ["backlog", "ready", "running", "done", "blocked"]}
    for task in queue.get("tasks", []):
        counts[task.get("state", "backlog")] += 1
    return counts


def available_tasks(queue: dict[str, Any]) -> list[dict[str, Any]]:
    return sorted(
        [task for task in queue.get("tasks", []) if task_is_available(queue, task)],
        key=lambda task: (int(task.get("priority", 100)), task.get("title", "")),
    )


def unavailable_reason(queue: dict[str, Any], task: dict[str, Any]) -> str:
    if task.get("state") != "ready":
        return f"state is {task.get('state', 'backlog')}"
    blockers = task_unmet_blockers(queue, task)
    if blockers:
        return "blocked by " + ", ".join(blockers)
    return "not available"


def resolve_project_id(cwd: Path, common_root: Path, explicit_project: str | None, worktree: Path) -> str:
    if explicit_project:
        return explicit_project
    matches = [project_id for project_id in discover_project_ids(cwd) if claim_record(load_claims(common_root, project_id), worktree)]
    if len(matches) == 1:
        return matches[0]
    project_ids = discover_project_ids(cwd)
    if not matches and len(project_ids) == 1:
        return project_ids[0]
    raise SystemExit("dispatch: could not infer project for this worktree; pass --project")


@contextmanager
def locked_project(common_root: Path, project_id: str) -> Iterator[tuple[dict[str, Any], dict[str, Any]]]:
    ensure_runtime_layout(common_root, project_id)
    with locked_file(project_lock_path(common_root, project_id)):
        queue = load_queue(common_root, project_id)
        claims = load_claims(common_root, project_id)
        yield queue, claims
        save_queue(common_root, project_id, queue)
        save_claims(common_root, project_id, claims)


def claim_sync_status(common_root: Path, queue: dict[str, Any], worktree_text: str, claim: dict[str, Any]) -> dict[str, Any]:
    payload: dict[str, Any] = {"task_id": claim["task_id"], "worktree": worktree_text}
    if not any(task.get("id") == claim["task_id"] for task in queue.get("tasks", [])):
        payload["status"] = "stale_task"
        return payload
    worktree = Path(worktree_text)
    if not worktree.exists():
        payload["status"] = "missing_worktree"
        return payload
    dirty = bool(git_status_lines(worktree))
    head = git_head(worktree)
    claimed_head = claim.get("claimed_head")
    landed = git_is_ancestor(common_root, head, git_head(common_root, "master"))
    payload.update(
        {
            "branch": git_branch(worktree),
            "head": head,
            "claimed_head": claimed_head,
            "dirty": dirty,
            "landed": landed,
            "head_changed": bool(claimed_head and head != claimed_head),
        }
    )
    if landed and payload["head_changed"] and not dirty:
        payload["status"] = "landed_clean"
    elif landed and dirty:
        payload["status"] = "landed_dirty"
    elif landed and not dirty:
        payload["status"] = "claimed_clean"
    elif dirty:
        payload["status"] = "dirty"
    else:
        payload["status"] = "clean_unlanded"
    return payload


def status_payload(cwd: Path, common_root: Path, project_id: str) -> dict[str, Any]:
    project = load_project(cwd, project_id)
    queue = load_queue(common_root, project_id)
    claims = load_claims(common_root, project_id)
    claims_view = [claim_sync_status(common_root, queue, worktree, claim) for worktree, claim in sorted(claims.get("claims", {}).items())]
    return {
        "project": project_id,
        "plan_path": project["plan_path"],
        "queue": queue,
        "counts": state_counts(queue),
        "availability": availability_counts(queue),
        "available": [
            {"id": task["id"], "title": task["title"], "priority": task.get("priority", 100)}
            for task in available_tasks(queue)
        ],
        "waiting": [
            {"id": task["id"], "title": task["title"], "blocked_by": task_unmet_blockers(queue, task)}
            for task in queue.get("tasks", [])
            if task.get("state") == "ready" and task_unmet_blockers(queue, task)
        ],
        "claims": claims_view,
    }


def print_status(payload: dict[str, Any]) -> None:
    counts = payload["counts"]
    availability = payload["availability"]
    print(f"project: {payload['project']}")
    print(f"plan: {payload['plan_path']}")
    print(
        "queue: "
        f"{counts['backlog']} backlog, {counts['ready']} ready, {counts['running']} running, "
        f"{counts['done']} done, {counts['blocked']} blocked"
    )
    print(f"available: {availability['available']}, waiting: {availability['waiting']}")
    if payload["available"]:
        print("available tasks:")
        for task in payload["available"]:
            print(f"- {task['id']}: {task['title']}")
    if payload["waiting"]:
        print("waiting tasks:")
        for task in payload["waiting"]:
            blockers = ", ".join(task["blocked_by"])
            print(f"- {task['id']}: {task['title']} [{blockers}]")
    if payload["claims"]:
        print("claims:")
        for claim in payload["claims"]:
            print(f"- {claim['worktree']}: {claim['task_id']} ({claim['status']})")


def resolve_blockers(queue: dict[str, Any], blockers: list[str], extra_titles: dict[str, str] | None = None) -> list[str]:
    title_to_id = {task["title"]: task["id"] for task in queue.get("tasks", [])}
    if extra_titles:
        title_to_id.update(extra_titles)
    known_ids = {task["id"] for task in queue.get("tasks", [])} | set(title_to_id.values())
    resolved: list[str] = []
    for blocker in blockers:
        if blocker in title_to_id:
            resolved.append(title_to_id[blocker])
            continue
        if blocker in known_ids:
            resolved.append(blocker)
            continue
        raise SystemExit(f"dispatch: unknown blocker {blocker!r}")
    return list(dict.fromkeys(resolved))


def cmd_project_init(args: argparse.Namespace) -> int:
    cwd = Path.cwd()
    common_root = repo_common_root(cwd)
    ensure_runtime_layout(common_root, args.project)
    save_project(cwd, args.project, {"plan_path": args.plan})
    save_queue(common_root, args.project, empty_queue(args.project))
    save_claims(common_root, args.project, empty_claims(args.project))
    print(project_def_path(cwd, args.project))
    return 0


def cmd_queue_import_plan(args: argparse.Namespace) -> int:
    cwd = Path.cwd()
    common_root = repo_common_root(cwd)
    project = load_project(cwd, args.project)
    plan_path = (repo_root(cwd) / project["plan_path"]).resolve()
    imported = parse_plan_checklist(plan_path)
    title_path = f"{project['plan_path']}:"
    with locked_project(common_root, args.project) as (queue, claims):
        title_to_id = {task["title"]: task["id"] for task in queue.get("tasks", [])}
        staged: list[dict[str, Any]] = []
        for item in imported:
            item_id = title_to_id.get(item["title"]) or next_task_id(queue["tasks"] + staged, args.project, item["title"])
            title_to_id[item["title"]] = item_id
            staged.append({"id": item_id, "title": item["title"]})
        desired_by_id: dict[str, dict[str, Any]] = {}
        for order, item in enumerate(imported, start=1):
            task_id = title_to_id[item["title"]]
            ready = "next dispatch batch" in item["section"].lower()
            task: dict[str, Any] = {
                "id": task_id,
                "title": item["title"],
                "state": "ready" if ready else "backlog",
                "priority": (10 if ready else 100) + order,
                "plan_ref": f"{project['plan_path']}:{item['line']}",
                "paths": item.get("paths", []),
                "validation": item.get("validation", []),
            }
            blockers = resolve_blockers(queue, item.get("blocked_by", []), title_to_id)
            if blockers:
                task["blocked_by"] = blockers
            desired_by_id[task_id] = task
        claimed_ids = {claim["task_id"] for claim in claims.get("claims", {}).values()}
        next_tasks: list[dict[str, Any]] = []
        for existing in queue.get("tasks", []):
            desired = desired_by_id.pop(existing["id"], None)
            plan_owned = str(existing.get("plan_ref") or "").startswith(title_path)
            if desired:
                desired["state"] = existing["state"] if existing["state"] in {"running", "done", "blocked"} else desired["state"]
                next_tasks.append(desired)
            elif plan_owned and existing["id"] not in claimed_ids and existing.get("state") != "running":
                continue
            else:
                next_tasks.append(existing)
        next_tasks.extend(sorted(desired_by_id.values(), key=lambda task: (task["priority"], task["title"])))
        queue["tasks"] = next_tasks
    print(f"imported {len(imported)} task cards from {project['plan_path']}")
    return 0


def cmd_task_add(args: argparse.Namespace) -> int:
    cwd = Path.cwd()
    common_root = repo_common_root(cwd)
    with locked_project(common_root, args.project) as (queue, _claims):
        if any(task["title"] == args.title for task in queue.get("tasks", [])):
            raise SystemExit(f"dispatch: task title already exists: {args.title}")
        task_id = args.task_id or next_task_id(queue["tasks"], args.project, args.title)
        blockers = resolve_blockers(queue, args.blocked_by or [])
        task: dict[str, Any] = {
            "id": task_id,
            "title": args.title,
            "state": args.state or ("ready" if args.path or args.validation or blockers else "backlog"),
            "priority": args.priority,
            "plan_ref": args.plan_ref,
            "paths": args.path or [],
            "validation": args.validation or [],
        }
        if blockers:
            task["blocked_by"] = blockers
        queue.setdefault("tasks", []).append(task)
    dump(task, as_json=args.json)
    return 0


def cmd_task_state(args: argparse.Namespace) -> int:
    common_root = repo_common_root()
    with locked_project(common_root, args.project) as (queue, _claims):
        task = queue_task(queue, args.task_id)
        task["state"] = args.state
    dump(task, as_json=args.json)
    return 0


def cmd_interactive_status(args: argparse.Namespace) -> int:
    cwd = Path.cwd()
    common_root = repo_common_root(cwd)
    worktree = Path(args.worktree or cwd).resolve()
    project_id = resolve_project_id(cwd, common_root, args.project, worktree)
    payload = status_payload(cwd, common_root, project_id)
    if args.json:
        dump(payload, as_json=True)
    else:
        print_status(payload)
    return 0


def cmd_interactive_next(args: argparse.Namespace) -> int:
    cwd = Path.cwd()
    common_root = repo_common_root(cwd)
    worktree = Path(args.worktree or cwd).resolve()
    if not worktree.exists():
        raise SystemExit(f"dispatch: missing worktree {worktree}")
    project_id = resolve_project_id(cwd, common_root, args.project, worktree)
    with locked_project(common_root, project_id) as (queue, claims):
        claim = claim_record(claims, worktree)
        if claim:
            claim_view = claim_sync_status(common_root, queue, str(worktree), claim)
            if claim_view["status"] == "landed_clean":
                queue_task(queue, claim["task_id"])["state"] = "done"
                claims["claims"].pop(str(worktree), None)
            elif claim_view["status"] == "stale_task":
                claims["claims"].pop(str(worktree), None)
            else:
                if args.task_id and args.task_id != claim["task_id"]:
                    raise SystemExit(
                        f"dispatch: worktree already owns {claim['task_id']}; "
                        f"finish it before claiming {args.task_id}"
                    )
                payload = {"action": "resume", "project": project_id, "task": queue_task(queue, claim["task_id"]), "claim": claim_view}
                dump(payload, as_json=args.json)
                return 0
        tasks = available_tasks(queue)
        if args.task_id:
            task = queue_task(queue, args.task_id)
            if not task_is_available(queue, task):
                raise SystemExit(f"dispatch: task {args.task_id!r} is not available: {unavailable_reason(queue, task)}")
        elif not tasks:
            payload = {"action": "idle", "project": project_id, "counts": state_counts(queue), "availability": availability_counts(queue)}
            dump(payload, as_json=args.json)
            return 0
        else:
            task = tasks[0]
        task["state"] = "running"
        claims.setdefault("claims", {})[str(worktree)] = {
            "task_id": task["id"],
            "branch": git_branch(worktree),
            "claimed_head": git_head(worktree),
        }
        payload = {
            "action": "claimed",
            "project": project_id,
            "task": task,
            "claim": claim_sync_status(common_root, queue, str(worktree), claims["claims"][str(worktree)]),
        }
    dump(payload, as_json=args.json)
    return 0


def cmd_interactive_finish(args: argparse.Namespace) -> int:
    cwd = Path.cwd()
    common_root = repo_common_root(cwd)
    worktree = Path(args.worktree or cwd).resolve()
    project_id = resolve_project_id(cwd, common_root, args.project, worktree)
    with locked_project(common_root, project_id) as (queue, claims):
        claim = claim_record(claims, worktree)
        if not claim:
            raise SystemExit(f"dispatch: no claim for worktree {worktree}")
        task = queue_task(queue, claim["task_id"])
        task["state"] = args.state
        claims["claims"].pop(str(worktree), None)
    dump({"project": project_id, "task_id": task["id"], "state": args.state, "worktree": str(worktree)}, as_json=args.json)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="dispatch.py")
    sub = parser.add_subparsers(dest="command", required=True)

    init_parser = sub.add_parser("project-init")
    init_parser.add_argument("--project", required=True)
    init_parser.add_argument("--plan", required=True)
    init_parser.set_defaults(func=cmd_project_init)

    import_parser = sub.add_parser("queue-import-plan")
    import_parser.add_argument("--project", required=True)
    import_parser.set_defaults(func=cmd_queue_import_plan)

    task_add = sub.add_parser("task-add")
    task_add.add_argument("--project", required=True)
    task_add.add_argument("--task-id")
    task_add.add_argument("--title", required=True)
    task_add.add_argument("--state", choices=["backlog", "ready", "running", "done", "blocked"])
    task_add.add_argument("--priority", type=int, default=100)
    task_add.add_argument("--plan-ref")
    task_add.add_argument("--path", action="append")
    task_add.add_argument("--validation", action="append")
    task_add.add_argument("--blocked-by", action="append")
    task_add.add_argument("--json", action="store_true")
    task_add.set_defaults(func=cmd_task_add)

    task_state = sub.add_parser("task-state")
    task_state.add_argument("--project", required=True)
    task_state.add_argument("--task-id", required=True)
    task_state.add_argument("--state", required=True, choices=["backlog", "ready", "running", "done", "blocked"])
    task_state.add_argument("--json", action="store_true")
    task_state.set_defaults(func=cmd_task_state)

    interactive_status = sub.add_parser("interactive-status")
    interactive_status.add_argument("--project")
    interactive_status.add_argument("--worktree")
    interactive_status.add_argument("--json", action="store_true")
    interactive_status.set_defaults(func=cmd_interactive_status)

    interactive_next = sub.add_parser("interactive-next")
    interactive_next.add_argument("--project")
    interactive_next.add_argument("--worktree")
    interactive_next.add_argument("--task-id")
    interactive_next.add_argument("--json", action="store_true")
    interactive_next.set_defaults(func=cmd_interactive_next)

    interactive_finish = sub.add_parser("interactive-finish")
    interactive_finish.add_argument("--project")
    interactive_finish.add_argument("--worktree")
    interactive_finish.add_argument("--state", required=True, choices=["ready", "done", "blocked"])
    interactive_finish.add_argument("--json", action="store_true")
    interactive_finish.set_defaults(func=cmd_interactive_finish)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
