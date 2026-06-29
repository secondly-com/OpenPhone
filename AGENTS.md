# AGENTS.md

## OpenPhone Operating Loop

OpenPhone is an AI-native Android OS. Treat every change as part of a phone,
runtime, safety, docs, or release system that must stay understandable to both
humans and agents.

Before editing:

- Check the current branch and working tree.
- Read the nearest relevant docs before changing behavior.
- Keep changes small, reviewable, and isolated to one coherent purpose.
- Do not commit directly to `main`, `master`, or `trunk`.

Default validation before finishing:

- Run `./scripts/check.sh` for repository, protocol, policy, integration, and
  assistant Java checks.
- Run `git diff --check`.
- If assistant, runtime, OpenClaw, watcher, background-job, or device-control
  behavior changed, explain whether a device eval was run. Prefer
  `./scripts/run-eval-suite.sh` for trajectory smokes and
  `./scripts/run-agent-benchmark.sh` for benchmark coverage when a device is
  available.
- If OpenClaw runtime behavior changed and a gateway/device are available, run
  `./scripts/smoke-test-openclaw-runtime.sh`.

Privacy and security:

- Never include API keys, signing keys, private SSH keys, provider tokens,
  proprietary vendor blobs, personal device data, generated trajectories,
  screenshots, audit exports, or build artifacts in commits.
- Keep secrets under ignored local paths such as `.worktree/secrets/` or GitHub
  Actions secrets.
- Treat screenshot, accessibility, notification, message, call, location,
  memory, trajectory, and audit-log changes as privacy-sensitive.
- State-changing agent tools must preserve confirmation and auditability.

Docs and contracts:

- Update docs when behavior, setup, policy, runtime contracts, device support,
  or release flow changes.
- Prefer contract tests, schemas, validators, and benchmarks over prose-only
  guarantees.
- When docs conflict, make the freshest behavior explicit and remove or update
  stale claims in the same change when practical.
- Use ignored `docs/local-temp/` for local-only agent notes, scratch plans,
  private triage, or temporary markdown. Do not move local scratch content into
  public docs unless it has been reviewed and intentionally rewritten for the
  repository.

Commit shape:

- Prefer one atomic commit per green unit of work.
- Do not commit unrelated local changes.
- Summarize changed files, validation run, and any residual risk.

## Pull Request Review Routine

When reviewing PRs, act as a correctness, safety, privacy, docs, release, and
eval reviewer before acting as a style reviewer.

- Compare the PR against the base branch, not just the latest commit.
- Read `.github/pull_request_template.md`, `docs/AI_FIRST_ENGINEERING.md`, and
  `docs/PR_REVIEWER_ROUTINE.md`.
- Lead with actionable findings by severity: `blocker`, `high`, `medium`,
  then `low`.
- Treat assistant, runtime, OpenClaw, watcher, background-job, device-control,
  policy, audit, release, runner, screenshot, accessibility, notification,
  message, call, location, memory, trajectory, and audit-log changes as
  high-scrutiny areas.
- Require clear validation evidence, and call out missing device, emulator,
  OpenClaw, trajectory, benchmark, or release validation when behavior needs
  it.
- Do not request broad rewrites or style-only churn unless it protects a
  contract or prevents future agent confusion.
