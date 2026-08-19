# Agent Runtime V1

OpenPhone's agent should behave like an OS resident process, not only a
foreground chat bot. This document defines the first runtime layer that turns
conversation intents into durable work that can continue after the current UI
session.

## Goals

- Persist background agent work as first-class jobs.
- Wake jobs from alarms, boot, package replacement, and explicit tool calls.
- Keep delivery, retries, diagnostics, and failure state with the job.
- Preserve the reviewed autonomy posture: background jobs pause before
  state-changing actions and resume only from an exact Android-owned review.
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
  "status": "queued",
  "created_at": 1781480000000,
  "updated_at": 1781480000000,
  "next_run_at": 1781483055000,
  "running_at": 0,
  "last_run_at": 0,
  "last_result": "",
  "failure_count": 0,
  "failure_alert_at": 0,
  "phase": "queued",
  "progress_text": "Queued",
  "progress_current": 0,
  "progress_total": 0,
  "checkpoint_json": {},
  "pending_confirmation_id": "",
  "pending_tool_request_json": {},
  "last_surface_id": "",
  "resume_token": "",
  "last_event_at": 1781480000000,
  "unread_result": false,
  "paused_at": 0
}
```

Lifecycle states are `queued`, `running`, `waiting`, `awaiting_review`,
`paused`, `completed`, `failed`, and `stopped`. Readers continue accepting the
legacy `active` value during migration. Runtime dispatch may also persist
`dispatched` while an external runtime owns the next step.

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

1. expires pending reviews and repairs stale `running` or review-resolution
   jobs,
2. marks due jobs `running`,
3. starts bounded background runners,
4. persists completion/failure,
5. applies retry/backoff or recurring interval,
6. schedules the next wake.

Jobs also wake during boot, locked boot, package replacement, and assistant
service startup.

## Safety

Background jobs may call observe/read tools and terminal tools directly. A
state-changing tool is never executed by the background model loop. Instead,
OpenPhone:

1. bounds and sanitizes the exact proposed tool arguments;
2. persists an `awaiting_review` checkpoint and 15-minute confirmation;
3. shows the exact action in an Android notification and AI Home run detail;
4. atomically claims the first Approve or Deny tap;
5. verifies the tool, parameter digest, runtime, phone session, job, expiry,
   idempotency key, checkpoint, and resume token;
6. executes only the persisted request after approval, or records a structured
   denial/timeout result;
7. resumes the job with that bound result instead of regenerating the action.

Provider secrets, raw authorization, screenshots, data URLs, large encoded
blobs, and unbounded context are rejected from checkpoints. Audit events store
digests and lifecycle metadata, not raw parameters. If the process dies while
an approved action is resolving, stale-run repair marks the outcome unknown
and does not replay it. A denied action can safely resume after restart.

The wire shapes are defined by `schemas/agent-job.schema.json` and
`schemas/background-confirmation.schema.json`; recorded valid, tampered, and
secret-bearing fixtures run in `./scripts/check.sh`.

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
