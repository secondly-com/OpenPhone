# Changelog

All notable OpenPhone-owned changes should be documented here.

OpenPhone uses semantic versioning for public project releases. Early releases
below `1.0.0` are developer previews and may change architecture, APIs, build
flow, and device support.

## [Unreleased]

### Added

- Dedicated OpenPhone Android Home activity with a calm black AI Home surface,
  press-and-hold/release voice input, text fallback, accessible controls, and a
  two-finger App Space gesture.
- Explicit App Space handoff to the installed Launcher3 implementation while
  preserving Home as a reliable return to AI Home.

### Changed

- Launcher3 remains installed for conventional app access but no longer
  advertises itself as a competing Home activity in OpenPhone products.
- Tapping the compact idle OpenPhone island returns directly to AI Home; the
  existing pull-down gesture continues to expose detailed status.

## [0.0.3] - 2026-07-03

### Added

- Scheduled and manual GCP cache refresh workflow with named GCP Lab lanes and
  latest labeled snapshot discovery for warm-cache runs.

### Changed

- The GCP-backed release path now uses version/device concurrency guards,
  duplicate-release rejection, IAP-scoped lab access, and separate emulator
  smoke build goals during release validation.
- The assistant now defaults to confirm mode, and malformed or unknown action
  payloads fail closed during capability inference instead of falling back to a
  lower-risk default.
- Release, OTA, trajectory, and audit validators now derive required fields,
  enums, schema markers, and related checks from the tracked JSON schemas.
- Repo checks now run `shellcheck` when available, clean temporary files
  through a shared trap root, and keep the GCP warm-cache default Android path
  user-relative instead of hardcoding a personal home directory.
- Public release docs now fix rendered `/docs` links and mark `0.0.2` as the
  current published latest release in the tracked notes.

### Fixed

- Release helper scripts no longer expose broker/admin/provider secrets through
  host argv, stdout, or Android intent extras.

## [0.0.2] - 2026-07-02

### Added

- Agent Runtime V1 design and first assistant-side background job runtime,
  exposed through `background_job_create`, `background_job_list`, and
  `background_job_stop`.
- Background job completion notifications now use explicit delivery text
  instead of dumping raw model/tool trace JSON.
- Dynamic island compact mode is narrower/lower, uses icon-only controls for
  listen/stop/approve/deny, and expands terminal detail in-place before
  opening the full assistant.
- Volume-chord control launches use an isolated control task and immediate
  backgrounding so the full assistant app does not flash open.
- Chat/orchestrator system failures now surface as inspectable dynamic-island
  error states instead of only appearing in the full assistant chat.
- Screen-question failures and timeouts now surface as inspectable
  dynamic-island error states.
- Orchestrator routing now has a UI watchdog, so model routing stalls return a
  visible island error instead of leaving the island glowing indefinitely.
- Voice transcription misses now expand in-place with the actual failure detail
  instead of only showing a generic compact retry state.
- Agent job contract schema for future OS-owned `agent_jobs` storage.
- Dynamic island presentation state model for compact, transcript, reply, and
  approval states.
- User-facing OpenPhone Assistant control surface.
- Active-agent status indication and assistant-owned cursor overlay.
- Development voice capture and OpenAI transcription path.
- Assistant-side trajectory logging for agent runs, including screenshot file
  extraction from framework screenshot payloads.
- Assistant-side accessibility UI tree capture merged into model screen
  context requests.
- Initial eval task definitions for the CUA-informed phone agent loop.
- Planning cleanup for the CUA-informed agent work and public GitHub project
  setup.
- Initial GitHub CI and release documentation.
- Pixel 9a DTB preparation and generated `vendor_kernel_boot.img`
  verification for `openphone_tegu` and `openphone_tegu_smoke` target-files/OTA
  builds.
- OpenPhone Assistant package version bumped to `0.1.1-dev` / `37` so
  system-package reparsing picks up newly declared privileged components during
  development OTAs.
- OpenPhone Assistant package version bumped to `0.1.2-dev` / `38` for the
  cancellation, structured local-result, and accessibility re-enable OTA.
- OpenPhone Assistant package version bumped to `0.1.3-dev` / `39` with a
  packaged parse marker so development OTAs force PackageManager to reparse the
  system APK when deterministic timestamps and similar APK sizes would otherwise
  keep stale metadata.
- OpenPhone Assistant package version bumped to `0.1.4-dev` / `40` for the
  trajectory export build.
- OpenPhone Assistant package version bumped to `0.1.12-dev` / `48` for the
  model disclosure and trajectory metadata build.
- Settings/About phone OpenPhone version and support rows.
- Settings homepage OpenPhone dashboard with assistant, task-grant,
  audit-evidence, and support entry points.
- Settings-hosted OpenPhone task-grant and audit status pages.
- SystemUI-owned OpenPhone Quick Settings tile that exposes agent status,
  launches the assistant when idle, and stops the active task when running.
- OpenPhone Assistant broker/proxy transport option for cloud model calls,
  allowing development builds to use an OpenPhone-controlled endpoint with a
  session token instead of putting provider API keys on the phone.
- Dependency-free reference model broker service with bearer-token auth,
  request size limits, in-memory request-count and byte-volume rate limiting,
  no request-body logging, and OpenAI Responses/transcription proxy endpoints.
- Signed expiring development-token minting for the model broker, so broker
  sessions do not have to rely only on static shared tokens.
- Admin-authenticated model broker `/v1/session_tokens` endpoint for minting
  signed expiring session tokens over HTTP.
- JSON provider/model registry support for the model broker, with the existing
  environment model allowlist retained as a local override.
- JSON device-subject registry support for the model broker token issuer, so
  hosted development brokers can reject unknown token subjects.
- User-supplied GMS sideload helper now runs a post-boot Google Play Services
  location grant repair so fused/network location clients can receive provider
  fixes on developer devices.
- Optional per-subject development HMAC proof for model broker token issuance,
  so registered device subjects can be required to prove possession of a
  device secret before receiving a signed session token.
- First-pass model broker deployment artifacts: hardened systemd unit,
  secret-free environment template, and Linux deployment notes.
- nginx TLS reverse-proxy template for hosted development model broker
  deployments.
- Model broker secret rotation helper for token-signing and admin-token
  rotation without modifying provider keys.
- Provider-key rotation mode for the model broker secret rotation helper.
- certbot/nginx setup helper for model broker TLS configuration and renewal
  validation.
- Release-signing preparation helper that creates a private key workspace and
  Android releasetools key map outside the repository.
- Release OTA signing wrapper around Android releasetools with in-repo key
  refusal and dry-run validation.
- OTA feed schema, generator, and validator for future on-device updater
  clients.
- First-pass sensitive-screen handling for the assistant-side accessibility
  UI tree: password-field labels are redacted, and screenshot tools are blocked
  on password/payment/account-like screens.
- Assistant fallback policy now covers `share.content`, and repo checks verify
  that `PolicyEngine` risk classes stay aligned with
  `openphone_capabilities.json`.
- Added a model-tool registry and schema. Repo checks now verify tool-to-
  capability mappings, framework executor coverage, OpenAI adapter coverage,
  and absence of stale model capability IDs.
- Model `open_url` tools now route through a framework-mediated `network.use`
  action with policy/audit handling instead of direct assistant intent launch.
- Repo checks now validate that assistant-emitted framework action types are in
  the action-request schema and have framework patch-stack handling.
- `FrameworkToolExecutor` now enforces non-empty model-visible reasons for
  model tools marked `requires_reason` in the model-tool registry.
- Audit-event schema now covers framework screen capture/watch and task stop
  events, with repo checks validating schema coverage for framework
  `recordAudit(...)` event names.
- Added a trajectory-event schema and schema marker for assistant
  `events.jsonl` exports, with repo checks validating recorder event coverage.
- Expanded the screen-context schema to cover assistant accessibility UI-tree
  windows, element state, sensitivity hints, and risk flags, with repo checks
  for the key emitted fields.
- Added `scripts/validate-trajectory-export.sh` for assistant trajectory
  evidence directories/zips, including event ordering, screenshot reference,
  and leakage checks.
- Added `schemas/audit-evidence.schema.json` and
  `scripts/validate-audit-evidence-export.sh` for framework audit evidence
  exports.
- Added `schemas/agent-eval-report.schema.json` and
  `scripts/validate-agent-eval-report.sh` so physical agent eval runs can be
  recorded with validated trajectory and audit evidence references.
- Added `scripts/collect-agent-eval.sh` to pull the latest phone-exported
  trajectory/audit files, create `agent-eval.json`, and validate the complete
  eval bundle.
- Added `scripts/diagnose-device-connection.sh` to classify Pixel bringup
  connection states across host USB, ADB, fastboot, shell, and logcat probes.
- Model broker hardening for JSONL request-outcome audit events and optional
  Responses API model allowlisting without logging request bodies.
- Model broker privacy gate for OpenPhone task metadata, sensitive-screen risk
  flags, and maximum screenshot/image count before Responses provider
  forwarding.
- Model broker bounded provider retry for transient upstream 429/5xx failures,
  with retry attempts recorded in body-free audit events.
- Automated model broker smoke test covering broker health, auth rejection,
  token issuer auth, device-proof rejection, signed token minting/acceptance,
  JSON/model/body-size/content-type rejections, audit event writing, and no
  request-body logging.
- Updated v0.0.1 preview release notes and release staging workflow around the
  current Pixel 9a OTA candidate.
- Assistant model provider, model name, cloud/local mode, and privacy
  disclosure shown in the UI and written to trajectory start events.
- Assistant task grant defaults now persist across app launches.
- Settings-owned durable OpenPhone task-grant defaults backed by
  `Settings.Secure`, with switches for input/navigation, screenshots,
  clipboard, sharing, and network/web-link behavior.
- First per-app capability policy seed installed under `system_ext`, plus
  assistant preflight enforcement using the current foreground package from the
  accessibility screen tree.
- Durable `Settings.Secure` app-policy override contract
  `openphone_app_policy_overrides`, evaluated before the built-in per-app
  policy seed.
- Added `scripts/generate-app-policy-override.sh` for creating and installing
  development per-app capability overrides.
- First assistant-owned preview OTA client for generated OpenPhone OTA feeds.
  It checks the feed device, downloads the selected OTA ZIP to
  `Downloads/OpenPhone`, and verifies size/SHA-256 before manual installation.
- OpenPhone Assistant development package bumped to `versionCode=52` /
  `versionName=0.1.16-dev` for the preview OTA client build.
- OpenPhone Assistant development package now reports `versionCode=57` /
  `versionName=0.1.21-dev` in the repository manifest.
- User-facing assistant chat composer with one stateful icon action: mic when
  empty, send when text is present, and stop while listening or running.
- Profile-icon entry point for the assistant advanced/model/developer surface.
- Keyboard-aware assistant layout that keeps the composer above the IME and
  respects bottom safe-area insets on the Pixel 9a.
- Assistant outside-tap keyboard dismissal.
- Fast privileged assistant APK iteration documented and validated on Pixel 9a
  for assistant-only UI/model-loop changes.
- User-supplied Google Mobile Services sideload helper and documentation for
  developer devices. OpenPhone still does not redistribute Google packages.

### Changed

- Contribution policy now accepts external contributions once contributors
  agree that OpenPhone / the project company can own, modify, sublicense, and
  redistribute the contribution.
- The OpenPhone framework service status JSON now includes active task count
  and task IDs so trusted OS surfaces can show and stop current work.
- The OpenPhone framework service SELinux label now lives in private platform
  policy, and the service is listed in the sepolicy fuzzer-binding map so full
  Pixel 9a OTA builds pass release hygiene gates.
- OpenPhone Assistant can export the latest trajectory as a zip file under
  `Downloads/OpenPhone`, giving physical evals a non-root evidence path.
- Public documentation now uses `docs/README.md` as the index, with old
  planning/status documents removed from the public tree.
- Stopping an active agent run now cancels the model adapter, interrupts the
  run thread, prevents stale generations from updating the UI, and treats
  disconnected OpenAI requests as cancellation rather than network failure.
- The local heuristic adapter now emits structured JSON results that the
  user-facing task surface can interpret cleanly.
- The assistant now attempts to re-enable its accessibility service on resume
  as well as at first launch, which helps after fresh OTAs or onboarding resets.
- The assistant app now hides the background service island while the app
  itself is foregrounded, avoiding two competing assistant controls on the same
  screen.
- Hidden control-surface launches now background themselves after starting a
  screen question, so the launcher or current app remains focused while the
  island shows the answer.
- Screen-question runs now have a 30-second UI watchdog that cancels the model
  adapter and returns a visible timeout instead of leaving the island glowing.
- GMS documentation now calls out the unsupported `/data/app` Play
  Store/Play services install state that causes repeated privileged-permission
  crash loops on developer devices.
- Pixel 9a GMS recovery evidence now documents removing stale user-installed
  Google package copies, reinstalling the OpenPhone OTA, and sideloading
  MindTheGapps before first post-OTA boot.

## [0.0.1] - Unreleased

Initial developer preview target.

Planned scope:

- Source-available OpenPhone repository.
- Pixel 9a `tegu` development target documentation.
- Privileged OpenPhone Assistant app.
- Hidden framework service for task, screen, action, policy, confirmation, and
  audit plumbing.
- Lightweight CI checks for repository hygiene.
- Release notes, changelog, and release process documentation.
