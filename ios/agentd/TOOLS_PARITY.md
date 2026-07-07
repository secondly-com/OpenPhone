# Tools parity — iOS vs Android

This is a first-pass audit of the tool surface. Marked ✅ when iOS has a
direct equivalent, ⚠️ when partial, ❌ when missing.

## Screen observation

| Capability | iOS | Notes |
|---|---|---|
| `get_screen` (foreground, UI tree, screenshot) | ✅ | `OPGetScreen` |
| Web DOM state (Safari) | ✅ | `web_content_dom_state` via app introspector |
| Recent apps / app switcher | ⚠️ | Metadata via SpringBoard state; no explicit `open_recent` |

## Input

| Capability | iOS | Notes |
|---|---|---|
| `tap`, `tap_element` | ✅ | `tap` (coords) + `tap_element` (id) |
| `long_press` | ✅ | present |
| `swipe` | ✅ | present |
| `type_text` | ✅ | Safari DOM + first-party UITextField bridge |
| `home` / `wake_and_home` | ✅ | present |
| `wait` | ✅ | present |

## First-party data

| Capability | iOS | Notes |
|---|---|---|
| `contacts_search` | ✅ | present |
| `calendar_search` | ✅ | present |
| `calls_search` | ✅ | present |
| `messages_search` | ✅ | present |
| Send a Message | ⚠️ | Only via UI navigation to Messages + type_text. No direct `messages_send`. |
| Place a Call | ⚠️ | Only via UI. No direct `calls_dial`. |
| Calendar create | ❌ | Add `calendar_create` — Android has direct create/edit. |
| Contacts create/edit | ❌ | Add `contacts_create` / `contacts_update`. |

## Clipboard / interop

| Capability | iOS | Notes |
|---|---|---|
| `clipboard_read` / `clipboard_write` | ✅ | present |
| `open_url` | ✅ | present |
| `open_app` | ✅ | present |
| Deep-link handoff (`x-callback-url`, universal links) | ⚠️ | Works via `open_url` but no dedicated `handoff` tool with expected-response schema. |

## Memory / context

| Capability | iOS | Notes |
|---|---|---|
| `memory_save`, `memory_search` | ✅ | present |
| `context_search` | ✅ | present |
| Chat history (last N voice turns) | ✅ | Added tonight — `OPRecordVoiceTurn` prepends recent turns to follow-up goals within 10s. |

## Autonomy / meta

| Capability | iOS | Notes |
|---|---|---|
| `finish_task`, `fail_task` | ✅ | present |
| `ask_user_confirmation` | ⚠️ | Not a model-emitted tool. iOS gates *any* UI-driving tool via `AutonomyMode=reviewed` and pauses with island Approve/Deny chips. Different mechanism, similar UX. |

## Watchers / background jobs

| Capability | iOS | Notes |
|---|---|---|
| Create / list / cancel `watcher` | ✅ | daemon commands exist |
| Recurring / due background jobs | ✅ | daemon commands exist |
| Model can create them mid-loop | ⚠️ | Tools are not in `OPModelToolNames()`. Only accessible via daemon RPC, not directly by the model. Consider adding `watcher_create`, `background_job_create` to the model tool list so it can schedule future work. |

## Suggested additions (highest-impact)

1. **`messages_send`** — write to iMessage via SpringBoard/Messages app plus a
   composed UI flow. Direct tool preferred over multi-step UI navigation.
2. **`calls_dial`** — start a call to a phone number or contact.
3. **`calendar_create`** and **`contacts_create`** — EventKit / Contacts
   frameworks via the daemon.
4. **`watcher_create` / `background_job_create`** — expose scheduler to the model.
5. **`ask_user_confirmation`** — turn the current island Approve/Deny into a
   model-callable tool so the model itself decides when to pause.

## Not applicable to iOS

- Android accessibility service `dispatchGesture` — iOS uses UIKit hit-testing
  bridge and SpringBoard tweak instead. Different implementation, same net
  capability.
- `dispatchNotification` / notification listeners — iOS does not expose
  notification stream to third parties.
