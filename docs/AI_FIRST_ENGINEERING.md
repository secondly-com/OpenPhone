# AI-First Engineering

OpenPhone should be built the way the product behaves: small autonomous loops,
strong runtime contracts, visible evidence, and human review at the right
boundaries.

This document is the operating map for making that real in the repository.

## Principles

- Build repeatable loops, not heroic one-off prompts.
- Prefer small green units over large branches.
- Make every agent run inherit the same repository contract.
- Turn repeated manual review into scripts, schemas, benchmarks, or docs checks.
- Keep physical-device evidence separate from source control.
- Let humans approve product, safety, and release decisions; let agents do the
  repetitive exploration, repair, and verification work.

## Required Loops

### Fast Commit Loop

Use for normal implementation tasks.

1. Pick one small task with a clear exit condition.
2. Inspect relevant docs, contracts, and tests.
3. Make the smallest coherent change.
4. Run `./scripts/check.sh`.
5. Run `git diff --check`.
6. Fix failures with at most a few bounded repair passes.
7. Commit one coherent green unit.

This loop is the default for docs, scripts, schemas, protocol contracts,
assistant implementation, and integration code.

### Runtime Contract Loop

Use when changing OpenPhone runtime tools, OpenClaw integration, MCP, CLI, or
future remote runtimes.

Required local checks:

```bash
./scripts/check-runtime-protocol.sh
./scripts/check.sh
git diff --check
```

Required live checks when hardware and a gateway are available:

```bash
./scripts/smoke-test-openclaw-runtime.sh
./scripts/run-eval-suite.sh
```

Any new runtime must define:

- command and event mapping;
- default exposure and safety class;
- confirmation behavior for state-changing actions;
- identity, token, and storage boundaries;
- at least one smoke or contract test.

### Device Eval Loop

Use before claiming phone-control quality improved.

The canonical smoke suite is:

```bash
./scripts/run-eval-suite.sh
```

Benchmark coverage is:

```bash
./scripts/run-agent-benchmark.sh \
  --benchmark docs/agent-benchmarks/openphone-v0.json
```

Device eval output belongs under ignored `.worktree/` paths or GitHub Actions
artifacts, not committed source files.

### Review Loop

Use for pull requests before merge.

1. A reviewer agent compares the branch against the base branch.
2. Findings focus on correctness, safety, privacy, missing validation, docs
   drift, and release risk.
3. The implementer fixes only accepted findings.
4. The reviewer re-checks once.

The goal is not to make agents argue forever. The loop exits when findings are
fixed, explicitly declined, or moved to follow-up work.

### Docs Freshness Loop

Run regularly, and whenever product behavior changes.

Docs review should check:

- whether `docs/README.md` still points to the canonical entry points;
- whether architecture, runtime, security, testing, and release docs agree;
- whether obsolete claims can be deleted instead of explained around;
- whether new scripts or contracts are documented;
- whether docs are readable for a new contributor and specific enough for an
  agent to act on.

Long-term, the docs should be published as a static site, for example at
`docs.openphone.secondly.com`. The source of truth should remain this repo; the
site should render curated docs, not become a second place where truth drifts.

Local-only agent notes belong in ignored `docs/local-temp/`, not in public docs.

## CI And CD Target State

### Current Baseline

- `ci.yml` runs repository checks and whitespace checks on GitHub-hosted Linux.
- `emulator.yml` boots an OpenPhone SDK phone emulator on the
  `openphone-emulator` self-hosted runner for PRs that touch runtime,
  assistant, overlay, patch, integration, or emulator code.
- `eval.yml` runs physical trajectory smokes on the `openphone-device`
  self-hosted runner.
- `release.yml` runs release work on the `openphone-build` self-hosted runner.

### Next CI Layers

1. **PR contract checks**
   - Always run `./scripts/check.sh` and `git diff --check`.
   - Fail quickly on schema, protocol, policy, CLI, MCP, and assistant Java
     regressions.

2. **Emulator runtime smoke**
   - Build or reuse an emulator image with the OpenPhone assistant.
   - Boot it headlessly on the `openphone-emulator` runner.
   - Verify OpenPhone services, assistant install, ADB runtime status, screen
     context, and a local assistant task without provider keys.

3. **Remote runtime smoke**
   - Start or connect to an OpenClaw gateway.
   - Configure the phone runtime over ADB.
   - Verify presence, command exposure, `openphone.screen.get`, and one safe
     tool round trip.

4. **Physical device eval**
   - Run trajectory smokes nightly and on demand.
   - Run the benchmark suite before releases and after high-risk runtime work.
   - Upload trajectories and summaries as private artifacts.

5. **Release gate**
   - Require build, device, runtime, docs, license, and security evidence before
     tagging a release.

### Release Publishing Loop

Every public release should have one obvious trail:

1. Update `docs/releases/CHANGELOG.md`.
2. Update the versioned release notes under `docs/releases/`.
3. Run CI and relevant evals.
4. Dispatch `.github/workflows/release.yml` with the version, device, release
   notes file, prerelease flag, and latest-release behavior.
5. Publish OTA artifacts, `SHA256SUMS`, and `ARTIFACTS.md` to GitHub Releases.
6. Confirm the GitHub release page is the public source for that version.

## Work Queue Shape

Keep tasks small enough that one agent can finish, validate, and commit them.

Each task should include:

- goal;
- likely files;
- validation command;
- risk level;
- exit condition;
- whether device, emulator, OpenClaw, or docs-site validation is required.

Good lanes:

- runtime protocol contracts;
- assistant UI and runtime implementation;
- policy, approvals, and auditability;
- OpenClaw and future runtime adapters;
- emulator/device eval infrastructure;
- docs/site publishing;
- release automation.

## Codex Routines To Add

These routines should run in isolated worktrees where possible.

- **PR reviewer:** review new pull requests for correctness, safety, docs drift,
  missing tests, and privacy risk.
- **CI watchdog:** when CI fails, produce a diagnosis or small patch.
- **Daily docs gardener:** find stale, contradictory, or orphaned docs and
  propose a small cleanup.
- **Eval summarizer:** after nightly device evals, summarize pass/fail,
  regressions, and artifacts.
- **Work queue curator:** maintain the next set of small tasks by lane.

Unattended routines must avoid broad local secrets and should not commit or
push without explicit human review unless the action is narrowly scoped and
well proven.

## Docs Site Target

A hosted docs site should be generated from `docs/` and should have a curated
navigation rather than dumping every Markdown file equally.

Recommended first version:

- static Markdown site generator such as VitePress, Docusaurus, or MkDocs;
- custom domain `docs.openphone.secondly.com`;
- GitHub Pages or another static host;
- docs build check in CI;
- broken-link check;
- clear sections for Concepts, Build, Testing, Runtime, Devices, Releases,
  Legal, and Contributing.

The first docs-site PR should only add the publishing scaffold and navigation.
It should not rewrite all docs at once.

## Definition Of AI-First

OpenPhone is AI-first when:

- every PR is reviewed by humans and agents;
- every important behavior has a script, contract, benchmark, or eval;
- docs are written for both people and agents;
- agents can safely run in parallel worktrees;
- CI proves local, remote, emulator, and physical-device behavior at the right
  cadence;
- repeated work turns into reusable loops.
