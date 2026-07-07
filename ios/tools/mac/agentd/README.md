# Agentd Mac Tools

These scripts install, restart, and inspect `openphone-agentd` on an owned
iPhone with a rootless runtime prefix at `/var/jb`.

They are development and recovery tools. They do not run the OpenPhone agent on
the Mac.

Local host smoke test before packaging or device install:

```sh
tools/mac/agentd/smoke-agentd-local.sh
```

The smoke test compiles `openphone-agentd` and `openphone-agentctl` for macOS,
runs the daemon against a temporary store, verifies `health`, exercises memory,
context, commitments, watchers, timer watcher materialization, stale watcher
repair, background-job creation, `background_job_run_due`, stale background-job
repair, the deferred hardware-trigger command path, audit/trajectory export, and one
deterministic `run_task` request. It also runs a fixture-backed model-mode
`run_task` through the daemon's model decision parser,
registered-tool executor, terminal `finish_task`, parser repair for
prose/fenced-code wrapped decision JSON, and trajectory export. It then
configures a local localhost model broker fixture and verifies broker-backed
model mode through the daemon HTTP provider path without any credential. A local
deterministic `task.failed` result is expected for Safari because `uiopen` only
exists on the device under the rootless prefix.

Validate an agentd store pulled from the phone or produced by the smoke test:

```sh
tools/mac/agentd/validate-agentd-store.py /var/mobile/Library/OpenPhone
```

The validator parses task, audit, and trajectory files and verifies the audit
hash chain.

Environment:

```sh
export OPENPHONE_IOS_HOST=<iphone-host-or-127.0.0.1-for-usb-forward>
export OPENPHONE_IOS_SSH_PORT=22
export OPENPHONE_IOS_USER=mobile
export OPENPHONE_IOS_PASSWORD=<optional-password-for-dev-devices>
```

When more than one iPhone is connected, do not start a generic USB tunnel.
Pin `iproxy` to the intended device UDID:

```sh
export OPENPHONE_IOS_HOST=127.0.0.1
export OPENPHONE_IOS_SSH_PORT=2222
export OPENPHONE_IOS_UDID=<iphone-14-pro-max-udid>
export OPENPHONE_IOS_EXPECTED_DEVICE_NAME=<your-device-name>
export OPENPHONE_IOS_EXPECTED_PRODUCT_TYPE=iPhone15,3
```

`iPhone15,3` is Apple's hardware identifier for the iPhone 14 Pro Max. The
scripts treat it only as an identity guard; it does not mean the separate
iPhone 15 named `<other-personal-device>` should be used.

Build and install the rootless package:

```sh
(cd ios/agentd && make package)
tools/mac/agentd/install-agentd-package.sh
```

`install-agentd-package.sh` copies the latest package from `ios/agentd/packages`,
runs `dpkg -i` with `sudo` on the phone, reloads the launchd plist, and prints
daemon health. Set `OPENPHONE_AGENTD_DEB=/path/to/package.deb` to install a
specific package. Set `OPENPHONE_IOS_START_IPROXY=1` with
`OPENPHONE_IOS_UDID=<udid>` to let the installer start and clean up a temporary
pinned USB tunnel. It refuses unpinned automated tunnels by default.

Install loose binaries after building `ios/agentd`:

```sh
tools/mac/agentd/install-agentd.sh
```

Restart:

```sh
tools/mac/agentd/restart-agentd.sh
```

Tail daemon log:

```sh
tools/mac/agentd/tail-agentd-log.sh
```

Run an on-device validation pass:

```sh
tools/mac/agentd/validate-on-device.sh --mode collect-only
tools/mac/agentd/validate-on-device.sh --mode baseline
tools/mac/agentd/validate-on-device.sh --mode full
OPENPHONE_VALIDATE_INCLUDE_STORES=1 tools/mac/agentd/validate-on-device.sh --mode collect-only
OPENPHONE_VALIDATE_INCLUDE_APP_UI=1 tools/mac/agentd/validate-on-device.sh --mode collect-only
OPENPHONE_VALIDATE_INCLUDE_TRIGGER_DIAGNOSTICS=1 \
  OPENPHONE_VALIDATE_TRIGGER_WAIT_SECONDS=20 \
  tools/mac/agentd/validate-on-device.sh --mode collect-only
```

Set `OPENPHONE_VALIDATE_START_IPROXY=1` with `OPENPHONE_IOS_UDID=<udid>` to
let validation start a temporary pinned tunnel. If a listener already exists on
the local SSH port, validation fails unless
`OPENPHONE_VALIDATE_ALLOW_EXISTING_IPROXY=1` is set after manually confirming
that listener targets the intended iPhone.

The validator writes a structured report under
`artifacts/validation/<run-id>/report.json`. `collect-only` does not build or
install anything. `baseline` runs local smoke, builds and installs the package,
then collects health, SpringBoard crash state, safe-mode markers, screen state,
and logs. `full` adds safe store/task queries. Screenshots are opt-in with
`OPENPHONE_VALIDATE_INCLUDE_SCREENSHOT=1`; when enabled, the validator pulls the
phone-local PNG and samples decoded pixels so blank captures fail the screenshot
gate. Optional gates stop early if a safe-mode marker or new SpringBoard crash is
detected. Set `OPENPHONE_VALIDATE_INCLUDE_STORES=1` with `collect-only` to run
read-only task, audit, memory, context, background-job, commitment, and watcher
queries without rebuilding or reinstalling the package. Store validation checks
both command status and required response shape, including expected arrays,
counts, and key identifiers. It also selects the latest safe task id from
`list_tasks`, then validates `get_task` and `get_trajectory` response shape.

`OPENPHONE_VALIDATE_INCLUDE_TRIGGER_DIAGNOSTICS=1` is the physical trigger gate:
unlock the phone first, start the validator, then press Volume Up followed by
Volume Down during the wait window. The report compares before/after
SpringBoard button, combo, and passive volume-notification counters, links the
latest task/trajectory, and fails with explicit reasons such as
`no_physical_volume_event_observed`, `volume_combo_not_observed`, or
`combo_observed_without_new_agent_task`. Press only after the validator has
entered the wait window; pressing during setup can still start a real task, but
the before/after delta gate will correctly fail because the event happened
before the baseline snapshot.

Set `OPENPHONE_VALIDATE_INCLUDE_PROVIDER_ATTEMPTS=1` to add a no-dispatch
input-provider sample: the validator starts a tiny validation task, runs a
missing-coordinate tap that cannot dispatch HID or activate SpringBoard, and
checks the resulting provider-attempt and trajectory schema.
Set `OPENPHONE_VALIDATE_INCLUDE_MEMORY_LIFECYCLE=1` to add a contained memory
lifecycle sample that saves, updates, merges, deletes, and searches validation
memories on the phone.
Set `OPENPHONE_VALIDATE_INCLUDE_MODEL_LOOP=1` to add a fixture-backed model-loop
sample that runs `run_task mode=model`, executes parsed
`openphone.model_decision.v1` decisions through daemon tools, finishes with
`finish_task`, verifies a stopped adopted task exits as `task.cancelled` before
executing a model decision, verifies parser repair for prose/fenced-code wrapped
decision JSON, and validates the model trajectory shape without network access.
Set `OPENPHONE_VALIDATE_INCLUDE_WATCHER_TIMER=1` to add a due timer watcher
sample. The validator creates a local `time` watcher, materializes it through
`watcher_run_due`, confirms a scheduler-enabled background job was created and
listed, checks that the watcher reached `fired`, and then stops the watcher.
Set `OPENPHONE_VALIDATE_INCLUDE_WATCHER_REPAIR=1` to add a stale watcher repair
sample. The validator creates a future local timer watcher, marks it
validation-only stale `running`, repairs it through `watcher_repair_stuck`,
verifies `metadata.stuck_repair`, fires it through `watcher_run_due`, optionally
drains the generated background job, and stops the fixture watcher.
Set `OPENPHONE_VALIDATE_INCLUDE_UNLOCKED_FOREGROUND=1` to add foreground source
validation. The validator requires the phone to be physically unlocked, launches
Safari through the daemon, waits for the SpringBoard state publisher, verifies
that `get_screen.context.foreground_app` is `com.apple.mobilesafari` with
`foreground_source=springboard_state`, rejects recent-layout inference, sends
Home, and captures cleanup screen state. If the phone is locked, the gate reports
`blocked_locked`; set `OPENPHONE_VALIDATE_REQUIRE_UNLOCKED=1` to make that gate
required.
Set `OPENPHONE_VALIDATE_INCLUDE_APP_UI=1` to add app-process UI validation. The
validator requires the phone to be physically unlocked, relaunches Safari and
Settings, waits for app tweak publication through daemon TCP intake, and
requires `get_screen.context.ui_tree_source=app_process` plus nonempty UI trees
for both apps.
Set `OPENPHONE_VALIDATE_INCLUDE_JOB_REPAIR=1` to add a stale background-job
repair sample. The validator creates a future scheduler-enabled job, marks that
job as validation-only stale `running`, repairs it through
`background_job_repair_stuck`, verifies the row is requeued with
`payload.stuck_repair`, lets the scheduler race/run it if due, and cleans up the
fixture job.
Set `OPENPHONE_VALIDATE_INCLUDE_RESTART_RECOVERY=1` to add daemon restart
recovery validation. The validator creates durable future watcher/job fixtures,
marks both validation-only stale `running`, kills `openphone-agentd`, waits for
launchd to restart it and for repair/materialization scheduler ticks to run,
then validates that stale watcher/job rows were repaired after restart. Override
the launchd restart timeout with
`OPENPHONE_VALIDATE_RESTART_RECOVERY_START_TIMEOUT_SECONDS`; the default is
`60`. Override the restarted-PID stability window with
`OPENPHONE_VALIDATE_RESTART_RECOVERY_STABLE_SECONDS`; the default is `12`.
Override the post-restart scheduler wait with
`OPENPHONE_VALIDATE_RESTART_RECOVERY_WAIT_SECONDS`; the default is `36`.
Set `OPENPHONE_VALIDATE_INCLUDE_PROVIDER_MODEL=1` to add a provider-backed
broker sample. The validator starts `bedrock-model-broker.py` on the Mac, opens
an SSH reverse tunnel so the phone can call `127.0.0.1:<phone-port>`, configures
`openphone-agentd` to that broker, runs `run_task mode=model`, validates
Bedrock-provider metadata in the phone trajectory, and resets model config. The
real Bedrock path requires `AWS_BEARER_TOKEN_BEDROCK` or
`OPENPHONE_BEDROCK_BEARER_TOKEN`; set `OPENPHONE_BEDROCK_MODEL` and
`OPENPHONE_BEDROCK_REGION` when needed. For transport tests without a provider
credential, set `OPENPHONE_BEDROCK_RUNTIME_URL` to a local mock Bedrock Runtime
endpoint.
Every report also runs an artifact hygiene gate over generated text/JSON
artifacts; it reports only detector names and locations, skips binary
screenshots/packages, and fails with exit code `90` if a password, passcode,
token, API key, private key, or bearer-token-shaped leak is found. The
provider-model gate fails with exit code `100` when the broker, reverse tunnel,
phone model config, task result, trajectory metadata, or reset step fails.

If Theos outputs binaries to a non-default location, set:

```sh
export OPENPHONE_AGENTD_BIN=/path/to/openphone-agentd
export OPENPHONE_AGENTCTL_BIN=/path/to/openphone-agentctl
```
