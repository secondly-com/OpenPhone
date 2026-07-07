# openphone-agentd

`openphone-agentd` is the phone-resident runtime authority for OpenPhone-iOS.

This first skeleton is intentionally small. It creates the OpenPhone data
directory, listens on a local Unix domain socket, defaults to YOLO mode, and
serves Android-shaped stubs for:

- `health`
- `start_task`
- `stop_task`
- `list_tasks`
- `get_task`
- `get_audit`
- `get_trajectory`
- `model_status`
- `model_configure`
- `list_apps`
- `get_screen`
- `execute_action`
- `run_task`
- `finish_task`
- `fail_task`
- `memory_save`
- `memory_search`
- `memory_update`
- `memory_delete`
- `memory_merge`
- `context_search`
- `clipboard_read`
- `clipboard_write`
- `contacts_search`
- `calendar_search`
- `calls_search`
- `messages_search`
- `commitment_create`
- `commitment_search`
- `commitment_update_status`
- `watcher_create`
- `watcher_list`
- `watcher_stop`
- `watcher_repair_stuck`
- `watcher_run_due`
- `background_job_create`
- `background_job_list`
- `background_job_stop`
- `background_job_repair_stuck`
- `background_job_run_due`
- `hardware_trigger`

The current implemented actions are `wait`, `open_app`, `open_url`, `home`,
`wake_and_home`, `tap`, `long_press`, `swipe`, and `type_text`.
`open_app` and `open_url` use `/var/jb/usr/bin/uiopen` when it exists.
`list_apps` scans known app roots and reads `.app/Info.plist` locally on the
phone. It accepts either a numeric limit or a text query.
`home` uses SpringBoardServices plus GraphicsServices menu-button events.
`wake_and_home` calls `SBSUndimScreen` and then sends a menu-button event.
Coordinate input uses IOKit `IOHIDEventSystemClient` from inside the daemon.
`tap_element` resolves `element_id` or `view_id` from the current UI tree,
computes the bounds center, and includes the target summary in the action
result. Tap-style actions first ask the app-process input bridge for app-owned
elements or the SpringBoard input bridge for SpringBoard-owned views, then fall
back to daemon HID if those bridges cannot activate the target. On the iPhone 14
Pro Max, tap and swipe were verified through raw `execute_action` and
deterministic `run_task`; package `0.1.0-107+debug` also verified a Settings
app-process `tap_element` visible effect through
`OpenPhoneAppIntrospector.AppInput`. The SpringBoard input bridge exposes
`show_passcode`, verified visually with the SpringBoard screenshot bridge.
`unlock_with_passcode` is implemented as an experimental bridge action, but it
returns unavailable unless lock-state verification confirms the device actually
unlocked; current on-device attempts still leave the lock state true.
Text input uses IOHID keyboard events plus the app-process input bridge. Package
`0.1.0-117+debug` verifies direct Notes search text entry through
`OpenPhoneAppIntrospector.AppInput` by checking the app-side text-length delta
and the after UI tree/screenshot. Package `0.1.0-121+debug` verifies a live
Bedrock model task in Notes: the model selected `tap_element` and `type_text`,
the app-process provider returned `user_facing_status=verified`, the requested
text was visible afterward, and the task finished with
`stop_reason=verified_type_text_goal_complete`. Package `0.1.0-122+debug`
extends verified text entry to the Notes body `UITextView`, publishes editable
text values back through the app UI tree, and verifies a live Bedrock-selected
body `type_text` task. Package `0.1.0-126+debug` verifies direct Safari page
text input through the MobileSafari WebKit DOM bridge: Wikipedia search field
`type_text` returned `user_facing_status=verified` with
`verification.source=web_content_dom_state`. HID-only text dispatch remains
unverified unless a later screen/UI diff proves a visible effect.

`get_screen` reports running app bundle IDs by spawning `/bin/ps` directly and
reading each `.app/Info.plist`. It also reports GraphicsServices display
dimensions/scale plus SpringBoard lock/passcode state. It decodes
SpringBoard's phone-local `RecentAppLayouts.pb.lzfse` file to expose
`recent_apps` and `last_known_foreground_candidate`; this is treated as a
fallback/inferred source, not true foreground when the device is locked. When a
fresh SpringBoard state publication has a foreground app and agrees with the
direct daemon foreground read, `get_screen` reports
`foreground_source=springboard_state` so validation can distinguish true
SpringBoard foreground from recent-layout inference. When `include_screenshot`
is true, the daemon invokes `openphone-screencap-helper` and returns a
phone-local PNG path, byte count, and hash if capture succeeds.
Screenshot bytes are not returned through JSON. On the current iPhone 14 Pro
Max, the helper can load the framebuffer and IOSurface symbols, but direct
framebuffer acquisition is denied by the runtime and returns an explicit
`display_connection_unavailable` result. The daemon falls back to the
SpringBoard screenshot bridge, which renders SpringBoard windows into a
phone-local PNG. App-process UI snapshots are published through a narrow
daemon-owned `app_ui_publish` path: app tweaks connect to `127.0.0.1:27631`,
the daemon stores `/var/mobile/Library/OpenPhone/app-ui/<bundle>.json`, and
`get_screen` prefers a fresh foreground-matched app tree before falling back to
SpringBoard. This is local-smoke covered and was verified on the iPhone 14 Pro
Max after installing `0.1.0-106+debug`: Safari and Settings both returned
`get_screen.context.ui_tree_source=app_process`. Package `0.1.0-107+debug`
adds `app_input_poll`/`app_input_complete` on the same loopback intake so the
app introspector can activate app-owned controls from inside the target process.
Manual validation tapped Settings `General` and observed the app UI tree change
to the General page. Notes search text entry is also verified on-device with
`user_facing_status=verified` in package `0.1.0-117+debug`, and the live
Bedrock Notes body text-entry loop is verified in package `0.1.0-122+debug`.
Package `0.1.0-123+debug` adds bounded non-UIView accessibility child
enumeration and matching element lookup for app-process trees. Current Safari
evidence shows MobileSafari still publishes zero WebKit accessibility children;
package `0.1.0-125+debug` attempted a separate
`com.apple.WebKit.WebContent` XPC tweak bridge but did not observe a WebContent
tweak load or WebContent app UI publication. Package `0.1.0-126+debug` adds the
working route for now: MobileSafari `_SFWebView`/WebKit DOM evaluation from the
app process, with DOM-backed web elements published under `ui_tree.web_dom`.

`memory_save`, `memory_search`, `memory_update`, `memory_delete`,
`memory_merge`, and `context_search` use a phone-local SQLite store at
`/var/mobile/Library/OpenPhone/db/openphone.sqlite`. The daemon creates the
`memory` and `context_event` tables, uses FTS5 when available, and falls back to
SQL `LIKE` search when FTS is unavailable. Memory updates and merges keep the
FTS index synchronized; merges update the target memory and delete the source
memory. `clipboard_read` and `clipboard_write` expose bounded phone clipboard
text through daemon commands and model/Realtime tools; both create context and
audit events. Package `0.1.0-132+debug` validates the real on-device provider
through `OpenPhoneVolumeTrigger.SpringBoardClipboard`, a SpringBoard-context
`UIPasteboard` bridge. Local macOS smoke uses a daemon-local fallback file when
SpringBoard is unavailable. `contacts_search` is the first read-only contacts
provider slice: it searches AddressBook SQLite on the phone when available,
falls back to a local fixture in macOS smoke, returns bounded contact summaries
to the caller/model, and stores only query length/hash plus count/provider
metadata in context/audit. Package `0.1.0-133+debug` validates read-only
AddressBook access on the iPhone 14 with a nonexistent query and sanitized
`contacts_searched` context event.
`calendar_search`, `calls_search`, and `messages_search` are read-only phone
data provider slices. They search Calendar, CallHistory, and SMS/iMessage
SQLite stores through a dedicated protected-data helper when available, fall
back to local fixtures in macOS smoke, return bounded summaries/previews to the
caller/model, and store only query length/hash, time range, count, and provider
metadata in context/audit. Package `0.1.0-143+debug` validates the protected
path on the iPhone 14 with nonexistent queries: main daemon calls returned
provider `Calendar.sqlitedb`, `CallHistory.storedata`, and `SMS.sqlite`, each
with count `0`, and indexed sanitized `calendar_searched`, `calls_searched`,
and `messages_searched` context events. The helper is currently started by the
installer from the proven SSH/sudo context; launchd-root, launchd-mobile, and
LaunchAgent helper starts did not receive equivalent protected SQLite access.
`commitment_create`,
`commitment_search`, `commitment_update_status`, `commitment_run_due`,
`watcher_create`,
`watcher_list`, `watcher_stop`, `watcher_run_due`, `watcher_repair_stuck`,
`background_job_create`,
`background_job_list`, `background_job_run_due`,
`background_job_repair_stuck`, and `background_job_stop` use the same SQLite
store. Background jobs now have a first deterministic runner for explicit
`background_job_run_due` and hardware-trigger paths: before claiming due work it
requeues stale scheduler-enabled `running` rows through
`background_job_repair_stuck`, records `payload.stuck_repair` metadata, then
claims due `queued` jobs, runs each through the phone-local `run_task` loop, and
persists the result back onto the job row. Periodic daemon scheduler ticks wait
through a startup grace period and perform repair/materialization only, so daemon
restart recovery can unstick durable rows without launching task bodies from the
maintenance thread. Jobs with `interval_ms` or explicit `recurring=true` now
requeue after successful runs with the next interval time, and recurring
failures requeue with bounded exponential backoff. The scheduler records
`run_policy`, `failure_count`, and `retry_backoff_ms` in both schedule/payload
metadata, and local smoke covers interval requeue, explicit
`recurring=false` terminal interval jobs, and first-failure backoff.
Due commitments now have a local bridge too: active commitments with
`due_at_ms`/`due_at` are claimed as `running`, materialize into audited
`commitment_due` background jobs, and then move to `triggered` with scheduler
evidence containing the generated job id. `commitment_run_due` runs that bridge
directly, and `background_job_run_due` includes it during scheduler ticks.
Timer watchers now have a local bridge: active
`time`/`timer`/`deadline` watchers with a due `next_run_at_ms` are first claimed
as `running`, then materialize into audited scheduler-enabled background jobs.
After successful job creation they move to `fired` or, for recurring watchers,
back to `active` with the next run time. Stale `running` timer watchers are
repaired by `watcher_repair_stuck` and by `watcher_run_due` before new due
watchers are claimed. Notification, message, call, web, and semantic watchers
remain durable-only until their providers exist. Notification, message, and call
providers are still not implemented.

`model_status` reports phone-local model-loop readiness without returning
provider credential values. `model_configure` writes only non-credential
metadata such as broker/direct-dev mode, endpoint URL, model name, and loop
limits under `/var/mobile/Library/OpenPhone/config/` with protected file
permissions. `run_task` supports `deterministic`, `model`, and `auto` modes.
Model mode now has the daemon-owned observe/parse/execute/verify loop,
`openphone.model_decision.v1` parser, conservative parser repair for
prose/fenced-code wrapped decision JSON, `finish_task`/`fail_task` terminal
tools, registered-tool execution through daemon APIs, cooperative cancellation
for adopted task IDs stopped through `stop_task`, and fixture-provider smoke
coverage. Broker HTTP execution is implemented inside the daemon and covered by
local smoke through a localhost broker fixture. Host-side provider validation
can use `tools/mac/agentd/bedrock-model-broker.py` with SSH reverse forwarding
so the phone calls a local broker endpoint while provider credentials stay off
the phone. Direct Bedrock execution from the phone is verified, including a
live Notes body UI-action task in package `0.1.0-122+debug`. Live model-loop
evidence for Safari DOM fields is still pending after the package
`0.1.0-126+debug` direct tool-path verification. Package `0.1.0-145+debug`
validates the SpringBoard prompt-to-agent handoff through the local prompt
bridge: request `prompt-run-1782975246` showed the `Agent request submitted`
and `Agent loop started` overlays, created
`ios-task-1782975246781-41566` from `source=springboard_prompt`, and completed
through Bedrock with `stop_reason=finish_task`, `steps_used=1`, and
`tool_errors=0`. Package `0.1.0-129+debug`
adds direct OpenAI Realtime WebSocket modes: `openai_realtime` defaults to
`gpt-realtime`, and `openai_realtime2` defaults to `gpt-realtime-2` with low
reasoning effort. The daemon keeps one Realtime session open per task, exposes
the same iPhone tools as function tools, executes function calls locally, sends
function outputs back into the session, and records normal model-loop
trajectory/audit events. Local smoke validates Realtime-2 config/status without
calling OpenAI; live execution requires a real OpenAI credential in
`/var/mobile/Library/OpenPhone/config/model-credential.json`.

`hardware_trigger` records a phone-local hardware activation, indexes it as a
context event, audits it, and starts an async phone-local model task when the
model provider is ready. Package `0.1.0-90+debug` returned a stable
acknowledgement without synchronously draining a deterministic job while the
device-only runner restart was investigated. The
physical path was confirmed on 2026-07-01 at 12:41 PDT: the SpringBoard hook
detected the combo, the daemon returned `ok`, queued `ios-job-72`, and the
daemon stayed on the same PID. The
daemon also starts an
experimental `IOHIDEventSystemClient` listener
for Volume Up + Volume Down. On the current phone this listener registers but
does not call `IOHIDEventSystemClientActivate`, because activating the
run-loop-scheduled client aborts `openphone-agentd` on this iOS 16.5 device.
If a daemon-side event reaches it later, it now honors the same
`com.openphone.volumetrigger` preferences as the SpringBoard path. The
package also ships `OpenPhoneVolumeTrigger.dylib` under
`/var/jb/usr/lib/TweakInject/` as the active SpringBoard tweak-loader fallback. The
fallback currently hooks `SBVolumeHardwareButtonActions` and related
SpringBoard volume selectors, plus object/raw-HID button probes such as the
narrow `SBCameraHardwareButtonStudyLogger logButtonEvent:` raw `IOHIDEvent`
hook. The raw-HID hook only classifies consumer Volume Up/Down usages and does
not start or activate a HID client. Package `0.1.0-175+debug` also installs a
passive `AVSystemController_SystemVolumeDidChangeNotification` observer inside
SpringBoard; it seeds the current system volume and feeds inferred up/down
deltas into the same combo state machine. The tweak logs individual button
events, retries the daemon Unix socket, uses a 1.2s Volume Up + Volume Down
combo window, opens an OpenPhone prompt by default, plays haptic feedback, and
shows scene-attached SpringBoard prompt/overlay state. Do not use a
SpringBoard-context `IOHIDEventSystemClient` listener on this device;
`IOHIDEventSystemClientActivate` crashed SpringBoard into safe mode.

## Build

This directory uses Theos rootless packaging:

```sh
cd ios/agentd
make package
```

The build host must have Theos installed. The Makefile auto-detects
`$HOME/theos`, `/opt/theos`, and `/var/theos`; otherwise run with
`THEOS=/path/to/theos`.

The package installs:

```text
/var/jb/usr/local/bin/openphone-agentd
/var/jb/usr/local/bin/openphone-agentctl
/var/jb/usr/local/bin/openphone-screencap-helper
/var/jb/Library/LaunchDaemons/com.openphone.agentd.plist
```

## On-Device Debug

After installing and loading the daemon, query health on the phone:

```sh
/var/jb/usr/local/bin/openphone-agentctl
```

Or send a command:

```sh
/var/jb/usr/local/bin/openphone-agentctl start_task "open Safari"
/var/jb/usr/local/bin/openphone-agentctl list_tasks 10
/var/jb/usr/local/bin/openphone-agentctl list_apps 50
/var/jb/usr/local/bin/openphone-agentctl list_apps safari
/var/jb/usr/local/bin/openphone-agentctl get_task <task-id>
/var/jb/usr/local/bin/openphone-agentctl get_trajectory <task-id> 20
/var/jb/usr/local/bin/openphone-agentctl get_audit 20
/var/jb/usr/local/bin/openphone-agentctl get_screen screenshot
/var/jb/usr/local/bin/openphone-agentctl memory_save "user prefers concise updates" preference user
/var/jb/usr/local/bin/openphone-agentctl memory_search concise 5
/var/jb/usr/local/bin/openphone-agentctl memory_update ios-memory-1 "user prefers concise status updates" preference user
/var/jb/usr/local/bin/openphone-agentctl memory_merge ios-memory-1 ios-memory-2 "user prefers concise updates"
/var/jb/usr/local/bin/openphone-agentctl memory_delete ios-memory-3 "obsolete memory"
/var/jb/usr/local/bin/openphone-agentctl context_search concise 5
/var/jb/usr/local/bin/openphone-agentctl '{"command":"clipboard_write","text":"copy this","reason":"user asked to copy text"}'
/var/jb/usr/local/bin/openphone-agentctl '{"command":"clipboard_read","max_chars":4096,"reason":"user asked about copied text"}'
/var/jb/usr/local/bin/openphone-agentctl '{"command":"contacts_search","query":"Ada","limit":5,"reason":"user asked for a saved contact"}'
/var/jb/usr/local/bin/openphone-agentctl '{"command":"calendar_search","query":"standup","limit":5,"reason":"user asked about schedule context"}'
/var/jb/usr/local/bin/openphone-agentctl '{"command":"calls_search","query":"Ada","limit":5,"reason":"user asked about recent calls"}'
/var/jb/usr/local/bin/openphone-agentctl '{"command":"messages_search","query":"Ada","limit":5,"reason":"user asked about saved messages"}'
/var/jb/usr/local/bin/openphone-agentctl commitment_create "follow up with Adam"
/var/jb/usr/local/bin/openphone-agentctl commitment_search Adam 5
/var/jb/usr/local/bin/openphone-agentctl commitment_update_status ios-commitment-1 completed
/var/jb/usr/local/bin/openphone-agentctl '{"command":"commitment_run_due","limit":5}'
/var/jb/usr/local/bin/openphone-agentctl watcher_create "watch for smoke condition" time
/var/jb/usr/local/bin/openphone-agentctl watcher_list smoke 5
/var/jb/usr/local/bin/openphone-agentctl '{"command":"watcher_run_due","limit":5}'
/var/jb/usr/local/bin/openphone-agentctl '{"command":"watcher_repair_stuck","limit":5}'
/var/jb/usr/local/bin/openphone-agentctl watcher_stop ios-watcher-1
/var/jb/usr/local/bin/openphone-agentctl background_job_create "smoke job" "summarize durable stores"
/var/jb/usr/local/bin/openphone-agentctl background_job_run_due 5 1 15000
/var/jb/usr/local/bin/openphone-agentctl '{"command":"background_job_repair_stuck","limit":5}'
/var/jb/usr/local/bin/openphone-agentctl background_job_list durable 5
/var/jb/usr/local/bin/openphone-agentctl background_job_stop ios-job-1
/var/jb/usr/local/bin/openphone-agentctl hardware_trigger volume_up_down_combo
/var/jb/usr/local/bin/openphone-agentctl model_status
/var/jb/usr/local/bin/openphone-agentctl model_configure broker https://broker.example/v1/decision openphone-broker-model true
/var/jb/usr/local/bin/openphone-agentctl '{"command":"model_configure","mode":"openai_realtime2","enabled":true,"model":"gpt-realtime-2","max_steps":40,"max_duration_ms":600000}'
/var/jb/usr/local/bin/openphone-agentctl '{"command":"execute_action","action":{"type":"wait","duration_ms":1000}}'
/var/jb/usr/local/bin/openphone-agentctl home
/var/jb/usr/local/bin/openphone-agentctl wake_and_home
/var/jb/usr/local/bin/openphone-agentctl show_passcode
/var/jb/usr/local/bin/openphone-agentctl tap 120 300
/var/jb/usr/local/bin/openphone-agentctl tap_element springboard-3-1
/var/jb/usr/local/bin/openphone-agentctl long_press 120 300 800
/var/jb/usr/local/bin/openphone-agentctl swipe 200 800 200 250 350
/var/jb/usr/local/bin/openphone-agentctl type_text "hello from OpenPhone"
/var/jb/usr/local/bin/openphone-agentctl '{"command":"execute_action","action":{"type":"unlock_with_passcode","passcode":"<device-passcode>"}}'
/var/jb/usr/local/bin/openphone-agentctl open_app com.apple.mobilesafari
/var/jb/usr/local/bin/openphone-agentctl open_url https://example.com
/var/jb/usr/local/bin/openphone-agentctl run_task "open Safari"
/var/jb/usr/local/bin/openphone-agentctl run_task "tap 120 300"
/var/jb/usr/local/bin/openphone-agentctl run_task "swipe 200 800 200 250 350"
/var/jb/usr/local/bin/openphone-agentctl run_task "type hello from OpenPhone"
/var/jb/usr/local/bin/openphone-agentctl run_task "open Safari" 3 60000
/var/jb/usr/local/bin/openphone-agentctl run_task "inspect the screen" model 3 60000
/var/jb/usr/local/bin/openphone-agentctl finish_task ios-task-1 "Task complete"
/var/jb/usr/local/bin/openphone-agentctl fail_task ios-task-1 "Unable to complete"
```

Logs and durable data live under:

```text
/var/mobile/Library/OpenPhone/
```

Important files:

```text
/var/mobile/Library/OpenPhone/tasks/<task-id>.json
/var/mobile/Library/OpenPhone/audit/audit-events.jsonl
/var/mobile/Library/OpenPhone/trajectories/<task-id>.jsonl
/var/mobile/Library/OpenPhone/db/openphone.sqlite
/var/mobile/Library/OpenPhone/openphone-agentd.log
```

This daemon is the runtime target. Host-side scripts may install, restart, and
query it, but they should not own agent reasoning or task execution.
