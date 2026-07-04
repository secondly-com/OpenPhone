#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$root/scripts/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/run-agent-benchmark.sh [options]

Runs an OpenPhone agent benchmark JSON file against the connected device.

Options:
  --benchmark <path>   Benchmark JSON. Defaults to
                       docs/agent-benchmarks/openphone-v0.json.
  --output-dir <path>  Output directory. Defaults to
                       .worktree/evals/<benchmark-id>-<timestamp>.
  --task <id>          Run one task ID instead of the whole benchmark.
  --local              Pass through to run-assistant-task.sh.
  -h, --help           Show this help.

The runner starts each task with scripts/run-assistant-task.sh, pulls the latest
trajectory, checks simple text/activity expectations when present, and writes
summary.json. It is intentionally conservative: failed expectation checks mean
the task needs inspection, even if the assistant reported task.finished.
EOF
}

benchmark="$root/docs/agent-benchmarks/openphone-v0.json"
output_dir=""
task_filter=""
use_local=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --benchmark)
      [[ $# -ge 2 ]] || die "--benchmark requires a value"
      benchmark="$2"
      shift 2
      ;;
    --output-dir)
      [[ $# -ge 2 ]] || die "--output-dir requires a value"
      output_dir="$2"
      shift 2
      ;;
    --task)
      [[ $# -ge 2 ]] || die "--task requires a value"
      task_filter="$2"
      shift 2
      ;;
    --local)
      use_local=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -f "$benchmark" ]] || die "missing benchmark: $benchmark"
need_cmd adb
need_cmd python3

benchmark_id="$(
  python3 - <<'PY' "$benchmark"
import json, sys
print(json.load(open(sys.argv[1])).get("benchmark_id", "benchmark"))
PY
)"

if [[ -z "$output_dir" ]]; then
  timestamp="$(date +%Y%m%d-%H%M%S)"
  output_dir="$root/.worktree/evals/${benchmark_id}-${timestamp}"
fi
mkdir -p "$output_dir"

tasks_json="$output_dir/tasks.json"
python3 - <<'PY' "$benchmark" "$task_filter" >"$tasks_json"
import json, sys
benchmark = json.load(open(sys.argv[1]))
task_filter = sys.argv[2]
tasks = benchmark.get("tasks", [])
if task_filter:
    tasks = [task for task in tasks if task.get("id") == task_filter]
if not tasks:
    raise SystemExit(f"no tasks matched: {task_filter}")
print(json.dumps(tasks))
PY

cp "$benchmark" "$output_dir/benchmark.json"
summary_jsonl="$output_dir/results.jsonl"
: >"$summary_jsonl"

task_count="$(python3 - <<'PY' "$tasks_json"
import json, sys
print(len(json.load(open(sys.argv[1]))))
PY
)"

printf 'Running %s task(s) from %s\n' "$task_count" "$benchmark"

for index in $(seq 0 $((task_count - 1))); do
  task_dir="$output_dir/task-$index"
  mkdir -p "$task_dir"
  task_file="$task_dir/task.json"
  python3 - <<'PY' "$tasks_json" "$index" >"$task_file"
import json, sys
tasks = json.load(open(sys.argv[1]))
print(json.dumps(tasks[int(sys.argv[2])], indent=2))
PY

  task_id="$(python3 - <<'PY' "$task_file"
import json, sys
print(json.load(open(sys.argv[1])).get("id", "task"))
PY
)"
  goal="$(python3 - <<'PY' "$task_file"
import json, sys
print(json.load(open(sys.argv[1]))["goal"])
PY
)"
  wait_seconds="$(python3 - <<'PY' "$task_file"
import json, sys
print(json.load(open(sys.argv[1])).get("wait_seconds", 180))
PY
)"

  printf '\n[%s/%s] %s\n' "$((index + 1))" "$task_count" "$task_id"
  run_args=(--goal "$goal" --wait "$wait_seconds")
  if [[ "$use_local" == true ]]; then
    run_args+=(--local)
  fi

  task_status="ran"
  if ! "$root/scripts/run-assistant-task.sh" "${run_args[@]}" >"$task_dir/run.log" 2>&1; then
    task_status="harness_failed"
  fi

  adb shell dumpsys window >"$task_dir/final-window.txt" 2>/dev/null || true
  adb shell uiautomator dump /sdcard/openphone-benchmark-window.xml >/dev/null 2>&1 || true
  adb exec-out cat /sdcard/openphone-benchmark-window.xml \
    >"$task_dir/final-window.xml" 2>/dev/null || true

  latest="$(
    adb shell 'ls -td /data/user/0/org.openphone.assistant/files/openphone-trajectories/* 2>/dev/null | head -1' |
      tr -d '\r'
  )"
  if [[ -n "$latest" ]]; then
    adb pull "$latest" "$task_dir/trajectory" >/dev/null 2>&1 || true
  fi

  python3 - <<'PY' "$task_file" "$task_dir" "$task_status" >>"$summary_jsonl"
import json, pathlib, sys
task = json.load(open(sys.argv[1]))
task_dir = pathlib.Path(sys.argv[2])
status = sys.argv[3]
summary_path = task_dir / "trajectory" / "summary.json"
final_window = task_dir / "final-window.xml"
final_window_text = final_window.read_text(errors="ignore") if final_window.exists() else ""
final_window_dump = task_dir / "final-window.txt"
final_window_state = final_window_dump.read_text(errors="ignore") if final_window_dump.exists() else ""
assistant_status = ""
text_blob = ""
activity_blob = ""
tool_sequence = []
if summary_path.exists():
    data = json.load(open(summary_path))
    result = data.get("result", data)
    assistant_status = result.get("status", "")
    for step in result.get("steps", []):
        if step.get("tool"):
            tool_sequence.append(step.get("tool"))
        for key in ("screen", "after_screen"):
            screen = step.get(key)
            if not isinstance(screen, dict):
                continue
            text_blob += " " + json.dumps(screen.get("visible_text", []))
            context = screen.get("context") or {}
            activity_blob += " " + context.get("activity", "")

expected_text = task.get("expected_text", [])
combined_text = text_blob + " " + final_window_text
missing_text = [value for value in expected_text if value.lower() not in combined_text.lower()]
expected_activity = task.get("expected_activity", "")
combined_activity = activity_blob + " " + final_window_state
activity_ok = not expected_activity or expected_activity in combined_activity
passed = (
    status == "ran"
    and assistant_status == "task.finished"
    and not missing_text
    and activity_ok
)
failure_reasons = []
if not passed:
    if status != "ran":
        failure_reasons.append(f"harness failed (status: {status})")
    trajectory_dir = task_dir / "trajectory"
    if not trajectory_dir.exists():
        failure_reasons.append("trajectory missing")
    elif not summary_path.exists():
        failure_reasons.append("trajectory summary missing")
    if assistant_status != "task.finished":
        reported = assistant_status or "missing"
        failure_reasons.append(f"assistant did not report task.finished (status: {reported})")
    if missing_text:
        failure_reasons.append("expected text missing: " + ", ".join(missing_text))
    if not activity_ok:
        failure_reasons.append(f"expected activity missing or different: {expected_activity}")
    if not final_window_text:
        failure_reasons.append("final UI dump missing")
print(json.dumps({
    "task_id": task.get("id", ""),
    "goal": task.get("goal", ""),
    "status": "pass" if passed else "fail",
    "harness_status": status,
    "assistant_status": assistant_status,
    "missing_text": missing_text,
    "expected_activity": expected_activity,
    "activity_ok": activity_ok,
    "final_ui_captured": bool(final_window_text),
    "failure_reasons": failure_reasons,
    "tool_sequence": tool_sequence,
    "task_dir": str(task_dir),
}))
PY
done

python3 - <<'PY' "$summary_jsonl" "$output_dir/summary.json"
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
summary = {
    "schema": "openphone.agent_benchmark_result.v1",
    "total": len(rows),
    "passed": sum(1 for row in rows if row["status"] == "pass"),
    "failed": sum(1 for row in rows if row["status"] != "pass"),
    "failures": [
        {
            "task_id": row.get("task_id", ""),
            "failure_reasons": row.get("failure_reasons", []),
        }
        for row in rows
        if row["status"] != "pass"
    ],
    "results": rows,
}
json.dump(summary, open(sys.argv[2], "w"), indent=2)
print(json.dumps(summary, indent=2))
PY
