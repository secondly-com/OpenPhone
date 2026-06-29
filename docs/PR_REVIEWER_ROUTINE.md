# PR Reviewer Routine

This routine defines how an OpenPhone reviewer agent should inspect a pull
request before merge. It is a review routine, not an auto-fix loop: it produces
actionable findings, identifies missing evidence, and exits when the branch is
safe for human review or the remaining risk is explicit.

## Triggers

Run the routine for:

- every new or updated pull request before merge;
- pull requests touching assistant, runtime, OpenClaw, watcher,
  background-job, device-control, policy, audit, release, or runner behavior;
- pull requests that change schemas, manifests, protocol contracts, CI, evals,
  build scripts, or release scripts;
- documentation-only pull requests that update behavior, setup, policy, runtime
  contracts, device support, or release flow;
- manual re-review after an implementer says review findings are fixed.

Do not run the routine against unreviewed local scratch notes under
`docs/local-temp/`; that directory is for ignored private agent notes.

## Required Context

Before reviewing, collect:

- the base branch, head branch, and full diff;
- `.github/pull_request_template.md` and the PR author's checked validation,
  risk, and evidence statements;
- `AGENTS.md` and the nearest docs for touched behavior;
- `docs/AI_FIRST_ENGINEERING.md` and this routine;
- relevant schemas, protocol manifests, tests, scripts, or workflow files for
  touched contracts;
- CI status for `./scripts/check.sh` and `git diff --check`;
- eval or device evidence when the changed behavior requires it.

If context is unavailable, note the missing context as review risk instead of
guessing.

## Review Checklist

Check correctness:

- Does the change implement the stated goal without broad unrelated edits?
- Are contracts, schemas, scripts, and docs updated together when behavior
  changes?
- Are edge cases, failure paths, and backwards compatibility handled?
- Are generated artifacts, local reports, trajectories, screenshots, audit
  exports, and build outputs absent from the diff?

Check safety and privacy:

- Are secrets, signing keys, provider tokens, private SSH keys, personal device
  data, proprietary vendor blobs, and local operator details absent?
- Do state-changing agent tools keep confirmation, auditability, and clear
  capability boundaries?
- Are screenshot, accessibility, notification, message, call, location, memory,
  trajectory, and audit-log changes treated as privacy-sensitive?
- Are default exposures and policy decisions conservative enough for the
  capability risk level?

Check validation:

- Does the PR include `./scripts/check.sh` and `git diff --check` results, or a
  credible reason they could not run?
- Are targeted tests, contract validators, schema checks, or workflow checks
  present for changed behavior?
- Does runtime or device-control work explain whether device, emulator,
  OpenClaw, trajectory, or benchmark validation was run?
- Are failed, skipped, or unavailable checks stated plainly in the PR?

Check docs and release risk:

- Are setup, runtime, policy, device, testing, and release docs still current?
- Does the PR template's docs checkbox match the actual diff?
- Does the change affect release artifacts, OTA feeds, runner requirements, or
  public support statements?
- Does any licensing or third-party material need a notice update?

## Severity

Use review severity to make merge risk clear:

| Severity | Meaning | Expected action |
| --- | --- | --- |
| `blocker` | Likely correctness, safety, privacy, license, secret, release, or data-loss issue. | Request changes before merge. |
| `high` | Important bug, missing required validation, or docs drift that could mislead agents or humans. | Request a fix or explicit owner-approved deferral. |
| `medium` | Risky edge case, incomplete evidence, brittle contract, or unclear behavior. | Fix when practical or move to tracked follow-up. |
| `low` | Clarity, maintainability, naming, or small docs improvement. | Suggest; do not block unless it compounds other risk. |

Every finding should include the affected file or behavior, why it matters, and
the smallest reviewable fix. Avoid style-only comments unless they protect a
contract or prevent future agent confusion.

## Device Eval Requests

Request a device eval when a PR changes:

- assistant action execution, UI automation, accessibility, screen context,
  input, clipboard, sharing, notification, call, message, location, or memory
  behavior;
- runtime command/event mapping, OpenClaw integration, MCP/CLI tool exposure,
  capability policy, confirmations, or audit logging;
- watcher, background-job, durable task, model-loop, or provider-routing
  behavior;
- device support, emulator images, OTA/update flow, release artifacts, or
  hardware support claims;
- tests or scripts that define trajectory, benchmark, OpenClaw, device, or
  release evidence.

Preferred validation by risk:

- assistant-only UI/model-loop changes: physical assistant UI smoke from
  `docs/TESTING.md`, with evidence kept outside source control;
- runtime, MCP, CLI, or OpenClaw contract changes:
  `./scripts/check-runtime-protocol.sh`, `./scripts/check.sh`, and
  `git diff --check`;
- live OpenClaw behavior: `./scripts/smoke-test-openclaw-runtime.sh` when a
  gateway and device are available;
- phone-control quality claims: `./scripts/run-eval-suite.sh`;
- benchmark or release-risk changes:
  `./scripts/run-agent-benchmark.sh --benchmark docs/agent-benchmarks/openphone-v0.json`.

If hardware, emulator, provider keys, or gateways are unavailable, the reviewer
should require an explicit PR note explaining the gap and the safest next
validation point.

## GitHub Actions And Codex Path

The current repo has lightweight automation for this routine:

- `.github/workflows/ci.yml` runs on pull requests and executes
  `./scripts/check.sh` plus `git diff --check`;
- `.github/workflows/codex-pr-review.yml` runs on every non-draft pull request,
  checks out the PR merge ref, invokes `openai/codex-action@v1` with the
  tracked `.github/codex/prompts/pr-review.md` prompt, and posts the review
  output as a PR comment from a read-only Codex sandbox;
- `.github/workflows/eval.yml` can be dispatched for physical trajectory
  smokes, benchmarks, and optional OpenClaw runtime smoke on the
  `openphone-device` runner.

The Codex PR review workflow intentionally does not run repository scripts or
tests from the PR branch because it receives `OPENAI_API_KEY`. CI runs
`./scripts/check.sh` and `git diff --check` separately without model secrets.
The reviewer should inspect the diff, identify missing evidence, and request
the existing manual `eval.yml` workflow when device or runtime evidence is
needed.

## Exit Conditions

The reviewer routine exits when:

- all `blocker` and `high` findings are fixed, explicitly declined by a human
  owner, or moved to tracked follow-up with accepted risk;
- required local checks have passed or their absence is explained;
- required device, emulator, OpenClaw, trajectory, benchmark, or release
  validation has passed or the PR states why it is deferred;
- no prohibited secrets, local-only notes, private evidence, screenshots,
  trajectories, audit exports, or build artifacts are present;
- remaining `medium` and `low` findings are either resolved or documented as
  non-blocking.

On re-review, focus on changed lines and previously reported findings. Do not
start an open-ended review loop after the branch reaches these exit conditions.
