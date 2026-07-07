#!/usr/bin/env python3
import argparse
import hashlib
import json
import pathlib
import sqlite3
import sys


def read_json(path):
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def read_jsonl(path):
    events = []
    if not path.exists():
        return events
    with path.open("r", encoding="utf-8") as handle:
        for line_no, line in enumerate(handle, 1):
            stripped = line.strip()
            if not stripped:
                continue
            try:
                events.append(json.loads(stripped))
            except json.JSONDecodeError as exc:
                raise ValueError(f"{path}:{line_no}: invalid jsonl: {exc}") from exc
    return events


def canonical_hashes(event):
    body = dict(event)
    body.pop("event_hash", None)
    encoded = json.dumps(
        body,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    ).encode("utf-8")
    hashes = {hashlib.sha256(encoded).hexdigest()}
    escaped_slash = encoded.replace(b"/", b"\\/")
    if escaped_slash != encoded:
        hashes.add(hashlib.sha256(escaped_slash).hexdigest())
    return hashes


def validate_audit(events):
    previous_hash = ""
    for index, event in enumerate(events):
        event_hash = event.get("event_hash")
        if not event_hash:
            raise ValueError(f"audit event {index} missing event_hash")
        if event.get("previous_hash", "") != previous_hash:
            raise ValueError(f"audit event {index} previous_hash mismatch")
        if event_hash not in canonical_hashes(event):
            raise ValueError(f"audit event {index} event_hash mismatch")
        previous_hash = event_hash


def inspect_sqlite_store(store):
    db_path = store / "db" / "openphone.sqlite"
    if not db_path.exists():
        return {
            "db_exists": False,
            "path": str(db_path),
        }
    conn = sqlite3.connect(db_path)
    try:
        tables = {
            row[0]
            for row in conn.execute("select name from sqlite_master where type in ('table', 'view')")
        }
        result = {
            "db_exists": True,
            "path": str(db_path),
            "tables": sorted(tables),
            "memory_rows": 0,
            "context_event_rows": 0,
            "commitment_rows": 0,
            "watcher_rows": 0,
            "agent_job_rows": 0,
            "memory_fts": "memory_fts" in tables,
            "context_event_fts": "context_event_fts" in tables,
            "commitment_fts": "commitment_fts" in tables,
            "watcher_fts": "watcher_fts" in tables,
            "agent_job_fts": "agent_job_fts" in tables,
        }
        if "memory" in tables:
            result["memory_rows"] = conn.execute("select count(*) from memory").fetchone()[0]
        if "context_event" in tables:
            result["context_event_rows"] = conn.execute("select count(*) from context_event").fetchone()[0]
        if "commitment" in tables:
            result["commitment_rows"] = conn.execute("select count(*) from commitment").fetchone()[0]
        if "watcher" in tables:
            result["watcher_rows"] = conn.execute("select count(*) from watcher").fetchone()[0]
        if "agent_job" in tables:
            result["agent_job_rows"] = conn.execute("select count(*) from agent_job").fetchone()[0]
        return result
    finally:
        conn.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("store", type=pathlib.Path)
    parser.add_argument("--require-task-artifacts", action="store_true")
    args = parser.parse_args()

    store = args.store
    tasks_dir = store / "tasks"
    audit_path = store / "audit" / "audit-events.jsonl"
    trajectories_dir = store / "trajectories"

    task_paths = sorted(tasks_dir.glob("*.json")) if tasks_dir.exists() else []
    tasks = [read_json(path) for path in task_paths]
    audit_events = read_jsonl(audit_path)
    validate_audit(audit_events)

    trajectory_paths = sorted(trajectories_dir.glob("*.jsonl")) if trajectories_dir.exists() else []
    trajectory_counts = {
        path.name: len(read_jsonl(path))
        for path in trajectory_paths
    }
    sqlite_store = inspect_sqlite_store(store)

    if args.require_task_artifacts:
        if not tasks:
            raise ValueError("missing task artifacts")
        if not audit_events:
            raise ValueError("missing audit events")
        if not trajectory_paths:
            raise ValueError("missing trajectory artifacts")
        for task in tasks:
            task_id = task.get("task_id")
            if not task_id:
                raise ValueError("task missing task_id")
            expected = trajectories_dir / f"{task_id}.jsonl"
            if not expected.exists():
                raise ValueError(f"missing trajectory for {task_id}")

    print(json.dumps({
        "status": "ok",
        "store": str(store),
        "tasks": len(tasks),
        "audit_events": len(audit_events),
        "trajectories": len(trajectory_paths),
        "trajectory_events": sum(trajectory_counts.values()),
        "sqlite": sqlite_store,
    }, indent=2))


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"validate-agentd-store: {exc}", file=sys.stderr)
        sys.exit(1)
