#!/usr/bin/env bash
# Runs the canonical OpenPhone trajectory smoke suite against the connected
# Pixel and pulls each task's trajectory off the device into
# .worktree/eval-trajectories/<timestamp>/.
#
# This is the script invoked by .github/workflows/eval.yml on the
# self-hosted `openphone-device` runner, but it is also fine to run locally:
#
#   ./scripts/run-eval-suite.sh
#
# Or with a custom goal list:
#
#   INPUT_GOALS="Remind me in 1 minute to stretch,What time is it?" \
#     ./scripts/run-eval-suite.sh

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

if ! command -v adb >/dev/null 2>&1; then
  echo "run-eval-suite: FAIL — adb not on PATH." >&2
  exit 1
fi

if ! adb get-state >/dev/null 2>&1; then
  echo "run-eval-suite: FAIL — no device on adb." >&2
  exit 1
fi

api_key_file="${OPENPHONE_API_KEY_FILE:-$root/.worktree/secrets/openai_api_key}"
if [[ -z "${OPENAI_API_KEY:-}" && ! -s "$api_key_file" ]]; then
  echo "run-eval-suite: FAIL — set OPENAI_API_KEY or provide $api_key_file" >&2
  exit 1
fi

# Canonical smoke set. Keep it small, deterministic, and broad enough to
# cover the spine: chat-only reply, memory write, screen read, watcher
# create. The goals run sequentially and each captures one trajectory.
DEFAULT_GOALS=(
  "Just respond with the word 'pong'."
  "Use memory_save to remember: my favorite color is blue."
  "What do you remember about my favorite color?"
  "Look at my screen and tell me one thing visible on it."
)

if [[ -n "${INPUT_GOALS:-}" ]]; then
  IFS=',' read -r -a GOALS <<< "$INPUT_GOALS"
else
  GOALS=("${DEFAULT_GOALS[@]}")
fi

stamp="$(date -u +%Y%m%d-%H%M%S)"
out_root="$root/.worktree/eval-trajectories/$stamp"
mkdir -p "$out_root"

echo "run-eval-suite: writing trajectories under $out_root"

i=0
for goal in "${GOALS[@]}"; do
  i=$((i + 1))
  echo
  echo "===== smoke $i/${#GOALS[@]} ====="
  echo "goal: $goal"
  run_args=(--goal "$goal" --wait 35)
  if [[ -z "${OPENAI_API_KEY:-}" ]]; then
    run_args+=(--api-key-file "$api_key_file")
  fi
  ./scripts/run-assistant-task.sh "${run_args[@]}" || {
    echo "run-eval-suite: task $i failed; continuing"
  }

  # Pull the latest trajectory from the device into the artifact dir.
  # `pull-latest-trajectory.sh` requires an explicit Export Trace from the
  # assistant's Advanced UI, which run-assistant-task does not trigger.
  # Instead, copy the trajectory directory directly off the device.
  adb root >/dev/null 2>&1 || true
  sleep 1
  latest=$(adb shell 'ls -1t /data/user/0/org.openphone.assistant/files/openphone-trajectories | head -1' \
      | tr -d '\r' || true)
  if [[ -n "$latest" ]]; then
    mkdir -p "$out_root/smoke-$i"
    adb shell "cat /data/user/0/org.openphone.assistant/files/openphone-trajectories/$latest/events.jsonl" \
        > "$out_root/smoke-$i/events.jsonl" 2>/dev/null || true
    adb shell "cat /data/user/0/org.openphone.assistant/files/openphone-trajectories/$latest/summary.json" \
        > "$out_root/smoke-$i/summary.json" 2>/dev/null || true
    echo "run-eval-suite: pulled trajectory $latest to smoke-$i"
  else
    echo "run-eval-suite: no trajectory captured for task $i"
  fi
  adb unroot >/dev/null 2>&1 || true
done

echo
echo "run-eval-suite: $i tasks complete; trajectories under $out_root"
