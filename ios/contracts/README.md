# OpenPhone Contracts

This directory mirrors the Android OpenPhone schemas and runtime protocol files
that iOS must target.

The files under `schemas/` and `protocol/` are copied from the Android
OpenPhone repo so iOS can keep command names, capabilities, screen context,
actions, audit events, trajectories, and jobs aligned while the implementation
is still private.

Current iOS status:

- `openphone-agentd` exposes the first local daemon boundary.
- The daemon defaults to `yolo`.
- The daemon currently serves health, task, screen, input, app, memory, context,
  commitment, watcher-store, background-job-store, audit, and trajectory
  commands.
- Real screenshot pixels, UI tree, notifications, messages, calls, calendar,
  contacts, watcher scheduling, background job execution, and commitment
  trigger execution still need implementation.

When contracts change in Android, update this mirror deliberately and note any
iOS compatibility work in `IOS_PLAN.md`.
