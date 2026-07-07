#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
work="${OPENPHONE_AGENTD_SMOKE_DIR:-/tmp/openphone-agentd-smoke}"
broker_pid=""
pid=""

rm -rf "$work"
mkdir -p "$work"

python3 - <<'PY' "$work/model-broker-port.txt" >"$work/model-broker.log" 2>&1 &
import http.server
import json
import pathlib
import sys

port_path = pathlib.Path(sys.argv[1])

class Handler(http.server.BaseHTTPRequestHandler):
    counter = 0

    def log_message(self, fmt, *args):
        return

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0") or "0")
        body = self.rfile.read(length)
        try:
            request = json.loads(body.decode("utf-8"))
        except Exception:
            request = {}
        Handler.counter += 1
        if Handler.counter == 1:
            decision = {
                "schema": "openphone.model_decision.v1",
                "thought": "broker fixture pauses before finishing",
                "tool": "wait",
                "arguments": {"duration_ms": 10},
                "expected_visible_change": "none",
                "confidence": 0.9,
            }
        else:
            decision = {
                "schema": "openphone.model_decision.v1",
                "thought": "broker fixture finished",
                "tool": "finish_task",
                "arguments": {"summary": "Broker fixture model loop completed."},
                "expected_visible_change": "none",
                "confidence": 0.95,
            }
        response = {
            "schema": "openphone.model_response.v1",
            "decision": decision,
            "metadata": {
                "fixture": True,
                "step": request.get("step"),
                "request_schema": request.get("schema"),
            },
            "usage": {"requests": Handler.counter},
        }
        encoded = json.dumps(response).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
port_path.write_text(str(server.server_port), encoding="utf-8")
server.serve_forever()
PY
broker_pid=$!
for _ in $(seq 1 50); do
  if [[ -s "$work/model-broker-port.txt" ]]; then
    break
  fi
  sleep 0.1
done
if [[ ! -s "$work/model-broker-port.txt" ]]; then
  echo "model broker fixture did not start" >&2
  exit 1
fi
broker_port="$(cat "$work/model-broker-port.txt")"

cleanup() {
  if [[ -n "$pid" ]]; then
    kill "$pid" >/dev/null 2>&1 || true
  fi
  if [[ -n "$broker_pid" ]]; then
    kill "$broker_pid" >/dev/null 2>&1 || true
  fi
  if [[ -n "$pid" ]]; then
    wait "$pid" >/dev/null 2>&1 || true
  fi
  if [[ -n "$broker_pid" ]]; then
    wait "$broker_pid" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

xcrun clang -fobjc-arc -framework Foundation -framework AVFoundation \
  -framework AudioToolbox -framework Speech \
  -lcompression -lsqlite3 \
  "$repo_root/agentd/src/main.m" \
  -o "$work/openphone-agentd"
xcrun clang -fobjc-arc -framework Foundation \
  "$repo_root/agentd/src/agentctl.m" \
  -o "$work/openphone-agentctl"

mkdir -p "$work/store/config"
python3 - <<'PY' "$work/store/config/contacts-fixture.json"
import json
import pathlib
import sys

fixture = {
    "schema": "openphone.contacts_fixture.v1",
    "contacts": [
        {
            "contact_id": "fixture-ada",
            "display_name": "Ada Lovelace",
            "given_name": "Ada",
            "family_name": "Lovelace",
            "organization": "Analytical Engines",
            "phone_numbers": ["+1555010101"],
            "emails": ["ada@example.test"],
        },
        {
            "contact_id": "fixture-grace",
            "display_name": "Grace Hopper",
            "emails": ["grace@example.test"],
        },
    ],
}
pathlib.Path(sys.argv[1]).write_text(json.dumps(fixture), encoding="utf-8")
PY
python3 - <<'PY' "$work/store/config/calendar-fixture.json"
import json
import pathlib
import sys

fixture = {
    "schema": "openphone.calendar_fixture.v1",
    "events": [
        {
            "event_id": "fixture-calendar-standup",
            "title": "OpenPhone Standup",
            "calendar_title": "Engineering",
            "location": "Room 101",
            "notes": "Discuss iOS agent progress and provider validation.",
            "start_at_ms": 1893456000000,
            "end_at_ms": 1893457800000,
            "all_day": False,
        },
        {
            "event_id": "fixture-calendar-review",
            "title": "Roadmap Review",
            "calendar_title": "Product",
            "start_at_ms": 1893542400000,
            "end_at_ms": 1893546000000,
        },
    ],
}
pathlib.Path(sys.argv[1]).write_text(json.dumps(fixture), encoding="utf-8")
PY
python3 - <<'PY' "$work/store/config/calls-fixture.json"
import json
import pathlib
import sys

fixture = {
    "schema": "openphone.calls_fixture.v1",
    "calls": [
        {
            "call_id": "fixture-call-openphone",
            "address": "+15550101234",
            "display_name": "OpenPhone Test Call",
            "service": "Phone",
            "direction": "incoming",
            "answered": True,
            "duration_seconds": 120,
            "start_at_ms": 1893459600000,
            "call_type": "phone",
        },
        {
            "call_id": "fixture-call-facetime",
            "address": "facetime@example.test",
            "display_name": "FaceTime Fixture",
            "service": "FaceTime",
            "direction": "outgoing",
            "answered": False,
            "duration_seconds": 0,
            "start_at_ms": 1893546000000,
            "call_type": "facetime",
        },
    ],
}
pathlib.Path(sys.argv[1]).write_text(json.dumps(fixture), encoding="utf-8")
PY
python3 - <<'PY' "$work/store/config/messages-fixture.json"
import json
import pathlib
import sys

fixture = {
    "schema": "openphone.messages_fixture.v1",
    "messages": [
        {
            "message_id": "fixture-message-openphone",
            "guid": "fixture-message-openphone-guid",
            "handle": "+15550105555",
            "service": "iMessage",
            "direction": "incoming",
            "text": "OpenPhone message fixture says hello from local smoke.",
            "subject": "",
            "sent_at_ms": 1893463200000,
            "read": True,
            "delivered": True,
        },
        {
            "message_id": "fixture-message-roadmap",
            "handle": "roadmap@example.test",
            "service": "SMS",
            "direction": "outgoing",
            "text": "Roadmap fixture message for provider validation.",
            "sent_at_ms": 1893549600000,
        },
    ],
}
pathlib.Path(sys.argv[1]).write_text(json.dumps(fixture), encoding="utf-8")
PY

OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentd" \
  >"$work/stdout.log" 2>"$work/stderr.log" &
pid=$!

sleep 1

OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  >"$work/health.json"
mkdir -p "$work/store/springboard"
python3 - <<'PY' "$work/store/springboard/state.json"
import json
import pathlib
import sys
import time

path = pathlib.Path(sys.argv[1])
path.write_text(json.dumps({
    "schema": "openphone.springboard_state.v1",
    "timestamp_ms": int(time.time() * 1000),
    "provider": "OpenPhoneVolumeTrigger.SpringBoardState",
    "foreground_app": "com.apple.mobilesafari",
    "foreground_source": "smoke_fixture",
    "active_scene_count": 1,
    "scene_count": 1,
    "scenes": [{
        "provider": "smoke_fixture",
        "bundle_id": "com.apple.mobilesafari",
        "identifier": "sceneID:com.apple.mobilesafari-default",
        "isForegroundActive": True
    }],
    "display": {
        "orientation": 1,
        "orientation_name": "portrait"
    },
    "ui_tree": {
        "status": "ok",
        "provider": "SpringBoard.UIKitAccessibility",
        "scope": "springboard_only",
        "window_count": 1,
        "element_count": 1,
        "text_count": 1,
        "visible_text": ["Safari"],
        "interactive_elements": [{
            "id": "springboard-0-0",
            "kind": "button",
            "label": "Safari",
            "bounds": [12, 34, 56, 78],
            "enabled": True,
            "focused": False,
            "window_id": 0,
            "sensitive": False,
            "risk_hint": "springboard_only"
        }],
        "windows": [{
            "id": 0,
            "type": 0,
            "focused": True,
            "active": True,
            "bounds": [0, 0, 430, 932]
        }]
    },
    "source": "smoke"
}))
PY
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  get_screen >"$work/get_screen_springboard_state.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  tap_element springboard-0-0 >"$work/tap_element.json"
app_ui_publish_request="$(python3 - <<'PY'
import json, time
state = {
    "schema": "openphone.app_ui_state.v1",
    "status": "ok",
    "provider": "OpenPhoneAppIntrospector.UIKitAccessibility",
    "bundle_id": "com.apple.mobilesafari",
    "process_name": "MobileSafari",
    "pid": 4242,
    "timestamp_ms": int(time.time() * 1000),
    "application_state": 0,
    "application_state_name": "active",
    "ui_tree": {
        "status": "ok",
        "provider": "OpenPhoneAppIntrospector.UIKitAccessibility",
        "scope": "app_process",
        "bundle_id": "com.apple.mobilesafari",
        "window_count": 1,
        "element_count": 2,
        "text_count": 2,
        "visible_text": ["Example Domain", "Address"],
        "interactive_elements": [{
            "id": "app-com.apple.mobilesafari-0-0",
            "kind": "text_field",
            "label": "Address",
            "bounds": [16, 50, 300, 42],
            "enabled": True,
            "focused": False,
            "window_id": 0,
            "source_bundle_id": "com.apple.mobilesafari",
            "scope": "app_process",
            "sensitive": False,
            "risk_hint": "app_process"
        }, {
            "id": "app-com.apple.mobilesafari-0-1",
            "kind": "button",
            "label": "Share",
            "bounds": [360, 50, 44, 42],
            "enabled": True,
            "focused": False,
            "window_id": 0,
            "source_bundle_id": "com.apple.mobilesafari",
            "scope": "app_process",
            "sensitive": False,
            "risk_hint": "app_process"
        }],
        "windows": [{
            "id": 0,
            "type": 0,
            "focused": True,
            "active": True,
            "bounds": [0, 0, 430, 932]
        }]
    },
    "source": "smoke"
}
print(json.dumps({
    "command": "app_ui_publish",
    "transport": "local_smoke_agentctl",
    "state": state
}))
PY
)"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  "$app_ui_publish_request" >"$work/app_ui_publish.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  get_screen >"$work/get_screen_app_ui_state.json"
python3 - <<'PY' "$work" >"$work/app_input_type_text_bridge.log" 2>&1 &
import json
import pathlib
import socket
import sys
import time

work = pathlib.Path(sys.argv[1])
text = "SmokeText"

def intake_request(payload):
    encoded = json.dumps(payload).encode("utf-8") + b"\n"
    with socket.create_connection(("127.0.0.1", 27631), timeout=2) as sock:
        sock.sendall(encoded)
        sock.shutdown(socket.SHUT_WR)
        chunks = []
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                break
            chunks.append(chunk)
            if b"\n" in chunk:
                break
    return json.loads(b"".join(chunks).decode("utf-8"))

request = None
deadline = time.time() + 8
while time.time() < deadline:
    poll = intake_request({
        "command": "app_input_poll",
        "bundle_id": "com.apple.mobilesafari",
        "scope": "app_process",
    })
    if poll.get("status") == "ok":
        request = poll["request"]
        break
    time.sleep(0.05)

if request is None:
    raise SystemExit("timed out waiting for app input request")

response = {
    "status": "ok",
    "provider": "OpenPhoneAppIntrospector.AppInput",
    "source": "app_process",
    "action_type": "type_text",
    "activation_method": "text_input_insert",
    "target_class": "UISearchBarTextField",
    "text_length": len(text),
    "before_text_length": 0,
    "after_text_length": len(text),
}
complete = intake_request({
    "command": "app_input_complete",
    "request_id": request["request_id"],
    "bundle_id": "com.apple.mobilesafari",
    "response": response,
})
if complete.get("status") != "ok":
    raise SystemExit(f"app input complete failed: {complete}")
PY
app_input_bridge_pid=$!
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  '{"command":"execute_action","action":{"type":"type_text","element_id":"app-com.apple.mobilesafari-0-0","text":"SmokeText","reason":"local smoke app-process verified text input"}}' \
  >"$work/app_input_type_text.json"
wait "$app_input_bridge_pid"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  memory_save "user prefers concise OpenPhone status updates" preference user >"$work/memory_save.json"
memory_id="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["memory"]["memory_id"])' "$work/memory_save.json")"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  memory_update "$memory_id" "user prefers concise OpenPhone validation details" preference user \
  >"$work/memory_update.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  memory_save "user prefers terse OpenPhone summaries" preference user >"$work/memory_save_merge_source.json"
merge_source_id="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["memory"]["memory_id"])' "$work/memory_save_merge_source.json")"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  memory_merge "$memory_id" "$merge_source_id" "user prefers concise OpenPhone validation details and terse summaries" \
  >"$work/memory_merge.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  memory_save "temporary OpenPhone memory delete fixture" fact user >"$work/memory_save_delete_fixture.json"
delete_memory_id="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["memory"]["memory_id"])' "$work/memory_save_delete_fixture.json")"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  memory_delete "$delete_memory_id" "agentctl memory_delete smoke cleanup" >"$work/memory_delete.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  '{"command":"clipboard_write","text":"OpenPhone clipboard smoke value","reason":"local smoke clipboard write"}' \
  >"$work/clipboard_write.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  '{"command":"clipboard_read","max_chars":200,"reason":"local smoke clipboard read"}' \
  >"$work/clipboard_read.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  '{"command":"contacts_search","query":"Ada","limit":5,"reason":"local smoke contacts search"}' \
  >"$work/contacts_search.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  '{"command":"calendar_search","query":"Standup","limit":5,"reason":"local smoke calendar search"}' \
  >"$work/calendar_search.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  '{"command":"calls_search","query":"OpenPhone","limit":5,"reason":"local smoke call-history search"}' \
  >"$work/calls_search.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  '{"command":"messages_search","query":"OpenPhone","limit":5,"reason":"local smoke messages search"}' \
  >"$work/messages_search.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  "$(python3 - <<'PY'
import json
# Over-length title/body carrying a unique marker whose *tail* must never be
# retained verbatim, proving the notification provider only keeps bounded
# previews (title<=200, body<=1000) and no full payload leaks to any store.
tail_marker = "NOTIFYPIItail_+15559998888_leak@example.test"
title = "OpenPhone Notification " + ("A" * 250) + tail_marker
body = "OpenPhone body preview head. " + ("B" * 1200) + tail_marker
print(json.dumps({
    "command": "notification_ingest",
    "bundle_id": "com.openphone.smoke",
    "title": title,
    "subtitle": "smoke subtitle",
    "body": body,
    "notification_id": "smoke-notif-1",
    "thread_id": "smoke-thread-1",
}))
PY
)" >"$work/notification_ingest.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  '{"command":"notification_list","limit":10}' >"$work/notification_list.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  context_search notification 5 >"$work/context_search_notification.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  memory_search terse 5 >"$work/memory_search.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  context_search concise 5 >"$work/context_search.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  context_search clipboard 5 >"$work/context_search_clipboard.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  context_search contacts 5 >"$work/context_search_contacts.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  context_search calendar 5 >"$work/context_search_calendar.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  context_search calls 5 >"$work/context_search_calls.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  context_search messages 5 >"$work/context_search_messages.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  commitment_create "follow up about OpenPhone iOS smoke" >"$work/commitment_create.json"
commitment_id="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["commitment_id"])' "$work/commitment_create.json")"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  commitment_search OpenPhone 5 >"$work/commitment_search.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  commitment_update_status "$commitment_id" completed >"$work/commitment_update_status.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  "$(python3 - <<'PY'
import json, time
print(json.dumps({
    "command": "commitment_create",
    "title": "due commitment smoke",
    "description": "summarize due commitment smoke",
    "trigger_type": "time",
    "trigger_spec": {
        "prompt": "summarize due commitment smoke",
        "delivery": {"mode": "notification"}
    },
    "due_at": int(time.time() * 1000) - 1000,
    "reason": "local smoke due commitment"
}))
PY
)" >"$work/commitment_due_create.json"
commitment_due_id="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["commitment_id"])' "$work/commitment_due_create.json")"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  '{"command":"commitment_run_due","limit":5,"source":"local_smoke_commitment_scheduler"}' \
  >"$work/commitment_run_due.json"
commitment_due_job_id="$(python3 - <<'PY' "$work/commitment_run_due.json" "$commitment_due_id"
import json, sys
data = json.load(open(sys.argv[1]))
target = f"ios-commitment-{sys.argv[2]}"
for entry in data.get("commitments", []):
    if entry.get("commitment_id") == target:
        print(entry["job_id"])
        break
else:
    raise SystemExit(f"commitment job not found for {target}: {data}")
PY
)"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  "{\"command\":\"background_job_run_due\",\"job_id\":\"$commitment_due_job_id\",\"limit\":1,\"max_steps\":1,\"max_duration_ms\":15000,\"mode\":\"deterministic\",\"source\":\"local_smoke_commitment_scheduler_job\",\"materialize_commitments\":false,\"materialize_watchers\":false,\"repair_stuck\":false}" \
  >"$work/commitment_due_job_run.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  commitment_search "due commitment smoke" 5 >"$work/commitment_due_after.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  "$(python3 - <<'PY'
import json, time
print(json.dumps({
    "command": "watcher_create",
    "title": "watch smoke condition",
    "source": "time",
    "type": "time",
    "next_run_at": int(time.time() * 1000) - 1000,
    "prompt": "summarize watcher smoke condition",
    "reason": "agentctl watcher scheduler smoke"
}))
PY
)" >"$work/watcher_create.json"
watcher_id="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["watcher_id"])' "$work/watcher_create.json")"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  watcher_list smoke 5 >"$work/watcher_list.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  '{"command":"watcher_run_due","limit":5,"source":"local_smoke"}' >"$work/watcher_materialize_due.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  background_job_run_due 5 1 15000 >"$work/watcher_run_due.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  watcher_list smoke 5 >"$work/watcher_after_run.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  watcher_stop "$watcher_id" >"$work/watcher_stop.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  "$(python3 - <<'PY'
import json, time
print(json.dumps({
    "command": "watcher_create",
    "title": "recurring watcher smoke",
    "source": "time",
    "type": "time",
    "next_run_at": int(time.time() * 1000) - 1000,
    "interval_ms": 5,
    "recurring": True,
    "prompt": "summarize recurring watcher smoke",
    "reason": "local smoke recurring watcher"
}))
PY
)" >"$work/watcher_recurring_create.json"
recurring_watcher_id="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["watcher_id"])' "$work/watcher_recurring_create.json")"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  '{"command":"watcher_run_due","limit":5,"source":"local_smoke_recurring_watcher_first"}' \
  >"$work/watcher_recurring_first.json"
sleep 0.05
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  '{"command":"watcher_run_due","limit":5,"source":"local_smoke_recurring_watcher_second"}' \
  >"$work/watcher_recurring_second.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  watcher_list "recurring watcher smoke" 5 >"$work/watcher_recurring_after.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  watcher_stop "$recurring_watcher_id" >"$work/watcher_recurring_stop.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  "$(python3 - <<'PY'
import json, time
print(json.dumps({
    "command": "watcher_create",
    "title": "watcher stuck repair smoke",
    "source": "time",
    "type": "time",
    "next_run_at": int(time.time() * 1000) + 600000,
    "prompt": "summarize watcher stuck repair fixture",
    "reason": "local smoke watcher stuck repair fixture"
}))
PY
)" >"$work/watcher_repair_create.json"
repair_watcher_id="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["watcher_id"])' "$work/watcher_repair_create.json")"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  "{\"command\":\"watcher_debug_mark_running\",\"watcher_id\":$repair_watcher_id,\"validation\":true,\"age_ms\":600000,\"source\":\"local_smoke_watcher_stuck_repair\"}" \
  >"$work/watcher_debug_mark_running.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  '{"command":"watcher_repair_stuck","limit":5,"stale_after_ms":1000,"source":"local_smoke_watcher_stuck_repair"}' \
  >"$work/watcher_repair_stuck.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  '{"command":"watcher_run_due","limit":5,"source":"local_smoke_watcher_repair"}' \
  >"$work/watcher_repair_run_due.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  watcher_list "watcher stuck repair smoke" 5 >"$work/watcher_repair_after_run.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  watcher_stop "$repair_watcher_id" >"$work/watcher_repair_stop.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  background_job_create "smoke background job" "summarize durable stores" >"$work/background_job_create.json"
job_id="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["job_id"])' "$work/background_job_create.json")"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  background_job_run_due 5 1 15000 >"$work/background_job_run_due.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  background_job_list durable 5 >"$work/background_job_list.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  background_job_stop "$job_id" >"$work/background_job_stop.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  "$(python3 - <<'PY'
import json, time
print(json.dumps({
    "command": "background_job_create",
    "title": "recurring background job",
    "prompt": "summarize recurring background job",
    "next_run_at": int(time.time() * 1000) - 1000,
    "interval_ms": 50,
    "recurring": True,
    "reason": "local smoke recurring background job"
}))
PY
)" >"$work/background_job_recurring_create.json"
recurring_job_id="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["job_id"])' "$work/background_job_recurring_create.json")"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  "{\"command\":\"background_job_run_due\",\"job_id\":$recurring_job_id,\"limit\":1,\"max_steps\":1,\"max_duration_ms\":15000,\"mode\":\"deterministic\",\"source\":\"local_smoke_recurring_job\"}" \
  >"$work/background_job_recurring_run_due.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  background_job_list "recurring background job" 5 >"$work/background_job_recurring_list.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  background_job_stop "$recurring_job_id" >"$work/background_job_recurring_stop.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  "$(python3 - <<'PY'
import json, time
print(json.dumps({
    "command": "background_job_create",
    "title": "nonrecurring interval background job",
    "prompt": "summarize nonrecurring interval background job",
    "next_run_at": int(time.time() * 1000) - 1000,
    "interval_ms": 50,
    "recurring": False,
    "reason": "local smoke nonrecurring interval background job"
}))
PY
)" >"$work/background_job_nonrecurring_interval_create.json"
nonrecurring_interval_job_id="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["job_id"])' "$work/background_job_nonrecurring_interval_create.json")"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  "{\"command\":\"background_job_run_due\",\"job_id\":$nonrecurring_interval_job_id,\"limit\":1,\"max_steps\":1,\"max_duration_ms\":15000,\"mode\":\"deterministic\",\"source\":\"local_smoke_nonrecurring_interval_job\"}" \
  >"$work/background_job_nonrecurring_interval_run_due.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  background_job_list "nonrecurring interval background job" 5 >"$work/background_job_nonrecurring_interval_list.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  "$(python3 - <<'PY'
import json, time
print(json.dumps({
    "command": "background_job_create",
    "title": "recurring backoff background job",
    "prompt": "model provider should be unavailable for this smoke job",
    "next_run_at": int(time.time() * 1000) - 1000,
    "interval_ms": 50,
    "recurring": True,
    "reason": "local smoke recurring background job backoff"
}))
PY
)" >"$work/background_job_backoff_create.json"
backoff_job_id="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["job_id"])' "$work/background_job_backoff_create.json")"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  "{\"command\":\"background_job_run_due\",\"job_id\":$backoff_job_id,\"limit\":1,\"max_steps\":1,\"max_duration_ms\":15000,\"mode\":\"model\",\"source\":\"local_smoke_recurring_job_backoff\"}" \
  >"$work/background_job_backoff_run_due.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  background_job_list "recurring backoff background job" 5 >"$work/background_job_backoff_list.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  background_job_stop "$backoff_job_id" >"$work/background_job_backoff_stop.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  "$(python3 - <<'PY'
import json, time
print(json.dumps({
    "command": "background_job_create",
    "title": "stuck repair background job",
    "prompt": "summarize stuck repair fixture",
    "next_run_at": int(time.time() * 1000) + 600000,
    "reason": "local smoke stuck repair fixture"
}))
PY
)" >"$work/background_job_repair_create.json"
repair_job_id="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["job_id"])' "$work/background_job_repair_create.json")"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  "{\"command\":\"background_job_debug_mark_running\",\"job_id\":$repair_job_id,\"validation\":true,\"age_ms\":600000,\"source\":\"local_smoke_stuck_repair\"}" \
  >"$work/background_job_debug_mark_running.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  '{"command":"background_job_repair_stuck","limit":5,"stale_after_ms":1000,"source":"local_smoke_stuck_repair"}' \
  >"$work/background_job_repair_stuck.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  background_job_run_due 5 1 15000 >"$work/background_job_repair_run_due.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  background_job_list "stuck repair" 10 >"$work/background_job_repair_list.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  background_job_stop "$repair_job_id" >"$work/background_job_repair_stop.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  agent_status >"$work/agent_status_initial.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  agent_control pause "local smoke pause" >"$work/agent_control_pause.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  agent_status >"$work/agent_status_paused.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  '{"command":"hardware_trigger","trigger":"volume_up_down_combo","source":"local_smoke","reason":"local smoke paused hardware trigger","run_task":true,"create_background_job":false,"dedupe":false}' \
  >"$work/hardware_trigger_paused.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  agent_control resume >"$work/agent_control_resume.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  agent_status >"$work/agent_status_resumed.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  '{"command":"agent_control","hardware_triggers_enabled":false,"reason":"local smoke disable hardware triggers","source":"local_smoke"}' \
  >"$work/agent_control_disable_hardware.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  '{"command":"hardware_trigger","trigger":"volume_up_down_combo","source":"local_smoke","reason":"local smoke disabled hardware trigger","run_task":true,"create_background_job":false,"dedupe":false}' \
  >"$work/hardware_trigger_disabled.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  '{"command":"agent_control","hardware_triggers_enabled":true,"reason":"local smoke re-enable hardware triggers","source":"local_smoke"}' \
  >"$work/agent_control_enable_hardware.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  '{"command":"agent_control","yolo_enabled":false,"reason":"local smoke disable yolo","source":"local_smoke"}' \
  >"$work/agent_control_disable_yolo.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  '{"command":"hardware_trigger","trigger":"volume_up_down_combo","source":"local_smoke","reason":"local smoke yolo-disabled hardware trigger","run_task":true,"create_background_job":false,"dedupe":false}' \
  >"$work/hardware_trigger_yolo_disabled.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  '{"command":"agent_control","yolo_enabled":true,"reason":"local smoke re-enable yolo","source":"local_smoke"}' \
  >"$work/agent_control_enable_yolo.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  hardware_trigger volume_up_down_combo "local smoke hardware trigger" >"$work/hardware_trigger.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  '{"command":"execute_action","task_id":"smoke-redaction-task","action":{"type":"unlock_with_passcode","passcode":"000000"}}' \
  >"$work/unlock_with_passcode.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  run_task "open Safari" >"$work/run_task.json"
task_id="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["task_id"])' "$work/run_task.json")"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  model_status >"$work/model_status.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  '{"command":"run_task","goal":"fixture model smoke","mode":"model","max_steps":3,"max_duration_ms":30000,"model_decisions":[{"schema":"openphone.model_decision.v1","thought":"pause before finishing","tool":"wait","arguments":{"duration_ms":10},"expected_visible_change":"none","confidence":0.9},{"schema":"openphone.model_decision.v1","thought":"fixture task is complete","tool":"finish_task","arguments":{"summary":"Fixture model loop completed."},"expected_visible_change":"none","confidence":0.95}]}' \
  >"$work/run_task_model.json"
model_task_id="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["task_id"])' "$work/run_task_model.json")"
fresh_app_ui_publish_request="$(APP_UI_PUBLISH_REQUEST="$app_ui_publish_request" python3 - <<'PY'
import json
import os
import time

payload = json.loads(os.environ["APP_UI_PUBLISH_REQUEST"])
payload["state"]["timestamp_ms"] = int(time.time() * 1000)
print(json.dumps(payload))
PY
)"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  "$fresh_app_ui_publish_request" >"$work/app_ui_publish_model_refresh.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  '{"command":"run_task","goal":"fixture model unverified tap smoke","mode":"model","max_steps":3,"max_duration_ms":30000,"model_decisions":[{"schema":"openphone.model_decision.v1","thought":"tap existing synthetic app element without changing state","tool":"tap_element","arguments":{"element_id":"app-com.apple.mobilesafari-0-0"},"expected_visible_change":"Safari address field is focused","confidence":0.8},{"schema":"openphone.model_decision.v1","thought":"finish after unverified dispatch sample","tool":"finish_task","arguments":{"summary":"Unverified dispatch sample completed."},"expected_visible_change":"none","confidence":0.95}]}' \
  >"$work/run_task_model_unverified.json"
model_unverified_task_id="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["task_id"])' "$work/run_task_model_unverified.json")"
python3 - <<'PY' "$work/store" >"$work/model-visible-mutator.log" 2>&1 &
import json
import pathlib
import socket
import sys
import time

store = pathlib.Path(sys.argv[1])
springboard_path = store / "springboard" / "state.json"
time.sleep(0.25)
springboard_path.write_text(json.dumps({
    "schema": "openphone.springboard_state.v1",
    "timestamp_ms": int(time.time() * 1000),
    "provider": "OpenPhoneVolumeTrigger.SpringBoardState",
    "foreground_app": "com.apple.mobilesafari",
    "foreground_source": "smoke_fixture_after_action",
    "active_scene_count": 1,
    "scene_count": 1,
    "scenes": [{
        "provider": "smoke_fixture_after_action",
        "bundle_id": "com.apple.mobilesafari",
        "identifier": "sceneID:com.apple.mobilesafari-default",
        "isForegroundActive": True
    }],
    "display": {
        "orientation": 1,
        "orientation_name": "portrait"
    },
    "ui_tree": {
        "status": "ok",
        "provider": "SpringBoard.UIKitAccessibility",
        "scope": "springboard_only",
        "window_count": 1,
        "element_count": 2,
        "text_count": 2,
        "visible_text": ["Safari", "Visible verifier changed"],
        "interactive_elements": [{
            "id": "springboard-0-0",
            "kind": "button",
            "label": "Safari",
            "bounds": [12, 34, 56, 78],
            "enabled": True,
            "focused": False,
            "window_id": 0,
            "sensitive": False,
            "risk_hint": "springboard_only"
        }, {
            "id": "springboard-0-1",
            "kind": "button",
            "label": "Changed",
            "bounds": [82, 34, 56, 78],
            "enabled": True,
            "focused": False,
            "window_id": 0,
            "sensitive": False,
            "risk_hint": "springboard_only"
        }],
        "windows": [{
            "id": 0,
            "type": 0,
            "focused": True,
            "active": True,
            "bounds": [0, 0, 430, 932]
        }]
    },
    "source": "smoke"
}), encoding="utf-8")
state = {
    "schema": "openphone.app_ui_state.v1",
    "status": "ok",
    "provider": "OpenPhoneAppIntrospector.UIKitAccessibility",
    "bundle_id": "com.apple.mobilesafari",
    "process_name": "MobileSafari",
    "pid": 4242,
    "timestamp_ms": int(time.time() * 1000),
    "application_state": 0,
    "application_state_name": "active",
    "ui_tree": {
        "status": "ok",
        "provider": "OpenPhoneAppIntrospector.UIKitAccessibility",
        "scope": "app_process",
        "bundle_id": "com.apple.mobilesafari",
        "window_count": 1,
        "element_count": 2,
        "text_count": 2,
        "visible_text": ["Example Domain", "Visible verifier changed"],
        "interactive_elements": [{
            "id": "app-com.apple.mobilesafari-0-0",
            "kind": "text_field",
            "label": "Address focused",
            "bounds": [16, 50, 300, 42],
            "enabled": True,
            "focused": True,
            "window_id": 0,
            "source_bundle_id": "com.apple.mobilesafari",
            "scope": "app_process",
            "sensitive": False,
            "risk_hint": "app_process"
        }, {
            "id": "app-com.apple.mobilesafari-0-1",
            "kind": "button",
            "label": "Done",
            "bounds": [360, 50, 44, 42],
            "enabled": True,
            "focused": False,
            "window_id": 0,
            "source_bundle_id": "com.apple.mobilesafari",
            "scope": "app_process",
            "sensitive": False,
            "risk_hint": "app_process"
        }],
        "windows": [{
            "id": 0,
            "type": 0,
            "focused": True,
            "active": True,
            "bounds": [0, 0, 430, 932]
        }]
    },
    "source": "smoke"
}
payload = json.dumps({
    "command": "app_ui_publish",
    "transport": "local_smoke_tcp",
    "state": state
}).encode("utf-8") + b"\n"
with socket.create_connection(("127.0.0.1", 27631), timeout=2) as sock:
    sock.sendall(payload)
    response = sock.recv(4096)
    print(response.decode("utf-8", errors="replace"))
PY
visible_mutator_pid=$!
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  '{"command":"run_task","goal":"fixture model visible verifier smoke","mode":"model","max_steps":3,"max_duration_ms":30000,"model_decisions":[{"schema":"openphone.model_decision.v1","thought":"long press while synthetic screen changes","tool":"long_press","arguments":{"x":40,"y":73,"duration_ms":900},"expected_visible_change":"visible text changes to include Visible verifier changed","confidence":0.9},{"schema":"openphone.model_decision.v1","thought":"finish after verified visible change","tool":"finish_task","arguments":{"summary":"Visible verifier model loop completed."},"expected_visible_change":"none","confidence":0.95}]}' \
  >"$work/run_task_model_visible.json"
wait "$visible_mutator_pid"
model_visible_task_id="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["task_id"])' "$work/run_task_model_visible.json")"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  '{"command":"start_task","goal":"cancelled model smoke"}' \
  >"$work/start_task_model_cancel.json"
model_cancel_task_id="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["task_id"])' "$work/start_task_model_cancel.json")"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  stop_task "$model_cancel_task_id" "local smoke cancellation" \
  >"$work/stop_task_model_cancel.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  "{\"command\":\"run_task\",\"task_id\":\"$model_cancel_task_id\",\"goal\":\"cancelled model smoke\",\"mode\":\"model\",\"max_steps\":3,\"max_duration_ms\":30000,\"model_decisions\":[{\"schema\":\"openphone.model_decision.v1\",\"thought\":\"should not execute after cancellation\",\"tool\":\"finish_task\",\"arguments\":{\"summary\":\"Should not finish.\"},\"expected_visible_change\":\"none\",\"confidence\":0.95}]}" \
  >"$work/run_task_model_cancelled.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  '{"command":"start_task","goal":"stale active task repair smoke"}' \
  >"$work/start_task_stale_repair.json"
stale_repair_task_id="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["task_id"])' "$work/start_task_stale_repair.json")"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  '{"command":"task_repair_stale_active","limit":5,"stale_after_ms":0,"source":"local_smoke_task_repair","reason":"local smoke stale active task repair"}' \
  >"$work/task_repair_stale_active.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  get_task "$stale_repair_task_id" >"$work/get_task_stale_repaired.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  get_trajectory "$stale_repair_task_id" 50 >"$work/get_task_stale_repaired_trajectory.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  '{"command":"run_task","goal":"fixture model parser repair smoke","mode":"model","max_steps":2,"max_duration_ms":30000,"model_decisions":["Here is the decision:\n```json\n{\"schema\":\"openphone.model_decision.v1\",\"thought\":\"wrapped finish\",\"tool\":\"finish_task\",\"arguments\":{\"summary\":\"Parser repair model loop completed.\"},\"expected_visible_change\":\"none\",\"confidence\":0.96}\n```\n"]}' \
  >"$work/run_task_model_repaired.json"
model_repaired_task_id="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["task_id"])' "$work/run_task_model_repaired.json")"
broker_endpoint="http://127.0.0.1:${broker_port}/decision"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  "{\"command\":\"model_configure\",\"mode\":\"broker\",\"endpoint_url\":\"$broker_endpoint\",\"model\":\"local-smoke-broker\",\"enabled\":true,\"credential_required\":false,\"timeout_ms\":30000,\"max_steps\":3,\"max_duration_ms\":30000,\"reason\":\"local smoke broker fixture\"}" \
  >"$work/model_configure.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  model_status >"$work/model_status_configured.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  '{"command":"run_task","goal":"broker model smoke","mode":"model","max_steps":3,"max_duration_ms":30000}' \
  >"$work/run_task_model_broker.json"
broker_model_task_id="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["task_id"])' "$work/run_task_model_broker.json")"
mkdir -p "$work/store/config"
printf '{"credential":"local-smoke-openai-realtime-value"}\n' >"$work/store/config/model-credential.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  '{"command":"model_configure","mode":"openai_realtime2","enabled":true,"credential_required":true,"max_steps":40,"max_duration_ms":600000,"reason":"local smoke realtime2 config"}' \
  >"$work/model_configure_realtime2.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  model_status >"$work/model_status_realtime2.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  list_tasks 10 >"$work/list_tasks.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  get_task "$task_id" >"$work/get_task.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  get_trajectory "$task_id" 20 >"$work/get_trajectory.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  get_trajectory "$model_task_id" 50 >"$work/get_model_trajectory.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  get_trajectory "$model_unverified_task_id" 50 >"$work/get_model_unverified_trajectory.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  get_trajectory "$model_visible_task_id" 50 >"$work/get_model_visible_trajectory.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  get_trajectory "$model_cancel_task_id" 50 >"$work/get_model_cancel_trajectory.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  get_trajectory "$model_repaired_task_id" 50 >"$work/get_model_repaired_trajectory.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  get_trajectory "$broker_model_task_id" 80 >"$work/get_model_broker_trajectory.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  get_trajectory smoke-redaction-task 20 >"$work/get_redaction_trajectory.json"
OPENPHONE_AGENTD_STORE="$work/store" "$work/openphone-agentctl" \
  get_audit 100 >"$work/get_audit.json"
"$repo_root/tools/mac/agentd/validate-agentd-store.py" \
  "$work/store" --require-task-artifacts >"$work/validate_store.json"

OPENPHONE_AGENTD_SMOKE_DIR="$work" python3 - <<'PY'
import json
import os
import pathlib

base = pathlib.Path(os.environ['OPENPHONE_AGENTD_SMOKE_DIR'])
health = json.loads(base.joinpath('health.json').read_text())
get_screen_springboard = json.loads(base.joinpath('get_screen_springboard_state.json').read_text())
app_ui_publish = json.loads(base.joinpath('app_ui_publish.json').read_text())
get_screen_app_ui = json.loads(base.joinpath('get_screen_app_ui_state.json').read_text())
tap_element = json.loads(base.joinpath('tap_element.json').read_text())
app_input_type_text = json.loads(base.joinpath('app_input_type_text.json').read_text())
memory_save = json.loads(base.joinpath('memory_save.json').read_text())
memory_update = json.loads(base.joinpath('memory_update.json').read_text())
memory_save_merge_source = json.loads(base.joinpath('memory_save_merge_source.json').read_text())
memory_merge = json.loads(base.joinpath('memory_merge.json').read_text())
memory_save_delete_fixture = json.loads(base.joinpath('memory_save_delete_fixture.json').read_text())
memory_delete = json.loads(base.joinpath('memory_delete.json').read_text())
memory_search = json.loads(base.joinpath('memory_search.json').read_text())
context_search = json.loads(base.joinpath('context_search.json').read_text())
clipboard_write = json.loads(base.joinpath('clipboard_write.json').read_text())
clipboard_read = json.loads(base.joinpath('clipboard_read.json').read_text())
context_search_clipboard = json.loads(base.joinpath('context_search_clipboard.json').read_text())
contacts_search = json.loads(base.joinpath('contacts_search.json').read_text())
context_search_contacts = json.loads(base.joinpath('context_search_contacts.json').read_text())
calendar_search = json.loads(base.joinpath('calendar_search.json').read_text())
context_search_calendar = json.loads(base.joinpath('context_search_calendar.json').read_text())
calls_search = json.loads(base.joinpath('calls_search.json').read_text())
context_search_calls = json.loads(base.joinpath('context_search_calls.json').read_text())
messages_search = json.loads(base.joinpath('messages_search.json').read_text())
context_search_messages = json.loads(base.joinpath('context_search_messages.json').read_text())
notification_ingest = json.loads(base.joinpath('notification_ingest.json').read_text())
notification_list = json.loads(base.joinpath('notification_list.json').read_text())
context_search_notification = json.loads(base.joinpath('context_search_notification.json').read_text())
commitment_create = json.loads(base.joinpath('commitment_create.json').read_text())
commitment_search = json.loads(base.joinpath('commitment_search.json').read_text())
commitment_update = json.loads(base.joinpath('commitment_update_status.json').read_text())
commitment_due_create = json.loads(base.joinpath('commitment_due_create.json').read_text())
commitment_run_due = json.loads(base.joinpath('commitment_run_due.json').read_text())
commitment_due_job_run = json.loads(base.joinpath('commitment_due_job_run.json').read_text())
commitment_due_after = json.loads(base.joinpath('commitment_due_after.json').read_text())
watcher_create = json.loads(base.joinpath('watcher_create.json').read_text())
watcher_list = json.loads(base.joinpath('watcher_list.json').read_text())
watcher_materialize_due = json.loads(base.joinpath('watcher_materialize_due.json').read_text())
watcher_run_due = json.loads(base.joinpath('watcher_run_due.json').read_text())
watcher_after_run = json.loads(base.joinpath('watcher_after_run.json').read_text())
watcher_stop = json.loads(base.joinpath('watcher_stop.json').read_text())
watcher_repair_create = json.loads(base.joinpath('watcher_repair_create.json').read_text())
watcher_debug_mark_running = json.loads(base.joinpath('watcher_debug_mark_running.json').read_text())
watcher_repair_stuck = json.loads(base.joinpath('watcher_repair_stuck.json').read_text())
watcher_repair_run_due = json.loads(base.joinpath('watcher_repair_run_due.json').read_text())
watcher_repair_after_run = json.loads(base.joinpath('watcher_repair_after_run.json').read_text())
watcher_repair_stop = json.loads(base.joinpath('watcher_repair_stop.json').read_text())
watcher_recurring_create = json.loads(base.joinpath('watcher_recurring_create.json').read_text())
watcher_recurring_first = json.loads(base.joinpath('watcher_recurring_first.json').read_text())
watcher_recurring_second = json.loads(base.joinpath('watcher_recurring_second.json').read_text())
watcher_recurring_after = json.loads(base.joinpath('watcher_recurring_after.json').read_text())
watcher_recurring_stop = json.loads(base.joinpath('watcher_recurring_stop.json').read_text())
background_job_create = json.loads(base.joinpath('background_job_create.json').read_text())
background_job_run_due = json.loads(base.joinpath('background_job_run_due.json').read_text())
background_job_list = json.loads(base.joinpath('background_job_list.json').read_text())
background_job_stop = json.loads(base.joinpath('background_job_stop.json').read_text())
background_job_recurring_create = json.loads(base.joinpath('background_job_recurring_create.json').read_text())
background_job_recurring_run_due = json.loads(base.joinpath('background_job_recurring_run_due.json').read_text())
background_job_recurring_list = json.loads(base.joinpath('background_job_recurring_list.json').read_text())
background_job_recurring_stop = json.loads(base.joinpath('background_job_recurring_stop.json').read_text())
background_job_nonrecurring_interval_create = json.loads(base.joinpath('background_job_nonrecurring_interval_create.json').read_text())
background_job_nonrecurring_interval_run_due = json.loads(base.joinpath('background_job_nonrecurring_interval_run_due.json').read_text())
background_job_nonrecurring_interval_list = json.loads(base.joinpath('background_job_nonrecurring_interval_list.json').read_text())
background_job_backoff_create = json.loads(base.joinpath('background_job_backoff_create.json').read_text())
background_job_backoff_run_due = json.loads(base.joinpath('background_job_backoff_run_due.json').read_text())
background_job_backoff_list = json.loads(base.joinpath('background_job_backoff_list.json').read_text())
background_job_backoff_stop = json.loads(base.joinpath('background_job_backoff_stop.json').read_text())
background_job_repair_create = json.loads(base.joinpath('background_job_repair_create.json').read_text())
background_job_debug_mark_running = json.loads(base.joinpath('background_job_debug_mark_running.json').read_text())
background_job_repair_stuck = json.loads(base.joinpath('background_job_repair_stuck.json').read_text())
background_job_repair_run_due = json.loads(base.joinpath('background_job_repair_run_due.json').read_text())
background_job_repair_list = json.loads(base.joinpath('background_job_repair_list.json').read_text())
background_job_repair_stop = json.loads(base.joinpath('background_job_repair_stop.json').read_text())
agent_status_initial = json.loads(base.joinpath('agent_status_initial.json').read_text())
agent_control_pause = json.loads(base.joinpath('agent_control_pause.json').read_text())
agent_status_paused = json.loads(base.joinpath('agent_status_paused.json').read_text())
hardware_trigger_paused = json.loads(base.joinpath('hardware_trigger_paused.json').read_text())
agent_control_resume = json.loads(base.joinpath('agent_control_resume.json').read_text())
agent_status_resumed = json.loads(base.joinpath('agent_status_resumed.json').read_text())
agent_control_disable_hardware = json.loads(base.joinpath('agent_control_disable_hardware.json').read_text())
hardware_trigger_disabled = json.loads(base.joinpath('hardware_trigger_disabled.json').read_text())
agent_control_enable_hardware = json.loads(base.joinpath('agent_control_enable_hardware.json').read_text())
agent_control_disable_yolo = json.loads(base.joinpath('agent_control_disable_yolo.json').read_text())
hardware_trigger_yolo_disabled = json.loads(base.joinpath('hardware_trigger_yolo_disabled.json').read_text())
agent_control_enable_yolo = json.loads(base.joinpath('agent_control_enable_yolo.json').read_text())
hardware_trigger = json.loads(base.joinpath('hardware_trigger.json').read_text())
unlock_with_passcode = json.loads(base.joinpath('unlock_with_passcode.json').read_text())
run = json.loads(base.joinpath('run_task.json').read_text())
model_status = json.loads(base.joinpath('model_status.json').read_text())
model_run = json.loads(base.joinpath('run_task_model.json').read_text())
model_unverified_run = json.loads(base.joinpath('run_task_model_unverified.json').read_text())
model_visible_run = json.loads(base.joinpath('run_task_model_visible.json').read_text())
start_model_cancel = json.loads(base.joinpath('start_task_model_cancel.json').read_text())
stop_model_cancel = json.loads(base.joinpath('stop_task_model_cancel.json').read_text())
model_cancel_run = json.loads(base.joinpath('run_task_model_cancelled.json').read_text())
start_stale_repair = json.loads(base.joinpath('start_task_stale_repair.json').read_text())
task_repair_stale_active = json.loads(base.joinpath('task_repair_stale_active.json').read_text())
get_task_stale_repaired = json.loads(base.joinpath('get_task_stale_repaired.json').read_text())
get_task_stale_repaired_trajectory = json.loads(base.joinpath('get_task_stale_repaired_trajectory.json').read_text())
model_repaired_run = json.loads(base.joinpath('run_task_model_repaired.json').read_text())
model_configure = json.loads(base.joinpath('model_configure.json').read_text())
model_status_configured = json.loads(base.joinpath('model_status_configured.json').read_text())
model_broker_run = json.loads(base.joinpath('run_task_model_broker.json').read_text())
model_configure_realtime2 = json.loads(base.joinpath('model_configure_realtime2.json').read_text())
model_status_realtime2 = json.loads(base.joinpath('model_status_realtime2.json').read_text())
list_tasks = json.loads(base.joinpath('list_tasks.json').read_text())
get_task = json.loads(base.joinpath('get_task.json').read_text())
get_trajectory = json.loads(base.joinpath('get_trajectory.json').read_text())
get_model_trajectory = json.loads(base.joinpath('get_model_trajectory.json').read_text())
get_model_unverified_trajectory = json.loads(base.joinpath('get_model_unverified_trajectory.json').read_text())
get_model_visible_trajectory = json.loads(base.joinpath('get_model_visible_trajectory.json').read_text())
get_model_cancel_trajectory = json.loads(base.joinpath('get_model_cancel_trajectory.json').read_text())
get_model_repaired_trajectory = json.loads(base.joinpath('get_model_repaired_trajectory.json').read_text())
get_model_broker_trajectory = json.loads(base.joinpath('get_model_broker_trajectory.json').read_text())
get_redaction_trajectory = json.loads(base.joinpath('get_redaction_trajectory.json').read_text())
get_audit = json.loads(base.joinpath('get_audit.json').read_text())
validate_store = json.loads(base.joinpath('validate_store.json').read_text())

def assert_no_sensitive_keys(value, path='root'):
    markers = (
        'password',
        'passcode',
        'token',
        'secret',
        'authorization',
        'api_key',
        'apikey',
        'private_key',
    )
    if isinstance(value, dict):
        for key, item in value.items():
            normalized = str(key).lower()
            assert not any(marker in normalized for marker in markers), f'sensitive key exported at {path}.{key}'
            assert_no_sensitive_keys(item, f'{path}.{key}')
    elif isinstance(value, list):
        for index, item in enumerate(value):
            assert_no_sensitive_keys(item, f'{path}[{index}]')

def assert_provider_attempt_shape(result, expected_user_facing_status):
    assert result['provider_attempts'], result
    assert result['verification']['status'] in ('verified', 'unverified', 'failed'), result
    assert result['verification']['source'], result
    assert result['verification']['reason'], result
    assert result['user_facing_status'] == expected_user_facing_status, result
    for index, attempt in enumerate(result['provider_attempts']):
        prefix = f'provider_attempts[{index}]'
        assert attempt['provider'], {prefix: attempt}
        assert attempt['scope'], {prefix: attempt}
        assert attempt['action_type'], {prefix: attempt}
        assert attempt['status'] in ('ok', 'unavailable', 'not_attempted'), {prefix: attempt}
        assert attempt['verification']['status'] in ('verified', 'unverified', 'failed'), {prefix: attempt}
        assert attempt['verification']['source'], {prefix: attempt}
        assert attempt['verification']['reason'], {prefix: attempt}

assert health['status'] == 'ok', health
assert health['autonomy_mode'] == 'yolo', health
assert health['agent']['state'] == 'running', health
assert health['agent']['trigger_policy'] == 'allow_yolo', health
assert health['providers']['model']['status'] == 'disabled', health
assert health['providers']['model']['mode'] == 'broker', health
assert get_screen_springboard['context']['foreground_app'] == 'com.apple.mobilesafari', get_screen_springboard
assert get_screen_springboard['context']['foreground_source'] == 'springboard_state', get_screen_springboard
assert get_screen_springboard['context']['springboard_state']['status'] == 'ok', get_screen_springboard
assert get_screen_springboard['context']['display']['orientation_name'] == 'portrait', get_screen_springboard
assert get_screen_springboard['context']['ui_tree']['status'] == 'ok', get_screen_springboard
assert get_screen_springboard['context']['visible_text'] == ['Safari'], get_screen_springboard
assert get_screen_springboard['context']['interactive_elements'][0]['id'] == 'springboard-0-0', get_screen_springboard
assert get_screen_springboard['context']['windows'][0]['bounds'] == [0, 0, 430, 932], get_screen_springboard
assert 'ui_tree_springboard_only' in get_screen_springboard['context']['risk_flags'], get_screen_springboard
assert app_ui_publish['status'] == 'ok', app_ui_publish
assert app_ui_publish['bundle_id'] == 'com.apple.mobilesafari', app_ui_publish
assert app_ui_publish['ui_tree_status'] == 'ok', app_ui_publish
assert get_screen_app_ui['context']['foreground_app'] == 'com.apple.mobilesafari', get_screen_app_ui
assert get_screen_app_ui['context']['foreground_source'] == 'springboard_state', get_screen_app_ui
assert get_screen_app_ui['context']['springboard_state']['status'] == 'ok', get_screen_app_ui
assert get_screen_app_ui['context']['app_ui_state']['status'] == 'ok', get_screen_app_ui
assert get_screen_app_ui['context']['app_ui_state']['bundle_id'] == 'com.apple.mobilesafari', get_screen_app_ui
assert get_screen_app_ui['context']['app_ui_state']['received_transport'] == 'local_smoke_agentctl', get_screen_app_ui
assert get_screen_app_ui['context']['ui_tree_source'] == 'app_process', get_screen_app_ui
assert get_screen_app_ui['context']['ui_tree']['scope'] == 'app_process', get_screen_app_ui
assert get_screen_app_ui['context']['ui_tree']['provider'] == 'OpenPhoneAppIntrospector.UIKitAccessibility', get_screen_app_ui
assert get_screen_app_ui['context']['visible_text'] == ['Example Domain', 'Address'], get_screen_app_ui
assert get_screen_app_ui['context']['interactive_elements'][0]['id'] == 'app-com.apple.mobilesafari-0-0', get_screen_app_ui
assert get_screen_app_ui['context']['interactive_elements'][0]['scope'] == 'app_process', get_screen_app_ui
assert 'ui_tree_app_process' in get_screen_app_ui['context']['risk_flags'], get_screen_app_ui
assert 'ui_tree_springboard_only' not in get_screen_app_ui['context']['risk_flags'], get_screen_app_ui
assert tap_element['state'] in ('action.executed', 'action.denied.input_failed'), tap_element
assert tap_element['detail'] == 'tap_element:springboard-0-0:40.0,73.0', tap_element
assert tap_element['coordinate_source'] == 'ui_tree.bounds_center', tap_element
assert tap_element['target']['id'] == 'springboard-0-0', tap_element
assert tap_element['target']['label'] == 'Safari', tap_element
assert tap_element['target']['bounds'] == [12, 34, 56, 78], tap_element
assert_provider_attempt_shape(tap_element, 'dispatch_unverified')
assert tap_element['verification']['status'] == 'unverified', tap_element
assert any(attempt['scope'] == 'daemon_hid' for attempt in tap_element['provider_attempts']), tap_element
assert app_input_type_text['state'] == 'action.executed', app_input_type_text
assert app_input_type_text['detail'] == 'type_text:9:app_process', app_input_type_text
assert_provider_attempt_shape(app_input_type_text, 'verified')
assert app_input_type_text['verification']['status'] == 'verified', app_input_type_text
assert app_input_type_text['verification']['source'] == 'app_process_text_state', app_input_type_text
assert app_input_type_text['provider_attempts'][0]['activation_method'] == 'text_input_insert', app_input_type_text
assert app_input_type_text['provider_attempts'][0]['before_text_length'] == 0, app_input_type_text
assert app_input_type_text['provider_attempts'][0]['after_text_length'] == 9, app_input_type_text
assert memory_save['status'] == 'ok', memory_save
assert memory_save['memory']['text'] == 'user prefers concise OpenPhone status updates', memory_save
assert memory_update['status'] == 'ok', memory_update
assert memory_update['memory_id'] == memory_save['memory']['memory_id'], memory_update
assert memory_update['memory']['text'] == 'user prefers concise OpenPhone validation details', memory_update
assert memory_update['previous_memory']['text'] == 'user prefers concise OpenPhone status updates', memory_update
assert memory_save_merge_source['status'] == 'ok', memory_save_merge_source
assert memory_merge['status'] == 'ok', memory_merge
assert memory_merge['memory_id'] == memory_save['memory']['memory_id'], memory_merge
assert memory_merge['merged_from'] == memory_save_merge_source['memory']['memory_id'], memory_merge
assert 'terse summaries' in memory_merge['memory']['text'], memory_merge
assert memory_merge['deleted_memory']['memory_id'] == memory_save_merge_source['memory']['memory_id'], memory_merge
assert memory_save_delete_fixture['status'] == 'ok', memory_save_delete_fixture
assert memory_delete['status'] == 'ok', memory_delete
assert memory_delete['deleted'] is True, memory_delete
assert memory_delete['memory_id'] == memory_save_delete_fixture['memory']['memory_id'], memory_delete
assert memory_search['status'] == 'ok', memory_search
assert memory_search['count'] >= 1, memory_search
assert any('terse summaries' in item['text'] for item in memory_search['memories']), memory_search
assert not any(item['memory_id'] == memory_save_merge_source['memory']['memory_id'] for item in memory_search['memories']), memory_search
assert not any(item['memory_id'] == memory_save_delete_fixture['memory']['memory_id'] for item in memory_search['memories']), memory_search
assert clipboard_write['status'] == 'ok', clipboard_write
assert clipboard_write['tool'] == 'clipboard_write', clipboard_write
assert clipboard_write['text_length'] == len('OpenPhone clipboard smoke value'), clipboard_write
assert clipboard_write['text_sha256'], clipboard_write
assert clipboard_read['status'] == 'ok', clipboard_read
assert clipboard_read['tool'] == 'clipboard_read', clipboard_read
assert clipboard_read['text'] == 'OpenPhone clipboard smoke value', clipboard_read
assert clipboard_read['text_length'] == len('OpenPhone clipboard smoke value'), clipboard_read
assert clipboard_read['text_sha256'] == clipboard_write['text_sha256'], clipboard_read
assert context_search_clipboard['status'] == 'ok', context_search_clipboard
assert context_search_clipboard['count'] >= 1, context_search_clipboard
assert any(item['type'] in ('clipboard_read', 'clipboard_written') for item in context_search_clipboard['events']), context_search_clipboard
assert contacts_search['status'] == 'ok', contacts_search
assert contacts_search['tool'] == 'contacts_search', contacts_search
assert contacts_search['provider'] == 'openphone.contacts_fixture_file', contacts_search
assert contacts_search['count'] == 1, contacts_search
assert contacts_search['query_length'] == 3, contacts_search
assert contacts_search['query_sha256'], contacts_search
assert contacts_search['contacts'][0]['display_name'] == 'Ada Lovelace', contacts_search
assert contacts_search['contacts'][0]['phone_numbers'] == ['+1555010101'], contacts_search
assert contacts_search['contacts'][0]['emails'] == ['ada@example.test'], contacts_search
assert context_search_contacts['status'] == 'ok', context_search_contacts
assert context_search_contacts['count'] >= 1, context_search_contacts
assert any(item['type'] == 'contacts_searched' for item in context_search_contacts['events']), context_search_contacts
assert not any('Ada Lovelace' in item['body'] for item in context_search_contacts['events']), context_search_contacts
assert calendar_search['status'] == 'ok', calendar_search
assert calendar_search['tool'] == 'calendar_search', calendar_search
assert calendar_search['provider'] == 'openphone.calendar_fixture_file', calendar_search
assert calendar_search['count'] == 1, calendar_search
assert calendar_search['query_length'] == len('Standup'), calendar_search
assert calendar_search['query_sha256'], calendar_search
assert calendar_search['events'][0]['title'] == 'OpenPhone Standup', calendar_search
assert calendar_search['events'][0]['calendar_title'] == 'Engineering', calendar_search
assert calendar_search['events'][0]['start_at_ms'] == 1893456000000, calendar_search
assert context_search_calendar['status'] == 'ok', context_search_calendar
assert context_search_calendar['count'] >= 1, context_search_calendar
assert any(item['type'] == 'calendar_searched' for item in context_search_calendar['events']), context_search_calendar
assert not any('OpenPhone Standup' in item['body'] for item in context_search_calendar['events']), context_search_calendar
assert calls_search['status'] == 'ok', calls_search
assert calls_search['tool'] == 'calls_search', calls_search
assert calls_search['provider'] == 'openphone.calls_fixture_file', calls_search
assert calls_search['count'] == 1, calls_search
assert calls_search['query_length'] == len('OpenPhone'), calls_search
assert calls_search['query_sha256'], calls_search
assert calls_search['calls'][0]['display_name'] == 'OpenPhone Test Call', calls_search
assert calls_search['calls'][0]['address'] == '+15550101234', calls_search
assert calls_search['calls'][0]['direction'] == 'incoming', calls_search
assert calls_search['calls'][0]['duration_seconds'] == 120, calls_search
assert calls_search['calls'][0]['start_at_ms'] == 1893459600000, calls_search
assert context_search_calls['status'] == 'ok', context_search_calls
assert context_search_calls['count'] >= 1, context_search_calls
assert any(item['type'] == 'calls_searched' for item in context_search_calls['events']), context_search_calls
assert not any('OpenPhone Test Call' in item['body'] for item in context_search_calls['events']), context_search_calls
assert not any('+15550101234' in item['body'] for item in context_search_calls['events']), context_search_calls
assert messages_search['status'] == 'ok', messages_search
assert messages_search['tool'] == 'messages_search', messages_search
assert messages_search['provider'] == 'openphone.messages_fixture_file', messages_search
assert messages_search['count'] == 1, messages_search
assert messages_search['query_length'] == len('OpenPhone'), messages_search
assert messages_search['query_sha256'], messages_search
assert messages_search['messages'][0]['handle'] == '+15550105555', messages_search
assert messages_search['messages'][0]['service'] == 'iMessage', messages_search
assert messages_search['messages'][0]['direction'] == 'incoming', messages_search
assert messages_search['messages'][0]['text_preview'] == 'OpenPhone message fixture says hello from local smoke.', messages_search
assert messages_search['messages'][0]['text_sha256'], messages_search
assert messages_search['messages'][0]['sent_at_ms'] == 1893463200000, messages_search
assert context_search_messages['status'] == 'ok', context_search_messages
assert context_search_messages['count'] >= 1, context_search_messages
assert any(item['type'] == 'messages_searched' for item in context_search_messages['events']), context_search_messages
assert not any('OpenPhone message fixture' in item['body'] for item in context_search_messages['events']), context_search_messages
assert not any('+15550105555' in item['body'] for item in context_search_messages['events']), context_search_messages
# Notification provider redaction: bounded previews only (title<=200, body<=1000),
# no full payload / tail PII in the stored log or the derived context event.
notification_tail = 'NOTIFYPIItail_+15559998888_leak@example.test'
assert notification_ingest['status'] == 'ok', notification_ingest
assert notification_ingest['bundle_id'] == 'com.openphone.smoke', notification_ingest
assert notification_ingest['stored_count'] >= 1, notification_ingest
assert notification_list['status'] == 'ok', notification_list
assert notification_list['count'] >= 1, notification_list
smoke_notifs = [n for n in notification_list['notifications'] if n.get('notification_id') == 'smoke-notif-1']
assert smoke_notifs, notification_list
notif = smoke_notifs[0]
assert notif['bundle_id'] == 'com.openphone.smoke', notif
assert len(notif['title']) <= 201, notif  # 200 chars + single ellipsis
assert len(notif['body']) <= 1001, notif
assert notification_tail not in notif['title'], notif
assert notification_tail not in notif['body'], notif
assert notif['body'].startswith('OpenPhone body preview head.'), notif
assert context_search_notification['status'] == 'ok', context_search_notification
assert context_search_notification['count'] >= 1, context_search_notification
assert any(item['type'] == 'notification_received' for item in context_search_notification['events']), context_search_notification
assert not any(notification_tail in item['body'] for item in context_search_notification['events']), context_search_notification
assert not any(notification_tail in item.get('title', '') for item in context_search_notification['events']), context_search_notification
assert context_search['status'] == 'ok', context_search
assert context_search['count'] >= 1, context_search
assert any('concise' in item['body'] for item in context_search['events']), context_search
assert commitment_create['status'] == 'ok', commitment_create
assert commitment_create['commitment']['title'] == 'follow up about OpenPhone iOS smoke', commitment_create
assert commitment_search['status'] == 'ok', commitment_search
assert commitment_search['count'] >= 1, commitment_search
assert commitment_update['status'] == 'ok', commitment_update
assert commitment_update['commitment']['status'] == 'completed', commitment_update
assert commitment_due_create['status'] == 'ok', commitment_due_create
assert commitment_due_create['commitment']['title'] == 'due commitment smoke', commitment_due_create
assert commitment_due_create['commitment']['status'] == 'active', commitment_due_create
assert commitment_due_create['commitment']['trigger_type'] == 'time', commitment_due_create
commitment_due_public_id = commitment_due_create['commitment']['commitment_id']
assert commitment_run_due['status'] == 'ok', commitment_run_due
assert commitment_run_due['scheduler_status'] == 'implemented_time_bridge', commitment_run_due
assert commitment_run_due['triggered_count'] >= 1, commitment_run_due
assert commitment_run_due['job_count'] >= 1, commitment_run_due
commitment_due_entries = [
    item for item in commitment_run_due['commitments']
    if item.get('commitment_id') == commitment_due_public_id
]
assert commitment_due_entries and commitment_due_entries[0]['status'] == 'background_job_queued', commitment_run_due
commitment_due_entry = commitment_due_entries[0]
assert commitment_due_entry['commitment']['status'] == 'triggered', commitment_due_entry
assert commitment_due_entry['commitment']['evidence']['scheduler']['last_trigger_status'] == 'background_job_queued', commitment_due_entry
assert commitment_due_entry['commitment']['evidence']['scheduler']['last_job_id'] == commitment_due_entry['job_id'], commitment_due_entry
assert commitment_due_entry['job']['type'] == 'commitment_due', commitment_due_entry
assert commitment_due_entry['job']['payload']['commitment_id'] == commitment_due_public_id, commitment_due_entry
assert commitment_due_job_run['status'] == 'ok', commitment_due_job_run
assert commitment_due_job_run['commitment_scheduler_status'] == 'implemented_time_bridge', commitment_due_job_run
commitment_due_job_entries = [
    item for item in commitment_due_job_run['jobs']
    if item.get('job_id') == commitment_due_entry['job_id']
]
assert commitment_due_job_entries and commitment_due_job_entries[0]['run_task']['status'] == 'task.finished', commitment_due_job_run
assert commitment_due_after['status'] == 'ok', commitment_due_after
commitment_due_after_entries = [
    item for item in commitment_due_after['commitments']
    if item.get('commitment_id') == commitment_due_public_id
]
assert commitment_due_after_entries and commitment_due_after_entries[0]['status'] == 'triggered', commitment_due_after
assert watcher_create['status'] == 'ok', watcher_create
assert watcher_create['watcher']['title'] == 'watch smoke condition', watcher_create
assert watcher_create['scheduler_status'] == 'implemented_timer_bridge', watcher_create
assert watcher_create['fires_locally'] is True, watcher_create
assert watcher_create['watcher']['scheduler_status'] == 'implemented_timer_bridge', watcher_create
assert watcher_create['watcher']['fires_locally'] is True, watcher_create
assert watcher_list['status'] == 'ok', watcher_list
assert watcher_list['count'] >= 1, watcher_list
assert watcher_list['scheduler_status'] == 'implemented_timer_bridge', watcher_list
assert watcher_materialize_due['status'] == 'ok', watcher_materialize_due
assert watcher_materialize_due['scheduler_status'] == 'implemented_timer_bridge', watcher_materialize_due
assert watcher_materialize_due['fired_count'] >= 1, watcher_materialize_due
assert watcher_materialize_due['job_count'] >= 1, watcher_materialize_due
assert watcher_materialize_due['watchers'][0]['status'] == 'background_job_queued', watcher_materialize_due
assert watcher_run_due['status'] == 'ok', watcher_run_due
assert watcher_run_due['watcher_scheduler_status'] == 'implemented_timer_bridge', watcher_run_due
assert watcher_run_due['ran_count'] >= 1, watcher_run_due
assert watcher_run_due['jobs'][0]['run_task']['status'] in ('task.finished', 'task.failed'), watcher_run_due
assert watcher_after_run['status'] == 'ok', watcher_after_run
assert watcher_after_run['watchers'][0]['status'] == 'fired', watcher_after_run
assert watcher_stop['status'] == 'ok', watcher_stop
assert watcher_stop['stopped_count'] == 1, watcher_stop
assert watcher_stop['watchers'][0]['status'] == 'stopped', watcher_stop
assert watcher_recurring_create['status'] == 'ok', watcher_recurring_create
recurring_watcher_public_id = watcher_recurring_create['watcher']['watcher_id']
assert watcher_recurring_create['watcher']['recurring'] == True, watcher_recurring_create
assert watcher_recurring_create['watcher']['interval_ms'] == 5, watcher_recurring_create
assert watcher_recurring_first['status'] == 'ok', watcher_recurring_first
assert watcher_recurring_first['scheduler_status'] == 'implemented_timer_bridge', watcher_recurring_first
recurring_first_entries = [item for item in watcher_recurring_first['watchers'] if item.get('watcher_id') == recurring_watcher_public_id]
assert recurring_first_entries and recurring_first_entries[0]['status'] == 'background_job_queued', watcher_recurring_first
assert recurring_first_entries[0]['watcher']['status'] == 'active', watcher_recurring_first
assert recurring_first_entries[0]['watcher']['metadata']['recurring'] == True, watcher_recurring_first
assert recurring_first_entries[0]['watcher']['metadata']['last_fire_status'] == 'background_job_queued', watcher_recurring_first
assert watcher_recurring_second['status'] == 'ok', watcher_recurring_second
recurring_second_entries = [item for item in watcher_recurring_second['watchers'] if item.get('watcher_id') == recurring_watcher_public_id]
assert recurring_second_entries and recurring_second_entries[0]['status'] == 'background_job_queued', watcher_recurring_second
assert recurring_second_entries[0]['watcher']['status'] == 'active', watcher_recurring_second
assert recurring_second_entries[0]['watcher']['schedule']['last_job_id'] != recurring_first_entries[0]['watcher']['schedule']['last_job_id'], watcher_recurring_second
assert watcher_recurring_after['status'] == 'ok', watcher_recurring_after
recurring_after_entries = [item for item in watcher_recurring_after['watchers'] if item.get('watcher_id') == recurring_watcher_public_id]
assert recurring_after_entries and recurring_after_entries[0]['status'] == 'active', watcher_recurring_after
assert recurring_after_entries[0]['metadata']['recurring'] == True, watcher_recurring_after
assert watcher_recurring_stop['status'] == 'ok', watcher_recurring_stop
assert watcher_recurring_stop['stopped_count'] == 1, watcher_recurring_stop
assert watcher_repair_create['status'] == 'ok', watcher_repair_create
repair_watcher_public_id = watcher_repair_create['watcher']['watcher_id']
assert watcher_debug_mark_running['status'] == 'ok', watcher_debug_mark_running
assert watcher_debug_mark_running['watcher']['status'] == 'running', watcher_debug_mark_running
assert watcher_repair_stuck['status'] == 'ok', watcher_repair_stuck
assert watcher_repair_stuck['repair_policy'] == 'requeue_stale_running', watcher_repair_stuck
assert watcher_repair_stuck['repaired_count'] >= 1, watcher_repair_stuck
watcher_repair_entries = [item for item in watcher_repair_stuck['watchers'] if item.get('watcher_id') == repair_watcher_public_id]
assert watcher_repair_entries and watcher_repair_entries[0]['status'] == 'requeued', watcher_repair_stuck
assert watcher_repair_entries[0]['watcher']['status'] == 'active', watcher_repair_stuck
assert watcher_repair_entries[0]['watcher']['metadata']['stuck_repair']['repair_action'] == 'requeued', watcher_repair_stuck
assert watcher_repair_run_due['status'] == 'ok', watcher_repair_run_due
assert watcher_repair_run_due['scheduler_status'] == 'implemented_timer_bridge', watcher_repair_run_due
assert watcher_repair_run_due['fired_count'] >= 1, watcher_repair_run_due
repair_due_entries = [item for item in watcher_repair_run_due['watchers'] if item.get('watcher_id') == repair_watcher_public_id]
assert repair_due_entries and repair_due_entries[0]['status'] == 'background_job_queued', watcher_repair_run_due
assert watcher_repair_after_run['status'] == 'ok', watcher_repair_after_run
repair_after_entries = [item for item in watcher_repair_after_run['watchers'] if item.get('watcher_id') == repair_watcher_public_id]
assert repair_after_entries and repair_after_entries[0]['status'] == 'fired', watcher_repair_after_run
assert repair_after_entries[0]['metadata']['stuck_repair']['repair_action'] == 'requeued', watcher_repair_after_run
assert watcher_repair_stop['status'] == 'ok', watcher_repair_stop
assert background_job_create['status'] == 'ok', background_job_create
assert background_job_create['job']['title'] == 'smoke background job', background_job_create
assert background_job_create['scheduler_status'] == 'implemented_agent_loop', background_job_create
assert background_job_create['runs_locally'] is True, background_job_create
assert background_job_run_due['status'] == 'ok', background_job_run_due
assert background_job_run_due['scheduler_status'] == 'implemented_agent_loop', background_job_run_due
assert background_job_run_due['runner'] == 'deterministic', background_job_run_due
assert background_job_run_due['ran_count'] >= 1, background_job_run_due
assert background_job_run_due['jobs'][0]['run_task']['status'] in ('task.finished', 'task.failed'), background_job_run_due
assert background_job_run_due['jobs'][0]['run_task']['task_id'], background_job_run_due
assert background_job_list['status'] == 'ok', background_job_list
assert background_job_list['count'] >= 1, background_job_list
assert background_job_stop['status'] == 'ok', background_job_stop
assert background_job_stop['job']['status'] == 'stopped', background_job_stop
assert background_job_recurring_create['status'] == 'ok', background_job_recurring_create
recurring_job_public_id = background_job_recurring_create['job']['job_id']
assert background_job_recurring_create['job']['status'] == 'queued', background_job_recurring_create
assert background_job_recurring_create['job']['schedule']['recurring'] == True, background_job_recurring_create
assert background_job_recurring_create['job']['interval_ms'] == 50, background_job_recurring_create
assert background_job_recurring_run_due['status'] == 'ok', background_job_recurring_run_due
recurring_job_entries = [item for item in background_job_recurring_run_due['jobs'] if item.get('job_id') == recurring_job_public_id]
assert recurring_job_entries and recurring_job_entries[0]['status'] == 'queued', background_job_recurring_run_due
assert recurring_job_entries[0]['run_task']['status'] == 'task.finished', background_job_recurring_run_due
recurring_job = recurring_job_entries[0]['job']
assert recurring_job['status'] == 'queued', recurring_job
assert recurring_job['schedule']['run_policy'] == 'recurring_interval', recurring_job
assert recurring_job['schedule']['retry_backoff_ms'] == 0, recurring_job
assert recurring_job['payload']['scheduler']['run_policy'] == 'recurring_interval', recurring_job
assert recurring_job['payload']['scheduler']['failure_count'] == 0, recurring_job
assert recurring_job['next_run_at_ms'] > recurring_job['payload']['scheduler']['last_run_at_ms'], recurring_job
assert background_job_recurring_list['status'] == 'ok', background_job_recurring_list
recurring_list_entries = [item for item in background_job_recurring_list['jobs'] if item.get('job_id') == recurring_job_public_id]
assert recurring_list_entries and recurring_list_entries[0]['status'] == 'queued', background_job_recurring_list
assert background_job_recurring_stop['status'] == 'ok', background_job_recurring_stop
assert background_job_recurring_stop['job']['status'] == 'stopped', background_job_recurring_stop
assert background_job_nonrecurring_interval_create['status'] == 'ok', background_job_nonrecurring_interval_create
nonrecurring_interval_job_public_id = background_job_nonrecurring_interval_create['job']['job_id']
assert background_job_nonrecurring_interval_create['job']['schedule']['recurring'] == False, background_job_nonrecurring_interval_create
assert background_job_nonrecurring_interval_create['job']['interval_ms'] == 50, background_job_nonrecurring_interval_create
assert background_job_nonrecurring_interval_run_due['status'] == 'ok', background_job_nonrecurring_interval_run_due
nonrecurring_interval_entries = [
    item for item in background_job_nonrecurring_interval_run_due['jobs']
    if item.get('job_id') == nonrecurring_interval_job_public_id
]
assert nonrecurring_interval_entries and nonrecurring_interval_entries[0]['status'] == 'completed', background_job_nonrecurring_interval_run_due
assert nonrecurring_interval_entries[0]['run_task']['status'] == 'task.finished', background_job_nonrecurring_interval_run_due
nonrecurring_interval_job = nonrecurring_interval_entries[0]['job']
assert nonrecurring_interval_job['status'] == 'completed', nonrecurring_interval_job
assert nonrecurring_interval_job['schedule']['recurring'] == False, nonrecurring_interval_job
assert nonrecurring_interval_job['schedule']['run_policy'] == 'terminal', nonrecurring_interval_job
assert nonrecurring_interval_job['next_run_at_ms'] == 0, nonrecurring_interval_job
assert background_job_nonrecurring_interval_list['status'] == 'ok', background_job_nonrecurring_interval_list
nonrecurring_interval_list_entries = [
    item for item in background_job_nonrecurring_interval_list['jobs']
    if item.get('job_id') == nonrecurring_interval_job_public_id
]
assert nonrecurring_interval_list_entries and nonrecurring_interval_list_entries[0]['status'] == 'completed', background_job_nonrecurring_interval_list
assert background_job_backoff_create['status'] == 'ok', background_job_backoff_create
backoff_job_public_id = background_job_backoff_create['job']['job_id']
assert background_job_backoff_create['job']['schedule']['recurring'] == True, background_job_backoff_create
assert background_job_backoff_run_due['status'] == 'ok', background_job_backoff_run_due
backoff_entries = [item for item in background_job_backoff_run_due['jobs'] if item.get('job_id') == backoff_job_public_id]
assert backoff_entries and backoff_entries[0]['status'] == 'queued', background_job_backoff_run_due
assert backoff_entries[0]['run_task']['status'] == 'error', background_job_backoff_run_due
assert backoff_entries[0]['run_task']['reason'] == 'model_provider_not_configured', background_job_backoff_run_due
backoff_job = backoff_entries[0]['job']
assert backoff_job['status'] == 'queued', backoff_job
assert backoff_job['schedule']['run_policy'] == 'recurring_failure_backoff', backoff_job
assert backoff_job['schedule']['failure_count'] == 1, backoff_job
assert backoff_job['schedule']['retry_backoff_ms'] == 30000, backoff_job
assert backoff_job['payload']['scheduler']['run_policy'] == 'recurring_failure_backoff', backoff_job
assert backoff_job['payload']['scheduler']['failure_count'] == 1, backoff_job
assert backoff_job['next_run_at_ms'] >= backoff_job['payload']['scheduler']['last_run_at_ms'] + 30000, backoff_job
assert background_job_backoff_list['status'] == 'ok', background_job_backoff_list
backoff_list_entries = [item for item in background_job_backoff_list['jobs'] if item.get('job_id') == backoff_job_public_id]
assert backoff_list_entries and backoff_list_entries[0]['status'] == 'queued', background_job_backoff_list
assert background_job_backoff_stop['status'] == 'ok', background_job_backoff_stop
assert background_job_backoff_stop['job']['status'] == 'stopped', background_job_backoff_stop
assert background_job_repair_create['status'] == 'ok', background_job_repair_create
repair_job_public_id = background_job_repair_create['job']['job_id']
assert background_job_debug_mark_running['status'] == 'ok', background_job_debug_mark_running
assert background_job_debug_mark_running['job']['status'] == 'running', background_job_debug_mark_running
assert background_job_repair_stuck['status'] == 'ok', background_job_repair_stuck
assert background_job_repair_stuck['repair_policy'] == 'requeue_stale_running', background_job_repair_stuck
assert background_job_repair_stuck['repaired_count'] >= 1, background_job_repair_stuck
repair_entries = [item for item in background_job_repair_stuck['jobs'] if item.get('job_id') == repair_job_public_id]
assert repair_entries and repair_entries[0]['status'] == 'requeued', background_job_repair_stuck
assert repair_entries[0]['job']['status'] == 'queued', background_job_repair_stuck
assert repair_entries[0]['job']['payload']['stuck_repair']['repair_action'] == 'requeued', background_job_repair_stuck
assert background_job_repair_run_due['status'] == 'ok', background_job_repair_run_due
assert background_job_repair_run_due['scheduler_status'] == 'implemented_agent_loop', background_job_repair_run_due
assert background_job_repair_list['status'] == 'ok', background_job_repair_list
repair_list_entries = [item for item in background_job_repair_list['jobs'] if item.get('job_id') == repair_job_public_id]
assert repair_list_entries, background_job_repair_list
assert repair_list_entries[0]['status'] in ('queued', 'completed', 'failed'), background_job_repair_list
assert repair_list_entries[0]['payload']['stuck_repair']['repair_action'] == 'requeued', background_job_repair_list
assert background_job_repair_stop['status'] == 'ok', background_job_repair_stop
assert agent_status_initial['status'] == 'ok', agent_status_initial
assert agent_status_initial['schema'] == 'openphone.agent_status.v1', agent_status_initial
assert agent_status_initial['control']['state'] == 'running', agent_status_initial
assert agent_status_initial['control']['trigger_policy'] == 'allow_yolo', agent_status_initial
assert agent_control_pause['status'] == 'ok', agent_control_pause
assert agent_control_pause['changed'] is True, agent_control_pause
assert agent_control_pause['control']['paused'] is True, agent_control_pause
assert agent_control_pause['control']['state'] == 'paused', agent_control_pause
assert agent_control_pause['control']['pause_reason'] == 'local smoke pause', agent_control_pause
assert agent_status_paused['state'] == 'paused', agent_status_paused
assert agent_status_paused['control']['trigger_policy'] == 'paused', agent_status_paused
assert hardware_trigger_paused['status'] == 'ok', hardware_trigger_paused
assert hardware_trigger_paused['state'] == 'trigger.paused', hardware_trigger_paused
assert hardware_trigger_paused['model_loop_status'] == 'paused', hardware_trigger_paused
assert hardware_trigger_paused['control']['paused'] is True, hardware_trigger_paused
assert 'agent_task_id' not in hardware_trigger_paused, hardware_trigger_paused
assert 'background_job' not in hardware_trigger_paused, hardware_trigger_paused
assert agent_control_resume['status'] == 'ok', agent_control_resume
assert agent_control_resume['changed'] is True, agent_control_resume
assert agent_control_resume['control']['paused'] is False, agent_control_resume
assert agent_control_resume['control']['trigger_policy'] == 'allow_yolo', agent_control_resume
assert agent_status_resumed['control']['state'] == 'running', agent_status_resumed
assert agent_status_resumed['control']['paused'] is False, agent_status_resumed
assert agent_control_disable_hardware['status'] == 'ok', agent_control_disable_hardware
assert agent_control_disable_hardware['changed'] is True, agent_control_disable_hardware
assert agent_control_disable_hardware['control']['hardware_triggers_enabled'] is False, agent_control_disable_hardware
assert agent_control_disable_hardware['control']['trigger_policy'] == 'disabled', agent_control_disable_hardware
assert hardware_trigger_disabled['status'] == 'ok', hardware_trigger_disabled
assert hardware_trigger_disabled['state'] == 'trigger.disabled', hardware_trigger_disabled
assert hardware_trigger_disabled['control']['hardware_triggers_enabled'] is False, hardware_trigger_disabled
assert 'agent_task_id' not in hardware_trigger_disabled, hardware_trigger_disabled
assert 'background_job' not in hardware_trigger_disabled, hardware_trigger_disabled
assert agent_control_enable_hardware['status'] == 'ok', agent_control_enable_hardware
assert agent_control_enable_hardware['control']['hardware_triggers_enabled'] is True, agent_control_enable_hardware
assert agent_control_enable_hardware['control']['trigger_policy'] == 'allow_yolo', agent_control_enable_hardware
assert agent_control_disable_yolo['status'] == 'ok', agent_control_disable_yolo
assert agent_control_disable_yolo['changed'] is True, agent_control_disable_yolo
assert agent_control_disable_yolo['control']['yolo_enabled'] is False, agent_control_disable_yolo
assert agent_control_disable_yolo['control']['trigger_policy'] == 'manual_only', agent_control_disable_yolo
assert hardware_trigger_yolo_disabled['status'] == 'ok', hardware_trigger_yolo_disabled
assert hardware_trigger_yolo_disabled['state'] == 'trigger.yolo_disabled', hardware_trigger_yolo_disabled
assert hardware_trigger_yolo_disabled['control']['yolo_enabled'] is False, hardware_trigger_yolo_disabled
assert 'agent_task_id' not in hardware_trigger_yolo_disabled, hardware_trigger_yolo_disabled
assert 'background_job' not in hardware_trigger_yolo_disabled, hardware_trigger_yolo_disabled
assert agent_control_enable_yolo['status'] == 'ok', agent_control_enable_yolo
assert agent_control_enable_yolo['control']['yolo_enabled'] is True, agent_control_enable_yolo
assert agent_control_enable_yolo['control']['trigger_policy'] == 'allow_yolo', agent_control_enable_yolo
assert hardware_trigger['status'] == 'ok', hardware_trigger
assert hardware_trigger['trigger'] == 'volume_up_down_combo', hardware_trigger
assert hardware_trigger['runtime_authority'] == 'phone_local', hardware_trigger
assert hardware_trigger['model_loop_status'] == 'not_started', hardware_trigger
assert hardware_trigger['background_job']['status'] == 'ok', hardware_trigger
assert hardware_trigger['background_job']['job']['status'] == 'queued', hardware_trigger
assert hardware_trigger['scheduler']['status'] == 'ok', hardware_trigger
assert hardware_trigger['scheduler']['scheduler_status'] == 'implemented_agent_loop', hardware_trigger
assert hardware_trigger['scheduler']['run_jobs'] is False, hardware_trigger
assert hardware_trigger['scheduler']['ran_count'] == 0, hardware_trigger
assert hardware_trigger['scheduler']['target_job_id'] == hardware_trigger['background_job']['job_id'], hardware_trigger
assert unlock_with_passcode['state'] == 'action.denied.input_failed', unlock_with_passcode
assert_provider_attempt_shape(unlock_with_passcode, 'failed')
assert unlock_with_passcode['verification']['status'] == 'failed', unlock_with_passcode
assert_no_sensitive_keys(unlock_with_passcode, 'unlock_with_passcode')
assert run['status'] in ('task.finished', 'task.failed'), run
assert run['task_id'], run
assert run['runner'] == 'deterministic', run
assert run['steps_used'] == 1, run
assert run['limits']['max_steps'] == 1, run
assert run['duration_ms'] >= 0, run
assert run['stop_reason'], run
assert pathlib.Path(run['trajectory']).exists(), run
assert model_status['schema'] == 'openphone.model_status.v1', model_status
assert model_status['status'] == 'disabled', model_status
assert model_status['mode'] == 'broker', model_status
assert model_status['credential']['status'] == 'missing', model_status
assert model_run['status'] == 'task.finished', model_run
assert model_run['runner'] == 'model', model_run
assert model_run['model_provider'] == 'fixture', model_run
assert model_run['steps_used'] == 2, model_run
assert model_run['stop_reason'] == 'finish_task', model_run
assert model_run['parser_failures'] == 0, model_run
assert model_run['tool_errors'] == 0, model_run
assert model_run['unverified_ui_actions'] == 0, model_run
assert pathlib.Path(model_run['trajectory']).exists(), model_run
assert model_unverified_run['status'] == 'task.finished', model_unverified_run
assert model_unverified_run['runner'] == 'model', model_unverified_run
assert model_unverified_run['model_provider'] == 'fixture', model_unverified_run
assert model_unverified_run['steps_used'] == 2, model_unverified_run
assert model_unverified_run['stop_reason'] == 'finish_task', model_unverified_run
assert model_unverified_run['tool_errors'] == 0, model_unverified_run
assert model_unverified_run['unverified_ui_actions'] == 1, model_unverified_run
assert pathlib.Path(model_unverified_run['trajectory']).exists(), model_unverified_run
assert model_visible_run['status'] == 'task.finished', model_visible_run
assert model_visible_run['runner'] == 'model', model_visible_run
assert model_visible_run['model_provider'] == 'fixture', model_visible_run
assert model_visible_run['steps_used'] == 2, model_visible_run
assert model_visible_run['stop_reason'] == 'finish_task', model_visible_run
assert model_visible_run['tool_errors'] == 0, model_visible_run
assert model_visible_run['unverified_ui_actions'] == 0, model_visible_run
assert pathlib.Path(model_visible_run['trajectory']).exists(), model_visible_run
assert start_model_cancel['task_id'], start_model_cancel
assert stop_model_cancel['state'] == 'task.stopped', stop_model_cancel
assert stop_model_cancel['cancel_requested'] is True, stop_model_cancel
assert model_cancel_run['status'] == 'task.cancelled', model_cancel_run
assert model_cancel_run['runner'] == 'model', model_cancel_run
assert model_cancel_run['model_provider'] == 'fixture', model_cancel_run
assert model_cancel_run['steps_used'] == 0, model_cancel_run
assert model_cancel_run['stop_reason'] == 'cancelled', model_cancel_run
assert model_cancel_run['cancel_reason'] == 'local smoke cancellation', model_cancel_run
assert model_cancel_run['parser_failures'] == 0, model_cancel_run
assert model_cancel_run['tool_errors'] == 0, model_cancel_run
assert start_stale_repair['task_id'], start_stale_repair
assert task_repair_stale_active['status'] == 'ok', task_repair_stale_active
assert task_repair_stale_active['repair_policy'] == 'fail_stale_active', task_repair_stale_active
assert task_repair_stale_active['repaired_count'] >= 1, task_repair_stale_active
stale_repair_entries = [
    item for item in task_repair_stale_active['tasks']
    if item.get('task_id') == start_stale_repair['task_id']
]
assert stale_repair_entries and stale_repair_entries[0]['status'] == 'failed', task_repair_stale_active
assert stale_repair_entries[0]['stop_reason'] == 'stale_active_repaired', task_repair_stale_active
assert get_task_stale_repaired['status'] == 'ok', get_task_stale_repaired
assert get_task_stale_repaired['task']['status'] == 'failed', get_task_stale_repaired
assert get_task_stale_repaired['task']['recovery']['repair_policy'] == 'fail_stale_active', get_task_stale_repaired
assert get_task_stale_repaired['task']['stop_reason'] == 'stale_active_repaired', get_task_stale_repaired
assert get_task_stale_repaired_trajectory['status'] == 'ok', get_task_stale_repaired_trajectory
stale_repair_events = [event['event'] for event in get_task_stale_repaired_trajectory['events']]
assert 'task_repaired' in stale_repair_events, stale_repair_events
assert 'task_failed' in stale_repair_events, stale_repair_events
assert model_repaired_run['status'] == 'task.finished', model_repaired_run
assert model_repaired_run['runner'] == 'model', model_repaired_run
assert model_repaired_run['model_provider'] == 'fixture', model_repaired_run
assert model_repaired_run['steps_used'] == 1, model_repaired_run
assert model_repaired_run['stop_reason'] == 'finish_task', model_repaired_run
assert model_repaired_run['parser_failures'] == 0, model_repaired_run
assert model_repaired_run['tool_errors'] == 0, model_repaired_run
assert pathlib.Path(model_repaired_run['trajectory']).exists(), model_repaired_run
assert model_configure['schema'] == 'openphone.model_status.v1', model_configure
assert model_configure['status'] == 'ready', model_configure
assert model_configure['credential_required'] is False, model_configure
assert model_status_configured['status'] == 'ready', model_status_configured
assert model_status_configured['mode'] == 'broker', model_status_configured
assert model_status_configured['credential']['status'] == 'missing', model_status_configured
assert model_broker_run['status'] == 'task.finished', model_broker_run
assert model_broker_run['runner'] == 'model', model_broker_run
assert model_broker_run['model_provider'] == 'broker', model_broker_run
assert model_broker_run['steps_used'] == 2, model_broker_run
assert model_broker_run['stop_reason'] == 'finish_task', model_broker_run
assert model_broker_run['parser_failures'] == 0, model_broker_run
assert model_broker_run['tool_errors'] == 0, model_broker_run
assert pathlib.Path(model_broker_run['trajectory']).exists(), model_broker_run
assert model_configure_realtime2['schema'] == 'openphone.model_status.v1', model_configure_realtime2
assert model_configure_realtime2['status'] == 'ready', model_configure_realtime2
assert model_configure_realtime2['mode'] == 'openai_realtime2', model_configure_realtime2
assert model_configure_realtime2['model'] == 'gpt-realtime-2', model_configure_realtime2
assert model_configure_realtime2['endpoint_configured'] is True, model_configure_realtime2
assert not model_configure_realtime2['endpoint_url_configured'], model_configure_realtime2
assert model_configure_realtime2['credential_required'] is True, model_configure_realtime2
assert model_configure_realtime2['credential']['status'] == 'present', model_configure_realtime2
assert model_configure_realtime2['credential']['source'] == 'credential_file', model_configure_realtime2
assert model_configure_realtime2['max_steps'] == 40, model_configure_realtime2
assert model_configure_realtime2['max_duration_ms'] == 600000, model_configure_realtime2
assert model_status_realtime2['status'] == 'ready', model_status_realtime2
assert model_status_realtime2['mode'] == 'openai_realtime2', model_status_realtime2
assert model_status_realtime2['model'] == 'gpt-realtime-2', model_status_realtime2
assert model_status_realtime2['credential_required'] is True, model_status_realtime2
assert model_status_realtime2['credential']['status'] == 'present', model_status_realtime2
assert list(base.joinpath('store/tasks').glob('*.json')), 'missing task file'
assert base.joinpath('store/audit/audit-events.jsonl').exists(), 'missing audit jsonl'
# Value-level retention scan: distinctive PII markers planted in provider
# fixtures must never appear verbatim in the persisted audit log or notification
# log. assert_no_sensitive_keys only checks key *names*; this proves the
# retention contract at the raw-bytes level for the durable stores.
provider_pii_markers = (
    '+15550101234',                                  # calls fixture address
    'OpenPhone Test Call',                           # calls fixture display name
    'OpenPhone message fixture says hello',          # messages fixture body
    '+15550105555',                                  # messages fixture handle
    'Discuss iOS agent progress',                    # calendar fixture notes
    'ada@example.test',                              # contacts fixture email
    'NOTIFYPIItail_+15559998888_leak@example.test',  # notification tail marker
)
audit_raw = base.joinpath('store/audit/audit-events.jsonl').read_text(encoding='utf-8')
for marker in provider_pii_markers:
    assert marker not in audit_raw, f'provider PII leaked verbatim into audit log: {marker}'
notif_log_path = base.joinpath('store/notifications/recent.json')
if notif_log_path.exists():
    notif_log_raw = notif_log_path.read_text(encoding='utf-8')
    assert 'NOTIFYPIItail_+15559998888_leak@example.test' not in notif_log_raw, \
        'notification tail PII leaked into stored notification log'
assert list_tasks['status'] == 'ok', list_tasks
assert list_tasks['tasks'], list_tasks
assert get_task['status'] == 'ok', get_task
assert get_task['task']['task_id'] == run['task_id'], get_task
assert get_trajectory['status'] == 'ok', get_trajectory
assert get_trajectory['events'], get_trajectory
assert get_model_trajectory['status'] == 'ok', get_model_trajectory
model_events = [event['event'] for event in get_model_trajectory['events']]
assert 'model_prompt_prepared' in model_events, model_events
assert model_events.count('model_decision') == 2, model_events
assert 'model_step_verified' in model_events, model_events
assert 'model_loop_finished' in model_events, model_events
assert get_model_unverified_trajectory['status'] == 'ok', get_model_unverified_trajectory
unverified_events = get_model_unverified_trajectory['events']
unverified_model_events = [event['event'] for event in unverified_events]
assert 'model_step_verified' in unverified_model_events, unverified_model_events
unverified_checks = [
    event['payload']['verification']
    for event in unverified_events
    if event.get('event') == 'model_step_verified'
]
assert any(check['status'] == 'unverified_dispatch_only' for check in unverified_checks), unverified_checks
assert any(
    check['screen_delta']['status'] == 'unchanged'
    for check in unverified_checks
    if check['status'] == 'unverified_dispatch_only'
), unverified_checks
assert get_model_visible_trajectory['status'] == 'ok', get_model_visible_trajectory
visible_events = get_model_visible_trajectory['events']
visible_model_events = [event['event'] for event in visible_events]
assert 'model_step_verified' in visible_model_events, visible_model_events
visible_checks = [
    event['payload']['verification']
    for event in visible_events
    if event.get('event') == 'model_step_verified'
]
assert any(check['status'] == 'verified' for check in visible_checks), visible_checks
assert any(
    check['screen_delta']['strong_signal'] is True and
    ('visible_text' in check['screen_delta']['signals'] or 'ui_tree' in check['screen_delta']['signals'])
    for check in visible_checks
    if check['status'] == 'verified'
), visible_checks
assert get_model_cancel_trajectory['status'] == 'ok', get_model_cancel_trajectory
cancel_model_events = [event['event'] for event in get_model_cancel_trajectory['events']]
assert 'task_stopped' in cancel_model_events, cancel_model_events
assert 'model_loop_cancelled' in cancel_model_events, cancel_model_events
assert 'model_loop_finished' in cancel_model_events, cancel_model_events
assert 'model_decision' not in cancel_model_events, cancel_model_events
assert get_model_repaired_trajectory['status'] == 'ok', get_model_repaired_trajectory
repaired_model_events = [event['event'] for event in get_model_repaired_trajectory['events']]
assert 'model_prompt_prepared' in repaired_model_events, repaired_model_events
assert 'model_parse_repaired' in repaired_model_events, repaired_model_events
assert repaired_model_events.count('model_decision') == 1, repaired_model_events
assert 'model_loop_finished' in repaired_model_events, repaired_model_events
assert get_model_broker_trajectory['status'] == 'ok', get_model_broker_trajectory
broker_model_events = [event['event'] for event in get_model_broker_trajectory['events']]
assert 'model_prompt_prepared' in broker_model_events, broker_model_events
assert broker_model_events.count('model_request') == 2, broker_model_events
assert broker_model_events.count('model_response') == 2, broker_model_events
assert broker_model_events.count('model_decision') == 2, broker_model_events
assert 'model_step_verified' in broker_model_events, broker_model_events
assert 'model_loop_finished' in broker_model_events, broker_model_events
assert get_redaction_trajectory['status'] == 'ok', get_redaction_trajectory
assert get_redaction_trajectory['events'], get_redaction_trajectory
assert get_audit['status'] == 'ok', get_audit
assert get_audit['events'], get_audit
assert_no_sensitive_keys(get_audit, 'get_audit')
assert_no_sensitive_keys(get_redaction_trajectory, 'get_redaction_trajectory')
assert_no_sensitive_keys(agent_status_initial, 'agent_status_initial')
assert_no_sensitive_keys(agent_control_pause, 'agent_control_pause')
assert_no_sensitive_keys(agent_status_paused, 'agent_status_paused')
assert_no_sensitive_keys(hardware_trigger_paused, 'hardware_trigger_paused')
assert_no_sensitive_keys(agent_control_resume, 'agent_control_resume')
assert_no_sensitive_keys(agent_status_resumed, 'agent_status_resumed')
assert_no_sensitive_keys(agent_control_disable_hardware, 'agent_control_disable_hardware')
assert_no_sensitive_keys(hardware_trigger_disabled, 'hardware_trigger_disabled')
assert_no_sensitive_keys(agent_control_enable_hardware, 'agent_control_enable_hardware')
assert_no_sensitive_keys(agent_control_disable_yolo, 'agent_control_disable_yolo')
assert_no_sensitive_keys(hardware_trigger_yolo_disabled, 'hardware_trigger_yolo_disabled')
assert_no_sensitive_keys(agent_control_enable_yolo, 'agent_control_enable_yolo')
assert_no_sensitive_keys(model_status, 'model_status')
assert_no_sensitive_keys(model_configure, 'model_configure')
assert_no_sensitive_keys(model_status_configured, 'model_status_configured')
assert_no_sensitive_keys(model_configure_realtime2, 'model_configure_realtime2')
assert_no_sensitive_keys(model_status_realtime2, 'model_status_realtime2')
assert_no_sensitive_keys(get_model_trajectory, 'get_model_trajectory')
assert_no_sensitive_keys(get_model_unverified_trajectory, 'get_model_unverified_trajectory')
assert_no_sensitive_keys(get_model_visible_trajectory, 'get_model_visible_trajectory')
assert_no_sensitive_keys(get_model_cancel_trajectory, 'get_model_cancel_trajectory')
assert_no_sensitive_keys(get_task_stale_repaired_trajectory, 'get_task_stale_repaired_trajectory')
assert_no_sensitive_keys(get_model_repaired_trajectory, 'get_model_repaired_trajectory')
assert_no_sensitive_keys(get_model_broker_trajectory, 'get_model_broker_trajectory')
assert validate_store['status'] == 'ok', validate_store
assert validate_store['audit_events'] >= get_audit['count'], validate_store
assert validate_store['sqlite']['commitment_rows'] >= 1, validate_store
assert validate_store['sqlite']['watcher_rows'] >= 1, validate_store
assert validate_store['sqlite']['agent_job_rows'] >= 1, validate_store

print(json.dumps({
    'health_status': health['status'],
    'springboard_state_foreground': get_screen_springboard['context']['foreground_app'],
    'app_ui_tree_source': get_screen_app_ui['context']['ui_tree_source'],
    'tap_element_state': tap_element['state'],
    'tap_element_detail': tap_element['detail'],
    'tap_element_user_facing_status': tap_element['user_facing_status'],
    'app_input_type_text_user_facing_status': app_input_type_text['user_facing_status'],
    'app_input_type_text_verification': app_input_type_text['verification']['status'],
    'memory_id': memory_save['memory']['memory_id'],
    'memory_updated_id': memory_update['memory_id'],
    'memory_merged_from': memory_merge['merged_from'],
    'memory_deleted_id': memory_delete['memory_id'],
    'memory_search_count': memory_search['count'],
    'context_search_count': context_search['count'],
    'clipboard_provider': clipboard_read['provider'],
    'clipboard_system_clipboard': clipboard_read['system_clipboard'],
    'clipboard_text_length': clipboard_read['text_length'],
    'clipboard_context_events': context_search_clipboard['count'],
    'contacts_provider': contacts_search['provider'],
    'contacts_count': contacts_search['count'],
    'contacts_context_events': context_search_contacts['count'],
    'calendar_provider': calendar_search['provider'],
    'calendar_count': calendar_search['count'],
    'calendar_context_events': context_search_calendar['count'],
    'calls_provider': calls_search['provider'],
    'calls_count': calls_search['count'],
    'calls_context_events': context_search_calls['count'],
    'messages_provider': messages_search['provider'],
    'messages_count': messages_search['count'],
    'messages_context_events': context_search_messages['count'],
    'notification_stored_count': notification_ingest['stored_count'],
    'notification_context_events': context_search_notification['count'],
    'commitment_id': commitment_create['commitment']['commitment_id'],
    'commitment_due_id': commitment_due_public_id,
    'commitment_due_job_id': commitment_due_entry['job_id'],
    'watcher_id': watcher_create['watcher']['watcher_id'],
    'recurring_watcher_id': recurring_watcher_public_id,
    'recurring_watcher_second_job_id': recurring_second_entries[0]['job_id'],
    'watcher_repair_id': repair_watcher_public_id,
    'job_id': background_job_create['job']['job_id'],
    'job_scheduler_ran_count': background_job_run_due['ran_count'],
    'recurring_job_id': recurring_job_public_id,
    'recurring_job_next_run_at_ms': recurring_job['next_run_at_ms'],
    'nonrecurring_interval_job_id': nonrecurring_interval_job_public_id,
    'backoff_job_id': backoff_job_public_id,
    'backoff_retry_ms': backoff_job['schedule']['retry_backoff_ms'],
    'agent_status_state': agent_status_resumed['state'],
    'agent_trigger_policy': agent_status_resumed['control']['trigger_policy'],
    'paused_trigger_state': hardware_trigger_paused['state'],
    'disabled_trigger_state': hardware_trigger_disabled['state'],
    'yolo_disabled_trigger_state': hardware_trigger_yolo_disabled['state'],
    'trigger_task_id': hardware_trigger['task_id'],
    'trigger_scheduler_ran_count': hardware_trigger['scheduler']['ran_count'],
    'trigger_background_job_id': hardware_trigger['background_job']['job']['job_id'],
    'redaction_trajectory_events': get_redaction_trajectory['count'],
    'unlock_user_facing_status': unlock_with_passcode['user_facing_status'],
    'run_status': run['status'],
    'model_status': model_status['status'],
    'model_run_status': model_run['status'],
    'model_run_provider': model_run['model_provider'],
    'model_run_steps': model_run['steps_used'],
    'model_unverified_ui_actions': model_unverified_run['unverified_ui_actions'],
    'model_visible_ui_actions': model_visible_run['unverified_ui_actions'],
    'model_cancel_status': model_cancel_run['status'],
    'model_cancel_stop_reason': model_cancel_run['stop_reason'],
    'model_cancel_task_id': model_cancel_run['task_id'],
    'stale_task_repair_status': get_task_stale_repaired['task']['status'],
    'stale_task_repair_task_id': start_stale_repair['task_id'],
    'model_repair_status': model_repaired_run['status'],
    'model_repair_task_id': model_repaired_run['task_id'],
    'model_broker_status': model_broker_run['status'],
    'model_broker_provider': model_broker_run['model_provider'],
    'model_broker_steps': model_broker_run['steps_used'],
    'model_realtime2_status': model_status_realtime2['status'],
    'model_realtime2_mode': model_status_realtime2['mode'],
    'model_realtime2_model': model_status_realtime2['model'],
    'task_id': run['task_id'],
    'model_task_id': model_run['task_id'],
    'model_repair_trajectory_events': get_model_repaired_trajectory['count'],
    'model_broker_task_id': model_broker_run['task_id'],
    'trajectory_exists': pathlib.Path(run['trajectory']).exists(),
    'trajectory_events': get_trajectory['count'],
    'model_trajectory_events': get_model_trajectory['count'],
    'model_cancel_trajectory_events': get_model_cancel_trajectory['count'],
    'model_broker_trajectory_events': get_model_broker_trajectory['count'],
    'audit_events': get_audit['count'],
    'validated_audit_events': validate_store['audit_events'],
    'audit_bytes': base.joinpath('store/audit/audit-events.jsonl').stat().st_size,
}, indent=2))
PY
