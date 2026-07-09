# Agent Runtime V1

OpenPhone's agent should behave like an OS resident process, not only a
foreground chat bot. This document defines the first runtime layer that turns
conversation intents into durable work that can continue after the current UI
session.

## Goals

- Persist background agent work as first-class jobs.
- Wake jobs from alarms, boot, package replacement, and explicit tool calls.
- Keep delivery, retries, diagnostics, and failure state with the job.
- Preserve the reviewed autonomy posture: background jobs do not silently
  perform state-changing actions.
- Keep model routing in the registry and schemas instead of Java keyword
  routing.

## Non-Goals

- Replacing watchers or commitments. Those remain specialized durable
  primitives for event monitors and open loops.
- Moving the job database into `system_server` in this slice. The final target
  is OS-owned storage behind `openphone_assistant_data`; V1 starts in the
  assistant process to validate runtime semantics without AIDL/sepolicy churn.
- Running unbounded always-on model loops. Jobs wake only when scheduled or
  triggered.

## Runtime Objects

An `agent_job` records durable background work.

```json
{
  "id": 42,
  "type": "agent_turn",
  "title": "Check launch notes",
  "prompt": "Check the saved page and tell me if the release notes changed.",
  "payload_json": {},
  "schedule_json": {
    "next_run_at": 1781483055000,
    "interval_ms": 3600000
  },
  "session_target": "main",
  "delivery_json": {
    "mode": "notification",
    "notification_text": "Release notes changed"
  },
  "status": "active",
  "created_at": 1781480000000,
  "updated_at": 1781480000000,
  "next_run_at": 1781483055000,
  "running_at": 0,
  "last_run_at": 0,
  "last_result": "",
  "failure_count": 0,
  "failure_alert_at": 0
}
```

Job types:

- `agent_turn`: run a bounded model/tool loop against a prompt.
- `system_event`: record or summarize an OS/runtime event.
- `heartbeat`: wake the agent runtime for maintenance; silent by default.

Delivery modes:

- `notification`: notify when a job completes or fails.
- `silent`: persist result without user-visible delivery.
- `none`: persist result only.

When a user gives exact notification wording, `delivery_json.notification_text`
is the user-visible notification body. The stored `last_result` may contain a
model/tool trace and must not be dumped directly into the notification surface.

## Scheduling

The assistant schedules a single alarm for the next active job. On wake it:

1. repairs stale `running` jobs,
2. marks due jobs `running`,
3. starts bounded background runners,
4. persists completion/failure,
5. applies retry/backoff or recurring interval,
6. schedules the next wake.

Jobs also wake during boot, locked boot, package replacement, and assistant
service startup.

## Cancellation and Upstream Failures

- `background_job_stop` marks the job `stopped`. A running job polls its
  stored status between agent steps and while waiting out retry backoff; a
  watchdog additionally aborts the in-flight model call, so a stopped job
  halts even when it is blocked on a stuck upstream read.
- `stopped` is terminal for that run: completion and failure results from a
  cancelled run are not recorded back onto the job, so a stop cannot be
  overwritten or the job resurrected by a run that finishes late.
- Model HTTP calls retry 429 and 5xx responses with bounded exponential
  backoff plus jitter, honoring `Retry-After` when it fits the in-call retry
  budget; a longer `Retry-After` fails the call immediately. A run that ends
  in an infrastructure error (exhausted retries, adapter crash) is recorded
  as a failure and follows the job store's normal failure backoff and
  repeated-failure alerting instead of counting as a completion.
- An unchecked exception inside the background runner (for example a broker
  outage surfacing as a runtime error) marks the job failed with backoff
  instead of killing the assistant process.

## Safety

Background jobs may call observe/read tools and terminal tools. State-changing
tools return `background.confirmation_required` instead of executing. The
foreground reviewed flow remains the only path for actions that mutate device,
account, communication, or external state.

This is intentionally conservative. The follow-up design can add reviewed
background approvals with a notification action and a resumable job checkpoint.

## OpenClaw/Hermes Mapping

OpenClaw contributes the durable job model: schedule, session target, delivery,
failure state, diagnostics, stuck-run repair, and heartbeat semantics.

Hermes contributes the operator model: background command, saved output,
delivery to the originating surface, and a scheduler tick that does not block
the active conversation.

OpenPhone V1 ports those ideas to Android by using AlarmManager, assistant
tool registry entries, notifications, and the existing OpenPhone model/tool
executor.

## Migration Path

V1 stores jobs in assistant private storage. The production target is an
OS-owned `agent_jobs` table in `/data/system/openphone/assistant_data.db` with
the same wire contract as `schemas/agent-job.schema.json`.

The assistant-facing API should stay stable:

- `background_job_create`
- `background_job_list`
- `background_job_stop`

Moving storage behind `OpenPhoneAssistantDataManager` should not change the
model-visible tool contract.
