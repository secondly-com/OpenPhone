#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
mode="baseline"
run_id="$(date '+%Y%m%dT%H%M%S%z')"

usage() {
  cat <<'EOF'
Usage:
  tools/mac/agentd/validate-on-device.sh [--mode baseline|full|collect-only] [--run-id RUN_ID]

Environment:
  OPENPHONE_IOS_HOST                  SSH host, default 127.0.0.1
  OPENPHONE_IOS_SSH_PORT              SSH port, default 22
  OPENPHONE_IOS_USER                  SSH user, default mobile
  OPENPHONE_IOS_PASSWORD              Optional development password
  OPENPHONE_IOS_KNOWN_HOSTS           Known-hosts file, default /tmp/openphone-ios-known-hosts
  OPENPHONE_IOS_UDID                  Target iPhone UDID for temporary iproxy
  OPENPHONE_IOS_EXPECTED_DEVICE_NAME  Optional remote uname -n guard, for example <your-device-name>
  OPENPHONE_IOS_EXPECTED_PRODUCT_TYPE Optional remote uname guard, for example iPhone15,3
  OPENPHONE_AGENTD_DEB                Optional explicit package path
  OPENPHONE_VALIDATION_DIR            Output root, default artifacts/validation
  OPENPHONE_VALIDATE_START_IPROXY     Set to 1 to start a temporary iproxy tunnel
  OPENPHONE_VALIDATE_ALLOW_UNPINNED_IPROXY
                                      Set to 1 only for a confirmed single-device setup
  OPENPHONE_VALIDATE_ALLOW_EXISTING_IPROXY
                                      Set to 1 to use an existing listener when START_IPROXY=1
  OPENPHONE_VALIDATE_INCLUDE_SCREENSHOT
                                      Set to 1 to run get_screen screenshot and pull the PNG
  OPENPHONE_VALIDATE_INCLUDE_UNLOCKED_FOREGROUND
                                      Set to 1 to launch Safari and verify unlocked foreground source
  OPENPHONE_VALIDATE_INCLUDE_APP_UI   Set to 1 to relaunch Safari/Settings and verify app-process UI trees
  OPENPHONE_VALIDATE_INCLUDE_LOCKSCREEN
                                      Set to 1 to verify locked SpringBoard show_passcode behavior.
  OPENPHONE_VALIDATE_INCLUDE_PREFS_UI Set to 1 to open and exercise the OpenPhone Settings pane. Requires unlocked phone.
  OPENPHONE_VALIDATE_INCLUDE_PREFS_BACKEND
                                      Set to 1 to verify OpenPhone Settings pane files and daemon policy controls
  OPENPHONE_VALIDATE_INCLUDE_STORES   Set to 1 to collect safe store/task reads
  OPENPHONE_VALIDATE_INCLUDE_PROVIDER_ATTEMPTS
                                      Set to 1 to run a no-dispatch provider-attempt shape sample
  OPENPHONE_VALIDATE_INCLUDE_VISIBLE_EFFECTS
                                      Set to 1 to verify real UI visible effects and screenshot-hash changes for Settings tap, Safari DOM text entry, and Notes body text entry
  OPENPHONE_VALIDATE_INCLUDE_MEMORY_LIFECYCLE
                                      Set to 1 to run memory save/update/merge/delete lifecycle sample
  OPENPHONE_VALIDATE_INCLUDE_MODEL_LOOP
                                      Set to 1 to run a fixture-backed model-loop task sample
  OPENPHONE_VALIDATE_INCLUDE_VOICE     Set to 1 to snapshot voice_status + island-status + credential presence
  OPENPHONE_VALIDATE_INCLUDE_WATCHER_TIMER
                                      Set to 1 to run a due timer watcher firing sample
  OPENPHONE_VALIDATE_INCLUDE_WATCHER_REPAIR
                                      Set to 1 to run a stale watcher repair sample
  OPENPHONE_VALIDATE_INCLUDE_JOB_REPAIR
                                      Set to 1 to run a stale background-job repair sample
  OPENPHONE_VALIDATE_INCLUDE_RESTART_RECOVERY
                                      Set to 1 to restart daemon with stale watcher/job rows
  OPENPHONE_VALIDATE_RESTART_RECOVERY_WAIT_SECONDS
                                      Seconds to wait after daemon restart before grading recovery
  OPENPHONE_VALIDATE_RESTART_RECOVERY_START_TIMEOUT_SECONDS
                                      Seconds to wait for launchd to restart daemon
  OPENPHONE_VALIDATE_RESTART_RECOVERY_STABLE_SECONDS
                                      Seconds the restarted daemon PID must remain stable
  OPENPHONE_VALIDATE_INCLUDE_PROVIDER_MODEL
                                      Set to 1 to run a provider-backed Bedrock broker model sample
  OPENPHONE_VALIDATE_INCLUDE_SAFARI_DOM_MODEL
                                      Set to 1 to run a direct Bedrock Safari DOM text-entry model sample.
                                      Uses an existing phone credential file when present; otherwise requires a Bedrock token env var.
  OPENPHONE_VALIDATE_INCLUDE_PROMPT_BRIDGE_MODEL
                                      Set to 1 to run the SpringBoard prompt bridge into the phone-local model loop.
                                      Requires the phone to be unlocked and the current model config to be ready.
  OPENPHONE_VALIDATE_INCLUDE_TRIGGER_DIAGNOSTICS
                                      Set to 1 to wait for a real physical Volume Up + Volume Down press and compare
                                      before/after SpringBoard trigger counters. Requires an unlocked phone and a
                                      human pressing the hardware buttons during the wait window.
  OPENPHONE_VALIDATE_TRIGGER_WAIT_SECONDS
                                      Seconds to wait for the physical trigger diagnostic window, default 20.
  AWS_BEARER_TOKEN_BEDROCK           Bedrock API key for provider-backed validation
  OPENPHONE_BEDROCK_BEARER_TOKEN     Alternate Bedrock API key env var
  OPENPHONE_BEDROCK_MODEL            Bedrock model id, default Claude Haiku 4.5
  OPENPHONE_BEDROCK_REGION           Bedrock region, default us-east-1
  OPENPHONE_VALIDATE_PROVIDER_MODEL_PHONE_PORT
                                      Phone-local reverse-forward port, default 18765
  OPENPHONE_VALIDATE_REQUIRE_UNLOCKED Set to 1 to require the unlocked foreground gate

Modes:
  baseline      local preflight, package build/install, health/stability collection
  full          baseline plus safe store/task collection
  collect-only  no build/install; collect current device state only
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      mode="${2:-}"
      shift 2
      ;;
    --run-id)
      run_id="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$mode" in
  baseline|full|collect-only) ;;
  *)
    echo "invalid mode: $mode" >&2
    exit 2
    ;;
esac

if [[ ! "$run_id" =~ ^[A-Za-z0-9_.:+-]+$ ]]; then
  echo "invalid run id: $run_id" >&2
  exit 2
fi

host="${OPENPHONE_IOS_HOST:-127.0.0.1}"
port="${OPENPHONE_IOS_SSH_PORT:-22}"
user="${OPENPHONE_IOS_USER:-mobile}"
password="${OPENPHONE_IOS_PASSWORD:-}"
known_hosts="${OPENPHONE_IOS_KNOWN_HOSTS:-/tmp/openphone-ios-known-hosts}"
validation_root="${OPENPHONE_VALIDATION_DIR:-$repo_root/artifacts/validation}"
run_dir="$validation_root/$run_id"
remote_tmp="/tmp/openphone-validation-$run_id"
ssh_target="$user@$host"
tail_lines="${OPENPHONE_VALIDATE_TAIL_LINES:-160}"
package="${OPENPHONE_AGENTD_DEB:-}"
target_udid="${OPENPHONE_IOS_UDID:-${OPENPHONE_VALIDATE_IPROXY_UDID:-}}"
started_iproxy_pid=""
remote_tmp_created=0
provider_broker_pid=""
provider_ssh_pid=""
provider_broker_port=""
provider_phone_port="${OPENPHONE_VALIDATE_PROVIDER_MODEL_PHONE_PORT:-18765}"
direct_bedrock_credential_touched=0
direct_bedrock_credential_had_backup=0
direct_bedrock_credential_temp=""
direct_bedrock_config_touched=0
direct_bedrock_config_had_backup=0
trigger_wait_seconds="${OPENPHONE_VALIDATE_TRIGGER_WAIT_SECONDS:-20}"

if [[ ! "$tail_lines" =~ ^[0-9]+$ ]]; then
  echo "invalid OPENPHONE_VALIDATE_TAIL_LINES: $tail_lines" >&2
  exit 2
fi
if [[ ! "$trigger_wait_seconds" =~ ^[0-9]+$ ]]; then
  echo "invalid OPENPHONE_VALIDATE_TRIGGER_WAIT_SECONDS: $trigger_wait_seconds" >&2
  exit 2
fi

mkdir -p "$run_dir"
summary_log="$run_dir/validate.log"
: >"$summary_log"

log() {
  printf '%s\n' "$*" | tee -a "$summary_log"
}

fail() {
  local code="$1"
  shift
  log "ERROR: $*"
  exit "$code"
}

redact_udid() {
  local value="$1"
  if [[ -z "$value" ]]; then
    printf '%s\n' ""
  elif [[ "${#value}" -le 8 ]]; then
    printf '%s\n' "..."
  else
    printf '%s\n' "...${value: -8}"
  fi
}

cleanup() {
  if [[ "$direct_bedrock_config_touched" == "1" ]]; then
    if [[ "$direct_bedrock_config_had_backup" == "1" ]]; then
      remote_exec "install -m 0600 '$remote_tmp/model-config.backup' /var/mobile/Library/OpenPhone/config/model.json" "$run_dir/cleanup.log" >/dev/null 2>&1 || true
    else
      remote_exec "rm -f /var/mobile/Library/OpenPhone/config/model.json" "$run_dir/cleanup.log" >/dev/null 2>&1 || true
    fi
  fi
  if [[ "$direct_bedrock_credential_touched" == "1" ]]; then
    if [[ "$direct_bedrock_credential_had_backup" == "1" ]]; then
      remote_exec "install -m 0600 '$remote_tmp/model-credential.backup' /var/mobile/Library/OpenPhone/config/model-credential.json" "$run_dir/cleanup.log" >/dev/null 2>&1 || true
    else
      remote_exec "rm -f /var/mobile/Library/OpenPhone/config/model-credential.json" "$run_dir/cleanup.log" >/dev/null 2>&1 || true
    fi
  fi
  if [[ -n "$direct_bedrock_credential_temp" ]]; then
    rm -f "$direct_bedrock_credential_temp" >/dev/null 2>&1 || true
  fi
  if [[ "$remote_tmp_created" == "1" && "${OPENPHONE_VALIDATE_KEEP_REMOTE_TMP:-0}" != "1" ]]; then
    remote_exec "rm -rf '$remote_tmp'" "$run_dir/cleanup.log" >/dev/null 2>&1 || true
  fi
  if [[ -n "$started_iproxy_pid" ]]; then
    kill "$started_iproxy_pid" >/dev/null 2>&1 || true
    wait "$started_iproxy_pid" >/dev/null 2>&1 || true
  fi
  if [[ -n "$provider_ssh_pid" ]]; then
    kill "$provider_ssh_pid" >/dev/null 2>&1 || true
    wait "$provider_ssh_pid" >/dev/null 2>&1 || true
  fi
  if [[ -n "$provider_broker_pid" ]]; then
    kill "$provider_broker_pid" >/dev/null 2>&1 || true
    wait "$provider_broker_pid" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "${2:-10}" "missing required command: $1"
  fi
}

run_local() {
  local name="$1"
  local code="$2"
  shift 2
  local log_path="$run_dir/$name.log"
  log "Running $name"
  if ! "$@" >"$log_path" 2>&1; then
    fail "$code" "$name failed; see $log_path"
  fi
}

run_expect_ssh() {
  local remote_cmd="$1"
  local log_path="$2"
  OPENPHONE_IOS_PASSWORD="$password" expect -f - -- \
    "$port" "$known_hosts" "$ssh_target" "$remote_cmd" >>"$log_path" 2>&1 <<'EXPECT'
set timeout 180
set port [lindex $argv 0]
set known_hosts [lindex $argv 1]
set target [lindex $argv 2]
set remote_cmd [lindex $argv 3]
spawn ssh -p $port -o StrictHostKeyChecking=no -o UserKnownHostsFile=$known_hosts $target $remote_cmd
expect {
  -nocase -re "yes/no" { send "yes\r"; exp_continue }
  -nocase -re "password.*:" { send "$env(OPENPHONE_IOS_PASSWORD)\r"; exp_continue }
  eof {}
  timeout { exit 124 }
}
catch wait result
exit [lindex $result 3]
EXPECT
}

run_expect_ssh_reverse() {
  local remote_port="$1"
  local local_port="$2"
  local log_path="$3"
  OPENPHONE_IOS_PASSWORD="$password" expect -f - -- \
    "$port" "$known_hosts" "$ssh_target" "$remote_port" "$local_port" >>"$log_path" 2>&1 <<'EXPECT'
set timeout 180
set port [lindex $argv 0]
set known_hosts [lindex $argv 1]
set target [lindex $argv 2]
set remote_port [lindex $argv 3]
set local_port [lindex $argv 4]
spawn ssh -N -p $port -o StrictHostKeyChecking=no -o UserKnownHostsFile=$known_hosts -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -R 127.0.0.1:$remote_port:127.0.0.1:$local_port $target
expect {
  -nocase -re "yes/no" { send "yes\r"; exp_continue }
  -nocase -re "password.*:" { send "$env(OPENPHONE_IOS_PASSWORD)\r"; exp_continue }
  eof { exit 1 }
  timeout { }
}
expect eof
EXPECT
}

start_ssh_reverse_forward() {
  local remote_port="$1"
  local local_port="$2"
  local log_path="$run_dir/provider-model-ssh-reverse.log"
  if [[ -n "$password" ]]; then
    require_command expect 30
    run_expect_ssh_reverse "$remote_port" "$local_port" "$log_path" &
    provider_ssh_pid="$!"
  else
    ssh -N -p "$port" \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile="$known_hosts" \
      -o ExitOnForwardFailure=yes \
      -o ServerAliveInterval=15 \
      -R "127.0.0.1:$remote_port:127.0.0.1:$local_port" \
      "$ssh_target" >>"$log_path" 2>&1 &
    provider_ssh_pid="$!"
  fi
  sleep 2
  if ! kill -0 "$provider_ssh_pid" >/dev/null 2>&1; then
    fail 100 "provider model SSH reverse tunnel failed; see $log_path"
  fi
}

remote_exec() {
  local remote_cmd="$1"
  local log_path="${2:-$run_dir/ssh.log}"
  if [[ -n "$password" ]]; then
    require_command expect 30
    run_expect_ssh "$remote_cmd" "$log_path"
  else
    ssh -p "$port" -o StrictHostKeyChecking=no -o UserKnownHostsFile="$known_hosts" \
      "$ssh_target" "$remote_cmd" >>"$log_path" 2>&1
  fi
}

run_expect_scp_from() {
  local remote_path="$1"
  local local_path="$2"
  local log_path="$3"
  OPENPHONE_IOS_PASSWORD="$password" expect -f - -- \
    "$port" "$known_hosts" "$ssh_target:$remote_path" "$local_path" >>"$log_path" 2>&1 <<'EXPECT'
set timeout 180
set port [lindex $argv 0]
set known_hosts [lindex $argv 1]
set source [lindex $argv 2]
set dest [lindex $argv 3]
spawn scp -P $port -o StrictHostKeyChecking=no -o UserKnownHostsFile=$known_hosts $source $dest
expect {
  -nocase -re "yes/no" { send "yes\r"; exp_continue }
  -nocase -re "password.*:" { send "$env(OPENPHONE_IOS_PASSWORD)\r"; exp_continue }
  eof {}
  timeout { exit 124 }
}
catch wait result
exit [lindex $result 3]
EXPECT
}

run_expect_scp_to() {
  local local_path="$1"
  local remote_path="$2"
  local log_path="$3"
  OPENPHONE_IOS_PASSWORD="$password" expect -f - -- \
    "$port" "$known_hosts" "$local_path" "$ssh_target:$remote_path" >>"$log_path" 2>&1 <<'EXPECT'
set timeout 180
set port [lindex $argv 0]
set known_hosts [lindex $argv 1]
set source [lindex $argv 2]
set dest [lindex $argv 3]
spawn scp -P $port -o StrictHostKeyChecking=no -o UserKnownHostsFile=$known_hosts $source $dest
expect {
  -nocase -re "yes/no" { send "yes\r"; exp_continue }
  -nocase -re "password.*:" { send "$env(OPENPHONE_IOS_PASSWORD)\r"; exp_continue }
  eof {}
  timeout { exit 124 }
}
catch wait result
exit [lindex $result 3]
EXPECT
}

scp_from() {
  local remote_path="$1"
  local local_path="$2"
  local log_path="${3:-$run_dir/scp.log}"
  mkdir -p "$(dirname "$local_path")"
  if [[ -n "$password" ]]; then
    require_command expect 30
    run_expect_scp_from "$remote_path" "$local_path" "$log_path"
  else
    scp -P "$port" -o StrictHostKeyChecking=no -o UserKnownHostsFile="$known_hosts" \
      "$ssh_target:$remote_path" "$local_path" >>"$log_path" 2>&1
  fi
}

scp_to() {
  local local_path="$1"
  local remote_path="$2"
  local log_path="${3:-$run_dir/scp.log}"
  if [[ -n "$password" ]]; then
    require_command expect 30
    run_expect_scp_to "$local_path" "$remote_path" "$log_path"
  else
    scp -P "$port" -o StrictHostKeyChecking=no -o UserKnownHostsFile="$known_hosts" \
      "$local_path" "$ssh_target:$remote_path" >>"$log_path" 2>&1
  fi
}

remote_capture() {
  local name="$1"
  local command="$2"
  local remote_path="$remote_tmp/$name"
  local status_path="$remote_path.status"
  remote_exec "mkdir -p '$remote_tmp'; ( $command ) > '$remote_path' 2> '$remote_path.stderr'; printf '%s\n' \$? > '$status_path'; exit 0"
  remote_tmp_created=1
  scp_from "$remote_path" "$run_dir/$name"
  scp_from "$remote_path.stderr" "$run_dir/$name.stderr" || true
  scp_from "$status_path" "$run_dir/$name.status" || true
}

start_iproxy_if_requested() {
  if [[ "${OPENPHONE_VALIDATE_START_IPROXY:-0}" != "1" ]]; then
    return
  fi
  require_command iproxy 30
  if [[ -z "$target_udid" && "${OPENPHONE_VALIDATE_ALLOW_UNPINNED_IPROXY:-0}" != "1" ]]; then
    fail 30 "refusing to start or reuse iproxy without OPENPHONE_IOS_UDID; set OPENPHONE_VALIDATE_ALLOW_UNPINNED_IPROXY=1 only for a confirmed single-device setup"
  fi
  if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    if [[ "${OPENPHONE_VALIDATE_ALLOW_EXISTING_IPROXY:-0}" != "1" ]]; then
      fail 30 "local port $port already has a listener; stop it or set OPENPHONE_VALIDATE_ALLOW_EXISTING_IPROXY=1 after confirming it targets the intended iPhone"
    fi
    log "Using existing listener on local port $port by explicit override"
    return
  fi
  local device_port="${OPENPHONE_VALIDATE_IPROXY_DEVICE_PORT:-22}"
  local -a iproxy_args=()
  if [[ -n "$target_udid" ]]; then
    iproxy_args=(-u "$target_udid")
    log "Starting temporary pinned iproxy $port:$device_port for UDID $(redact_udid "$target_udid")"
  else
    log "Starting temporary unpinned iproxy $port:$device_port"
  fi
  iproxy "${iproxy_args[@]}" "$port:$device_port" >"$run_dir/iproxy.log" 2>&1 &
  started_iproxy_pid="$!"
  sleep 2
  if ! lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    fail 30 "iproxy did not start; see $run_dir/iproxy.log"
  fi
}

check_remote_target_identity() {
  local expected_name="${OPENPHONE_IOS_EXPECTED_DEVICE_NAME:-}"
  local expected_product="${OPENPHONE_IOS_EXPECTED_PRODUCT_TYPE:-}"
  if [[ -z "$expected_name" && -z "$expected_product" ]]; then
    return
  fi
  log "Checking remote target identity"
  remote_capture "target-identity.txt" \
    'printf "nodename=%s\n" "$(uname -n 2>/dev/null || true)"; printf "uname=%s\n" "$(uname -a 2>/dev/null || true)"'
  if ! OPENPHONE_EXPECTED_DEVICE_NAME="$expected_name" \
      OPENPHONE_EXPECTED_PRODUCT_TYPE="$expected_product" \
      OPENPHONE_TARGET_IDENTITY_PATH="$run_dir/target-identity.txt" \
      python3 - <<'PY'
import os
import pathlib
import sys

path = pathlib.Path(os.environ["OPENPHONE_TARGET_IDENTITY_PATH"])
expected_name = os.environ.get("OPENPHONE_EXPECTED_DEVICE_NAME", "")
expected_product = os.environ.get("OPENPHONE_EXPECTED_PRODUCT_TYPE", "")
fields = {}
for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
    if "=" in line:
        key, value = line.split("=", 1)
        fields[key.strip()] = value.strip()

errors = []
if expected_name and fields.get("nodename") != expected_name:
    errors.append(f"device_name:{fields.get('nodename', '')}")
if expected_product and expected_product not in fields.get("uname", ""):
    errors.append(f"product_type_missing:{expected_product}")
if errors:
    print("; ".join(errors), file=sys.stderr)
    sys.exit(1)
PY
  then
    fail 30 "remote target identity did not match expected iPhone; see $run_dir/target-identity.txt"
  fi
}

collect_safety() {
  local suffix="$1"
  local crash_name="springboard-crashes.txt"
  local marker_name="safe-mode-markers.txt"
  if [[ -n "$suffix" ]]; then
    crash_name="springboard-crashes.$suffix.txt"
    marker_name="safe-mode-markers.$suffix.txt"
  fi
  remote_capture "$crash_name" \
    'find /var/mobile/Library/Logs/CrashReporter /private/var/mobile/Library/Logs/CrashReporter -name SpringBoard-\*.ips -type f -print 2>/dev/null | sort | tail -20'
  remote_capture "$marker_name" \
    'for p in /private/var/mobile/.eksafemode /var/mobile/Library/Preferences/.eksafemode; do if [ -e "$p" ]; then ls -ld "$p"; fi; done'
}

check_preinstall_safety() {
  local marker_file="$run_dir/safe-mode-markers.before.txt"
  if [[ -s "$marker_file" ]]; then
    fail 40 "safe-mode marker present before install; see $marker_file"
  fi
}

check_stability_gate() {
  local marker_file="$run_dir/safe-mode-markers.txt"
  if [[ -s "$marker_file" ]]; then
    generate_report >/dev/null
    fail 40 "safe-mode marker present after device collection; see $marker_file"
  fi
  if OPENPHONE_VALIDATE_RUN_DIR="$run_dir" python3 - <<'PY'
import pathlib
import sys

run_dir = pathlib.Path(__import__("os").environ["OPENPHONE_VALIDATE_RUN_DIR"])

def latest(name):
    path = run_dir / name
    if not path.exists():
        return ""
    names = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if line:
            names.append(pathlib.Path(line).name)
    return max(set(names)) if names else ""

before = latest("springboard-crashes.before.txt")
after = latest("springboard-crashes.txt")
if before and after and after > before:
    print(f"new SpringBoard crash after install: {after} > {before}", file=sys.stderr)
    sys.exit(40)
PY
  then
    return
  else
    local code=$?
    generate_report >/dev/null
    fail "$code" "SpringBoard stability gate failed; see $run_dir/report.json"
  fi
}

collect_device_state() {
  log "Collecting device state"
  remote_capture "health.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  remote_capture "get-screen.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl get_screen; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  collect_safety ""
  remote_capture "processes.txt" \
    'ps -A 2>/dev/null | grep "[o]penphone-agentd" || true'
  remote_capture "openphone-agentd.log.tail" \
    "if [ -f /var/mobile/Library/OpenPhone/openphone-agentd.log ]; then tail -n $tail_lines /var/mobile/Library/OpenPhone/openphone-agentd.log; fi"
  remote_capture "openphone-volume-trigger.log.tail" \
    "if [ -f /var/mobile/Library/OpenPhone/openphone-volume-trigger.log ]; then tail -n $tail_lines /var/mobile/Library/OpenPhone/openphone-volume-trigger.log; fi"
  remote_capture "springboard-state.json" \
    'if [ -f /var/mobile/Library/OpenPhone/springboard/state.json ]; then cat /var/mobile/Library/OpenPhone/springboard/state.json; else printf "%s\n" "{}"; fi'
  remote_capture "springboard-trigger-status.json" \
    'if [ -f /var/mobile/Library/OpenPhone/springboard/trigger-status.json ]; then cat /var/mobile/Library/OpenPhone/springboard/trigger-status.json; else printf "%s\n" "{}"; fi'
}

collect_trigger_diagnostics_sample() {
  if [[ "${OPENPHONE_VALIDATE_INCLUDE_TRIGGER_DIAGNOSTICS:-0}" != "1" ]]; then
    return
  fi
  log "Collecting physical trigger diagnostics"
  remote_capture "trigger-diagnostics-before-status.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl agent_status; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  remote_capture "trigger-diagnostics-before-trigger.json" \
    'if [ -f /var/mobile/Library/OpenPhone/springboard/trigger-status.json ]; then cat /var/mobile/Library/OpenPhone/springboard/trigger-status.json; else printf "%s\n" "{}"; fi'

  log "Waiting ${trigger_wait_seconds}s for a real Volume Up then Volume Down press on the unlocked phone"
  sleep "$trigger_wait_seconds"

  remote_capture "trigger-diagnostics-after-status.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl agent_status; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  remote_capture "trigger-diagnostics-after-trigger.json" \
    'if [ -f /var/mobile/Library/OpenPhone/springboard/trigger-status.json ]; then cat /var/mobile/Library/OpenPhone/springboard/trigger-status.json; else printf "%s\n" "{}"; fi'
  remote_capture "trigger-diagnostics-list-tasks.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl list_tasks 10; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  remote_capture "trigger-diagnostics-tweak-log-tail.txt" \
    "if [ -f /var/mobile/Library/OpenPhone/openphone-volume-trigger.log ]; then tail -n $tail_lines /var/mobile/Library/OpenPhone/openphone-volume-trigger.log; fi"

  local latest_task_id
  latest_task_id="$(json_field "$run_dir/trigger-diagnostics-after-status.json" "latest_task.task_id")"
  if [[ -n "$latest_task_id" && "$latest_task_id" =~ ^[A-Za-z0-9_.:-]+$ ]]; then
    remote_capture "trigger-diagnostics-latest-trajectory.json" \
      "if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl get_trajectory '$latest_task_id' 120; else printf '%s\n' '{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}'; fi"
  else
    printf '%s\n' '{"status":"skipped","reason":"missing_latest_task_id"}' >"$run_dir/trigger-diagnostics-latest-trajectory.json"
  fi
}

collect_safe_store_state() {
  log "Collecting safe store/task state"
  remote_capture "list-tasks.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl list_tasks 10; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  local latest_task_id
  latest_task_id="$(OPENPHONE_LIST_TASKS_JSON="$run_dir/list-tasks.json" python3 - <<'PY'
import json
import os
import re
import sys

try:
    data = json.load(open(os.environ["OPENPHONE_LIST_TASKS_JSON"], "r", encoding="utf-8"))
except Exception:
    sys.exit(0)

tasks = data.get("tasks")
if not isinstance(tasks, list) or not tasks:
    sys.exit(0)

task_id = tasks[0].get("task_id") if isinstance(tasks[0], dict) else ""
if isinstance(task_id, str) and re.match(r"^[A-Za-z0-9_.:-]+$", task_id):
    print(task_id)
PY
)"
  if [[ -n "$latest_task_id" ]]; then
    remote_capture "get-task.json" \
      "if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl get_task '$latest_task_id'; else printf '%s\n' '{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}'; fi"
    remote_capture "get-trajectory.json" \
      "if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl get_trajectory '$latest_task_id' 50; else printf '%s\n' '{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}'; fi"
  else
    printf '%s\n' '{"status":"skipped","reason":"no_safe_task_id"}' >"$run_dir/get-task.json"
    printf '%s\n' '{"status":"skipped","reason":"no_safe_task_id"}' >"$run_dir/get-trajectory.json"
  fi
  remote_capture "get-audit.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl get_audit 30; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  remote_capture "memory-search.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl memory_search OpenPhone 5; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  remote_capture "context-search.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl context_search OpenPhone 5; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  remote_capture "background-job-list.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl background_job_list durable 10; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  remote_capture "commitment-search.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl commitment_search OpenPhone 10; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  remote_capture "watcher-list.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl watcher_list OpenPhone 10; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
}

collect_provider_attempt_sample() {
  if [[ "${OPENPHONE_VALIDATE_INCLUDE_PROVIDER_ATTEMPTS:-0}" != "1" ]]; then
    return
  fi
  log "Collecting provider-attempt no-dispatch sample"
  remote_capture "provider-attempt-start-task.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl '"'"'{"command":"start_task","goal":"validator provider-attempt no-dispatch sample","approved_capabilities":["input.perform","tasks.observe"]}'"'"'; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  local sample_task_id
  sample_task_id="$(OPENPHONE_PROVIDER_ATTEMPT_START_JSON="$run_dir/provider-attempt-start-task.json" python3 - <<'PY'
import json
import os
import re
import sys

try:
    data = json.load(open(os.environ["OPENPHONE_PROVIDER_ATTEMPT_START_JSON"], "r", encoding="utf-8"))
except Exception:
    sys.exit(0)

task_id = data.get("task_id")
if isinstance(task_id, str) and re.match(r"^[A-Za-z0-9_.:-]+$", task_id):
    print(task_id)
PY
)"
  if [[ -n "$sample_task_id" ]]; then
    remote_capture "provider-attempt-action.json" \
      "if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl '{\"command\":\"execute_action\",\"task_id\":\"$sample_task_id\",\"action\":{\"type\":\"tap\",\"reason\":\"validator provider-attempt missing-coordinate sample\"}}'; else printf '%s\n' '{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}'; fi"
    remote_capture "provider-attempt-trajectory.json" \
      "if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl get_trajectory '$sample_task_id' 20; else printf '%s\n' '{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}'; fi"
  else
    printf '%s\n' '{"status":"skipped","reason":"no_provider_attempt_sample_task_id"}' >"$run_dir/provider-attempt-action.json"
    printf '%s\n' '{"status":"skipped","reason":"no_provider_attempt_sample_task_id"}' >"$run_dir/provider-attempt-trajectory.json"
  fi
}

collect_watcher_timer_sample() {
  if [[ "${OPENPHONE_VALIDATE_INCLUDE_WATCHER_TIMER:-0}" != "1" ]]; then
    return
  fi
  log "Collecting timer watcher firing sample"
  remote_capture "watcher-timer-create.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then now_ms=$(($(date +%s) * 1000 - 1000)); /var/jb/usr/local/bin/openphone-agentctl "{\"command\":\"watcher_create\",\"title\":\"validator timer watcher\",\"source\":\"time\",\"type\":\"time\",\"next_run_at\":$now_ms,\"prompt\":\"summarize validator timer watcher\",\"reason\":\"validator timer watcher gate\"}"; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  remote_capture "watcher-timer-run-due.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl "{\"command\":\"watcher_run_due\",\"limit\":5,\"source\":\"validator_watcher_timer_gate\",\"reason\":\"validator timer watcher gate\"}"; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  remote_capture "watcher-timer-job-run-due.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl background_job_run_due 5 1 15000; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  remote_capture "watcher-timer-job-list.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl background_job_list "validator timer watcher" 10; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  remote_capture "watcher-timer-after-list.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl watcher_list "validator timer watcher" 5; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  local watcher_id
  watcher_id="$(OPENPHONE_WATCHER_TIMER_CREATE_JSON="$run_dir/watcher-timer-create.json" python3 - <<'PY'
import json
import os
import re
import sys

try:
    data = json.load(open(os.environ["OPENPHONE_WATCHER_TIMER_CREATE_JSON"], "r", encoding="utf-8"))
except Exception:
    sys.exit(0)

watcher_id = data.get("watcher_id")
if isinstance(watcher_id, int):
    print(watcher_id)
elif isinstance(watcher_id, str) and re.match(r"^[A-Za-z0-9_.:-]+$", watcher_id):
    print(watcher_id)
PY
)"
  if [[ -n "$watcher_id" ]]; then
    remote_capture "watcher-timer-stop.json" \
      "if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl watcher_stop '$watcher_id'; else printf '%s\n' '{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}'; fi"
  else
    printf '%s\n' '{"status":"skipped","reason":"no_watcher_timer_id"}' >"$run_dir/watcher-timer-stop.json"
  fi
}

collect_watcher_repair_sample() {
  if [[ "${OPENPHONE_VALIDATE_INCLUDE_WATCHER_REPAIR:-0}" != "1" ]]; then
    return
  fi
  log "Collecting stale watcher repair sample"
  remote_capture "watcher-repair-create.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then future_ms=$(($(date +%s) * 1000 + 600000)); /var/jb/usr/local/bin/openphone-agentctl "{\"command\":\"watcher_create\",\"title\":\"validator watcher stuck repair\",\"source\":\"time\",\"type\":\"time\",\"next_run_at\":$future_ms,\"prompt\":\"summarize validator watcher stuck repair\",\"reason\":\"validator watcher stuck repair gate\"}"; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  local watcher_id
  watcher_id="$(OPENPHONE_WATCHER_REPAIR_CREATE_JSON="$run_dir/watcher-repair-create.json" python3 - <<'PY'
import json
import os
import re
import sys

try:
    data = json.load(open(os.environ["OPENPHONE_WATCHER_REPAIR_CREATE_JSON"], "r", encoding="utf-8"))
except Exception:
    sys.exit(0)

watcher_id = data.get("watcher_id")
if isinstance(watcher_id, int):
    print(watcher_id)
elif isinstance(watcher_id, str) and re.match(r"^[A-Za-z0-9_.:-]+$", watcher_id):
    print(watcher_id)
PY
)"
  if [[ -n "$watcher_id" ]]; then
    remote_capture "watcher-repair-mark-running.json" \
      "if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl '{\"command\":\"watcher_debug_mark_running\",\"watcher_id\":$watcher_id,\"validation\":true,\"age_ms\":600000,\"source\":\"validator_watcher_stuck_repair_gate\"}'; else printf '%s\n' '{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}'; fi"
    remote_capture "watcher-repair-run.json" \
      "if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl '{\"command\":\"watcher_repair_stuck\",\"limit\":5,\"stale_after_ms\":1000,\"source\":\"validator_watcher_stuck_repair_gate\"}'; else printf '%s\n' '{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}'; fi"
    remote_capture "watcher-repair-run-due.json" \
      'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl "{\"command\":\"watcher_run_due\",\"limit\":5,\"source\":\"validator_watcher_repair_gate\",\"reason\":\"validator watcher repair gate\"}"; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
    remote_capture "watcher-repair-job-run-due.json" \
      'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl background_job_run_due 5 1 15000; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
    remote_capture "watcher-repair-after-list.json" \
      'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl watcher_list "validator watcher stuck repair" 5; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
    remote_capture "watcher-repair-stop.json" \
      "if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl watcher_stop '$watcher_id'; else printf '%s\n' '{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}'; fi"
  else
    printf '%s\n' '{"status":"skipped","reason":"no_watcher_repair_id"}' >"$run_dir/watcher-repair-mark-running.json"
    printf '%s\n' '{"status":"skipped","reason":"no_watcher_repair_id"}' >"$run_dir/watcher-repair-run.json"
    printf '%s\n' '{"status":"skipped","reason":"no_watcher_repair_id"}' >"$run_dir/watcher-repair-run-due.json"
    printf '%s\n' '{"status":"skipped","reason":"no_watcher_repair_id"}' >"$run_dir/watcher-repair-job-run-due.json"
    printf '%s\n' '{"status":"skipped","reason":"no_watcher_repair_id"}' >"$run_dir/watcher-repair-after-list.json"
    printf '%s\n' '{"status":"skipped","reason":"no_watcher_repair_id"}' >"$run_dir/watcher-repair-stop.json"
  fi
}

collect_job_repair_sample() {
  if [[ "${OPENPHONE_VALIDATE_INCLUDE_JOB_REPAIR:-0}" != "1" ]]; then
    return
  fi
  log "Collecting stale background-job repair sample"
  remote_capture "job-repair-create.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then future_ms=$(($(date +%s) * 1000 + 600000)); /var/jb/usr/local/bin/openphone-agentctl "{\"command\":\"background_job_create\",\"title\":\"validator stuck repair job\",\"prompt\":\"summarize validator stuck repair job\",\"next_run_at\":$future_ms,\"reason\":\"validator stuck repair gate\"}"; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  local job_id
  job_id="$(OPENPHONE_JOB_REPAIR_CREATE_JSON="$run_dir/job-repair-create.json" python3 - <<'PY'
import json
import os
import re
import sys

try:
    data = json.load(open(os.environ["OPENPHONE_JOB_REPAIR_CREATE_JSON"], "r", encoding="utf-8"))
except Exception:
    sys.exit(0)

job_id = data.get("job_id")
if isinstance(job_id, int):
    print(job_id)
elif isinstance(job_id, str) and re.match(r"^[A-Za-z0-9_.:-]+$", job_id):
    print(job_id)
PY
)"
  if [[ -n "$job_id" ]]; then
    remote_capture "job-repair-mark-running.json" \
      "if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl '{\"command\":\"background_job_debug_mark_running\",\"job_id\":$job_id,\"validation\":true,\"age_ms\":600000,\"source\":\"validator_stuck_repair_gate\"}'; else printf '%s\n' '{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}'; fi"
    remote_capture "job-repair-run.json" \
      "if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl '{\"command\":\"background_job_repair_stuck\",\"limit\":5,\"stale_after_ms\":1000,\"source\":\"validator_stuck_repair_gate\"}'; else printf '%s\n' '{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}'; fi"
    remote_capture "job-repair-run-due.json" \
      'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl background_job_run_due 5 1 15000; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
    remote_capture "job-repair-list.json" \
      'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl background_job_list "validator stuck repair" 10; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
    remote_capture "job-repair-stop.json" \
      "if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl background_job_stop '$job_id'; else printf '%s\n' '{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}'; fi"
  else
    printf '%s\n' '{"status":"skipped","reason":"no_job_repair_id"}' >"$run_dir/job-repair-mark-running.json"
    printf '%s\n' '{"status":"skipped","reason":"no_job_repair_id"}' >"$run_dir/job-repair-run.json"
    printf '%s\n' '{"status":"skipped","reason":"no_job_repair_id"}' >"$run_dir/job-repair-run-due.json"
    printf '%s\n' '{"status":"skipped","reason":"no_job_repair_id"}' >"$run_dir/job-repair-list.json"
    printf '%s\n' '{"status":"skipped","reason":"no_job_repair_id"}' >"$run_dir/job-repair-stop.json"
  fi
}

collect_restart_recovery_sample() {
  if [[ "${OPENPHONE_VALIDATE_INCLUDE_RESTART_RECOVERY:-0}" != "1" ]]; then
    return
  fi
  local wait_seconds="${OPENPHONE_VALIDATE_RESTART_RECOVERY_WAIT_SECONDS:-36}"
  local start_timeout_seconds="${OPENPHONE_VALIDATE_RESTART_RECOVERY_START_TIMEOUT_SECONDS:-60}"
  local stable_seconds="${OPENPHONE_VALIDATE_RESTART_RECOVERY_STABLE_SECONDS:-12}"
  log "Collecting daemon restart recovery sample"
  remote_capture "restart-recovery-watcher-create.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then future_ms=$(($(date +%s) * 1000 + 600000)); /var/jb/usr/local/bin/openphone-agentctl "{\"command\":\"watcher_create\",\"title\":\"validator restart recovery watcher\",\"source\":\"time\",\"type\":\"time\",\"next_run_at\":$future_ms,\"prompt\":\"summarize validator restart recovery watcher\",\"reason\":\"validator restart recovery gate\"}"; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  remote_capture "restart-recovery-job-create.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then future_ms=$(($(date +%s) * 1000 + 600000)); /var/jb/usr/local/bin/openphone-agentctl "{\"command\":\"background_job_create\",\"title\":\"validator restart recovery job\",\"prompt\":\"summarize validator restart recovery job\",\"next_run_at\":$future_ms,\"reason\":\"validator restart recovery gate\"}"; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  local watcher_id
  watcher_id="$(OPENPHONE_RESTART_WATCHER_CREATE_JSON="$run_dir/restart-recovery-watcher-create.json" python3 - <<'PY'
import json
import os
import re
import sys

try:
    data = json.load(open(os.environ["OPENPHONE_RESTART_WATCHER_CREATE_JSON"], "r", encoding="utf-8"))
except Exception:
    sys.exit(0)

watcher_id = data.get("watcher_id")
if isinstance(watcher_id, int):
    print(watcher_id)
elif isinstance(watcher_id, str) and re.match(r"^[A-Za-z0-9_.:-]+$", watcher_id):
    print(watcher_id)
PY
)"
  local job_id
  job_id="$(OPENPHONE_RESTART_JOB_CREATE_JSON="$run_dir/restart-recovery-job-create.json" python3 - <<'PY'
import json
import os
import re
import sys

try:
    data = json.load(open(os.environ["OPENPHONE_RESTART_JOB_CREATE_JSON"], "r", encoding="utf-8"))
except Exception:
    sys.exit(0)

job_id = data.get("job_id")
if isinstance(job_id, int):
    print(job_id)
elif isinstance(job_id, str) and re.match(r"^[A-Za-z0-9_.:-]+$", job_id):
    print(job_id)
PY
)"
  if [[ -n "$watcher_id" && -n "$job_id" ]]; then
    remote_capture "restart-recovery-watcher-mark-running.json" \
      "if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl '{\"command\":\"watcher_debug_mark_running\",\"watcher_id\":$watcher_id,\"validation\":true,\"age_ms\":600000,\"source\":\"validator_restart_recovery_gate\"}'; else printf '%s\n' '{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}'; fi"
    remote_capture "restart-recovery-job-mark-running.json" \
      "if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl '{\"command\":\"background_job_debug_mark_running\",\"job_id\":$job_id,\"validation\":true,\"age_ms\":600000,\"source\":\"validator_restart_recovery_gate\"}'; else printf '%s\n' '{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}'; fi"
    remote_capture "restart-recovery-restart.json" \
      "if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then before=\$(ps -A 2>/dev/null | grep '[o]penphone-agentd$' | sed -n '1s/^ *\\([0-9][0-9]*\\).*/\\1/p'); if [ -n \"\$before\" ]; then kill \"\$before\" >/dev/null 2>&1 || true; fi; after=''; last_seen=''; stable_elapsed=0; elapsed=0; while [ \"\$elapsed\" -lt $start_timeout_seconds ]; do current=\$(ps -A 2>/dev/null | grep '[o]penphone-agentd$' | sed -n '1s/^ *\\([0-9][0-9]*\\).*/\\1/p'); if [ -n \"\$current\" ] && [ \"\$current\" != \"\$before\" ]; then if [ \"\$current\" = \"\$last_seen\" ]; then stable_elapsed=\$((stable_elapsed + 1)); else last_seen=\"\$current\"; stable_elapsed=0; fi; if [ \"\$stable_elapsed\" -ge $stable_seconds ]; then after=\"\$current\"; break; fi; else stable_elapsed=0; fi; sleep 1; elapsed=\$((elapsed + 1)); done; post_wait_pid=''; if [ -n \"\$after\" ] && [ \"\$after\" != \"\$before\" ]; then restart_status=ok; sleep $wait_seconds; post_wait_pid=\$(ps -A 2>/dev/null | grep '[o]penphone-agentd$' | sed -n '1s/^ *\\([0-9][0-9]*\\).*/\\1/p'); else restart_status=error; fi; printf '{\"status\":\"%s\",\"before_pid\":\"%s\",\"after_pid\":\"%s\",\"post_wait_pid\":\"%s\",\"restart_elapsed_seconds\":%s,\"stable_elapsed_seconds\":%s,\"required_stable_seconds\":$stable_seconds,\"post_restart_wait_seconds\":$wait_seconds,\"start_timeout_seconds\":$start_timeout_seconds}\\n' \"\$restart_status\" \"\$before\" \"\$after\" \"\$post_wait_pid\" \"\$elapsed\" \"\$stable_elapsed\"; else printf '%s\n' '{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}'; fi"
    remote_capture "restart-recovery-after-health.json" \
      'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
    remote_capture "restart-recovery-watcher-list.json" \
      'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl watcher_list "validator restart recovery watcher" 25; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
    remote_capture "restart-recovery-job-list.json" \
      'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl background_job_list "validator restart recovery job" 25; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
    local generated_job_id
    generated_job_id="$(OPENPHONE_RESTART_WATCHER_LIST_JSON="$run_dir/restart-recovery-watcher-list.json" OPENPHONE_RESTART_WATCHER_ROW_ID="$watcher_id" python3 - <<'PY'
import json
import os
import re
import sys

try:
    data = json.load(open(os.environ["OPENPHONE_RESTART_WATCHER_LIST_JSON"], "r", encoding="utf-8"))
except Exception:
    sys.exit(0)

watcher_row_id = os.environ.get("OPENPHONE_RESTART_WATCHER_ROW_ID", "")
for watcher in data.get("watchers", []):
    if not isinstance(watcher, dict):
        continue
    if watcher_row_id and str(watcher.get("id", "")) != watcher_row_id:
        continue
    metadata = watcher.get("metadata") if isinstance(watcher.get("metadata"), dict) else {}
    schedule = watcher.get("schedule") if isinstance(watcher.get("schedule"), dict) else {}
    job_id = metadata.get("last_job_id") or schedule.get("last_job_id") or ""
    if isinstance(job_id, int):
        print(job_id)
        break
    if isinstance(job_id, str) and re.match(r"^[A-Za-z0-9_.:-]+$", job_id):
        print(job_id)
        break
PY
)"
    remote_capture "restart-recovery-watcher-stop.json" \
      "if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl watcher_stop '$watcher_id'; else printf '%s\n' '{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}'; fi"
    remote_capture "restart-recovery-job-stop.json" \
      "if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl background_job_stop '$job_id'; else printf '%s\n' '{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}'; fi"
    if [[ -n "$generated_job_id" ]]; then
      remote_capture "restart-recovery-generated-job-stop.json" \
        "if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl background_job_stop '$generated_job_id' 'validator restart recovery generated job cleanup'; else printf '%s\n' '{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}'; fi"
    else
      printf '%s\n' '{"status":"skipped","reason":"missing_restart_recovery_generated_job_id"}' >"$run_dir/restart-recovery-generated-job-stop.json"
    fi
  else
    printf '%s\n' '{"status":"skipped","reason":"missing_restart_recovery_fixture_id"}' >"$run_dir/restart-recovery-watcher-mark-running.json"
    printf '%s\n' '{"status":"skipped","reason":"missing_restart_recovery_fixture_id"}' >"$run_dir/restart-recovery-job-mark-running.json"
    printf '%s\n' '{"status":"skipped","reason":"missing_restart_recovery_fixture_id"}' >"$run_dir/restart-recovery-restart.json"
    printf '%s\n' '{"status":"skipped","reason":"missing_restart_recovery_fixture_id"}' >"$run_dir/restart-recovery-after-health.json"
    printf '%s\n' '{"status":"skipped","reason":"missing_restart_recovery_fixture_id"}' >"$run_dir/restart-recovery-watcher-list.json"
    printf '%s\n' '{"status":"skipped","reason":"missing_restart_recovery_fixture_id"}' >"$run_dir/restart-recovery-job-list.json"
    printf '%s\n' '{"status":"skipped","reason":"missing_restart_recovery_fixture_id"}' >"$run_dir/restart-recovery-watcher-stop.json"
    printf '%s\n' '{"status":"skipped","reason":"missing_restart_recovery_fixture_id"}' >"$run_dir/restart-recovery-job-stop.json"
    printf '%s\n' '{"status":"skipped","reason":"missing_restart_recovery_fixture_id"}' >"$run_dir/restart-recovery-generated-job-stop.json"
  fi
}

safe_json_string() {
  python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$1"
}

json_field() {
  local artifact="$1"
  local expression="$2"
  OPENPHONE_JSON_FIELD_FILE="$artifact" OPENPHONE_JSON_FIELD_EXPR="$expression" python3 - <<'PY'
import json
import os
import sys

try:
    data = json.load(open(os.environ["OPENPHONE_JSON_FIELD_FILE"], "r", encoding="utf-8"))
except Exception:
    sys.exit(0)

value = data
for part in os.environ["OPENPHONE_JSON_FIELD_EXPR"].split("."):
    if isinstance(value, dict):
        value = value.get(part)
    else:
        sys.exit(0)
if isinstance(value, str):
    print(value)
elif isinstance(value, (int, float)):
    print(value)
PY
}

collect_memory_lifecycle_sample() {
  if [[ "${OPENPHONE_VALIDATE_INCLUDE_MEMORY_LIFECYCLE:-0}" != "1" ]]; then
    return
  fi
  log "Collecting memory lifecycle sample"
  local primary_text="validator memory lifecycle primary $(date '+%Y%m%d%H%M%S')"
  local updated_text="$primary_text updated merge-ready"
  local source_text="$primary_text secondary merge source"
  local merged_text="$primary_text merged durable result"
  local delete_text="$primary_text delete fixture"

  remote_capture "memory-lifecycle-save-primary.json" \
    "if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl '{\"command\":\"memory_save\",\"type\":\"fact\",\"subject\":\"validator\",\"text\":$(safe_json_string "$primary_text"),\"reason\":\"validator memory lifecycle primary\"}'; else printf '%s\n' '{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}'; fi"
  local primary_id
  primary_id="$(json_field "$run_dir/memory-lifecycle-save-primary.json" "memory.memory_id")"

  if [[ -n "$primary_id" ]]; then
    remote_capture "memory-lifecycle-update.json" \
      "if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl '{\"command\":\"memory_update\",\"memory_id\":\"$primary_id\",\"type\":\"fact\",\"subject\":\"validator\",\"text\":$(safe_json_string "$updated_text"),\"reason\":\"validator memory lifecycle update\"}'; else printf '%s\n' '{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}'; fi"
  else
    printf '%s\n' '{"status":"skipped","reason":"missing_primary_memory_id"}' >"$run_dir/memory-lifecycle-update.json"
  fi

  remote_capture "memory-lifecycle-save-source.json" \
    "if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl '{\"command\":\"memory_save\",\"type\":\"fact\",\"subject\":\"validator\",\"text\":$(safe_json_string "$source_text"),\"reason\":\"validator memory lifecycle merge source\"}'; else printf '%s\n' '{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}'; fi"
  local source_id
  source_id="$(json_field "$run_dir/memory-lifecycle-save-source.json" "memory.memory_id")"

  if [[ -n "$primary_id" && -n "$source_id" ]]; then
    remote_capture "memory-lifecycle-merge.json" \
      "if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl '{\"command\":\"memory_merge\",\"target_memory_id\":\"$primary_id\",\"source_memory_id\":\"$source_id\",\"text\":$(safe_json_string "$merged_text"),\"reason\":\"validator memory lifecycle merge\"}'; else printf '%s\n' '{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}'; fi"
  else
    printf '%s\n' '{"status":"skipped","reason":"missing_merge_memory_id"}' >"$run_dir/memory-lifecycle-merge.json"
  fi

  remote_capture "memory-lifecycle-save-delete.json" \
    "if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl '{\"command\":\"memory_save\",\"type\":\"fact\",\"subject\":\"validator\",\"text\":$(safe_json_string "$delete_text"),\"reason\":\"validator memory lifecycle delete source\"}'; else printf '%s\n' '{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}'; fi"
  local delete_id
  delete_id="$(json_field "$run_dir/memory-lifecycle-save-delete.json" "memory.memory_id")"
  if [[ -n "$delete_id" ]]; then
    remote_capture "memory-lifecycle-delete.json" \
      "if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl '{\"command\":\"memory_delete\",\"memory_id\":\"$delete_id\",\"reason\":\"validator memory lifecycle delete\"}'; else printf '%s\n' '{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}'; fi"
  else
    printf '%s\n' '{"status":"skipped","reason":"missing_delete_memory_id"}' >"$run_dir/memory-lifecycle-delete.json"
  fi

  remote_capture "memory-lifecycle-search.json" \
    "if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl '{\"command\":\"memory_search\",\"query\":$(safe_json_string "$primary_text"),\"limit\":10,\"reason\":\"validator memory lifecycle search\"}'; else printf '%s\n' '{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}'; fi"
}

collect_model_loop_sample() {
  if [[ "${OPENPHONE_VALIDATE_INCLUDE_MODEL_LOOP:-0}" != "1" ]]; then
    return
  fi
  log "Collecting fixture model-loop sample"
  remote_capture "model-status.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl model_status; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  local goal="validator fixture model loop $(date '+%Y%m%d%H%M%S')"
  remote_capture "model-loop-run.json" \
    "if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl '{\"command\":\"run_task\",\"goal\":$(safe_json_string "$goal"),\"mode\":\"model\",\"max_steps\":3,\"max_duration_ms\":30000,\"model_decisions\":[{\"schema\":\"openphone.model_decision.v1\",\"thought\":\"pause before finishing\",\"tool\":\"wait\",\"arguments\":{\"duration_ms\":10},\"expected_visible_change\":\"none\",\"confidence\":0.9},{\"schema\":\"openphone.model_decision.v1\",\"thought\":\"validation complete\",\"tool\":\"finish_task\",\"arguments\":{\"summary\":\"Fixture model loop completed.\"},\"expected_visible_change\":\"none\",\"confidence\":0.95}]}'; else printf '%s\n' '{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}'; fi"
  local model_task_id
  model_task_id="$(json_field "$run_dir/model-loop-run.json" "task_id")"
  if [[ -n "$model_task_id" ]]; then
    remote_capture "model-loop-trajectory.json" \
      "if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl get_trajectory '$model_task_id' 80; else printf '%s\n' '{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}'; fi"
  else
    printf '%s\n' '{"status":"skipped","reason":"missing_model_loop_task_id"}' >"$run_dir/model-loop-trajectory.json"
  fi

  local repair_goal="validator parser repair model loop $(date '+%Y%m%d%H%M%S')"
  local repair_decision=$'Here is the decision:\n```json\n{"schema":"openphone.model_decision.v1","thought":"wrapped validation complete","tool":"finish_task","arguments":{"summary":"Parser repair model loop completed."},"expected_visible_change":"none","confidence":0.96}\n```\n'
  remote_capture "model-loop-repair-run.json" \
    "if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl '{\"command\":\"run_task\",\"goal\":$(safe_json_string "$repair_goal"),\"mode\":\"model\",\"max_steps\":2,\"max_duration_ms\":30000,\"model_decisions\":[$(safe_json_string "$repair_decision")]}'; else printf '%s\n' '{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}'; fi"
  local repair_task_id
  repair_task_id="$(json_field "$run_dir/model-loop-repair-run.json" "task_id")"
  if [[ -n "$repair_task_id" ]]; then
    remote_capture "model-loop-repair-trajectory.json" \
      "if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl get_trajectory '$repair_task_id' 80; else printf '%s\n' '{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}'; fi"
  else
    printf '%s\n' '{"status":"skipped","reason":"missing_model_loop_repair_task_id"}' >"$run_dir/model-loop-repair-trajectory.json"
  fi

  local cancel_goal="validator cancelled model loop $(date '+%Y%m%d%H%M%S')"
  remote_capture "model-loop-cancel-start.json" \
    "if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl '{\"command\":\"start_task\",\"goal\":$(safe_json_string "$cancel_goal")}'; else printf '%s\n' '{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}'; fi"
  local cancel_task_id
  cancel_task_id="$(json_field "$run_dir/model-loop-cancel-start.json" "task_id")"
  if [[ -n "$cancel_task_id" && "$cancel_task_id" =~ ^[A-Za-z0-9_.:-]+$ ]]; then
    remote_capture "model-loop-cancel-stop.json" \
      "if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl '{\"command\":\"stop_task\",\"task_id\":\"$cancel_task_id\",\"reason\":\"validator model loop cancellation\"}'; else printf '%s\n' '{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}'; fi"
    remote_capture "model-loop-cancel-run.json" \
      "if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl '{\"command\":\"run_task\",\"task_id\":\"$cancel_task_id\",\"goal\":$(safe_json_string "$cancel_goal"),\"mode\":\"model\",\"max_steps\":3,\"max_duration_ms\":30000,\"model_decisions\":[{\"schema\":\"openphone.model_decision.v1\",\"thought\":\"should not execute after cancellation\",\"tool\":\"finish_task\",\"arguments\":{\"summary\":\"Should not finish.\"},\"expected_visible_change\":\"none\",\"confidence\":0.95}]}'; else printf '%s\n' '{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}'; fi"
    remote_capture "model-loop-cancel-trajectory.json" \
      "if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl get_trajectory '$cancel_task_id' 80; else printf '%s\n' '{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}'; fi"
  else
    printf '%s\n' '{"status":"skipped","reason":"missing_model_loop_cancel_task_id"}' >"$run_dir/model-loop-cancel-stop.json"
    printf '%s\n' '{"status":"skipped","reason":"missing_model_loop_cancel_task_id"}' >"$run_dir/model-loop-cancel-run.json"
    printf '%s\n' '{"status":"skipped","reason":"missing_model_loop_cancel_task_id"}' >"$run_dir/model-loop-cancel-trajectory.json"
  fi
}

collect_voice_status_sample() {
  if [[ "${OPENPHONE_VALIDATE_INCLUDE_VOICE:-0}" != "1" ]]; then
    return
  fi
  log "Collecting voice_status + island snapshot sample"
  remote_capture "voice-status.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl '"'"'{"command":"voice_status"}'"'"'; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  remote_capture "island-status.json" \
    'cat /var/mobile/Library/OpenPhone/springboard/island-status.json 2>/dev/null || printf "%s\n" "{\"status\":\"absent\"}"'
  remote_capture "voice-credential-file-exists.json" \
    'if [ -f /var/mobile/Library/OpenPhone/config/voice-credential.json ]; then printf "%s\n" "{\"status\":\"present\"}"; else printf "%s\n" "{\"status\":\"absent\"}"; fi'
}

start_provider_broker_if_requested() {
  if [[ "${OPENPHONE_VALIDATE_INCLUDE_PROVIDER_MODEL:-0}" != "1" ]]; then
    return
  fi
  local token="${AWS_BEARER_TOKEN_BEDROCK:-${OPENPHONE_BEDROCK_BEARER_TOKEN:-}}"
  if [[ -z "$token" ]]; then
    fail 100 "OPENPHONE_VALIDATE_INCLUDE_PROVIDER_MODEL=1 requires AWS_BEARER_TOKEN_BEDROCK or OPENPHONE_BEDROCK_BEARER_TOKEN"
  fi
  require_command python3 100
  require_command ssh 100
  log "Starting provider-backed Bedrock broker"
  local port_file="$run_dir/provider-model-broker-port.txt"
  AWS_BEARER_TOKEN_BEDROCK="$token" \
    OPENPHONE_BEDROCK_BEARER_TOKEN="${OPENPHONE_BEDROCK_BEARER_TOKEN:-}" \
    OPENPHONE_BEDROCK_MODEL="${OPENPHONE_BEDROCK_MODEL:-}" \
    OPENPHONE_BEDROCK_REGION="${OPENPHONE_BEDROCK_REGION:-}" \
    AWS_REGION="${AWS_REGION:-}" \
    AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-}" \
    OPENPHONE_BEDROCK_RUNTIME_URL="${OPENPHONE_BEDROCK_RUNTIME_URL:-}" \
    OPENPHONE_BEDROCK_MAX_TOKENS="${OPENPHONE_BEDROCK_MAX_TOKENS:-}" \
    OPENPHONE_BEDROCK_TEMPERATURE="${OPENPHONE_BEDROCK_TEMPERATURE:-}" \
    "$repo_root/tools/mac/agentd/bedrock-model-broker.py" \
      --port-file "$port_file" >"$run_dir/provider-model-broker.log" 2>&1 &
  provider_broker_pid="$!"
  for _ in $(seq 1 100); do
    if [[ -s "$port_file" ]]; then
      break
    fi
    if ! kill -0 "$provider_broker_pid" >/dev/null 2>&1; then
      fail 100 "provider model broker exited early; see $run_dir/provider-model-broker.log"
    fi
    sleep 0.1
  done
  if [[ ! -s "$port_file" ]]; then
    fail 100 "provider model broker did not publish a port; see $run_dir/provider-model-broker.log"
  fi
  provider_broker_port="$(cat "$port_file")"
  log "Starting provider model reverse tunnel phone:$provider_phone_port -> mac:$provider_broker_port"
  start_ssh_reverse_forward "$provider_phone_port" "$provider_broker_port"
}

collect_provider_model_sample() {
  if [[ "${OPENPHONE_VALIDATE_INCLUDE_PROVIDER_MODEL:-0}" != "1" ]]; then
    return
  fi
  log "Collecting provider-backed model-loop sample"
  local endpoint="http://127.0.0.1:${provider_phone_port}/decision"
  local model_name="${OPENPHONE_BEDROCK_MODEL:-anthropic.claude-haiku-4-5-20251001-v1:0}"
  local goal="provider-backed broker validation $(date '+%Y%m%d%H%M%S')"
  remote_capture "provider-model-configure.json" \
    "if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl '{\"command\":\"model_configure\",\"mode\":\"broker\",\"endpoint_url\":$(safe_json_string "$endpoint"),\"model\":$(safe_json_string "$model_name"),\"enabled\":true,\"credential_required\":false,\"timeout_ms\":60000,\"max_steps\":2,\"max_duration_ms\":60000,\"reason\":\"validator provider-backed broker sample\"}'; else printf '%s\n' '{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}'; fi"
  remote_capture "provider-model-status.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl model_status; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  remote_capture "provider-model-run.json" \
    "if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl '{\"command\":\"run_task\",\"goal\":$(safe_json_string "$goal"),\"mode\":\"model\",\"max_steps\":2,\"max_duration_ms\":60000}'; else printf '%s\n' '{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}'; fi"
  local provider_task_id
  provider_task_id="$(json_field "$run_dir/provider-model-run.json" "task_id")"
  if [[ -n "$provider_task_id" && "$provider_task_id" =~ ^[A-Za-z0-9_.:-]+$ ]]; then
    remote_capture "provider-model-trajectory.json" \
      "if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl get_trajectory '$provider_task_id' 120; else printf '%s\n' '{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}'; fi"
  else
    printf '%s\n' '{"status":"skipped","reason":"missing_provider_model_task_id"}' >"$run_dir/provider-model-trajectory.json"
  fi
  remote_capture "provider-model-reset.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl '\''{"command":"model_configure","mode":"broker","endpoint_url":"","model":"","enabled":false,"credential_required":true,"reason":"validator provider-backed broker cleanup"}'\''; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
}

install_direct_bedrock_credential() {
  local token="${AWS_BEARER_TOKEN_BEDROCK:-${OPENPHONE_BEDROCK_BEARER_TOKEN:-}}"
  require_command python3 100
  # shellcheck disable=SC2016
  remote_capture "safari-dom-model-backup.json" \
    'mkdir -p /var/mobile/Library/OpenPhone/config '"$remote_tmp"'; \
      credential_backup=false; config_backup=false; \
      if [ -f /var/mobile/Library/OpenPhone/config/model-credential.json ]; then cp /var/mobile/Library/OpenPhone/config/model-credential.json '"$remote_tmp"'/model-credential.backup && credential_backup=true; fi; \
      if [ -f /var/mobile/Library/OpenPhone/config/model.json ]; then cp /var/mobile/Library/OpenPhone/config/model.json '"$remote_tmp"'/model-config.backup && config_backup=true; fi; \
      printf "{\"status\":\"ok\",\"credential_backup\":%s,\"config_backup\":%s}\n" "$credential_backup" "$config_backup"'
  if OPENPHONE_BACKUP_JSON="$run_dir/safari-dom-model-backup.json" python3 - <<'PY'
import json
import os
import sys

try:
    data = json.load(open(os.environ["OPENPHONE_BACKUP_JSON"], "r", encoding="utf-8"))
except Exception:
    sys.exit(1)
sys.exit(0 if data.get("credential_backup") is True else 1)
PY
  then
    direct_bedrock_credential_had_backup=1
  fi
  if OPENPHONE_BACKUP_JSON="$run_dir/safari-dom-model-backup.json" python3 - <<'PY'
import json
import os
import sys

try:
    data = json.load(open(os.environ["OPENPHONE_BACKUP_JSON"], "r", encoding="utf-8"))
except Exception:
    sys.exit(1)
sys.exit(0 if data.get("config_backup") is True else 1)
PY
  then
    direct_bedrock_config_had_backup=1
  fi

  if [[ -z "$token" ]]; then
    if [[ "$direct_bedrock_credential_had_backup" == "1" ]]; then
      log "Using existing phone Bedrock credential file for Safari DOM model sample"
      return
    fi
    fail 100 "OPENPHONE_VALIDATE_INCLUDE_SAFARI_DOM_MODEL=1 requires AWS_BEARER_TOKEN_BEDROCK, OPENPHONE_BEDROCK_BEARER_TOKEN, or an existing phone credential file"
  fi

  direct_bedrock_credential_temp="$(mktemp -t openphone-bedrock-credential.XXXXXX)"
  chmod 0600 "$direct_bedrock_credential_temp"
  OPENPHONE_VALIDATE_BEDROCK_TOKEN="$token" python3 - <<'PY' >"$direct_bedrock_credential_temp"
import json
import os

print(json.dumps({"credential": os.environ["OPENPHONE_VALIDATE_BEDROCK_TOKEN"]}))
PY
  scp_to "$direct_bedrock_credential_temp" "$remote_tmp/model-credential.upload" "$run_dir/safari-dom-model-credential-scp.log"
  remote_exec "install -m 0600 '$remote_tmp/model-credential.upload' /var/mobile/Library/OpenPhone/config/model-credential.json; rm -f '$remote_tmp/model-credential.upload'" "$run_dir/safari-dom-model-credential-install.log"
  direct_bedrock_credential_touched=1
  rm -f "$direct_bedrock_credential_temp"
  direct_bedrock_credential_temp=""
}

restore_direct_bedrock_state() {
  # shellcheck disable=SC2016
  remote_capture "safari-dom-model-reset.json" \
    'mkdir -p /var/mobile/Library/OpenPhone/config; \
      reset_status=ok; credential_restored=false; credential_removed=false; config_restored=false; config_removed=false; \
      if [ -f '"$remote_tmp"'/model-config.backup ]; then install -m 0600 '"$remote_tmp"'/model-config.backup /var/mobile/Library/OpenPhone/config/model.json && config_restored=true || reset_status=error; else rm -f /var/mobile/Library/OpenPhone/config/model.json && config_removed=true || reset_status=error; fi; \
      if [ -f '"$remote_tmp"'/model-credential.backup ]; then install -m 0600 '"$remote_tmp"'/model-credential.backup /var/mobile/Library/OpenPhone/config/model-credential.json && credential_restored=true || reset_status=error; else rm -f /var/mobile/Library/OpenPhone/config/model-credential.json && credential_removed=true || reset_status=error; fi; \
      printf "{\"status\":\"%s\",\"credential_restored\":%s,\"credential_removed\":%s,\"config_restored\":%s,\"config_removed\":%s}\n" "$reset_status" "$credential_restored" "$credential_removed" "$config_restored" "$config_removed"'
  if grep -q '"status":"ok"' "$run_dir/safari-dom-model-reset.json"; then
    direct_bedrock_credential_touched=0
    direct_bedrock_config_touched=0
  fi
}

collect_safari_dom_model_sample() {
  if [[ "${OPENPHONE_VALIDATE_INCLUDE_SAFARI_DOM_MODEL:-0}" != "1" ]]; then
    return
  fi
  log "Collecting direct Bedrock Safari DOM model-loop sample"

  remote_capture "safari-dom-model-before-screen.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl get_screen; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  local locked_state
  locked_state="$(OPENPHONE_SAFARI_DOM_BEFORE_JSON="$run_dir/safari-dom-model-before-screen.json" python3 - <<'PY'
import json
import os
import sys

try:
    data = json.load(open(os.environ["OPENPHONE_SAFARI_DOM_BEFORE_JSON"], "r", encoding="utf-8"))
except Exception:
    print("unknown")
    sys.exit(0)

lock = data.get("context", {}).get("lock", {}) if isinstance(data, dict) else {}
locked = lock.get("locked")
if locked is True:
    print("true")
elif locked is False:
    print("false")
else:
    print("unknown")
PY
)"
  if [[ "$locked_state" != "false" ]]; then
    for name in safari-dom-model-open-url safari-dom-model-pre-screen safari-dom-model-configure safari-dom-model-status safari-dom-model-run safari-dom-model-trajectory safari-dom-model-after-screen safari-dom-model-safari-state; do
      printf '{"status":"skipped","reason":"device_locked_or_unknown","locked_state":"%s"}\n' "$locked_state" \
        >"$run_dir/$name.json"
    done
    printf '%s\n' "" >"$run_dir/safari-dom-model-marker.txt"
    printf '{"status":"skipped","reason":"device_locked_or_unknown","locked_state":"%s"}\n' "$locked_state" \
      >"$run_dir/safari-dom-model-reset.json"
    return
  fi

  install_direct_bedrock_credential

  local marker
  marker="OPModelSafariDOM-$(date '+%H%M%S')"
  printf '%s\n' "$marker" >"$run_dir/safari-dom-model-marker.txt"
  local model_name="${OPENPHONE_BEDROCK_MODEL:-us.anthropic.claude-haiku-4-5-20251001-v1:0}"
  local region="${OPENPHONE_BEDROCK_REGION:-${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}}"
  local timeout_ms="${OPENPHONE_VALIDATE_SAFARI_DOM_MODEL_TIMEOUT_MS:-120000}"
  local max_steps="${OPENPHONE_VALIDATE_SAFARI_DOM_MODEL_MAX_STEPS:-4}"
  local max_duration_ms="${OPENPHONE_VALIDATE_SAFARI_DOM_MODEL_MAX_DURATION_MS:-180000}"
  remote_capture "safari-dom-model-open-url.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then killall MobileSafari >/dev/null 2>&1 || true; sleep 2; /var/jb/usr/local/bin/openphone-agentctl '"'"'{"command":"execute_action","action":{"type":"open_url","url":"https://www.wikipedia.org/","reason":"validator Safari DOM model launch"}}'"'"'; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  remote_capture "safari-dom-model-pre-screen.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then sleep 8; /var/jb/usr/local/bin/openphone-agentctl get_screen; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  remote_capture "safari-dom-model-configure.json" \
    "if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl '{\"command\":\"model_configure\",\"mode\":\"bedrock_converse\",\"endpoint_url\":\"\",\"model\":$(safe_json_string "$model_name"),\"region\":$(safe_json_string "$region"),\"enabled\":true,\"credential_required\":true,\"timeout_ms\":$timeout_ms,\"max_steps\":$max_steps,\"max_duration_ms\":$max_duration_ms,\"reason\":\"validator direct Bedrock Safari DOM sample\"}'; else printf '%s\n' '{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}'; fi"
  direct_bedrock_config_touched=1
  remote_capture "safari-dom-model-status.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl model_status; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  local goal="On the currently open Wikipedia home page in Safari, enter the exact text $marker into the visible or focused search field. Do not submit the search. Finish only after that exact text is visible in the field."
  remote_capture "safari-dom-model-run.json" \
    "if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl '{\"command\":\"run_task\",\"goal\":$(safe_json_string "$goal"),\"mode\":\"model\",\"max_steps\":$max_steps,\"max_duration_ms\":$max_duration_ms}'; else printf '%s\n' '{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}'; fi"
  local safari_dom_task_id
  safari_dom_task_id="$(json_field "$run_dir/safari-dom-model-run.json" "task_id")"
  if [[ -n "$safari_dom_task_id" && "$safari_dom_task_id" =~ ^[A-Za-z0-9_.:-]+$ ]]; then
    remote_capture "safari-dom-model-trajectory.json" \
      "if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl get_trajectory '$safari_dom_task_id' 160; else printf '%s\n' '{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}'; fi"
  else
    printf '%s\n' '{"status":"skipped","reason":"missing_safari_dom_model_task_id"}' >"$run_dir/safari-dom-model-trajectory.json"
  fi
  remote_capture "safari-dom-model-after-screen.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl get_screen; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  remote_capture "safari-dom-model-safari-state.json" \
    'if [ -f /var/mobile/Library/OpenPhone/app-ui/com.apple.mobilesafari.json ]; then cat /var/mobile/Library/OpenPhone/app-ui/com.apple.mobilesafari.json; else printf "%s\n" "{\"status\":\"missing\",\"bundle_id\":\"com.apple.mobilesafari\"}"; fi'
  restore_direct_bedrock_state
}

collect_prompt_bridge_model_sample() {
  if [[ "${OPENPHONE_VALIDATE_INCLUDE_PROMPT_BRIDGE_MODEL:-0}" != "1" ]]; then
    return
  fi
  log "Collecting SpringBoard prompt bridge model-loop sample"

  remote_capture "prompt-bridge-before-screen.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl get_screen; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  local locked_state
  locked_state="$(OPENPHONE_PROMPT_BRIDGE_BEFORE_JSON="$run_dir/prompt-bridge-before-screen.json" python3 - <<'PY'
import json
import os
import sys

try:
    data = json.load(open(os.environ["OPENPHONE_PROMPT_BRIDGE_BEFORE_JSON"], "r", encoding="utf-8"))
except Exception:
    print("unknown")
    sys.exit(0)

lock = data.get("context", {}).get("lock", {}) if isinstance(data, dict) else {}
locked = lock.get("locked")
if locked is True:
    print("true")
elif locked is False:
    print("false")
else:
    print("unknown")
PY
)"
  if [[ "$locked_state" != "false" ]]; then
    for name in prompt-bridge-open-url prompt-bridge-pre-screen prompt-bridge-model-status prompt-bridge-response prompt-bridge-agent-status prompt-bridge-trajectory prompt-bridge-after-screen prompt-bridge-safari-state prompt-bridge-tweak-log; do
      printf '{"status":"skipped","reason":"device_locked_or_unknown","locked_state":"%s"}\n' "$locked_state" \
        >"$run_dir/$name.json"
    done
    printf '%s\n' "" >"$run_dir/prompt-bridge-marker.txt"
    printf '%s\n' "" >"$run_dir/prompt-bridge-request-id.txt"
    return
  fi

  local marker request_id goal request_b64
  marker="OPPromptBridge-$(date '+%H%M%S')"
  request_id="prompt-bridge-$run_id-$(date '+%s')"
  goal="On the current Safari Wikipedia home page, type the exact text $marker into the visible Search field, then finish only after the text is visible. Do not submit the search."
  printf '%s\n' "$marker" >"$run_dir/prompt-bridge-marker.txt"
  printf '%s\n' "$request_id" >"$run_dir/prompt-bridge-request-id.txt"

  remote_capture "prompt-bridge-open-url.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then killall MobileSafari >/dev/null 2>&1 || true; sleep 2; /var/jb/usr/local/bin/openphone-agentctl '"'"'{"command":"execute_action","action":{"type":"open_url","url":"https://www.wikipedia.org/","reason":"validator prompt bridge Safari launch"}}'"'"'; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  remote_capture "prompt-bridge-pre-screen.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then sleep 8; /var/jb/usr/local/bin/openphone-agentctl get_screen; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  remote_capture "prompt-bridge-model-status.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl model_status; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'

  request_b64="$(OPENPHONE_PROMPT_BRIDGE_REQUEST_ID="$request_id" OPENPHONE_PROMPT_BRIDGE_GOAL="$goal" python3 - <<'PY'
import base64
import json
import os
import time

request = {
    "schema": "openphone.springboard_prompt_request.v1",
    "request_id": os.environ["OPENPHONE_PROMPT_BRIDGE_REQUEST_ID"],
    "operation": "run_goal",
    "goal": os.environ["OPENPHONE_PROMPT_BRIDGE_GOAL"],
    "timestamp_ms": int(time.time() * 1000),
}
print(base64.b64encode(json.dumps(request, separators=(",", ":")).encode("utf-8")).decode("ascii"))
PY
)"
  remote_capture "prompt-bridge-response.json" \
    "mkdir -p /var/mobile/Library/OpenPhone/springboard; rm -f /var/mobile/Library/OpenPhone/springboard/prompt-response.json /var/mobile/Library/OpenPhone/springboard/prompt-request.json; printf '%s' '$request_b64' | base64 -d > /var/mobile/Library/OpenPhone/springboard/prompt-request.json; for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do if [ -f /var/mobile/Library/OpenPhone/springboard/prompt-response.json ]; then cat /var/mobile/Library/OpenPhone/springboard/prompt-response.json; exit 0; fi; sleep 1; done; printf '%s\n' '{\"status\":\"timeout\",\"reason\":\"prompt_bridge_response_timeout\"}'"
  remote_capture "prompt-bridge-agent-status.json" \
    "if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then status_file=/tmp/openphone-prompt-bridge-agent-status.json; for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24; do /var/jb/usr/local/bin/openphone-agentctl agent_status > \"\$status_file\"; if grep -q '$marker' \"\$status_file\" && grep -q '\"latest_task\":{[^}]*\"status\":\"completed\"' \"\$status_file\"; then cat \"\$status_file\"; rm -f \"\$status_file\"; exit 0; fi; sleep 5; done; cat \"\$status_file\"; rm -f \"\$status_file\"; else printf '%s\n' '{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}'; fi"

  local prompt_bridge_task_id
  prompt_bridge_task_id="$(json_field "$run_dir/prompt-bridge-agent-status.json" "latest_task.task_id")"
  if [[ -n "$prompt_bridge_task_id" && "$prompt_bridge_task_id" =~ ^[A-Za-z0-9_.:-]+$ ]]; then
    remote_capture "prompt-bridge-trajectory.json" \
      "if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl get_trajectory '$prompt_bridge_task_id' 160; else printf '%s\n' '{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}'; fi"
  else
    printf '%s\n' '{"status":"skipped","reason":"missing_prompt_bridge_task_id"}' >"$run_dir/prompt-bridge-trajectory.json"
  fi
  remote_capture "prompt-bridge-after-screen.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl get_screen; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  remote_capture "prompt-bridge-safari-state.json" \
    'if [ -f /var/mobile/Library/OpenPhone/app-ui/com.apple.mobilesafari.json ]; then cat /var/mobile/Library/OpenPhone/app-ui/com.apple.mobilesafari.json; else printf "%s\n" "{\"status\":\"missing\",\"bundle_id\":\"com.apple.mobilesafari\"}"; fi'
  remote_capture "prompt-bridge-tweak-log.txt" \
    "if [ -f /var/mobile/Library/OpenPhone/openphone-volume-trigger.log ]; then tail -n $tail_lines /var/mobile/Library/OpenPhone/openphone-volume-trigger.log; fi"
}

collect_screenshot_if_requested() {
  if [[ "${OPENPHONE_VALIDATE_INCLUDE_SCREENSHOT:-0}" != "1" ]]; then
    return
  fi
  log "Collecting screenshot artifact"
  remote_capture "get-screen-screenshot.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl get_screen screenshot; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  OPENPHONE_SCREENSHOT_JSON="$run_dir/get-screen-screenshot.json" python3 - <<'PY' >"$run_dir/screenshot-remote-path.txt"
import json
import os
import sys

path = os.environ["OPENPHONE_SCREENSHOT_JSON"]
try:
    data = json.load(open(path, "r", encoding="utf-8"))
except Exception:
    sys.exit(0)

def walk(value):
    if isinstance(value, dict):
        if value.get("status") == "ok" and isinstance(value.get("path"), str):
            yield value["path"]
        for item in value.values():
            yield from walk(item)
    elif isinstance(value, list):
        for item in value:
            yield from walk(item)

for candidate in walk(data):
    if candidate.endswith(".png"):
        print(candidate)
        break
PY
  local screenshot_remote
  screenshot_remote="$(head -n 1 "$run_dir/screenshot-remote-path.txt" || true)"
  if [[ -n "$screenshot_remote" ]]; then
    scp_from "$screenshot_remote" "$run_dir/screenshot.png" || true
    if [[ -f "$run_dir/screenshot.png" ]]; then
      python3 - <<'PY' "$run_dir/screenshot.png" >"$run_dir/screenshot-sanity.json"
import binascii
import itertools
import json
import pathlib
import struct
import sys
import zlib

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"

def paeth(a, b, c):
    p = a + b - c
    pa = abs(p - a)
    pb = abs(p - b)
    pc = abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c

def parse_png(path):
    data = path.read_bytes()
    if not data.startswith(PNG_SIGNATURE):
        raise ValueError("not_png")
    pos = len(PNG_SIGNATURE)
    chunks = []
    idat = []
    info = {}
    while pos + 8 <= len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        kind = data[pos + 4:pos + 8]
        payload = data[pos + 8:pos + 8 + length]
        crc_expected = struct.unpack(">I", data[pos + 8 + length:pos + 12 + length])[0]
        crc_actual = binascii.crc32(kind + payload) & 0xFFFFFFFF
        if crc_actual != crc_expected:
            raise ValueError(f"crc_mismatch:{kind.decode('ascii', 'replace')}")
        pos += 12 + length
        chunks.append(kind.decode("ascii", "replace"))
        if kind == b"IHDR":
            width, height, bit_depth, color_type, compression, filter_method, interlace = struct.unpack(">IIBBBBB", payload)
            info.update({
                "width": width,
                "height": height,
                "bit_depth": bit_depth,
                "color_type": color_type,
                "compression": compression,
                "filter_method": filter_method,
                "interlace": interlace,
            })
        elif kind == b"IDAT":
            idat.append(payload)
        elif kind == b"IEND":
            break
    if not info:
        raise ValueError("missing_ihdr")
    return data, chunks, info, b"".join(idat)

def channel_count(color_type):
    return {
        0: 1,
        2: 3,
        4: 2,
        6: 4,
    }.get(color_type)

def decode_rows(info, compressed):
    width = info["width"]
    height = info["height"]
    bit_depth = info["bit_depth"]
    color_type = info["color_type"]
    if info["interlace"] != 0:
        raise ValueError("unsupported_interlace")
    if bit_depth not in (8, 16):
        raise ValueError(f"unsupported_bit_depth:{bit_depth}")
    channels = channel_count(color_type)
    if channels is None:
        raise ValueError(f"unsupported_color_type:{color_type}")
    bytes_per_sample = bit_depth // 8
    bpp = channels * bytes_per_sample
    row_len = width * bpp
    raw = zlib.decompress(compressed)
    expected = height * (row_len + 1)
    if len(raw) < expected:
        raise ValueError("truncated_idat")
    rows = []
    prev = bytearray(row_len)
    offset = 0
    for _ in range(height):
        filter_type = raw[offset]
        offset += 1
        row = bytearray(raw[offset:offset + row_len])
        offset += row_len
        for i in range(row_len):
            left = row[i - bpp] if i >= bpp else 0
            up = prev[i]
            up_left = prev[i - bpp] if i >= bpp else 0
            if filter_type == 0:
                recon = row[i]
            elif filter_type == 1:
                recon = (row[i] + left) & 0xFF
            elif filter_type == 2:
                recon = (row[i] + up) & 0xFF
            elif filter_type == 3:
                recon = (row[i] + ((left + up) // 2)) & 0xFF
            elif filter_type == 4:
                recon = (row[i] + paeth(left, up, up_left)) & 0xFF
            else:
                raise ValueError(f"unsupported_filter:{filter_type}")
            row[i] = recon
        rows.append(bytes(row))
        prev = row
    return rows, channels, bytes_per_sample

def sampled_pixels(rows, info, channels, bytes_per_sample):
    width = info["width"]
    height = info["height"]
    bpp = channels * bytes_per_sample
    xs = sorted(set(int(round(v)) for v in [i * (width - 1) / 10 for i in range(11)])) if width > 1 else [0]
    ys = sorted(set(int(round(v)) for v in [i * (height - 1) / 10 for i in range(11)])) if height > 1 else [0]
    for y, x in itertools.product(ys, xs):
        start = x * bpp
        raw = rows[y][start:start + bpp]
        if bytes_per_sample == 2:
            values = tuple(raw[i] for i in range(0, len(raw), 2))
        else:
            values = tuple(raw)
        yield values

path = pathlib.Path(sys.argv[1])
result = {"path": str(path), "exists": path.exists(), "status": "error"}
try:
    if not path.exists():
        raise ValueError("missing_file")
    data, chunks, info, compressed = parse_png(path)
    rows, channels, bytes_per_sample = decode_rows(info, compressed)
    samples = list(sampled_pixels(rows, info, channels, bytes_per_sample))
    color_components = [sample[:3] if len(sample) >= 3 else sample[:1] for sample in samples]
    unique_colors = {component for component in color_components}
    nonzero_samples = sum(1 for component in color_components if any(value != 0 for value in component))
    result.update({
        "bytes": len(data),
        "format": "png",
        "width": info["width"],
        "height": info["height"],
        "bit_depth": info["bit_depth"],
        "color_type": info["color_type"],
        "interlace": info["interlace"],
        "chunk_counts": {kind: chunks.count(kind) for kind in sorted(set(chunks))},
        "sampled_pixels": len(samples),
        "sampled_unique_colors": len(unique_colors),
        "sampled_nonzero_pixels": nonzero_samples,
        "nonblank": nonzero_samples > 0 and len(unique_colors) > 1,
    })
    result["status"] = "ok" if result["nonblank"] else "blank_or_flat"
except Exception as exc:
    result["reason"] = str(exc)

print(json.dumps(result, indent=2))
PY
    fi
  fi
}

collect_unlocked_foreground_sample() {
  if [[ "${OPENPHONE_VALIDATE_INCLUDE_UNLOCKED_FOREGROUND:-0}" != "1" && \
        "${OPENPHONE_VALIDATE_REQUIRE_UNLOCKED:-0}" != "1" ]]; then
    return
  fi
  log "Collecting unlocked foreground sample"
  remote_capture "unlocked-foreground-before-screen.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl get_screen; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  local locked_state
  locked_state="$(OPENPHONE_UNLOCKED_FOREGROUND_BEFORE_JSON="$run_dir/unlocked-foreground-before-screen.json" python3 - <<'PY'
import json
import os
import sys

try:
    data = json.load(open(os.environ["OPENPHONE_UNLOCKED_FOREGROUND_BEFORE_JSON"], "r", encoding="utf-8"))
except Exception:
    print("unknown")
    sys.exit(0)

lock = data.get("context", {}).get("lock", {}) if isinstance(data, dict) else {}
locked = lock.get("locked")
if locked is True:
    print("true")
elif locked is False:
    print("false")
else:
    print("unknown")
PY
)"
  if [[ "$locked_state" != "false" ]]; then
    printf '{"status":"skipped","reason":"device_locked_or_unknown","locked_state":"%s"}\n' "$locked_state" \
      >"$run_dir/unlocked-foreground-open-safari.json"
    printf '{"status":"skipped","reason":"device_locked_or_unknown","locked_state":"%s"}\n' "$locked_state" \
      >"$run_dir/unlocked-foreground-safari-screen.json"
    printf '{"status":"skipped","reason":"device_locked_or_unknown","locked_state":"%s"}\n' "$locked_state" \
      >"$run_dir/unlocked-foreground-home.json"
    printf '{"status":"skipped","reason":"device_locked_or_unknown","locked_state":"%s"}\n' "$locked_state" \
      >"$run_dir/unlocked-foreground-home-screen.json"
    return
  fi
  remote_capture "unlocked-foreground-open-safari.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl '"'"'{"command":"execute_action","action":{"type":"open_app","bundle_id":"com.apple.mobilesafari","reason":"validator unlocked foreground Safari launch"}}'"'"'; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  remote_capture "unlocked-foreground-safari-screen.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then sleep 2; /var/jb/usr/local/bin/openphone-agentctl get_screen; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  remote_capture "unlocked-foreground-home.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl '"'"'{"command":"execute_action","action":{"type":"home","reason":"validator unlocked foreground cleanup home"}}'"'"'; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  remote_capture "unlocked-foreground-home-screen.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then sleep 1; /var/jb/usr/local/bin/openphone-agentctl get_screen; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
}

collect_app_ui_sample() {
  if [[ "${OPENPHONE_VALIDATE_INCLUDE_APP_UI:-0}" != "1" ]]; then
    return
  fi
  log "Collecting app-process UI sample"
  remote_capture "app-ui-before-screen.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl get_screen; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  local locked_state
  locked_state="$(OPENPHONE_APP_UI_BEFORE_JSON="$run_dir/app-ui-before-screen.json" python3 - <<'PY'
import json
import os
import sys

try:
    data = json.load(open(os.environ["OPENPHONE_APP_UI_BEFORE_JSON"], "r", encoding="utf-8"))
except Exception:
    print("unknown")
    sys.exit(0)

lock = data.get("context", {}).get("lock", {}) if isinstance(data, dict) else {}
locked = lock.get("locked")
if locked is True:
    print("true")
elif locked is False:
    print("false")
else:
    print("unknown")
PY
)"
  if [[ "$locked_state" != "false" ]]; then
    for name in app-ui-relaunch app-ui-open-safari app-ui-safari-screen app-ui-open-settings app-ui-settings-screen app-ui-health app-ui-safari-state app-ui-settings-state; do
      printf '{"status":"skipped","reason":"device_locked_or_unknown","locked_state":"%s"}\n' "$locked_state" \
        >"$run_dir/$name.json"
    done
    printf '{"status":"skipped","reason":"device_locked_or_unknown","locked_state":"%s"}\n' "$locked_state" \
      >"$run_dir/app-ui-ls.txt"
    return
  fi
  remote_capture "app-ui-relaunch.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then killall MobileSafari Preferences >/dev/null 2>&1 || true; sleep 2; printf "%s\n" "{\"status\":\"ok\",\"action\":\"relaunch_targets\"}"; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  remote_capture "app-ui-open-safari.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl '"'"'{"command":"execute_action","action":{"type":"open_app","bundle_id":"com.apple.mobilesafari","reason":"validator app UI Safari launch"}}'"'"'; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  remote_capture "app-ui-safari-screen.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then sleep 8; /var/jb/usr/local/bin/openphone-agentctl get_screen; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  remote_capture "app-ui-open-settings.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl '"'"'{"command":"execute_action","action":{"type":"open_app","bundle_id":"com.apple.Preferences","reason":"validator app UI Settings launch"}}'"'"'; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  remote_capture "app-ui-settings-screen.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then sleep 8; /var/jb/usr/local/bin/openphone-agentctl get_screen; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  remote_capture "app-ui-health.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  remote_capture "app-ui-ls.txt" \
    'ls -la /var/mobile/Library/OpenPhone/app-ui 2>&1 || true'
  remote_capture "app-ui-safari-state.json" \
    'if [ -f /var/mobile/Library/OpenPhone/app-ui/com.apple.mobilesafari.json ]; then cat /var/mobile/Library/OpenPhone/app-ui/com.apple.mobilesafari.json; else printf "%s\n" "{\"status\":\"missing\",\"bundle_id\":\"com.apple.mobilesafari\"}"; fi'
  remote_capture "app-ui-settings-state.json" \
    'if [ -f /var/mobile/Library/OpenPhone/app-ui/com.apple.Preferences.json ]; then cat /var/mobile/Library/OpenPhone/app-ui/com.apple.Preferences.json; else printf "%s\n" "{\"status\":\"missing\",\"bundle_id\":\"com.apple.Preferences\"}"; fi'
  remote_capture "openphone-app-introspector.log.tail" \
    "if [ -f /var/mobile/Library/OpenPhone/openphone-app-introspector.log ]; then tail -n $tail_lines /var/mobile/Library/OpenPhone/openphone-app-introspector.log; fi"
}

collect_lockscreen_sample() {
  if [[ "${OPENPHONE_VALIDATE_INCLUDE_LOCKSCREEN:-0}" != "1" ]]; then
    return
  fi
  log "Collecting lock-screen passcode sample"
  remote_capture "lockscreen-before-screen.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl get_screen screenshot; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  remote_capture "lockscreen-show-passcode.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl show_passcode; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  remote_capture "lockscreen-after-screen.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then sleep 2; /var/jb/usr/local/bin/openphone-agentctl get_screen screenshot; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  remote_capture "lockscreen-status-after.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl agent_status; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
}

collect_prefs_backend_sample() {
  if [[ "${OPENPHONE_VALIDATE_INCLUDE_PREFS_BACKEND:-0}" != "1" ]]; then
    return
  fi
  log "Collecting OpenPhone Settings backend sample"
  remote_capture "prefs-backend-files.json" \
    'bundle="/var/jb/Library/PreferenceBundles/OpenPhoneAgentPrefs.bundle/OpenPhoneAgentPrefs"; info="/var/jb/Library/PreferenceBundles/OpenPhoneAgentPrefs.bundle/Info.plist"; entry="/var/jb/Library/PreferenceLoader/Preferences/OpenPhoneAgentPrefs.plist"; printf "{\"status\":\"ok\",\"bundle_executable\":%s,\"bundle_info\":%s,\"loader_entry\":%s,\"bundle_path\":\"%s\",\"info_path\":\"%s\",\"loader_entry_path\":\"%s\"}\n" "$([ -x "$bundle" ] && printf true || printf false)" "$([ -f "$info" ] && printf true || printf false)" "$([ -f "$entry" ] && printf true || printf false)" "$bundle" "$info" "$entry"'
  remote_capture "prefs-backend-status-before.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl agent_status; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  remote_capture "prefs-backend-disable-hardware.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl '"'"'{"command":"agent_control","hardware_triggers_enabled":false,"reason":"validator prefs backend disable hardware triggers","source":"prefs_backend_validator"}'"'"'; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  remote_capture "prefs-backend-trigger-disabled.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl '"'"'{"command":"hardware_trigger","trigger":"volume_up_down_combo","source":"prefs_backend_validator","reason":"validator hardware disabled suppression","run_task":true,"create_background_job":false,"dedupe":false}'"'"'; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  remote_capture "prefs-backend-enable-hardware.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl '"'"'{"command":"agent_control","hardware_triggers_enabled":true,"reason":"validator prefs backend restore hardware triggers","source":"prefs_backend_validator"}'"'"'; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  remote_capture "prefs-backend-disable-yolo.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl '"'"'{"command":"agent_control","yolo_enabled":false,"reason":"validator prefs backend disable yolo","source":"prefs_backend_validator"}'"'"'; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  remote_capture "prefs-backend-trigger-yolo-disabled.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl '"'"'{"command":"hardware_trigger","trigger":"volume_up_down_combo","source":"prefs_backend_validator","reason":"validator yolo disabled suppression","run_task":true,"create_background_job":false,"dedupe":false}'"'"'; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  remote_capture "prefs-backend-enable-yolo.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl '"'"'{"command":"agent_control","yolo_enabled":true,"reason":"validator prefs backend restore yolo","source":"prefs_backend_validator"}'"'"'; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  remote_capture "prefs-backend-status-after.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl agent_status; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
}

collect_prefs_ui_sample() {
  if [[ "${OPENPHONE_VALIDATE_INCLUDE_PREFS_UI:-0}" != "1" ]]; then
    return
  fi
  log "Collecting OpenPhone Settings UI sample"
  remote_capture "prefs-ui-before-screen.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl get_screen; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  local locked_state
  locked_state="$(OPENPHONE_PREFS_UI_BEFORE_JSON="$run_dir/prefs-ui-before-screen.json" python3 - <<'PY'
import json
import os
import sys

try:
    data = json.load(open(os.environ["OPENPHONE_PREFS_UI_BEFORE_JSON"], "r", encoding="utf-8"))
except Exception:
    print("unknown")
    sys.exit(0)

lock = data.get("context", {}).get("lock", {}) if isinstance(data, dict) else {}
locked = lock.get("locked")
if locked is True:
    print("true")
elif locked is False:
    print("false")
else:
    print("unknown")
PY
)"
  if [[ "$locked_state" != "false" ]]; then
    for name in prefs-ui-prepare prefs-ui-open-url prefs-ui-url-screen prefs-ui-open-settings prefs-ui-settings-screen prefs-ui-tap-row prefs-ui-pane-screen prefs-ui-disable-hardware prefs-ui-after-disable-screen prefs-ui-status-disabled prefs-ui-enable-hardware prefs-ui-after-enable-screen prefs-ui-status-enabled prefs-ui-final-restore prefs-ui-status-after; do
      printf '{"status":"skipped","reason":"device_locked_or_unknown","locked_state":"%s"}\n' "$locked_state" \
        >"$run_dir/$name.json"
    done
    printf '%s\n' "" >"$run_dir/prefs-ui-row-element.txt"
    printf '%s\n' "" >"$run_dir/prefs-ui-hardware-element.txt"
    return
  fi

  remote_capture "prefs-ui-prepare.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl '"'"'{"command":"agent_control","hardware_triggers_enabled":true,"yolo_enabled":true,"reason":"validator prefs UI prepare policy","source":"prefs_ui_validator"}'"'"'; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  remote_capture "prefs-ui-open-url.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then killall Preferences >/dev/null 2>&1 || true; sleep 2; /var/jb/usr/local/bin/openphone-agentctl '"'"'{"command":"execute_action","action":{"type":"open_url","url":"prefs:root=OpenPhoneAgentPrefs","reason":"validator OpenPhone Settings URL launch"}}'"'"'; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  remote_capture "prefs-ui-url-screen.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then sleep 5; /var/jb/usr/local/bin/openphone-agentctl get_screen screenshot; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'

  local pane_visible
  pane_visible="$(OPENPHONE_PREFS_UI_SCREEN_JSON="$run_dir/prefs-ui-url-screen.json" python3 - <<'PY'
import json
import os
import sys

try:
    data = json.load(open(os.environ["OPENPHONE_PREFS_UI_SCREEN_JSON"], "r", encoding="utf-8"))
except Exception:
    print("false")
    sys.exit(0)

tree = data.get("context", {}).get("ui_tree", {}) if isinstance(data, dict) else {}
visible = tree.get("visible_text", []) if isinstance(tree, dict) else []
visible_set = {str(item) for item in visible} if isinstance(visible, list) else set()
required = {"OpenPhone Agent", "Hardware Triggers", "YOLO Execution"}
print("true" if required.issubset(visible_set) else "false")
PY
)"
  if [[ "$pane_visible" == "true" ]]; then
    printf '{"status":"skipped","reason":"pane_opened_by_url"}\n' >"$run_dir/prefs-ui-open-settings.json"
    cp "$run_dir/prefs-ui-url-screen.json" "$run_dir/prefs-ui-settings-screen.json"
    printf '%s\n' "" >"$run_dir/prefs-ui-row-element.txt"
    printf '{"status":"skipped","reason":"pane_opened_by_url"}\n' >"$run_dir/prefs-ui-tap-row.json"
    cp "$run_dir/prefs-ui-url-screen.json" "$run_dir/prefs-ui-pane-screen.json"
  else
    remote_capture "prefs-ui-open-settings.json" \
      'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then killall Preferences >/dev/null 2>&1 || true; sleep 2; /var/jb/usr/local/bin/openphone-agentctl '"'"'{"command":"execute_action","action":{"type":"open_app","bundle_id":"com.apple.Preferences","reason":"validator OpenPhone Settings root launch"}}'"'"'; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
    remote_capture "prefs-ui-settings-screen.json" \
      'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then sleep 5; /var/jb/usr/local/bin/openphone-agentctl get_screen screenshot; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
    local prefs_row_element_id
    prefs_row_element_id="$(OPENPHONE_PREFS_UI_SETTINGS_JSON="$run_dir/prefs-ui-settings-screen.json" python3 - <<'PY'
import json
import os
import re
import sys

try:
    data = json.load(open(os.environ["OPENPHONE_PREFS_UI_SETTINGS_JSON"], "r", encoding="utf-8"))
except Exception:
    sys.exit(0)

elements = data.get("context", {}).get("ui_tree", {}).get("interactive_elements", [])
if not isinstance(elements, list):
    sys.exit(0)
for element in elements:
    if not isinstance(element, dict):
        continue
    label = element.get("label")
    klass = element.get("class")
    bounds = element.get("bounds")
    element_id = element.get("id") or element.get("element_id")
    wide = isinstance(bounds, list) and len(bounds) >= 3 and isinstance(bounds[2], (int, float)) and bounds[2] >= 250
    table_cell = isinstance(klass, str) and "TableCell" in klass
    if label == "OpenPhone Agent" and element.get("enabled") is True and table_cell and wide and isinstance(element_id, str):
        if re.match(r"^[A-Za-z0-9_.:-]+$", element_id):
            print(element_id)
            break
PY
)"
    printf '%s\n' "$prefs_row_element_id" >"$run_dir/prefs-ui-row-element.txt"
    if [[ -n "$prefs_row_element_id" && "$prefs_row_element_id" =~ ^[A-Za-z0-9_.:-]+$ ]]; then
      remote_capture "prefs-ui-tap-row.json" \
        "if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl '{\"command\":\"execute_action\",\"action\":{\"type\":\"tap_element\",\"element_id\":\"$prefs_row_element_id\",\"reason\":\"validator OpenPhone Settings pane row\"}}'; else printf '%s\n' '{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}'; fi"
    else
      printf '{"status":"skipped","reason":"missing_openphone_agent_row"}\n' >"$run_dir/prefs-ui-tap-row.json"
    fi
    remote_capture "prefs-ui-pane-screen.json" \
      'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then sleep 5; /var/jb/usr/local/bin/openphone-agentctl get_screen screenshot; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  fi

  local hardware_element_id
  hardware_element_id="$(OPENPHONE_PREFS_UI_PANE_JSON="$run_dir/prefs-ui-pane-screen.json" python3 - <<'PY'
import json
import os
import re
import sys

try:
    data = json.load(open(os.environ["OPENPHONE_PREFS_UI_PANE_JSON"], "r", encoding="utf-8"))
except Exception:
    sys.exit(0)

elements = data.get("context", {}).get("ui_tree", {}).get("interactive_elements", [])
if not isinstance(elements, list):
    sys.exit(0)

def valid_id(value):
    return isinstance(value, str) and re.match(r"^[A-Za-z0-9_.:-]+$", value)

fallback = ""
for element in elements:
    if not isinstance(element, dict):
        continue
    element_id = element.get("id") or element.get("element_id")
    if not valid_id(element_id):
        continue
    label = element.get("label")
    klass = element.get("class")
    kind = element.get("kind")
    if label == "Hardware Triggers" and ((isinstance(klass, str) and "Switch" in klass) or kind == "switch"):
        print(element_id)
        sys.exit(0)
    if not fallback and label == "Hardware Triggers":
        fallback = element_id
if fallback:
    print(fallback)
PY
)"
  printf '%s\n' "$hardware_element_id" >"$run_dir/prefs-ui-hardware-element.txt"
  if [[ -n "$hardware_element_id" && "$hardware_element_id" =~ ^[A-Za-z0-9_.:-]+$ ]]; then
    remote_capture "prefs-ui-disable-hardware.json" \
      "if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl '{\"command\":\"execute_action\",\"action\":{\"type\":\"tap_element\",\"element_id\":\"$hardware_element_id\",\"reason\":\"validator OpenPhone Settings disable Hardware Triggers\"}}'; else printf '%s\n' '{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}'; fi"
  else
    printf '{"status":"skipped","reason":"missing_hardware_triggers_element"}\n' >"$run_dir/prefs-ui-disable-hardware.json"
  fi
  remote_capture "prefs-ui-after-disable-screen.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then sleep 3; /var/jb/usr/local/bin/openphone-agentctl get_screen screenshot; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  remote_capture "prefs-ui-status-disabled.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl agent_status; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'

  local restore_hardware_element_id
  local refreshed_hardware_element_id
  restore_hardware_element_id="$hardware_element_id"
  refreshed_hardware_element_id="$(OPENPHONE_PREFS_UI_PANE_JSON="$run_dir/prefs-ui-after-disable-screen.json" python3 - <<'PY'
import json
import os
import re
import sys

try:
    data = json.load(open(os.environ["OPENPHONE_PREFS_UI_PANE_JSON"], "r", encoding="utf-8"))
except Exception:
    sys.exit(0)

elements = data.get("context", {}).get("ui_tree", {}).get("interactive_elements", [])
if not isinstance(elements, list):
    sys.exit(0)

def valid_id(value):
    return isinstance(value, str) and re.match(r"^[A-Za-z0-9_.:-]+$", value)

fallback = ""
for element in elements:
    if not isinstance(element, dict):
        continue
    element_id = element.get("id") or element.get("element_id")
    if not valid_id(element_id):
        continue
    label = element.get("label")
    klass = element.get("class")
    kind = element.get("kind")
    if label == "Hardware Triggers" and ((isinstance(klass, str) and "Switch" in klass) or kind == "switch"):
        print(element_id)
        sys.exit(0)
    if not fallback and label == "Hardware Triggers":
        fallback = element_id
if fallback:
    print(fallback)
PY
)"
  if [[ -n "$refreshed_hardware_element_id" && "$refreshed_hardware_element_id" =~ ^[A-Za-z0-9_.:-]+$ ]]; then
    restore_hardware_element_id="$refreshed_hardware_element_id"
  fi

  if [[ -n "$restore_hardware_element_id" && "$restore_hardware_element_id" =~ ^[A-Za-z0-9_.:-]+$ ]]; then
    remote_capture "prefs-ui-enable-hardware.json" \
      "if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl '{\"command\":\"execute_action\",\"action\":{\"type\":\"tap_element\",\"element_id\":\"$restore_hardware_element_id\",\"reason\":\"validator OpenPhone Settings restore Hardware Triggers\"}}'; else printf '%s\n' '{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}'; fi"
  else
    printf '{"status":"skipped","reason":"missing_hardware_triggers_element"}\n' >"$run_dir/prefs-ui-enable-hardware.json"
  fi
  remote_capture "prefs-ui-after-enable-screen.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then sleep 3; /var/jb/usr/local/bin/openphone-agentctl get_screen screenshot; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  remote_capture "prefs-ui-status-enabled.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl agent_status; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  remote_capture "prefs-ui-final-restore.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl '"'"'{"command":"agent_control","hardware_triggers_enabled":true,"yolo_enabled":true,"reason":"validator prefs UI final restore","source":"prefs_ui_validator"}'"'"'; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  remote_capture "prefs-ui-status-after.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl agent_status; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
}

collect_visible_effect_sample() {
  if [[ "${OPENPHONE_VALIDATE_INCLUDE_VISIBLE_EFFECTS:-0}" != "1" ]]; then
    return
  fi
  log "Collecting visible-effect UI sample"
  remote_capture "visible-effects-before-screen.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl get_screen; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  local locked_state
  locked_state="$(OPENPHONE_VISIBLE_EFFECTS_BEFORE_JSON="$run_dir/visible-effects-before-screen.json" python3 - <<'PY'
import json
import os
import sys

try:
    data = json.load(open(os.environ["OPENPHONE_VISIBLE_EFFECTS_BEFORE_JSON"], "r", encoding="utf-8"))
except Exception:
    print("unknown")
    sys.exit(0)

lock = data.get("context", {}).get("lock", {}) if isinstance(data, dict) else {}
locked = lock.get("locked")
if locked is True:
    print("true")
elif locked is False:
    print("false")
else:
    print("unknown")
PY
)"
  if [[ "$locked_state" != "false" ]]; then
    for name in visible-effects-open-settings visible-effects-settings-precheck visible-effects-settings-reset visible-effects-settings-before visible-effects-tap-settings visible-effects-settings-after visible-effects-open-safari visible-effects-safari-before visible-effects-type-safari visible-effects-safari-after visible-effects-safari-state visible-effects-open-notes visible-effects-notes-before visible-effects-type-notes visible-effects-notes-after visible-effects-notes-state; do
      printf '{"status":"skipped","reason":"device_locked_or_unknown","locked_state":"%s"}\n' "$locked_state" \
        >"$run_dir/$name.json"
    done
    printf '%s\n' "" >"$run_dir/visible-effects-settings-scenario.txt"
    printf '%s\n' "" >"$run_dir/visible-effects-settings-target-label.txt"
    printf '%s\n' "" >"$run_dir/visible-effects-settings-back-element.txt"
    printf '%s\n' "" >"$run_dir/visible-effects-settings-element.txt"
    printf '%s\n' "" >"$run_dir/visible-effects-safari-field.txt"
    printf '%s\n' "" >"$run_dir/visible-effects-safari-marker.txt"
    printf '%s\n' "" >"$run_dir/visible-effects-notes-field.txt"
    printf '%s\n' "" >"$run_dir/visible-effects-notes-marker.txt"
    return
  fi

  remote_capture "visible-effects-open-settings.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then killall Preferences >/dev/null 2>&1 || true; sleep 2; /var/jb/usr/local/bin/openphone-agentctl '"'"'{"command":"execute_action","action":{"type":"open_app","bundle_id":"com.apple.Preferences","reason":"validator visible-effect Settings launch"}}'"'"'; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  remote_capture "visible-effects-settings-precheck.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then sleep 5; /var/jb/usr/local/bin/openphone-agentctl get_screen screenshot; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  cp "$run_dir/visible-effects-settings-precheck.json" "$run_dir/visible-effects-settings-before.json"
  printf '%s\n' "" >"$run_dir/visible-effects-settings-back-element.txt"
  printf '%s\n' '{"status":"skipped","reason":"adaptive_settings_target_does_not_require_root_reset"}' >"$run_dir/visible-effects-settings-reset.json"
  local settings_target
  settings_target="$(OPENPHONE_VISIBLE_EFFECTS_SETTINGS_PRECHECK_JSON="$run_dir/visible-effects-settings-precheck.json" python3 - <<'PY'
import json
import os
import sys

try:
    data = json.load(open(os.environ["OPENPHONE_VISIBLE_EFFECTS_SETTINGS_PRECHECK_JSON"], "r", encoding="utf-8"))
except Exception:
    sys.exit(0)

tree = data.get("context", {}).get("ui_tree", {})
visible = tree.get("visible_text", []) if isinstance(tree, dict) else []
visible_set = {str(item) for item in visible} if isinstance(visible, list) else set()
if {"Text Replacement", "Keyboards"}.issubset(visible_set) and (
    "Enable Dictation" in visible_set or "One-Handed Keyboard" in visible_set
):
    print("keyboard_to_keyboards\tKeyboards")
elif {"Add New Keyboard…", "English (US)", "Emoji", "Keyboards"}.issubset(visible_set):
    print("keyboards_to_english\tEnglish (US)")
elif {"About", "Software Update", "Keyboard"}.issubset(visible_set):
    print("general_to_keyboard\tKeyboard")
else:
    print("root_to_general\tGeneral")
PY
)"
  local settings_scenario="${settings_target%%$'\t'*}"
  local settings_target_label="${settings_target#*$'\t'}"
  if [[ -z "$settings_scenario" || "$settings_scenario" == "$settings_target" ]]; then
    settings_scenario="root_to_general"
    settings_target_label="General"
  fi
  printf '%s\n' "$settings_scenario" >"$run_dir/visible-effects-settings-scenario.txt"
  printf '%s\n' "$settings_target_label" >"$run_dir/visible-effects-settings-target-label.txt"
  local settings_element_id
  settings_element_id="$(OPENPHONE_VISIBLE_EFFECTS_SETTINGS_BEFORE_JSON="$run_dir/visible-effects-settings-before.json" OPENPHONE_VISIBLE_EFFECTS_SETTINGS_TARGET_LABEL="$settings_target_label" python3 - <<'PY'
import json
import os
import re
import sys

try:
    data = json.load(open(os.environ["OPENPHONE_VISIBLE_EFFECTS_SETTINGS_BEFORE_JSON"], "r", encoding="utf-8"))
except Exception:
    sys.exit(0)

elements = data.get("context", {}).get("ui_tree", {}).get("interactive_elements", [])
if not isinstance(elements, list):
    sys.exit(0)
target_label = os.environ.get("OPENPHONE_VISIBLE_EFFECTS_SETTINGS_TARGET_LABEL", "General")
for element in elements:
    if not isinstance(element, dict):
        continue
    label = element.get("label")
    klass = element.get("class")
    bounds = element.get("bounds")
    element_id = element.get("id") or element.get("element_id")
    wide = isinstance(bounds, list) and len(bounds) >= 3 and isinstance(bounds[2], (int, float)) and bounds[2] >= 250
    table_cell = isinstance(klass, str) and "TableCell" in klass
    if label == target_label and element.get("enabled") is True and table_cell and wide and isinstance(element_id, str):
        if re.match(r"^[A-Za-z0-9_.:-]+$", element_id):
            print(element_id)
            break
PY
)"
  printf '%s\n' "$settings_element_id" >"$run_dir/visible-effects-settings-element.txt"
  if [[ -n "$settings_element_id" && "$settings_element_id" =~ ^[A-Za-z0-9_.:-]+$ ]]; then
    remote_capture "visible-effects-tap-settings.json" \
      "if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl '{\"command\":\"execute_action\",\"action\":{\"type\":\"tap_element\",\"element_id\":\"$settings_element_id\",\"reason\":\"validator visible-effect Settings $settings_target_label row\"}}'; else printf '%s\n' '{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}'; fi"
  else
    printf '{"status":"skipped","reason":"missing_settings_target_element","target_label":%s}\n' "$(safe_json_string "$settings_target_label")" >"$run_dir/visible-effects-tap-settings.json"
  fi
  remote_capture "visible-effects-settings-after.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then sleep 5; /var/jb/usr/local/bin/openphone-agentctl get_screen screenshot; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'

  local marker
  marker="OPVisibleEffect-$(date '+%H%M%S')"
  printf '%s\n' "$marker" >"$run_dir/visible-effects-safari-marker.txt"
  remote_capture "visible-effects-open-safari.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then killall MobileSafari >/dev/null 2>&1 || true; sleep 2; /var/jb/usr/local/bin/openphone-agentctl '"'"'{"command":"execute_action","action":{"type":"open_url","url":"https://www.wikipedia.org/","reason":"validator visible-effect Safari launch"}}'"'"'; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  remote_capture "visible-effects-safari-before.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then sleep 8; /var/jb/usr/local/bin/openphone-agentctl get_screen screenshot; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  local safari_field_id
  safari_field_id="$(OPENPHONE_VISIBLE_EFFECTS_SAFARI_BEFORE_JSON="$run_dir/visible-effects-safari-before.json" python3 - <<'PY'
import json
import os
import re
import sys

try:
    data = json.load(open(os.environ["OPENPHONE_VISIBLE_EFFECTS_SAFARI_BEFORE_JSON"], "r", encoding="utf-8"))
except Exception:
    sys.exit(0)

elements = data.get("context", {}).get("ui_tree", {}).get("interactive_elements", [])
if not isinstance(elements, list):
    sys.exit(0)
for element in elements:
    if not isinstance(element, dict):
        continue
    element_id = element.get("id") or element.get("element_id")
    if not isinstance(element_id, str) or not element_id.startswith("app-com.apple.mobilesafari-web-"):
        continue
    label = element.get("label")
    kind = element.get("kind")
    tag = element.get("tag")
    input_type = element.get("input_type")
    if label == "INPUT" or kind == "web_text_field" or tag == "input" or input_type == "search":
        if re.match(r"^[A-Za-z0-9_.:-]+$", element_id):
            print(element_id)
            break
PY
)"
  printf '%s\n' "$safari_field_id" >"$run_dir/visible-effects-safari-field.txt"
  if [[ -n "$safari_field_id" && "$safari_field_id" =~ ^[A-Za-z0-9_.:-]+$ ]]; then
    remote_capture "visible-effects-type-safari.json" \
      "if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl '{\"command\":\"execute_action\",\"action\":{\"type\":\"type_text\",\"element_id\":\"$safari_field_id\",\"text\":$(safe_json_string "$marker"),\"reason\":\"validator visible-effect Safari DOM text entry\"}}'; else printf '%s\n' '{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}'; fi"
  else
    printf '%s\n' '{"status":"skipped","reason":"missing_safari_dom_field"}' >"$run_dir/visible-effects-type-safari.json"
  fi
  remote_capture "visible-effects-safari-after.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then sleep 3; /var/jb/usr/local/bin/openphone-agentctl get_screen screenshot; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  remote_capture "visible-effects-safari-state.json" \
    'if [ -f /var/mobile/Library/OpenPhone/app-ui/com.apple.mobilesafari.json ]; then cat /var/mobile/Library/OpenPhone/app-ui/com.apple.mobilesafari.json; else printf "%s\n" "{\"status\":\"missing\",\"bundle_id\":\"com.apple.mobilesafari\"}"; fi'

  local notes_marker
  notes_marker="OPVisibleNotes-$(date '+%H%M%S')"
  printf '%s\n' "$notes_marker" >"$run_dir/visible-effects-notes-marker.txt"
  remote_capture "visible-effects-open-notes.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl '"'"'{"command":"execute_action","action":{"type":"open_app","bundle_id":"com.apple.mobilenotes","reason":"validator visible-effect Notes launch"}}'"'"'; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  remote_capture "visible-effects-notes-before.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then sleep 5; /var/jb/usr/local/bin/openphone-agentctl get_screen screenshot; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  local notes_field_id
  notes_field_id="$(OPENPHONE_VISIBLE_EFFECTS_NOTES_BEFORE_JSON="$run_dir/visible-effects-notes-before.json" python3 - <<'PY'
import json
import os
import re
import sys

try:
    data = json.load(open(os.environ["OPENPHONE_VISIBLE_EFFECTS_NOTES_BEFORE_JSON"], "r", encoding="utf-8"))
except Exception:
    sys.exit(0)

elements = data.get("context", {}).get("ui_tree", {}).get("interactive_elements", [])
if not isinstance(elements, list):
    sys.exit(0)
for element in elements:
    if not isinstance(element, dict):
        continue
    element_id = element.get("id") or element.get("element_id")
    if not isinstance(element_id, str) or not element_id.startswith("app-com.apple.mobilenotes-"):
        continue
    klass = element.get("class")
    kind = element.get("kind")
    source_bundle = element.get("source_bundle_id")
    editable = (
        kind in ("text_area", "text_field")
        or (isinstance(klass, str) and ("TextView" in klass or "TextField" in klass))
    )
    if source_bundle == "com.apple.mobilenotes" and editable and element.get("enabled") is True and not element.get("sensitive"):
        if re.match(r"^[A-Za-z0-9_.:-]+$", element_id):
            print(element_id)
            break
PY
)"
  printf '%s\n' "$notes_field_id" >"$run_dir/visible-effects-notes-field.txt"
  if [[ -n "$notes_field_id" && "$notes_field_id" =~ ^[A-Za-z0-9_.:-]+$ ]]; then
    remote_capture "visible-effects-type-notes.json" \
      "if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then /var/jb/usr/local/bin/openphone-agentctl '{\"command\":\"execute_action\",\"action\":{\"type\":\"type_text\",\"element_id\":\"$notes_field_id\",\"text\":$(safe_json_string "$notes_marker"),\"reason\":\"validator visible-effect Notes body text entry\"}}'; else printf '%s\n' '{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}'; fi"
  else
    printf '%s\n' '{"status":"skipped","reason":"missing_notes_text_field"}' >"$run_dir/visible-effects-type-notes.json"
  fi
  remote_capture "visible-effects-notes-after.json" \
    'if [ -x /var/jb/usr/local/bin/openphone-agentctl ]; then sleep 3; /var/jb/usr/local/bin/openphone-agentctl get_screen screenshot; else printf "%s\n" "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"; fi'
  remote_capture "visible-effects-notes-state.json" \
    'if [ -f /var/mobile/Library/OpenPhone/app-ui/com.apple.mobilenotes.json ]; then cat /var/mobile/Library/OpenPhone/app-ui/com.apple.mobilenotes.json; else printf "%s\n" "{\"status\":\"missing\",\"bundle_id\":\"com.apple.mobilenotes\"}"; fi'
}

generate_report() {
  OPENPHONE_VALIDATE_MODE="$mode" \
  OPENPHONE_VALIDATE_RUN_ID="$run_id" \
  OPENPHONE_VALIDATE_PACKAGE="$package" \
  OPENPHONE_VALIDATE_INSTALLED="$([[ "$mode" == "collect-only" ]] && printf false || printf true)" \
  OPENPHONE_VALIDATE_REQUIRE_UNLOCKED="${OPENPHONE_VALIDATE_REQUIRE_UNLOCKED:-0}" \
  OPENPHONE_VALIDATE_INCLUDE_SCREENSHOT="${OPENPHONE_VALIDATE_INCLUDE_SCREENSHOT:-0}" \
  OPENPHONE_VALIDATE_INCLUDE_UNLOCKED_FOREGROUND="${OPENPHONE_VALIDATE_INCLUDE_UNLOCKED_FOREGROUND:-0}" \
  OPENPHONE_VALIDATE_INCLUDE_APP_UI="${OPENPHONE_VALIDATE_INCLUDE_APP_UI:-0}" \
  OPENPHONE_VALIDATE_INCLUDE_LOCKSCREEN="${OPENPHONE_VALIDATE_INCLUDE_LOCKSCREEN:-0}" \
  OPENPHONE_VALIDATE_INCLUDE_PREFS_UI="${OPENPHONE_VALIDATE_INCLUDE_PREFS_UI:-0}" \
  OPENPHONE_VALIDATE_INCLUDE_PREFS_BACKEND="${OPENPHONE_VALIDATE_INCLUDE_PREFS_BACKEND:-0}" \
  OPENPHONE_VALIDATE_INCLUDE_STORES="${OPENPHONE_VALIDATE_INCLUDE_STORES:-0}" \
  OPENPHONE_VALIDATE_INCLUDE_PROVIDER_ATTEMPTS="${OPENPHONE_VALIDATE_INCLUDE_PROVIDER_ATTEMPTS:-0}" \
  OPENPHONE_VALIDATE_INCLUDE_VISIBLE_EFFECTS="${OPENPHONE_VALIDATE_INCLUDE_VISIBLE_EFFECTS:-0}" \
  OPENPHONE_VALIDATE_INCLUDE_MEMORY_LIFECYCLE="${OPENPHONE_VALIDATE_INCLUDE_MEMORY_LIFECYCLE:-0}" \
  OPENPHONE_VALIDATE_INCLUDE_MODEL_LOOP="${OPENPHONE_VALIDATE_INCLUDE_MODEL_LOOP:-0}" \
  OPENPHONE_VALIDATE_INCLUDE_PROVIDER_MODEL="${OPENPHONE_VALIDATE_INCLUDE_PROVIDER_MODEL:-0}" \
  OPENPHONE_VALIDATE_INCLUDE_SAFARI_DOM_MODEL="${OPENPHONE_VALIDATE_INCLUDE_SAFARI_DOM_MODEL:-0}" \
  OPENPHONE_VALIDATE_INCLUDE_PROMPT_BRIDGE_MODEL="${OPENPHONE_VALIDATE_INCLUDE_PROMPT_BRIDGE_MODEL:-0}" \
  OPENPHONE_VALIDATE_INCLUDE_TRIGGER_DIAGNOSTICS="${OPENPHONE_VALIDATE_INCLUDE_TRIGGER_DIAGNOSTICS:-0}" \
  OPENPHONE_VALIDATE_INCLUDE_WATCHER_TIMER="${OPENPHONE_VALIDATE_INCLUDE_WATCHER_TIMER:-0}" \
  OPENPHONE_VALIDATE_INCLUDE_WATCHER_REPAIR="${OPENPHONE_VALIDATE_INCLUDE_WATCHER_REPAIR:-0}" \
  OPENPHONE_VALIDATE_INCLUDE_JOB_REPAIR="${OPENPHONE_VALIDATE_INCLUDE_JOB_REPAIR:-0}" \
  OPENPHONE_VALIDATE_INCLUDE_RESTART_RECOVERY="${OPENPHONE_VALIDATE_INCLUDE_RESTART_RECOVERY:-0}" \
  OPENPHONE_VALIDATE_RUN_DIR="$run_dir" \
  python3 - <<'PY'
import datetime
import json
import os
import pathlib
import re
import sys

run_dir = pathlib.Path(os.environ["OPENPHONE_VALIDATE_RUN_DIR"])
mode = os.environ["OPENPHONE_VALIDATE_MODE"]
package_path = os.environ.get("OPENPHONE_VALIDATE_PACKAGE", "")

def read_text(name):
    path = run_dir / name
    if not path.exists():
        return ""
    return path.read_text(encoding="utf-8", errors="replace")

def read_json(name):
    text = read_text(name).strip()
    if not text:
        return {}
    try:
        return json.loads(text)
    except Exception:
        start = text.find("{")
        end = text.rfind("}")
        if start >= 0 and end > start:
            try:
                return json.loads(text[start:end + 1])
            except Exception:
                return {"status": "error", "reason": "invalid_json", "artifact": name}
        return {"status": "error", "reason": "invalid_json", "artifact": name}

def latest_crash(name):
    crashes = []
    for line in read_text(name).splitlines():
        line = line.strip()
        if line:
            crashes.append(pathlib.Path(line).name)
    return max(set(crashes)) if crashes else ""

def status_of(name):
    data = read_json(name)
    return data.get("status") if isinstance(data, dict) else None

def nested_value(data, path, default=None):
    value = data
    for key in path:
        if isinstance(value, dict):
            value = value.get(key)
        else:
            return default
    return default if value is None else value

def int_value(value, default=0):
    try:
        return int(value)
    except Exception:
        return default

def trigger_status_from(data):
    if not isinstance(data, dict):
        return {}
    if data.get("schema") == "openphone.springboard_trigger_status.v1":
        return data
    if "hooks" in data and (
        "button_events_seen" in data
        or "combo_events_seen" in data
        or "volume_notification" in data
    ):
        return data
    fallback = nested_value(data, ["triggers", "volume_combo", "springboard_fallback"], {})
    return fallback if isinstance(fallback, dict) else {}

def trigger_snapshot(data):
    status = trigger_status_from(data)
    hooks = status.get("hooks") if isinstance(status.get("hooks"), dict) else {}
    volume_notification = (
        status.get("volume_notification")
        if isinstance(status.get("volume_notification"), dict)
        else {}
    )
    return {
        "status": status.get("status"),
        "event": status.get("event"),
        "volume_hooked": int_value(hooks.get("volume_hooked")),
        "volume_total": int_value(hooks.get("volume_total")),
        "any_volume_hooked": bool(hooks.get("any_volume_hooked")),
        "button_events_seen": int_value(status.get("button_events_seen")),
        "combo_events_seen": int_value(status.get("combo_events_seen")),
        "last_button_event": status.get("last_button_event") or "",
        "last_button_event_source": status.get("last_button_event_source") or "",
        "last_button_event_ms": int_value(status.get("last_button_event_ms")),
        "last_combo_event_ms": int_value(status.get("last_combo_event_ms")),
        "last_trigger_route": status.get("last_trigger_route") or "",
        "volume_notification": {
            "installed": bool(volume_notification.get("installed")),
            "seeded": bool(volume_notification.get("seeded")),
            "events_seen": int_value(volume_notification.get("events_seen")),
            "last_event_ms": int_value(volume_notification.get("last_event_ms")),
            "last_volume": volume_notification.get("last_volume"),
            "last_direction": volume_notification.get("last_direction") or "",
            "last_reason": volume_notification.get("last_reason") or "",
            "last_category": volume_notification.get("last_category") or "",
        },
    }

def task_summary_from_agent_status(data):
    if not isinstance(data, dict):
        return {}
    latest = data.get("latest_task") if isinstance(data.get("latest_task"), dict) else {}
    current = data.get("current_task") if isinstance(data.get("current_task"), dict) else {}
    return {
        "latest_task_id": latest.get("task_id") or "",
        "latest_status": latest.get("status") or "",
        "latest_runner": latest.get("runner") or "",
        "latest_source": latest.get("source") or "",
        "latest_model_provider": latest.get("model_provider") or "",
        "latest_model_loop_status": latest.get("model_loop_status") or "",
        "latest_stop_reason": latest.get("stop_reason") or "",
        "current_task_id": current.get("task_id") or "",
        "current_status": current.get("status") or "",
        "current_runner": current.get("runner") or "",
    }

def check_trigger_diagnostics_shape():
    before_trigger = read_json("trigger-diagnostics-before-trigger.json")
    after_trigger = read_json("trigger-diagnostics-after-trigger.json")
    before_status = read_json("trigger-diagnostics-before-status.json")
    after_status = read_json("trigger-diagnostics-after-status.json")
    before = trigger_snapshot(before_trigger or before_status)
    after = trigger_snapshot(after_trigger or after_status)
    before_task = task_summary_from_agent_status(before_status)
    after_task = task_summary_from_agent_status(after_status)
    button_delta = max(0, after["button_events_seen"] - before["button_events_seen"])
    combo_delta = max(0, after["combo_events_seen"] - before["combo_events_seen"])
    notification_delta = max(
        0,
        after["volume_notification"]["events_seen"]
        - before["volume_notification"]["events_seen"],
    )
    latest_task_changed = (
        bool(after_task["latest_task_id"])
        and after_task["latest_task_id"] != before_task["latest_task_id"]
    )
    current_task_started = bool(after_task["current_task_id"])
    agent_task_observed = latest_task_changed or current_task_started
    latest_runner = after_task["latest_runner"] or after_task["current_runner"]
    checks = {
        "ok": True,
        "errors": [],
        "before": before,
        "after": after,
        "button_event_delta": button_delta,
        "combo_event_delta": combo_delta,
        "volume_notification_event_delta": notification_delta,
        "before_task": before_task,
        "after_task": after_task,
        "latest_task_changed": latest_task_changed,
        "current_task_started": current_task_started,
        "agent_task_observed": agent_task_observed,
    }
    if after["status"] not in ("enabled", "disabled"):
        checks["ok"] = False
        checks["errors"].append(f"trigger_status:{after['status']}")
    if after["status"] != "enabled":
        checks["ok"] = False
        checks["errors"].append("trigger_not_enabled")
    if after["volume_hooked"] <= 0 and not after["volume_notification"]["installed"]:
        checks["ok"] = False
        checks["errors"].append("no_volume_hook_or_notification_observer")
    if button_delta <= 0 and notification_delta <= 0:
        checks["ok"] = False
        checks["errors"].append("no_physical_volume_event_observed")
    if combo_delta <= 0:
        checks["ok"] = False
        checks["errors"].append("volume_combo_not_observed")
    if combo_delta > 0 and not agent_task_observed:
        checks["ok"] = False
        checks["errors"].append("combo_observed_without_new_agent_task")
    if combo_delta > 0 and agent_task_observed and latest_runner and latest_runner != "model":
        checks["ok"] = False
        checks["errors"].append(f"trigger_task_runner:{latest_runner}")
    return checks

def check_response_shape(name, list_key=None, item_keys=(), required_keys=()):
    data = read_json(name)
    checks = {
        "artifact": name,
        "ok": True,
        "status": data.get("status") if isinstance(data, dict) else None,
        "errors": [],
    }
    if not isinstance(data, dict):
        checks["ok"] = False
        checks["errors"].append("not_object")
        return checks
    if data.get("status") != "ok":
        checks["ok"] = False
        checks["errors"].append("status_not_ok")
    for key in required_keys:
        if key not in data:
            checks["ok"] = False
            checks["errors"].append(f"missing:{key}")
    if list_key:
        items = data.get(list_key)
        if not isinstance(items, list):
            checks["ok"] = False
            checks["errors"].append(f"{list_key}_not_list")
            items = []
        count = data.get("count")
        if not isinstance(count, int) or count < 0:
            checks["ok"] = False
            checks["errors"].append("count_not_nonnegative_int")
        elif len(items) > count:
            checks["ok"] = False
            checks["errors"].append(f"{list_key}_longer_than_count")
        checks["count"] = count if isinstance(count, int) else None
        checks["items_seen"] = len(items)
        if item_keys and items:
            for index, item in enumerate(items[:5]):
                if not isinstance(item, dict):
                    checks["ok"] = False
                    checks["errors"].append(f"{list_key}[{index}]_not_object")
                    continue
                for key in item_keys:
                    if key not in item:
                        checks["ok"] = False
                        checks["errors"].append(f"{list_key}[{index}]_missing:{key}")
    return checks

def check_task_detail_shape(name):
    data = read_json(name)
    checks = {
        "artifact": name,
        "ok": True,
        "status": data.get("status") if isinstance(data, dict) else None,
        "errors": [],
    }
    if not isinstance(data, dict):
        checks["ok"] = False
        checks["errors"].append("not_object")
        return checks
    if data.get("status") != "ok":
        checks["ok"] = False
        checks["errors"].append("status_not_ok")
    task = data.get("task")
    if not isinstance(task, dict):
        checks["ok"] = False
        checks["errors"].append("task_not_object")
        task = {}
    task_id = data.get("task_id")
    if not isinstance(task_id, str) or not task_id:
        checks["ok"] = False
        checks["errors"].append("missing_task_id")
    elif task.get("task_id") != task_id:
        checks["ok"] = False
        checks["errors"].append("task_id_mismatch")
    for key in ("state", "status", "autonomy_mode", "goal"):
        if key not in task:
            checks["ok"] = False
            checks["errors"].append(f"task_missing:{key}")
    checks["task_id"] = task_id if isinstance(task_id, str) else ""
    return checks

def check_provider_attempt_shapes(root):
    checks = {
        "status": "not_observed",
        "attempts_seen": 0,
        "modern_attempts": 0,
        "legacy_attempts": 0,
        "errors": [],
    }

    def walk(value, path):
        if isinstance(value, dict):
            attempts = value.get("provider_attempts")
            if isinstance(attempts, list):
                for index, attempt in enumerate(attempts[:20]):
                    attempt_path = f"{path}.provider_attempts[{index}]"
                    checks["attempts_seen"] += 1
                    if not isinstance(attempt, dict):
                        checks["errors"].append(f"{attempt_path}_not_object")
                        continue
                    modern = any(key in attempt for key in (
                        "scope",
                        "action_type",
                        "verification",
                        "dispatch_metadata",
                    ))
                    if not modern:
                        checks["legacy_attempts"] += 1
                        continue
                    checks["modern_attempts"] += 1
                    for key in ("provider", "scope", "action_type", "status"):
                        if not isinstance(attempt.get(key), str) or not attempt.get(key):
                            checks["errors"].append(f"{attempt_path}_missing:{key}")
                    if attempt.get("status") not in ("ok", "unavailable", "not_attempted"):
                        checks["errors"].append(f"{attempt_path}_status")
                    verification = attempt.get("verification")
                    if not isinstance(verification, dict):
                        checks["errors"].append(f"{attempt_path}_verification_not_object")
                    else:
                        if verification.get("status") not in ("verified", "unverified", "failed"):
                            checks["errors"].append(f"{attempt_path}_verification_status")
                        for key in ("source", "reason"):
                            if not isinstance(verification.get(key), str) or not verification.get(key):
                                checks["errors"].append(f"{attempt_path}_verification_missing:{key}")
            for key, item in value.items():
                walk(item, f"{path}.{key}" if path else str(key))
        elif isinstance(value, list):
            for index, item in enumerate(value[:50]):
                walk(item, f"{path}[{index}]")

    walk(root, "")
    if checks["errors"]:
        checks["status"] = "fail"
    elif checks["modern_attempts"] > 0:
        checks["status"] = "pass"
    elif checks["legacy_attempts"] > 0:
        checks["status"] = "legacy_only"
    return checks

def check_provider_attempt_sample_shape(name):
    data = read_json(name)
    checks = {
        "artifact": name,
        "ok": True,
        "state": data.get("state") if isinstance(data, dict) else None,
        "errors": [],
    }
    if not isinstance(data, dict):
        checks["ok"] = False
        checks["errors"].append("not_object")
        checks["provider_attempts"] = check_provider_attempt_shapes({})
        return checks
    state = data.get("state")
    if not isinstance(state, str) or not state:
        checks["ok"] = False
        checks["errors"].append("missing_state")
    attempts = check_provider_attempt_shapes(data)
    checks["provider_attempts"] = attempts
    if attempts["status"] != "pass":
        checks["ok"] = False
        checks["errors"].append(f"provider_attempts:{attempts['status']}")
    verification = data.get("verification")
    if not isinstance(verification, dict):
        checks["ok"] = False
        checks["errors"].append("verification_not_object")
    elif verification.get("status") not in ("verified", "unverified", "failed"):
        checks["ok"] = False
        checks["errors"].append("verification_status")
    if data.get("user_facing_status") not in ("verified", "dispatch_unverified", "failed"):
        checks["ok"] = False
        checks["errors"].append("user_facing_status")
    return checks

def check_memory_lifecycle_shape():
    artifacts = {
        "save_primary": read_json("memory-lifecycle-save-primary.json"),
        "update": read_json("memory-lifecycle-update.json"),
        "save_source": read_json("memory-lifecycle-save-source.json"),
        "merge": read_json("memory-lifecycle-merge.json"),
        "save_delete": read_json("memory-lifecycle-save-delete.json"),
        "delete": read_json("memory-lifecycle-delete.json"),
        "search": read_json("memory-lifecycle-search.json"),
    }
    checks = {
        "ok": True,
        "errors": [],
        "artifacts": {},
    }
    for name, data in artifacts.items():
        status = data.get("status") if isinstance(data, dict) else None
        checks["artifacts"][name] = {"status": status}
        if status != "ok":
            checks["ok"] = False
            checks["errors"].append(f"{name}_status:{status}")

    primary_id = artifacts["save_primary"].get("memory", {}).get("memory_id") if isinstance(artifacts["save_primary"].get("memory"), dict) else ""
    source_id = artifacts["save_source"].get("memory", {}).get("memory_id") if isinstance(artifacts["save_source"].get("memory"), dict) else ""
    delete_id = artifacts["save_delete"].get("memory", {}).get("memory_id") if isinstance(artifacts["save_delete"].get("memory"), dict) else ""
    update_memory = artifacts["update"].get("memory") if isinstance(artifacts["update"].get("memory"), dict) else {}
    merge_memory = artifacts["merge"].get("memory") if isinstance(artifacts["merge"].get("memory"), dict) else {}

    if not primary_id:
        checks["ok"] = False
        checks["errors"].append("missing_primary_id")
    if not source_id:
        checks["ok"] = False
        checks["errors"].append("missing_source_id")
    if not delete_id:
        checks["ok"] = False
        checks["errors"].append("missing_delete_id")
    if update_memory.get("memory_id") != primary_id:
        checks["ok"] = False
        checks["errors"].append("update_primary_id_mismatch")
    if merge_memory.get("memory_id") != primary_id:
        checks["ok"] = False
        checks["errors"].append("merge_primary_id_mismatch")
    if artifacts["merge"].get("merged_from") != source_id:
        checks["ok"] = False
        checks["errors"].append("merge_source_id_mismatch")
    if artifacts["delete"].get("memory_id") != delete_id or artifacts["delete"].get("deleted") is not True:
        checks["ok"] = False
        checks["errors"].append("delete_result_mismatch")

    memories = artifacts["search"].get("memories")
    if not isinstance(memories, list):
        checks["ok"] = False
        checks["errors"].append("search_memories_not_list")
        memories = []
    if primary_id and not any(item.get("memory_id") == primary_id for item in memories if isinstance(item, dict)):
        checks["ok"] = False
        checks["errors"].append("merged_memory_not_searchable")
    if source_id and any(item.get("memory_id") == source_id for item in memories if isinstance(item, dict)):
        checks["ok"] = False
        checks["errors"].append("source_memory_still_searchable")
    if delete_id and any(item.get("memory_id") == delete_id for item in memories if isinstance(item, dict)):
        checks["ok"] = False
        checks["errors"].append("deleted_memory_still_searchable")

    checks["primary_memory_id"] = primary_id
    checks["source_memory_id"] = source_id
    checks["deleted_memory_id"] = delete_id
    checks["search_count"] = artifacts["search"].get("count")
    return checks

def check_watcher_timer_shape():
    create = read_json("watcher-timer-create.json")
    run_due = read_json("watcher-timer-run-due.json")
    job_run_due = read_json("watcher-timer-job-run-due.json")
    job_list = read_json("watcher-timer-job-list.json")
    after = read_json("watcher-timer-after-list.json")
    stop = read_json("watcher-timer-stop.json")
    checks = {
        "ok": True,
        "errors": [],
        "create_status": create.get("status") if isinstance(create, dict) else None,
        "run_due_status": run_due.get("status") if isinstance(run_due, dict) else None,
        "job_run_due_status": job_run_due.get("status") if isinstance(job_run_due, dict) else None,
        "job_list_status": job_list.get("status") if isinstance(job_list, dict) else None,
        "after_status": after.get("status") if isinstance(after, dict) else None,
        "stop_status": stop.get("status") if isinstance(stop, dict) else None,
    }
    if not isinstance(create, dict) or create.get("status") != "ok":
        checks["ok"] = False
        checks["errors"].append(f"create_status:{create.get('status') if isinstance(create, dict) else None}")
        create = {}
    watcher = create.get("watcher") if isinstance(create.get("watcher"), dict) else {}
    public_id = watcher.get("watcher_id") if isinstance(watcher.get("watcher_id"), str) else ""
    if create.get("scheduler_status") != "implemented_timer_bridge":
        checks["ok"] = False
        checks["errors"].append("create_scheduler_status")
    if create.get("fires_locally") is not True or watcher.get("fires_locally") is not True:
        checks["ok"] = False
        checks["errors"].append("create_not_firing_locally")
    if not public_id:
        checks["ok"] = False
        checks["errors"].append("missing_watcher_id")

    if not isinstance(run_due, dict) or run_due.get("status") != "ok":
        checks["ok"] = False
        checks["errors"].append(f"run_due_status:{run_due.get('status') if isinstance(run_due, dict) else None}")
        run_due = {}
    if run_due.get("scheduler_status") != "implemented_timer_bridge":
        checks["ok"] = False
        checks["errors"].append("run_due_scheduler_status")
    fired_count = run_due.get("fired_count") if isinstance(run_due.get("fired_count"), int) else 0
    job_count = run_due.get("job_count") if isinstance(run_due.get("job_count"), int) else 0
    watcher_entries = run_due.get("watchers")
    if not isinstance(watcher_entries, list):
        checks["ok"] = False
        checks["errors"].append("watcher_entries_not_list")
        watcher_entries = []
    matched_entry = {}
    for entry in watcher_entries:
        if not isinstance(entry, dict):
            continue
        if not public_id or entry.get("watcher_id") == public_id:
            matched_entry = entry
            break
    if not matched_entry:
        if fired_count > 0:
            checks["ok"] = False
            checks["errors"].append("watcher_entry_not_found")
    elif matched_entry.get("status") != "background_job_queued":
        checks["ok"] = False
        checks["errors"].append(f"watcher_entry_status:{matched_entry.get('status')}")
    job_id = matched_entry.get("job_id") if isinstance(matched_entry.get("job_id"), str) else ""

    if not isinstance(job_run_due, dict) or job_run_due.get("status") not in ("ok", None):
        checks["ok"] = False
        checks["errors"].append(f"job_run_due_status:{job_run_due.get('status') if isinstance(job_run_due, dict) else None}")
        job_run_due = {}
    jobs = job_run_due.get("jobs")
    if not isinstance(jobs, list):
        jobs = []
    ran_job = {}
    for job in jobs:
        if not isinstance(job, dict):
            continue
        if not job_id or job.get("job_id") == job_id:
            ran_job = job
            break
    if not ran_job:
        checks["job_run_race"] = True
    else:
        run_task = ran_job.get("run_task") if isinstance(ran_job.get("run_task"), dict) else {}
        if run_task.get("status") not in ("task.finished", "task.failed"):
            checks["ok"] = False
            checks["errors"].append(f"run_task_status:{run_task.get('status')}")
        if not isinstance(run_task.get("task_id"), str) or not run_task.get("task_id"):
            checks["ok"] = False
            checks["errors"].append("run_task_missing_task_id")
        checks["task_id"] = run_task.get("task_id") if isinstance(run_task.get("task_id"), str) else ""

    if not isinstance(after, dict) or after.get("status") != "ok":
        checks["ok"] = False
        checks["errors"].append(f"after_status:{after.get('status') if isinstance(after, dict) else None}")
        after = {}
    after_watchers = after.get("watchers")
    if not isinstance(after_watchers, list):
        checks["ok"] = False
        checks["errors"].append("after_watchers_not_list")
        after_watchers = []
    after_match = next((item for item in after_watchers
                        if isinstance(item, dict) and (not public_id or item.get("watcher_id") == public_id)), {})
    if not after_match:
        checks["ok"] = False
        checks["errors"].append("after_watcher_missing")
    elif after_match.get("status") != "fired":
        checks["ok"] = False
        checks["errors"].append(f"after_watcher_status:{after_match.get('status')}")
    else:
        metadata = after_match.get("metadata") if isinstance(after_match.get("metadata"), dict) else {}
        if not job_id:
            job_id = metadata.get("last_job_id") if isinstance(metadata.get("last_job_id"), str) else ""
        if metadata.get("last_fire_status") != "background_job_queued":
            checks["ok"] = False
            checks["errors"].append("after_last_fire_status")
    if not job_id:
        checks["ok"] = False
        checks["errors"].append("missing_job_id")

    if not isinstance(job_list, dict) or job_list.get("status") != "ok":
        checks["ok"] = False
        checks["errors"].append(f"job_list_status:{job_list.get('status') if isinstance(job_list, dict) else None}")
        job_list = {}
    listed_jobs = job_list.get("jobs")
    if not isinstance(listed_jobs, list):
        checks["ok"] = False
        checks["errors"].append("job_list_jobs_not_list")
        listed_jobs = []
    listed_job = next((item for item in listed_jobs
                       if isinstance(item, dict) and (not job_id or item.get("job_id") == job_id)), {})
    if not listed_job:
        checks["ok"] = False
        checks["errors"].append("generated_job_not_listed")

    if not isinstance(stop, dict) or stop.get("status") != "ok":
        checks["ok"] = False
        checks["errors"].append(f"stop_status:{stop.get('status') if isinstance(stop, dict) else None}")
    elif not isinstance(stop.get("stopped_count"), int) or stop.get("stopped_count") < 1:
        checks["ok"] = False
        checks["errors"].append("stop_count")
    checks["watcher_id"] = public_id
    checks["job_id"] = job_id
    checks["watcher_fire_count"] = fired_count
    checks["watcher_jobs_created"] = job_count
    checks["job_status"] = listed_job.get("status") if isinstance(listed_job, dict) else ""
    return checks

def check_watcher_repair_shape():
    create = read_json("watcher-repair-create.json")
    mark = read_json("watcher-repair-mark-running.json")
    repair = read_json("watcher-repair-run.json")
    run_due = read_json("watcher-repair-run-due.json")
    job_run_due = read_json("watcher-repair-job-run-due.json")
    after = read_json("watcher-repair-after-list.json")
    stop = read_json("watcher-repair-stop.json")
    checks = {
        "ok": True,
        "errors": [],
        "create_status": create.get("status") if isinstance(create, dict) else None,
        "mark_status": mark.get("status") if isinstance(mark, dict) else None,
        "repair_status": repair.get("status") if isinstance(repair, dict) else None,
        "run_due_status": run_due.get("status") if isinstance(run_due, dict) else None,
        "job_run_due_status": job_run_due.get("status") if isinstance(job_run_due, dict) else None,
        "after_status": after.get("status") if isinstance(after, dict) else None,
        "stop_status": stop.get("status") if isinstance(stop, dict) else None,
    }
    if not isinstance(create, dict) or create.get("status") != "ok":
        checks["ok"] = False
        checks["errors"].append(f"create_status:{create.get('status') if isinstance(create, dict) else None}")
        create = {}
    watcher = create.get("watcher") if isinstance(create.get("watcher"), dict) else {}
    public_id = watcher.get("watcher_id") if isinstance(watcher.get("watcher_id"), str) else ""
    if not public_id:
        checks["ok"] = False
        checks["errors"].append("missing_watcher_id")
    if create.get("scheduler_status") != "implemented_timer_bridge":
        checks["ok"] = False
        checks["errors"].append("create_scheduler_status")

    if not isinstance(mark, dict) or mark.get("status") != "ok":
        checks["ok"] = False
        checks["errors"].append(f"mark_status:{mark.get('status') if isinstance(mark, dict) else None}")
        mark = {}
    marked_watcher = mark.get("watcher") if isinstance(mark.get("watcher"), dict) else {}
    if marked_watcher.get("status") != "running":
        checks["ok"] = False
        checks["errors"].append(f"mark_watcher_status:{marked_watcher.get('status')}")
    fixture = marked_watcher.get("metadata", {}).get("validation_stuck_fixture") if isinstance(marked_watcher.get("metadata"), dict) else {}
    if not isinstance(fixture, dict) or fixture.get("status") != "marked_running":
        checks["ok"] = False
        checks["errors"].append("missing_validation_fixture")

    if not isinstance(repair, dict) or repair.get("status") != "ok":
        checks["ok"] = False
        checks["errors"].append(f"repair_status:{repair.get('status') if isinstance(repair, dict) else None}")
        repair = {}
    if repair.get("repair_policy") != "requeue_stale_running":
        checks["ok"] = False
        checks["errors"].append("repair_policy")
    if not isinstance(repair.get("repaired_count"), int) or repair.get("repaired_count") < 1:
        checks["ok"] = False
        checks["errors"].append("repaired_count")
    repair_watchers = repair.get("watchers")
    if not isinstance(repair_watchers, list):
        checks["ok"] = False
        checks["errors"].append("repair_watchers_not_list")
        repair_watchers = []
    repaired_entry = next((item for item in repair_watchers
                           if isinstance(item, dict) and (not public_id or item.get("watcher_id") == public_id)), {})
    if not repaired_entry:
        checks["ok"] = False
        checks["errors"].append("repaired_watcher_missing")
        repaired_watcher = {}
    else:
        if repaired_entry.get("status") != "requeued":
            checks["ok"] = False
            checks["errors"].append(f"repaired_entry_status:{repaired_entry.get('status')}")
        repaired_watcher = repaired_entry.get("watcher") if isinstance(repaired_entry.get("watcher"), dict) else {}
        if repaired_watcher.get("status") != "active":
            checks["ok"] = False
            checks["errors"].append(f"repaired_watcher_status:{repaired_watcher.get('status')}")
        stuck_repair = repaired_watcher.get("metadata", {}).get("stuck_repair") if isinstance(repaired_watcher.get("metadata"), dict) else {}
        if not isinstance(stuck_repair, dict) or stuck_repair.get("repair_action") != "requeued":
            checks["ok"] = False
            checks["errors"].append("missing_stuck_repair_metadata")

    if not isinstance(run_due, dict) or run_due.get("status") != "ok":
        checks["ok"] = False
        checks["errors"].append(f"run_due_status:{run_due.get('status') if isinstance(run_due, dict) else None}")
        run_due = {}
    if run_due.get("scheduler_status") != "implemented_timer_bridge":
        checks["ok"] = False
        checks["errors"].append("run_due_scheduler_status")
    if not isinstance(run_due.get("fired_count"), int) or run_due.get("fired_count") < 1:
        checks["ok"] = False
        checks["errors"].append("run_due_fired_count")
    run_due_watchers = run_due.get("watchers")
    if not isinstance(run_due_watchers, list):
        checks["ok"] = False
        checks["errors"].append("run_due_watchers_not_list")
        run_due_watchers = []
    fired_entry = next((item for item in run_due_watchers
                        if isinstance(item, dict) and (not public_id or item.get("watcher_id") == public_id)), {})
    if not fired_entry:
        checks["ok"] = False
        checks["errors"].append("fired_watcher_missing")
    elif fired_entry.get("status") != "background_job_queued":
        checks["ok"] = False
        checks["errors"].append(f"fired_entry_status:{fired_entry.get('status')}")

    job_run_ok = isinstance(job_run_due, dict) and job_run_due.get("status") == "ok"
    if not job_run_ok:
        checks["job_run_race"] = True
        job_run_due = {}
    elif job_run_due.get("scheduler_status") != "implemented_agent_loop":
        checks["ok"] = False
        checks["errors"].append("job_run_due_scheduler_status")

    if not isinstance(after, dict) or after.get("status") != "ok":
        checks["ok"] = False
        checks["errors"].append(f"after_status:{after.get('status') if isinstance(after, dict) else None}")
        after = {}
    after_watchers = after.get("watchers")
    if not isinstance(after_watchers, list):
        checks["ok"] = False
        checks["errors"].append("after_watchers_not_list")
        after_watchers = []
    after_match = next((item for item in after_watchers
                        if isinstance(item, dict) and (not public_id or item.get("watcher_id") == public_id)), {})
    if not after_match:
        checks["ok"] = False
        checks["errors"].append("after_watcher_missing")
    else:
        if after_match.get("status") not in ("fired", "active", "stopped"):
            checks["ok"] = False
            checks["errors"].append(f"after_watcher_status:{after_match.get('status')}")
        metadata = after_match.get("metadata") if isinstance(after_match.get("metadata"), dict) else {}
        listed_repair = metadata.get("stuck_repair") if isinstance(metadata.get("stuck_repair"), dict) else {}
        if listed_repair.get("repair_action") != "requeued":
            checks["ok"] = False
            checks["errors"].append("after_missing_stuck_repair")
        if metadata.get("last_fire_status") != "background_job_queued":
            checks["ok"] = False
            checks["errors"].append("after_last_fire_status")

    if not isinstance(stop, dict) or stop.get("status") != "ok":
        checks["ok"] = False
        checks["errors"].append(f"stop_status:{stop.get('status') if isinstance(stop, dict) else None}")
    elif not isinstance(stop.get("stopped_count"), int) or stop.get("stopped_count") < 1:
        checks["ok"] = False
        checks["errors"].append("stop_count")

    checks["watcher_id"] = public_id
    checks["repaired_count"] = repair.get("repaired_count") if isinstance(repair, dict) else None
    checks["run_due_fired_count"] = run_due.get("fired_count") if isinstance(run_due, dict) else None
    checks["final_watcher_status"] = after_match.get("status") if isinstance(after_match, dict) else ""
    return checks

def check_job_repair_shape():
    create = read_json("job-repair-create.json")
    mark = read_json("job-repair-mark-running.json")
    repair = read_json("job-repair-run.json")
    run_due = read_json("job-repair-run-due.json")
    listing = read_json("job-repair-list.json")
    stop = read_json("job-repair-stop.json")
    checks = {
        "ok": True,
        "errors": [],
        "create_status": create.get("status") if isinstance(create, dict) else None,
        "mark_status": mark.get("status") if isinstance(mark, dict) else None,
        "repair_status": repair.get("status") if isinstance(repair, dict) else None,
        "run_due_status": run_due.get("status") if isinstance(run_due, dict) else None,
        "list_status": listing.get("status") if isinstance(listing, dict) else None,
        "stop_status": stop.get("status") if isinstance(stop, dict) else None,
    }
    if not isinstance(create, dict) or create.get("status") != "ok":
        checks["ok"] = False
        checks["errors"].append(f"create_status:{create.get('status') if isinstance(create, dict) else None}")
        create = {}
    created_job = create.get("job") if isinstance(create.get("job"), dict) else {}
    public_id = created_job.get("job_id") if isinstance(created_job.get("job_id"), str) else ""
    if not public_id:
        checks["ok"] = False
        checks["errors"].append("missing_job_id")

    if not isinstance(mark, dict) or mark.get("status") != "ok":
        checks["ok"] = False
        checks["errors"].append(f"mark_status:{mark.get('status') if isinstance(mark, dict) else None}")
        mark = {}
    marked_job = mark.get("job") if isinstance(mark.get("job"), dict) else {}
    if marked_job.get("status") != "running":
        checks["ok"] = False
        checks["errors"].append(f"mark_job_status:{marked_job.get('status')}")
    fixture = marked_job.get("payload", {}).get("validation_stuck_fixture") if isinstance(marked_job.get("payload"), dict) else {}
    if not isinstance(fixture, dict) or fixture.get("status") != "marked_running":
        checks["ok"] = False
        checks["errors"].append("missing_validation_fixture")

    if not isinstance(repair, dict) or repair.get("status") != "ok":
        checks["ok"] = False
        checks["errors"].append(f"repair_status:{repair.get('status') if isinstance(repair, dict) else None}")
        repair = {}
    if repair.get("repair_policy") != "requeue_stale_running":
        checks["ok"] = False
        checks["errors"].append("repair_policy")
    if not isinstance(repair.get("repaired_count"), int) or repair.get("repaired_count") < 1:
        checks["ok"] = False
        checks["errors"].append("repaired_count")
    repair_jobs = repair.get("jobs")
    if not isinstance(repair_jobs, list):
        checks["ok"] = False
        checks["errors"].append("repair_jobs_not_list")
        repair_jobs = []
    repaired_entry = next((item for item in repair_jobs
                           if isinstance(item, dict) and (not public_id or item.get("job_id") == public_id)), {})
    if not repaired_entry:
        checks["ok"] = False
        checks["errors"].append("repaired_job_missing")
        repaired_job = {}
    else:
        if repaired_entry.get("status") != "requeued":
            checks["ok"] = False
            checks["errors"].append(f"repaired_entry_status:{repaired_entry.get('status')}")
        repaired_job = repaired_entry.get("job") if isinstance(repaired_entry.get("job"), dict) else {}
        if repaired_job.get("status") != "queued":
            checks["ok"] = False
            checks["errors"].append(f"repaired_job_status:{repaired_job.get('status')}")
        stuck_repair = repaired_job.get("payload", {}).get("stuck_repair") if isinstance(repaired_job.get("payload"), dict) else {}
        if not isinstance(stuck_repair, dict) or stuck_repair.get("repair_action") != "requeued":
            checks["ok"] = False
            checks["errors"].append("missing_stuck_repair_metadata")

    run_due_ok = isinstance(run_due, dict) and run_due.get("status") == "ok"
    if not run_due_ok:
        checks["job_run_race"] = True
        run_due = {}
    elif run_due.get("scheduler_status") != "implemented_agent_loop":
        checks["ok"] = False
        checks["errors"].append("run_due_scheduler_status")

    if not isinstance(listing, dict) or listing.get("status") != "ok":
        checks["ok"] = False
        checks["errors"].append(f"list_status:{listing.get('status') if isinstance(listing, dict) else None}")
        listing = {}
    listed_jobs = listing.get("jobs")
    if not isinstance(listed_jobs, list):
        checks["ok"] = False
        checks["errors"].append("listed_jobs_not_list")
        listed_jobs = []
    listed_job = next((item for item in listed_jobs
                       if isinstance(item, dict) and (not public_id or item.get("job_id") == public_id)), {})
    if not listed_job:
        checks["ok"] = False
        checks["errors"].append("listed_repaired_job_missing")
    else:
        if listed_job.get("status") not in ("queued", "completed", "failed", "stopped"):
            checks["ok"] = False
            checks["errors"].append(f"listed_job_status:{listed_job.get('status')}")
        if not run_due_ok and listed_job.get("status") not in ("completed", "failed", "stopped"):
            checks["ok"] = False
            checks["errors"].append("run_due_missing_without_completed_job")
        listed_repair = listed_job.get("payload", {}).get("stuck_repair") if isinstance(listed_job.get("payload"), dict) else {}
        if not isinstance(listed_repair, dict) or listed_repair.get("repair_action") != "requeued":
            checks["ok"] = False
            checks["errors"].append("listed_missing_stuck_repair")

    if not isinstance(stop, dict) or stop.get("status") != "ok":
        checks["ok"] = False
        checks["errors"].append(f"stop_status:{stop.get('status') if isinstance(stop, dict) else None}")
    elif not isinstance(stop.get("stopped_count"), int) or stop.get("stopped_count") < 1:
        checks["ok"] = False
        checks["errors"].append("stop_count")

    checks["job_id"] = public_id
    checks["repaired_count"] = repair.get("repaired_count") if isinstance(repair, dict) else None
    checks["run_due_ran_count"] = run_due.get("ran_count") if isinstance(run_due, dict) else None
    checks["final_job_status"] = listed_job.get("status") if isinstance(listed_job, dict) else ""
    return checks

def check_restart_recovery_shape():
    watcher_create = read_json("restart-recovery-watcher-create.json")
    job_create = read_json("restart-recovery-job-create.json")
    watcher_mark = read_json("restart-recovery-watcher-mark-running.json")
    job_mark = read_json("restart-recovery-job-mark-running.json")
    restart = read_json("restart-recovery-restart.json")
    after_health = read_json("restart-recovery-after-health.json")
    watcher_list = read_json("restart-recovery-watcher-list.json")
    job_list = read_json("restart-recovery-job-list.json")
    watcher_stop = read_json("restart-recovery-watcher-stop.json")
    job_stop = read_json("restart-recovery-job-stop.json")
    generated_job_stop = read_json("restart-recovery-generated-job-stop.json")
    checks = {
        "ok": True,
        "errors": [],
        "watcher_create_status": watcher_create.get("status") if isinstance(watcher_create, dict) else None,
        "job_create_status": job_create.get("status") if isinstance(job_create, dict) else None,
        "watcher_mark_status": watcher_mark.get("status") if isinstance(watcher_mark, dict) else None,
        "job_mark_status": job_mark.get("status") if isinstance(job_mark, dict) else None,
        "restart_status": restart.get("status") if isinstance(restart, dict) else None,
        "after_health_status": after_health.get("status") if isinstance(after_health, dict) else None,
        "watcher_list_status": watcher_list.get("status") if isinstance(watcher_list, dict) else None,
        "job_list_status": job_list.get("status") if isinstance(job_list, dict) else None,
        "watcher_stop_status": watcher_stop.get("status") if isinstance(watcher_stop, dict) else None,
        "job_stop_status": job_stop.get("status") if isinstance(job_stop, dict) else None,
        "generated_job_stop_status": generated_job_stop.get("status") if isinstance(generated_job_stop, dict) else None,
    }
    if not isinstance(watcher_create, dict) or watcher_create.get("status") != "ok":
        checks["ok"] = False
        checks["errors"].append(f"watcher_create_status:{watcher_create.get('status') if isinstance(watcher_create, dict) else None}")
        watcher_create = {}
    if not isinstance(job_create, dict) or job_create.get("status") != "ok":
        checks["ok"] = False
        checks["errors"].append(f"job_create_status:{job_create.get('status') if isinstance(job_create, dict) else None}")
        job_create = {}
    created_watcher = watcher_create.get("watcher") if isinstance(watcher_create.get("watcher"), dict) else {}
    created_job = job_create.get("job") if isinstance(job_create.get("job"), dict) else {}
    watcher_public_id = created_watcher.get("watcher_id") if isinstance(created_watcher.get("watcher_id"), str) else ""
    job_public_id = created_job.get("job_id") if isinstance(created_job.get("job_id"), str) else ""
    if not watcher_public_id:
        checks["ok"] = False
        checks["errors"].append("missing_watcher_id")
    if not job_public_id:
        checks["ok"] = False
        checks["errors"].append("missing_job_id")

    if not isinstance(watcher_mark, dict) or watcher_mark.get("status") != "ok":
        checks["ok"] = False
        checks["errors"].append(f"watcher_mark_status:{watcher_mark.get('status') if isinstance(watcher_mark, dict) else None}")
        watcher_mark = {}
    marked_watcher = watcher_mark.get("watcher") if isinstance(watcher_mark.get("watcher"), dict) else {}
    if marked_watcher.get("status") != "running":
        checks["ok"] = False
        checks["errors"].append(f"watcher_mark_state:{marked_watcher.get('status')}")
    watcher_fixture = marked_watcher.get("metadata", {}).get("validation_stuck_fixture") if isinstance(marked_watcher.get("metadata"), dict) else {}
    if not isinstance(watcher_fixture, dict) or watcher_fixture.get("status") != "marked_running":
        checks["ok"] = False
        checks["errors"].append("watcher_fixture_missing")

    if not isinstance(job_mark, dict) or job_mark.get("status") != "ok":
        checks["ok"] = False
        checks["errors"].append(f"job_mark_status:{job_mark.get('status') if isinstance(job_mark, dict) else None}")
        job_mark = {}
    marked_job = job_mark.get("job") if isinstance(job_mark.get("job"), dict) else {}
    if marked_job.get("status") != "running":
        checks["ok"] = False
        checks["errors"].append(f"job_mark_state:{marked_job.get('status')}")
    job_fixture = marked_job.get("payload", {}).get("validation_stuck_fixture") if isinstance(marked_job.get("payload"), dict) else {}
    if not isinstance(job_fixture, dict) or job_fixture.get("status") != "marked_running":
        checks["ok"] = False
        checks["errors"].append("job_fixture_missing")

    if not isinstance(restart, dict) or restart.get("status") != "ok":
        checks["ok"] = False
        checks["errors"].append(f"restart_status:{restart.get('status') if isinstance(restart, dict) else None}")
        restart = {}
    before_pid = restart.get("before_pid") if isinstance(restart.get("before_pid"), str) else ""
    after_pid = restart.get("after_pid") if isinstance(restart.get("after_pid"), str) else ""
    post_wait_pid = restart.get("post_wait_pid") if isinstance(restart.get("post_wait_pid"), str) else ""
    if not before_pid or not after_pid:
        checks["ok"] = False
        checks["errors"].append("restart_pid_missing")
    elif before_pid == after_pid:
        checks["ok"] = False
        checks["errors"].append("restart_pid_unchanged")
    if after_pid and post_wait_pid and after_pid != post_wait_pid:
        checks["ok"] = False
        checks["errors"].append("restart_pid_changed_after_wait")

    if not isinstance(after_health, dict) or after_health.get("status") != "ok":
        checks["ok"] = False
        checks["errors"].append(f"after_health_status:{after_health.get('status') if isinstance(after_health, dict) else None}")
    elif after_health.get("autonomy_mode") != "yolo":
        checks["ok"] = False
        checks["errors"].append("after_health_autonomy")
    else:
        health_pid = str(after_health.get("pid", ""))
        if post_wait_pid and health_pid and health_pid != post_wait_pid:
            checks["ok"] = False
            checks["errors"].append("after_health_pid_mismatch")
        wait_ms = restart.get("post_restart_wait_seconds", 0)
        uptime_ms = after_health.get("uptime_ms", 0)
        if isinstance(wait_ms, int) and isinstance(uptime_ms, int) and wait_ms > 0:
            if uptime_ms < max(0, (wait_ms - 5) * 1000):
                checks["ok"] = False
                checks["errors"].append("after_health_uptime_short")

    if not isinstance(watcher_list, dict) or watcher_list.get("status") != "ok":
        checks["ok"] = False
        checks["errors"].append(f"watcher_list_status:{watcher_list.get('status') if isinstance(watcher_list, dict) else None}")
        watcher_list = {}
    listed_watchers = watcher_list.get("watchers")
    if not isinstance(listed_watchers, list):
        checks["ok"] = False
        checks["errors"].append("watcher_list_not_list")
        listed_watchers = []
    listed_watcher = next((item for item in listed_watchers
                           if isinstance(item, dict) and (not watcher_public_id or item.get("watcher_id") == watcher_public_id)), {})
    generated_job_id = ""
    if not listed_watcher:
        checks["ok"] = False
        checks["errors"].append("watcher_missing_after_restart")
    else:
        if listed_watcher.get("status") != "fired":
            checks["ok"] = False
            checks["errors"].append(f"watcher_final_status:{listed_watcher.get('status')}")
        watcher_metadata = listed_watcher.get("metadata") if isinstance(listed_watcher.get("metadata"), dict) else {}
        watcher_schedule = listed_watcher.get("schedule") if isinstance(listed_watcher.get("schedule"), dict) else {}
        watcher_repair = watcher_metadata.get("stuck_repair") if isinstance(watcher_metadata.get("stuck_repair"), dict) else {}
        if watcher_repair.get("repair_action") != "requeued":
            checks["ok"] = False
            checks["errors"].append("watcher_missing_stuck_repair")
        if watcher_metadata.get("last_fire_status") != "background_job_queued":
            checks["ok"] = False
            checks["errors"].append("watcher_not_fired_after_restart")
        generated_job_id = watcher_metadata.get("last_job_id") or watcher_schedule.get("last_job_id") or ""
        if not generated_job_id:
            checks["ok"] = False
            checks["errors"].append("watcher_generated_job_missing")

    if not isinstance(job_list, dict) or job_list.get("status") != "ok":
        checks["ok"] = False
        checks["errors"].append(f"job_list_status:{job_list.get('status') if isinstance(job_list, dict) else None}")
        job_list = {}
    listed_jobs = job_list.get("jobs")
    if not isinstance(listed_jobs, list):
        checks["ok"] = False
        checks["errors"].append("job_list_not_list")
        listed_jobs = []
    listed_job = next((item for item in listed_jobs
                       if isinstance(item, dict) and (not job_public_id or item.get("job_id") == job_public_id)), {})
    if not listed_job:
        checks["ok"] = False
        checks["errors"].append("job_missing_after_restart")
    else:
        if listed_job.get("status") not in ("queued", "completed", "failed"):
            checks["ok"] = False
            checks["errors"].append(f"job_final_status:{listed_job.get('status')}")
        job_repair = listed_job.get("payload", {}).get("stuck_repair") if isinstance(listed_job.get("payload"), dict) else {}
        if job_repair.get("repair_action") != "requeued":
            checks["ok"] = False
            checks["errors"].append("job_missing_stuck_repair")

    if not isinstance(watcher_stop, dict) or watcher_stop.get("status") != "ok":
        checks["ok"] = False
        checks["errors"].append(f"watcher_stop_status:{watcher_stop.get('status') if isinstance(watcher_stop, dict) else None}")
    elif not isinstance(watcher_stop.get("stopped_count"), int) or watcher_stop.get("stopped_count") < 1:
        checks["ok"] = False
        checks["errors"].append("watcher_stop_count")
    if not isinstance(job_stop, dict) or job_stop.get("status") != "ok":
        checks["ok"] = False
        checks["errors"].append(f"job_stop_status:{job_stop.get('status') if isinstance(job_stop, dict) else None}")
    elif not isinstance(job_stop.get("stopped_count"), int) or job_stop.get("stopped_count") < 1:
        checks["ok"] = False
        checks["errors"].append("job_stop_count")
    if generated_job_id:
        if not isinstance(generated_job_stop, dict) or generated_job_stop.get("status") != "ok":
            checks["ok"] = False
            checks["errors"].append(f"generated_job_stop_status:{generated_job_stop.get('status') if isinstance(generated_job_stop, dict) else None}")
        elif not isinstance(generated_job_stop.get("stopped_count"), int) or generated_job_stop.get("stopped_count") < 1:
            checks["ok"] = False
            checks["errors"].append("generated_job_stop_count")

    checks["watcher_id"] = watcher_public_id
    checks["job_id"] = job_public_id
    checks["generated_job_id"] = generated_job_id
    checks["before_pid"] = before_pid
    checks["after_pid"] = after_pid
    checks["post_wait_pid"] = post_wait_pid
    checks["final_watcher_status"] = listed_watcher.get("status") if isinstance(listed_watcher, dict) else ""
    checks["final_job_status"] = listed_job.get("status") if isinstance(listed_job, dict) else ""
    return checks

def check_model_loop_shape():
    status = read_json("model-status.json")
    run = read_json("model-loop-run.json")
    trajectory = read_json("model-loop-trajectory.json")
    repair_run = read_json("model-loop-repair-run.json")
    repair_trajectory = read_json("model-loop-repair-trajectory.json")
    cancel_start = read_json("model-loop-cancel-start.json")
    cancel_stop = read_json("model-loop-cancel-stop.json")
    cancel_run = read_json("model-loop-cancel-run.json")
    cancel_trajectory = read_json("model-loop-cancel-trajectory.json")
    checks = {
        "ok": True,
        "errors": [],
        "model_status": status.get("status") if isinstance(status, dict) else None,
        "run_status": run.get("status") if isinstance(run, dict) else None,
        "trajectory_status": trajectory.get("status") if isinstance(trajectory, dict) else None,
        "repair_run_status": repair_run.get("status") if isinstance(repair_run, dict) else None,
        "repair_trajectory_status": repair_trajectory.get("status") if isinstance(repair_trajectory, dict) else None,
        "cancel_run_status": cancel_run.get("status") if isinstance(cancel_run, dict) else None,
        "cancel_trajectory_status": cancel_trajectory.get("status") if isinstance(cancel_trajectory, dict) else None,
    }
    if not isinstance(status, dict) or status.get("schema") != "openphone.model_status.v1":
        checks["ok"] = False
        checks["errors"].append("model_status_schema")
    if not isinstance(run, dict):
        checks["ok"] = False
        checks["errors"].append("run_not_object")
        run = {}
    if run.get("status") != "task.finished":
        checks["ok"] = False
        checks["errors"].append(f"run_status:{run.get('status')}")
    if run.get("runner") != "model":
        checks["ok"] = False
        checks["errors"].append("runner_not_model")
    if run.get("model_provider") != "fixture":
        checks["ok"] = False
        checks["errors"].append("provider_not_fixture")
    if run.get("stop_reason") != "finish_task":
        checks["ok"] = False
        checks["errors"].append("stop_reason_not_finish_task")
    if run.get("steps_used") != 2:
        checks["ok"] = False
        checks["errors"].append("steps_used_not_2")
    if run.get("parser_failures") != 0:
        checks["ok"] = False
        checks["errors"].append("parser_failures")
    if run.get("tool_errors") != 0:
        checks["ok"] = False
        checks["errors"].append("tool_errors")
    task_id = run.get("task_id")
    if not isinstance(task_id, str) or not task_id:
        checks["ok"] = False
        checks["errors"].append("missing_task_id")
    if not isinstance(trajectory, dict) or trajectory.get("status") != "ok":
        checks["ok"] = False
        checks["errors"].append("trajectory_status")
        events = []
    else:
        events = trajectory.get("events")
        if not isinstance(events, list):
            checks["ok"] = False
            checks["errors"].append("trajectory_events_not_list")
            events = []
    event_names = [event.get("event") for event in events if isinstance(event, dict)]
    if "model_prompt_prepared" not in event_names:
        checks["ok"] = False
        checks["errors"].append("missing_model_prompt_prepared")
    if event_names.count("model_decision") < 2:
        checks["ok"] = False
        checks["errors"].append("missing_model_decisions")
    if "model_step_verified" not in event_names:
        checks["ok"] = False
        checks["errors"].append("missing_model_step_verified")
    if "model_loop_finished" not in event_names:
        checks["ok"] = False
        checks["errors"].append("missing_model_loop_finished")

    if not isinstance(repair_run, dict):
        checks["ok"] = False
        checks["errors"].append("repair_run_not_object")
        repair_run = {}
    if repair_run.get("status") != "task.finished":
        checks["ok"] = False
        checks["errors"].append(f"repair_run_status:{repair_run.get('status')}")
    if repair_run.get("runner") != "model":
        checks["ok"] = False
        checks["errors"].append("repair_runner_not_model")
    if repair_run.get("model_provider") != "fixture":
        checks["ok"] = False
        checks["errors"].append("repair_provider_not_fixture")
    if repair_run.get("stop_reason") != "finish_task":
        checks["ok"] = False
        checks["errors"].append("repair_stop_reason_not_finish_task")
    if repair_run.get("steps_used") != 1:
        checks["ok"] = False
        checks["errors"].append("repair_steps_used_not_1")
    if repair_run.get("parser_failures") != 0:
        checks["ok"] = False
        checks["errors"].append("repair_parser_failures")
    if repair_run.get("tool_errors") != 0:
        checks["ok"] = False
        checks["errors"].append("repair_tool_errors")
    repair_task_id = repair_run.get("task_id")
    if not isinstance(repair_task_id, str) or not repair_task_id:
        checks["ok"] = False
        checks["errors"].append("missing_repair_task_id")
    if not isinstance(repair_trajectory, dict) or repair_trajectory.get("status") != "ok":
        checks["ok"] = False
        checks["errors"].append("repair_trajectory_status")
        repair_events = []
    else:
        repair_events = repair_trajectory.get("events")
        if not isinstance(repair_events, list):
            checks["ok"] = False
            checks["errors"].append("repair_trajectory_events_not_list")
            repair_events = []
    repair_event_names = [event.get("event") for event in repair_events if isinstance(event, dict)]
    if "model_prompt_prepared" not in repair_event_names:
        checks["ok"] = False
        checks["errors"].append("repair_missing_model_prompt_prepared")
    if "model_parse_repaired" not in repair_event_names:
        checks["ok"] = False
        checks["errors"].append("repair_missing_model_parse_repaired")
    if repair_event_names.count("model_decision") != 1:
        checks["ok"] = False
        checks["errors"].append("repair_model_decision_count")
    if "model_loop_finished" not in repair_event_names:
        checks["ok"] = False
        checks["errors"].append("repair_missing_model_loop_finished")

    cancel_task_id = cancel_start.get("task_id") if isinstance(cancel_start, dict) else ""
    if not isinstance(cancel_task_id, str) or not cancel_task_id:
        checks["ok"] = False
        checks["errors"].append("missing_cancel_task_id")
    if not isinstance(cancel_stop, dict) or cancel_stop.get("state") != "task.stopped":
        checks["ok"] = False
        checks["errors"].append("cancel_stop_state")
    if isinstance(cancel_stop, dict) and cancel_stop.get("cancel_requested") is not True:
        checks["ok"] = False
        checks["errors"].append("cancel_requested_not_true")
    if not isinstance(cancel_run, dict):
        checks["ok"] = False
        checks["errors"].append("cancel_run_not_object")
        cancel_run = {}
    if cancel_run.get("status") != "task.cancelled":
        checks["ok"] = False
        checks["errors"].append(f"cancel_run_status:{cancel_run.get('status')}")
    if cancel_run.get("runner") != "model":
        checks["ok"] = False
        checks["errors"].append("cancel_runner_not_model")
    if cancel_run.get("model_provider") != "fixture":
        checks["ok"] = False
        checks["errors"].append("cancel_provider_not_fixture")
    if cancel_run.get("stop_reason") != "cancelled":
        checks["ok"] = False
        checks["errors"].append("cancel_stop_reason")
    if cancel_run.get("steps_used") != 0:
        checks["ok"] = False
        checks["errors"].append("cancel_steps_used_not_0")
    if cancel_run.get("parser_failures") != 0:
        checks["ok"] = False
        checks["errors"].append("cancel_parser_failures")
    if cancel_run.get("tool_errors") != 0:
        checks["ok"] = False
        checks["errors"].append("cancel_tool_errors")
    if not isinstance(cancel_trajectory, dict) or cancel_trajectory.get("status") != "ok":
        checks["ok"] = False
        checks["errors"].append("cancel_trajectory_status")
        cancel_events = []
    else:
        cancel_events = cancel_trajectory.get("events")
        if not isinstance(cancel_events, list):
            checks["ok"] = False
            checks["errors"].append("cancel_trajectory_events_not_list")
            cancel_events = []
    cancel_event_names = [event.get("event") for event in cancel_events if isinstance(event, dict)]
    if "task_stopped" not in cancel_event_names:
        checks["ok"] = False
        checks["errors"].append("cancel_missing_task_stopped")
    if "model_loop_cancelled" not in cancel_event_names:
        checks["ok"] = False
        checks["errors"].append("cancel_missing_model_loop_cancelled")
    if "model_loop_finished" not in cancel_event_names:
        checks["ok"] = False
        checks["errors"].append("cancel_missing_model_loop_finished")
    if "model_decision" in cancel_event_names:
        checks["ok"] = False
        checks["errors"].append("cancel_model_decision_executed")
    checks["task_id"] = task_id if isinstance(task_id, str) else ""
    checks["repair_task_id"] = repair_task_id if isinstance(repair_task_id, str) else ""
    checks["cancel_task_id"] = cancel_task_id if isinstance(cancel_task_id, str) else ""
    checks["events_seen"] = len(events)
    checks["repair_events_seen"] = len(repair_events)
    checks["cancel_events_seen"] = len(cancel_events)
    return checks

def check_provider_model_shape():
    configure = read_json("provider-model-configure.json")
    status = read_json("provider-model-status.json")
    run = read_json("provider-model-run.json")
    trajectory = read_json("provider-model-trajectory.json")
    reset = read_json("provider-model-reset.json")
    checks = {
        "ok": True,
        "errors": [],
        "configure_status": configure.get("status") if isinstance(configure, dict) else None,
        "status_status": status.get("status") if isinstance(status, dict) else None,
        "run_status": run.get("status") if isinstance(run, dict) else None,
        "trajectory_status": trajectory.get("status") if isinstance(trajectory, dict) else None,
        "reset_status": reset.get("status") if isinstance(reset, dict) else None,
    }
    if not isinstance(configure, dict) or configure.get("status") != "ready":
        checks["ok"] = False
        checks["errors"].append(f"configure_status:{configure.get('status') if isinstance(configure, dict) else None}")
    if isinstance(configure, dict):
        if configure.get("mode") != "broker":
            checks["ok"] = False
            checks["errors"].append("configure_mode_not_broker")
        if configure.get("credential_required") is not False:
            checks["ok"] = False
            checks["errors"].append("configure_credential_required")
        if not bool(configure.get("endpoint_configured")):
            checks["ok"] = False
            checks["errors"].append("configure_endpoint_not_configured")
    if not isinstance(status, dict) or status.get("status") != "ready":
        checks["ok"] = False
        checks["errors"].append(f"model_status:{status.get('status') if isinstance(status, dict) else None}")
    if not isinstance(run, dict):
        checks["ok"] = False
        checks["errors"].append("run_not_object")
        run = {}
    if run.get("status") != "task.finished":
        checks["ok"] = False
        checks["errors"].append(f"run_status:{run.get('status')}")
    if run.get("runner") != "model":
        checks["ok"] = False
        checks["errors"].append("runner_not_model")
    if run.get("model_provider") != "broker":
        checks["ok"] = False
        checks["errors"].append("provider_not_broker")
    if run.get("stop_reason") != "finish_task":
        checks["ok"] = False
        checks["errors"].append("stop_reason_not_finish_task")
    if run.get("parser_failures") != 0:
        checks["ok"] = False
        checks["errors"].append("parser_failures")
    if run.get("tool_errors") != 0:
        checks["ok"] = False
        checks["errors"].append("tool_errors")
    task_id = run.get("task_id")
    if not isinstance(task_id, str) or not task_id:
        checks["ok"] = False
        checks["errors"].append("missing_task_id")
    if not isinstance(trajectory, dict) or trajectory.get("status") != "ok":
        checks["ok"] = False
        checks["errors"].append("trajectory_status")
        events = []
    else:
        events = trajectory.get("events")
        if not isinstance(events, list):
            checks["ok"] = False
            checks["errors"].append("trajectory_events_not_list")
            events = []
    event_names = [event.get("event") for event in events if isinstance(event, dict)]
    for required in ("model_prompt_prepared", "model_request", "model_response", "model_decision", "model_loop_finished"):
        if required not in event_names:
            checks["ok"] = False
            checks["errors"].append(f"missing_{required}")
    provider_backed = False
    provider_model = ""
    for event in events:
        if not isinstance(event, dict) or event.get("event") != "model_response":
            continue
        payload = event.get("payload")
        metadata = payload.get("metadata") if isinstance(payload, dict) and isinstance(payload.get("metadata"), dict) else {}
        if metadata.get("provider") == "bedrock_converse" and metadata.get("provider_backed") is True:
            provider_backed = True
            provider_model = metadata.get("model") if isinstance(metadata.get("model"), str) else ""
            break
    if not provider_backed:
        checks["ok"] = False
        checks["errors"].append("missing_provider_backed_metadata")
    if not isinstance(reset, dict) or reset.get("enabled") is not False:
        checks["ok"] = False
        checks["errors"].append("reset_not_disabled")
    checks["task_id"] = task_id if isinstance(task_id, str) else ""
    checks["events_seen"] = len(events)
    checks["provider_backed"] = provider_backed
    checks["provider_model"] = provider_model
    return checks

def contains_text(value, needle):
    if not needle:
        return False
    if isinstance(value, str):
        return needle in value
    if isinstance(value, dict):
        return any(contains_text(item, needle) for item in value.values())
    if isinstance(value, list):
        return any(contains_text(item, needle) for item in value)
    return False

def web_dom_status(data):
    context = data.get("context") if isinstance(data, dict) else {}
    ui_tree = context.get("ui_tree") if isinstance(context, dict) else {}
    web_dom = ui_tree.get("web_dom") if isinstance(ui_tree, dict) else {}
    return web_dom if isinstance(web_dom, dict) else {}

def check_safari_dom_model_shape():
    marker = read_text("safari-dom-model-marker.txt").strip()
    before = read_json("safari-dom-model-before-screen.json")
    open_url = read_json("safari-dom-model-open-url.json")
    pre_screen = read_json("safari-dom-model-pre-screen.json")
    configure = read_json("safari-dom-model-configure.json")
    status = read_json("safari-dom-model-status.json")
    run = read_json("safari-dom-model-run.json")
    trajectory = read_json("safari-dom-model-trajectory.json")
    after_screen = read_json("safari-dom-model-after-screen.json")
    safari_state = read_json("safari-dom-model-safari-state.json")
    reset = read_json("safari-dom-model-reset.json")
    before_fields = app_ui_fields(before)
    pre_fields = app_ui_fields(pre_screen)
    after_fields = app_ui_fields(after_screen)
    pre_web_dom = web_dom_status(pre_screen)
    after_web_dom = web_dom_status(after_screen)
    checks = {
        "ok": True,
        "blocked": False,
        "errors": [],
        "marker": marker,
        "before_locked": before_fields["locked"],
        "open_url_state": action_state(open_url),
        "pre": pre_fields,
        "after": after_fields,
        "pre_web_dom_status": pre_web_dom.get("status"),
        "pre_web_dom_element_count": pre_web_dom.get("element_count"),
        "after_web_dom_status": after_web_dom.get("status"),
        "after_web_dom_element_count": after_web_dom.get("element_count"),
        "configure_status": configure.get("status") if isinstance(configure, dict) else None,
        "model_status": status.get("status") if isinstance(status, dict) else None,
        "run_status": run.get("status") if isinstance(run, dict) else None,
        "trajectory_status": trajectory.get("status") if isinstance(trajectory, dict) else None,
        "safari_state_status": safari_state.get("status") if isinstance(safari_state, dict) else None,
        "reset_status": reset.get("status") if isinstance(reset, dict) else None,
    }
    if before_fields["locked"] is not False:
        checks["ok"] = False
        checks["blocked"] = True
        checks["errors"].append("device_locked_or_unknown")
        return checks
    if not marker:
        checks["ok"] = False
        checks["errors"].append("missing_marker")
    if not isinstance(open_url, dict) or action_state(open_url) != "action.executed":
        checks["ok"] = False
        checks["errors"].append(f"open_url_state:{action_state(open_url)}")
    if pre_fields["foreground_app"] != "com.apple.mobilesafari":
        checks["ok"] = False
        checks["errors"].append(f"pre_foreground_app:{pre_fields['foreground_app']}")
    if pre_fields["ui_tree_source"] != "app_process":
        checks["ok"] = False
        checks["errors"].append(f"pre_ui_tree_source:{pre_fields['ui_tree_source']}")
    if pre_web_dom.get("status") != "ok":
        checks["ok"] = False
        checks["errors"].append(f"pre_web_dom_status:{pre_web_dom.get('status')}")
    if not isinstance(pre_web_dom.get("element_count"), int) or pre_web_dom.get("element_count") <= 0:
        checks["ok"] = False
        checks["errors"].append(f"pre_web_dom_element_count:{pre_web_dom.get('element_count')}")
    if not isinstance(configure, dict) or configure.get("status") != "ready":
        checks["ok"] = False
        checks["errors"].append(f"configure_status:{configure.get('status') if isinstance(configure, dict) else None}")
    if isinstance(configure, dict):
        if configure.get("mode") != "bedrock_converse":
            checks["ok"] = False
            checks["errors"].append("configure_mode_not_bedrock_converse")
        if not configure.get("credential", {}).get("credential_file_present"):
            checks["ok"] = False
            checks["errors"].append("credential_file_not_present")
    if not isinstance(status, dict) or status.get("status") != "ready":
        checks["ok"] = False
        checks["errors"].append(f"model_status:{status.get('status') if isinstance(status, dict) else None}")
    if isinstance(status, dict) and status.get("mode") != "bedrock_converse":
        checks["ok"] = False
        checks["errors"].append("status_mode_not_bedrock_converse")
    if not isinstance(run, dict):
        checks["ok"] = False
        checks["errors"].append("run_not_object")
        run = {}
    if run.get("status") != "task.finished":
        checks["ok"] = False
        checks["errors"].append(f"run_status:{run.get('status')}")
    if run.get("runner") != "model":
        checks["ok"] = False
        checks["errors"].append("runner_not_model")
    if run.get("model_provider") != "bedrock_converse":
        checks["ok"] = False
        checks["errors"].append(f"model_provider:{run.get('model_provider')}")
    if run.get("stop_reason") != "verified_type_text_goal_complete":
        checks["ok"] = False
        checks["errors"].append(f"stop_reason:{run.get('stop_reason')}")
    if run.get("parser_failures") != 0:
        checks["ok"] = False
        checks["errors"].append("parser_failures")
    if run.get("tool_errors") != 0:
        checks["ok"] = False
        checks["errors"].append("tool_errors")
    if run.get("unverified_ui_actions") != 0:
        checks["ok"] = False
        checks["errors"].append("unverified_ui_actions")
    task_id = run.get("task_id")
    if not isinstance(task_id, str) or not task_id:
        checks["ok"] = False
        checks["errors"].append("missing_task_id")
    if not isinstance(trajectory, dict) or trajectory.get("status") != "ok":
        checks["ok"] = False
        checks["errors"].append("trajectory_status")
        events = []
    else:
        events = trajectory.get("events")
        if not isinstance(events, list):
            checks["ok"] = False
            checks["errors"].append("trajectory_events_not_list")
            events = []
    event_names = [event.get("event") for event in events if isinstance(event, dict)]
    for required in ("model_prompt_prepared", "model_request", "model_response", "model_decision", "tool_call", "model_step_verified", "model_loop_finished"):
        if required not in event_names:
            checks["ok"] = False
            checks["errors"].append(f"missing_{required}")
    provider_backed = False
    chose_type_text = False
    typed_marker = False
    dom_verified = False
    webcontent_attempt = False
    for event in events:
        if not isinstance(event, dict):
            continue
        payload = event.get("payload") if isinstance(event.get("payload"), dict) else {}
        if event.get("event") == "model_response":
            metadata = payload.get("metadata") if isinstance(payload.get("metadata"), dict) else {}
            if metadata.get("provider") == "bedrock_converse" and metadata.get("provider_backed") is True:
                provider_backed = True
        if event.get("event") == "model_decision":
            decision = payload.get("decision") if isinstance(payload.get("decision"), dict) else {}
            arguments = decision.get("arguments") if isinstance(decision.get("arguments"), dict) else {}
            if decision.get("tool") == "type_text":
                chose_type_text = True
                if marker and arguments.get("text") == marker:
                    typed_marker = True
        if event.get("event") == "model_step_verified":
            if payload.get("tool") == "type_text":
                verification = payload.get("verification") if isinstance(payload.get("verification"), dict) else {}
                provider_verification = verification.get("provider_verification") if isinstance(verification.get("provider_verification"), dict) else {}
                if verification.get("status") == "verified" and provider_verification.get("source") == "web_content_dom_state":
                    dom_verified = True
                tool_result = payload.get("tool_result") if isinstance(payload.get("tool_result"), dict) else {}
                attempts = tool_result.get("provider_attempts") if isinstance(tool_result.get("provider_attempts"), list) else []
                for attempt in attempts:
                    if not isinstance(attempt, dict):
                        continue
                    if attempt.get("provider") == "OpenPhoneAppIntrospector.WebContentInput" and attempt.get("activation_method") == "webkit_dom_text_input":
                        webcontent_attempt = True
    if not provider_backed:
        checks["ok"] = False
        checks["errors"].append("missing_bedrock_provider_metadata")
    if not chose_type_text:
        checks["ok"] = False
        checks["errors"].append("missing_type_text_decision")
    if not typed_marker:
        checks["ok"] = False
        checks["errors"].append("type_text_marker_mismatch")
    if not dom_verified:
        checks["ok"] = False
        checks["errors"].append("missing_dom_verified_step")
    if not webcontent_attempt:
        checks["ok"] = False
        checks["errors"].append("missing_webcontent_input_attempt")
    marker_visible = contains_text(after_screen, marker) or contains_text(safari_state, marker)
    if not marker_visible:
        checks["ok"] = False
        checks["errors"].append("marker_not_visible_after")
    if after_fields["foreground_app"] != "com.apple.mobilesafari":
        checks["ok"] = False
        checks["errors"].append(f"after_foreground_app:{after_fields['foreground_app']}")
    if not isinstance(reset, dict) or reset.get("status") != "ok":
        checks["ok"] = False
        checks["errors"].append(f"reset_status:{reset.get('status') if isinstance(reset, dict) else None}")
    checks["task_id"] = task_id if isinstance(task_id, str) else ""
    checks["events_seen"] = len(events)
    checks["provider_backed"] = provider_backed
    checks["type_text_decision"] = chose_type_text
    checks["typed_marker"] = typed_marker
    checks["dom_verified"] = dom_verified
    checks["webcontent_attempt"] = webcontent_attempt
    checks["marker_visible_after"] = marker_visible
    return checks

def check_prompt_bridge_model_shape():
    marker = read_text("prompt-bridge-marker.txt").strip()
    request_id = read_text("prompt-bridge-request-id.txt").strip()
    before = read_json("prompt-bridge-before-screen.json")
    open_url = read_json("prompt-bridge-open-url.json")
    pre_screen = read_json("prompt-bridge-pre-screen.json")
    model_status = read_json("prompt-bridge-model-status.json")
    response = read_json("prompt-bridge-response.json")
    agent_status = read_json("prompt-bridge-agent-status.json")
    trajectory = read_json("prompt-bridge-trajectory.json")
    after_screen = read_json("prompt-bridge-after-screen.json")
    safari_state = read_json("prompt-bridge-safari-state.json")
    tweak_log = read_text("prompt-bridge-tweak-log.txt")
    before_fields = app_ui_fields(before)
    pre_fields = app_ui_fields(pre_screen)
    after_fields = app_ui_fields(after_screen)
    pre_web_dom = web_dom_status(pre_screen)
    latest_task = agent_status.get("latest_task") if isinstance(agent_status, dict) else {}
    if not isinstance(latest_task, dict):
        latest_task = {}
    checks = {
        "ok": True,
        "blocked": False,
        "errors": [],
        "marker": marker,
        "request_id": request_id,
        "before_locked": before_fields["locked"],
        "open_url_state": action_state(open_url),
        "pre": pre_fields,
        "after": after_fields,
        "pre_web_dom_status": pre_web_dom.get("status"),
        "pre_web_dom_element_count": pre_web_dom.get("element_count"),
        "model_status": model_status.get("status") if isinstance(model_status, dict) else None,
        "model_mode": model_status.get("mode") if isinstance(model_status, dict) else None,
        "prompt_response_status": response.get("status") if isinstance(response, dict) else None,
        "prompt_response_operation": response.get("operation") if isinstance(response, dict) else None,
        "agent_state": agent_status.get("state") if isinstance(agent_status, dict) else None,
        "latest_task_id": latest_task.get("task_id"),
        "latest_task_status": latest_task.get("status"),
        "latest_task_stop_reason": latest_task.get("stop_reason"),
        "latest_task_model_provider": latest_task.get("model_provider"),
        "latest_task_tool": latest_task.get("model_loop_tool"),
        "trajectory_status": trajectory.get("status") if isinstance(trajectory, dict) else None,
        "safari_state_status": safari_state.get("status") if isinstance(safari_state, dict) else None,
        "tweak_log_mentions_request": request_id in tweak_log if request_id else False,
    }
    if before_fields["locked"] is not False:
        checks["ok"] = False
        checks["blocked"] = True
        checks["errors"].append("device_locked_or_unknown")
        return checks
    if not marker:
        checks["ok"] = False
        checks["errors"].append("missing_marker")
    if not request_id:
        checks["ok"] = False
        checks["errors"].append("missing_request_id")
    if not isinstance(open_url, dict) or action_state(open_url) != "action.executed":
        checks["ok"] = False
        checks["errors"].append(f"open_url_state:{action_state(open_url)}")
    if pre_fields["foreground_app"] != "com.apple.mobilesafari":
        checks["ok"] = False
        checks["errors"].append(f"pre_foreground_app:{pre_fields['foreground_app']}")
    if pre_fields["ui_tree_source"] != "app_process":
        checks["ok"] = False
        checks["errors"].append(f"pre_ui_tree_source:{pre_fields['ui_tree_source']}")
    if pre_web_dom.get("status") != "ok":
        checks["ok"] = False
        checks["errors"].append(f"pre_web_dom_status:{pre_web_dom.get('status')}")
    if not isinstance(model_status, dict) or model_status.get("status") != "ready":
        checks["ok"] = False
        checks["errors"].append(f"model_status:{model_status.get('status') if isinstance(model_status, dict) else None}")
    if not isinstance(response, dict) or response.get("status") != "ok":
        checks["ok"] = False
        checks["errors"].append(f"prompt_response_status:{response.get('status') if isinstance(response, dict) else None}")
    if isinstance(response, dict):
        if response.get("operation") != "run_goal":
            checks["ok"] = False
            checks["errors"].append(f"prompt_response_operation:{response.get('operation')}")
        if request_id and response.get("request_id") != request_id:
            checks["ok"] = False
            checks["errors"].append("prompt_response_request_id_mismatch")
    if latest_task.get("status") != "completed":
        checks["ok"] = False
        checks["errors"].append(f"latest_task_status:{latest_task.get('status')}")
    if latest_task.get("stop_reason") != "verified_type_text_goal_complete":
        checks["ok"] = False
        checks["errors"].append(f"latest_task_stop_reason:{latest_task.get('stop_reason')}")
    if latest_task.get("model_provider") != "bedrock_converse":
        checks["ok"] = False
        checks["errors"].append(f"latest_task_model_provider:{latest_task.get('model_provider')}")
    if latest_task.get("model_loop_tool") != "type_text":
        checks["ok"] = False
        checks["errors"].append(f"latest_task_tool:{latest_task.get('model_loop_tool')}")
    if latest_task.get("tool_errors") != 0:
        checks["ok"] = False
        checks["errors"].append("latest_task_tool_errors")
    task_id = latest_task.get("task_id")
    if not isinstance(task_id, str) or not task_id:
        checks["ok"] = False
        checks["errors"].append("missing_task_id")
    if not isinstance(trajectory, dict) or trajectory.get("status") != "ok":
        checks["ok"] = False
        checks["errors"].append("trajectory_status")
        events = []
    else:
        events = trajectory.get("events")
        if not isinstance(events, list):
            checks["ok"] = False
            checks["errors"].append("trajectory_events_not_list")
            events = []
    event_names = [event.get("event") for event in events if isinstance(event, dict)]
    for required in ("task_started", "model_prompt_prepared", "model_request", "model_response", "model_decision", "tool_call", "model_step_verified", "model_loop_finished"):
        if required not in event_names:
            checks["ok"] = False
            checks["errors"].append(f"missing_{required}")
    provider_backed = False
    chose_type_text = False
    typed_marker = False
    dom_verified = False
    webcontent_attempt = False
    for event in events:
        if not isinstance(event, dict):
            continue
        payload = event.get("payload") if isinstance(event.get("payload"), dict) else {}
        if event.get("event") == "model_response":
            metadata = payload.get("metadata") if isinstance(payload.get("metadata"), dict) else {}
            if metadata.get("provider") == "bedrock_converse" and metadata.get("provider_backed") is True:
                provider_backed = True
        if event.get("event") == "model_decision":
            decision = payload.get("decision") if isinstance(payload.get("decision"), dict) else {}
            arguments = decision.get("arguments") if isinstance(decision.get("arguments"), dict) else {}
            if decision.get("tool") == "type_text":
                chose_type_text = True
                if marker and arguments.get("text") == marker:
                    typed_marker = True
        if event.get("event") == "model_step_verified" and payload.get("tool") == "type_text":
            verification = payload.get("verification") if isinstance(payload.get("verification"), dict) else {}
            provider_verification = verification.get("provider_verification") if isinstance(verification.get("provider_verification"), dict) else {}
            if verification.get("status") == "verified" and provider_verification.get("source") == "web_content_dom_state":
                dom_verified = True
            tool_result = payload.get("tool_result") if isinstance(payload.get("tool_result"), dict) else {}
            attempts = tool_result.get("provider_attempts") if isinstance(tool_result.get("provider_attempts"), list) else []
            for attempt in attempts:
                if not isinstance(attempt, dict):
                    continue
                if attempt.get("provider") == "OpenPhoneAppIntrospector.WebContentInput" and attempt.get("activation_method") == "webkit_dom_text_input":
                    webcontent_attempt = True
    marker_visible = contains_text(after_screen, marker) or contains_text(safari_state, marker)
    if not provider_backed:
        checks["ok"] = False
        checks["errors"].append("missing_bedrock_provider_metadata")
    if not chose_type_text:
        checks["ok"] = False
        checks["errors"].append("missing_type_text_decision")
    if not typed_marker:
        checks["ok"] = False
        checks["errors"].append("type_text_marker_mismatch")
    if not dom_verified:
        checks["ok"] = False
        checks["errors"].append("missing_dom_verified_step")
    if not webcontent_attempt:
        checks["ok"] = False
        checks["errors"].append("missing_webcontent_input_attempt")
    if not marker_visible:
        checks["ok"] = False
        checks["errors"].append("marker_not_visible_after")
    if after_fields["foreground_app"] != "com.apple.mobilesafari":
        checks["ok"] = False
        checks["errors"].append(f"after_foreground_app:{after_fields['foreground_app']}")
    if request_id and request_id not in tweak_log:
        checks["ok"] = False
        checks["errors"].append("tweak_log_missing_request")
    checks["task_id"] = task_id if isinstance(task_id, str) else ""
    checks["events_seen"] = len(events)
    checks["provider_backed"] = provider_backed
    checks["type_text_decision"] = chose_type_text
    checks["typed_marker"] = typed_marker
    checks["dom_verified"] = dom_verified
    checks["webcontent_attempt"] = webcontent_attempt
    checks["marker_visible_after"] = marker_visible
    return checks

def check_trajectory_shape(name):
    data = read_json(name)
    checks = {
        "artifact": name,
        "ok": True,
        "status": data.get("status") if isinstance(data, dict) else None,
        "errors": [],
    }
    if not isinstance(data, dict):
        checks["ok"] = False
        checks["errors"].append("not_object")
        return checks
    if data.get("status") != "ok":
        checks["ok"] = False
        checks["errors"].append("status_not_ok")
    if not isinstance(data.get("task_id"), str) or not data.get("task_id"):
        checks["ok"] = False
        checks["errors"].append("missing_task_id")
    if not isinstance(data.get("trajectory_path"), str) or not data.get("trajectory_path"):
        checks["ok"] = False
        checks["errors"].append("missing_trajectory_path")
    events = data.get("events")
    if not isinstance(events, list):
        checks["ok"] = False
        checks["errors"].append("events_not_list")
        events = []
    count = data.get("count")
    if not isinstance(count, int) or count < 0:
        checks["ok"] = False
        checks["errors"].append("count_not_nonnegative_int")
    elif len(events) > count:
        checks["ok"] = False
        checks["errors"].append("events_longer_than_count")
    if not events:
        checks["ok"] = False
        checks["errors"].append("events_empty")
    for index, event in enumerate(events[:10]):
        if not isinstance(event, dict):
            checks["ok"] = False
            checks["errors"].append(f"events[{index}]_not_object")
            continue
        for key in ("schema", "timestamp_ms", "event", "payload", "source"):
            if key not in event:
                checks["ok"] = False
                checks["errors"].append(f"events[{index}]_missing:{key}")
        if event.get("schema") != "openphone.trajectory_event.v1":
            checks["ok"] = False
            checks["errors"].append(f"events[{index}]_schema")
    provider_attempts = check_provider_attempt_shapes(events)
    checks["provider_attempts"] = provider_attempts
    if provider_attempts["status"] == "fail":
        checks["ok"] = False
        checks["errors"].extend(provider_attempts["errors"])
    checks["count"] = count if isinstance(count, int) else None
    checks["items_seen"] = len(events)
    return checks

FORBIDDEN_SECRET_KEYS = {
    "password",
    "passcode",
    "pin",
    "token",
    "access_token",
    "refresh_token",
    "bearer",
    "bearer_token",
    "authorization",
    "auth_header",
    "api_key",
    "apikey",
    "secret",
    "client_secret",
    "private_key",
    "secret_key",
    "aws_access_key_id",
    "aws_secret_access_key",
}

SAFE_SECRET_KEY_EXCEPTIONS = {
    "passcode_available",
    "passcode_visible",
    "requires_passcode",
    "has_passcode",
}

SECRET_VALUE_PATTERNS = (
    ("private_key_pem", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("authorization_bearer", re.compile(r"\bauthorization\s*:\s*bearer\s+[A-Za-z0-9._~+/=-]{12,}", re.IGNORECASE)),
    ("sensitive_env_assignment", re.compile(r"\b(AWS_BEARER_TOKEN_BEDROCK|OPENAI_API_KEY|ANTHROPIC_API_KEY|OPENPHONE_IOS_PASSWORD)\s*=\s*['\"]?[^'\"\s]+", re.IGNORECASE)),
    ("openai_api_key", re.compile(r"\bsk-[A-Za-z0-9_-]{20,}\b")),
    ("bedrock_bearer_token", re.compile(r"\bABSK[A-Za-z0-9+/=]{20,}\b")),
    ("aws_access_key", re.compile(r"\b(AKIA|ASIA)[A-Z0-9]{16}\b")),
    ("slack_token", re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{20,}\b")),
    ("basic_auth_url", re.compile(r"https?://[^/\s:@]{1,128}:[^/\s:@]{1,128}@")),
)

MAX_HYGIENE_FINDINGS = 50
MAX_HYGIENE_FILE_BYTES = 2 * 1024 * 1024
BINARY_ARTIFACT_SUFFIXES = {
    ".deb",
    ".dylib",
    ".gif",
    ".heic",
    ".jpg",
    ".jpeg",
    ".png",
    ".sqlite",
}

def normalize_secret_key(key):
    return re.sub(r"[^a-z0-9]+", "_", str(key).strip().lower()).strip("_")

def is_forbidden_secret_key(key):
    normalized = normalize_secret_key(key)
    if normalized in SAFE_SECRET_KEY_EXCEPTIONS:
        return False
    if normalized in FORBIDDEN_SECRET_KEYS:
        return True
    return normalized.endswith((
        "_password",
        "_passcode",
        "_token",
        "_api_key",
        "_apikey",
        "_secret",
        "_private_key",
        "_secret_key",
    ))

def add_hygiene_finding(findings, finding):
    if len(findings) < MAX_HYGIENE_FINDINGS:
        findings.append(finding)

def scan_secret_string(artifact, locator, value, findings):
    for detector, pattern in SECRET_VALUE_PATTERNS:
        if pattern.search(value):
            finding = {
                "artifact": artifact,
                "detector": detector,
            }
            if locator:
                finding["location"] = locator
            add_hygiene_finding(findings, finding)

def scan_json_for_hygiene(artifact, value, path, findings):
    if isinstance(value, dict):
        for key, item in value.items():
            next_path = f"{path}.{key}" if path else str(key)
            if is_forbidden_secret_key(key):
                add_hygiene_finding(findings, {
                    "artifact": artifact,
                    "detector": "forbidden_json_key",
                    "location": next_path,
                })
            scan_json_for_hygiene(artifact, item, next_path, findings)
    elif isinstance(value, list):
        for index, item in enumerate(value):
            scan_json_for_hygiene(artifact, item, f"{path}[{index}]", findings)
    elif isinstance(value, str):
        scan_secret_string(artifact, path, value, findings)

def scan_text_for_hygiene(artifact, text, findings):
    for line_number, line in enumerate(text.splitlines(), 1):
        before = len(findings)
        scan_secret_string(artifact, f"line:{line_number}", line, findings)
        if len(findings) > before and len(findings) >= MAX_HYGIENE_FINDINGS:
            return

def check_artifact_hygiene():
    findings = []
    checked_files = []
    skipped_files = []

    for path in sorted(run_dir.iterdir()):
        if not path.is_file():
            continue
        artifact = path.name
        if artifact in ("report.json", "exit-code.txt"):
            continue
        suffix = path.suffix.lower()
        if suffix in BINARY_ARTIFACT_SUFFIXES:
            skipped_files.append({"artifact": artifact, "reason": "binary_suffix"})
            continue
        try:
            size = path.stat().st_size
        except OSError:
            skipped_files.append({"artifact": artifact, "reason": "stat_failed"})
            continue
        if size > MAX_HYGIENE_FILE_BYTES:
            skipped_files.append({"artifact": artifact, "reason": "too_large"})
            continue
        try:
            raw = path.read_bytes()
        except OSError:
            skipped_files.append({"artifact": artifact, "reason": "read_failed"})
            continue
        if b"\x00" in raw[:4096]:
            skipped_files.append({"artifact": artifact, "reason": "binary_probe"})
            continue

        text = raw.decode("utf-8", errors="replace")
        checked_files.append(artifact)
        if suffix == ".json" and text.strip():
            try:
                data = json.loads(text)
            except Exception:
                scan_text_for_hygiene(artifact, text, findings)
            else:
                scan_json_for_hygiene(artifact, data, "", findings)
        else:
            scan_text_for_hygiene(artifact, text, findings)

    return {
        "status": "fail" if findings else "pass",
        "checked_files": len(checked_files),
        "skipped_files": skipped_files,
        "findings": findings,
        "truncated": len(findings) >= MAX_HYGIENE_FINDINGS,
    }

def action_state(data):
    if not isinstance(data, dict):
        return None
    return data.get("state") or data.get("status")

def screen_context(data):
    return data.get("context", {}) if isinstance(data, dict) else {}

def context_lock_state(context):
    lock = context.get("lock", {}) if isinstance(context, dict) else {}
    return lock.get("locked") if isinstance(lock, dict) else None

def foreground_fields(data):
    context = screen_context(data)
    springboard = context.get("springboard_state", {}) if isinstance(context, dict) else {}
    risk_flags = context.get("risk_flags", []) if isinstance(context, dict) else []
    return {
        "foreground_app": context.get("foreground_app") if isinstance(context, dict) else None,
        "foreground_source": context.get("foreground_source") if isinstance(context, dict) else None,
        "springboard_state_status": springboard.get("status") if isinstance(springboard, dict) else None,
        "springboard_state_foreground_app": springboard.get("foreground_app") if isinstance(springboard, dict) else None,
        "risk_flags": risk_flags if isinstance(risk_flags, list) else [],
        "locked": context_lock_state(context),
    }

def app_ui_fields(data):
    context = screen_context(data)
    app_state = context.get("app_ui_state", {}) if isinstance(context, dict) else {}
    ui_tree = context.get("ui_tree", {}) if isinstance(context, dict) else {}
    risk_flags = context.get("risk_flags", []) if isinstance(context, dict) else []
    return {
        "status": data.get("status") if isinstance(data, dict) else None,
        "locked": context_lock_state(context),
        "foreground_app": context.get("foreground_app") if isinstance(context, dict) else None,
        "foreground_source": context.get("foreground_source") if isinstance(context, dict) else None,
        "ui_tree_source": context.get("ui_tree_source") if isinstance(context, dict) else None,
        "app_ui_status": app_state.get("status") if isinstance(app_state, dict) else None,
        "app_ui_bundle_id": app_state.get("bundle_id") if isinstance(app_state, dict) else None,
        "ui_tree_status": ui_tree.get("status") if isinstance(ui_tree, dict) else None,
        "element_count": ui_tree.get("element_count") if isinstance(ui_tree, dict) else None,
        "text_count": ui_tree.get("text_count") if isinstance(ui_tree, dict) else None,
        "risk_flags": risk_flags if isinstance(risk_flags, list) else [],
    }

def ui_visible_text(data):
    context = screen_context(data)
    ui_tree = context.get("ui_tree", {}) if isinstance(context, dict) else {}
    visible = ui_tree.get("visible_text") if isinstance(ui_tree, dict) else []
    return [str(item) for item in visible] if isinstance(visible, list) else []

def json_contains_string(value, needle):
    if not needle:
        return False
    if isinstance(value, str):
        return needle in value
    if isinstance(value, dict):
        return any(json_contains_string(item, needle) for item in value.values())
    if isinstance(value, list):
        return any(json_contains_string(item, needle) for item in value)
    return False

def screenshot_fields(data):
    screenshot = data.get("screenshot") if isinstance(data, dict) else {}
    if not isinstance(screenshot, dict):
        context = screen_context(data)
        screenshot = context.get("screenshot", {}) if isinstance(context, dict) else {}
    if not isinstance(screenshot, dict):
        screenshot = {}
    return {
        "status": screenshot.get("status"),
        "provider": screenshot.get("provider"),
        "path": screenshot.get("path"),
        "sha256": screenshot.get("sha256"),
        "bytes": screenshot.get("bytes"),
        "width": screenshot.get("width"),
        "height": screenshot.get("height"),
    }

def screenshot_hash_changed(before, after):
    before_screenshot = screenshot_fields(before)
    after_screenshot = screenshot_fields(after)
    before_hash = before_screenshot.get("sha256")
    after_hash = after_screenshot.get("sha256")
    return {
        "before": before_screenshot,
        "after": after_screenshot,
        "changed": (
            before_screenshot.get("status") == "ok"
            and after_screenshot.get("status") == "ok"
            and isinstance(before_hash, str)
            and isinstance(after_hash, str)
            and len(before_hash) >= 16
            and len(after_hash) >= 16
            and before_hash != after_hash
        ),
    }

def check_unlocked_foreground_shape():
    before = read_json("unlocked-foreground-before-screen.json")
    open_safari = read_json("unlocked-foreground-open-safari.json")
    safari_screen = read_json("unlocked-foreground-safari-screen.json")
    home = read_json("unlocked-foreground-home.json")
    home_screen = read_json("unlocked-foreground-home-screen.json")
    before_fields = foreground_fields(before)
    safari_fields = foreground_fields(safari_screen)
    home_fields = foreground_fields(home_screen)
    checks = {
        "ok": True,
        "blocked": False,
        "errors": [],
        "before_locked": before_fields["locked"],
        "open_safari_state": action_state(open_safari),
        "safari_foreground_app": safari_fields["foreground_app"],
        "safari_foreground_source": safari_fields["foreground_source"],
        "safari_springboard_state_status": safari_fields["springboard_state_status"],
        "safari_springboard_state_foreground_app": safari_fields["springboard_state_foreground_app"],
        "home_state": action_state(home),
        "home_foreground_app": home_fields["foreground_app"],
        "home_foreground_source": home_fields["foreground_source"],
        "home_springboard_state_status": home_fields["springboard_state_status"],
    }
    if before_fields["locked"] is not False:
        checks["ok"] = False
        checks["blocked"] = True
        checks["errors"].append("device_locked_or_unknown")
        return checks
    if not isinstance(open_safari, dict) or open_safari.get("status") == "skipped":
        checks["ok"] = False
        checks["errors"].append(f"open_safari_status:{open_safari.get('status') if isinstance(open_safari, dict) else None}")
    elif action_state(open_safari) != "action.executed":
        checks["ok"] = False
        checks["errors"].append(f"open_safari_state:{action_state(open_safari)}")

    if not isinstance(safari_screen, dict) or safari_screen.get("status") == "skipped":
        checks["ok"] = False
        checks["errors"].append(f"safari_screen_status:{safari_screen.get('status') if isinstance(safari_screen, dict) else None}")
    else:
        if safari_fields["locked"] is not False:
            checks["ok"] = False
            checks["errors"].append(f"safari_locked:{safari_fields['locked']}")
        if safari_fields["foreground_app"] != "com.apple.mobilesafari":
            checks["ok"] = False
            checks["errors"].append(f"safari_foreground_app:{safari_fields['foreground_app']}")
        if safari_fields["foreground_source"] != "springboard_state":
            checks["ok"] = False
            checks["errors"].append(f"safari_foreground_source:{safari_fields['foreground_source']}")
        if safari_fields["springboard_state_status"] != "ok":
            checks["ok"] = False
            checks["errors"].append(f"safari_springboard_state_status:{safari_fields['springboard_state_status']}")
        if safari_fields["springboard_state_foreground_app"] != "com.apple.mobilesafari":
            checks["ok"] = False
            checks["errors"].append(f"safari_springboard_state_foreground_app:{safari_fields['springboard_state_foreground_app']}")
        if "foreground_app_inferred" in safari_fields["risk_flags"]:
            checks["ok"] = False
            checks["errors"].append("safari_foreground_inferred")

    if not isinstance(home, dict) or home.get("status") == "skipped":
        checks["ok"] = False
        checks["errors"].append(f"home_status:{home.get('status') if isinstance(home, dict) else None}")
    elif action_state(home) != "action.executed":
        checks["ok"] = False
        checks["errors"].append(f"home_state:{action_state(home)}")

    if not isinstance(home_screen, dict) or home_screen.get("status") == "skipped":
        checks["ok"] = False
        checks["errors"].append(f"home_screen_status:{home_screen.get('status') if isinstance(home_screen, dict) else None}")
    elif home_fields["locked"] is not False:
        checks["ok"] = False
        checks["errors"].append(f"home_locked:{home_fields['locked']}")
    return checks

def check_app_ui_shape():
    before = read_json("app-ui-before-screen.json")
    relaunch = read_json("app-ui-relaunch.json")
    open_safari = read_json("app-ui-open-safari.json")
    safari_screen = read_json("app-ui-safari-screen.json")
    open_settings = read_json("app-ui-open-settings.json")
    settings_screen = read_json("app-ui-settings-screen.json")
    health_after = read_json("app-ui-health.json")
    safari_state = read_json("app-ui-safari-state.json")
    settings_state = read_json("app-ui-settings-state.json")
    before_fields = app_ui_fields(before)
    safari_fields = app_ui_fields(safari_screen)
    settings_fields = app_ui_fields(settings_screen)
    health_screen = ((health_after.get("providers") or {}).get("screen") or {}) if isinstance(health_after, dict) else {}
    intake = health_screen.get("app_ui_intake") if isinstance(health_screen, dict) else {}
    checks = {
        "ok": True,
        "blocked": False,
        "errors": [],
        "before_locked": before_fields["locked"],
        "relaunch_status": relaunch.get("status") if isinstance(relaunch, dict) else None,
        "open_safari_state": action_state(open_safari),
        "open_settings_state": action_state(open_settings),
        "safari": safari_fields,
        "settings": settings_fields,
        "intake_status": intake.get("status") if isinstance(intake, dict) else None,
        "publish_count": intake.get("publish_count") if isinstance(intake, dict) else None,
        "last_bundle_id": intake.get("last_bundle_id") if isinstance(intake, dict) else None,
        "safari_state_status": safari_state.get("status") if isinstance(safari_state, dict) else None,
        "settings_state_status": settings_state.get("status") if isinstance(settings_state, dict) else None,
    }
    if before_fields["locked"] is not False:
        checks["ok"] = False
        checks["blocked"] = True
        checks["errors"].append("device_locked_or_unknown")
        return checks
    if not isinstance(relaunch, dict) or relaunch.get("status") != "ok":
        checks["ok"] = False
        checks["errors"].append(f"relaunch_status:{relaunch.get('status') if isinstance(relaunch, dict) else None}")
    for label, open_result, screen_result, fields, bundle_id, state in (
        ("safari", open_safari, safari_screen, safari_fields, "com.apple.mobilesafari", safari_state),
        ("settings", open_settings, settings_screen, settings_fields, "com.apple.Preferences", settings_state),
    ):
        if not isinstance(open_result, dict) or action_state(open_result) != "action.executed":
            checks["ok"] = False
            checks["errors"].append(f"{label}_open_state:{action_state(open_result)}")
        if not isinstance(screen_result, dict) or screen_result.get("status") != "ok":
            checks["ok"] = False
            checks["errors"].append(f"{label}_screen_status:{screen_result.get('status') if isinstance(screen_result, dict) else None}")
            continue
        if fields["locked"] is not False:
            checks["ok"] = False
            checks["errors"].append(f"{label}_locked:{fields['locked']}")
        if fields["foreground_app"] != bundle_id:
            checks["ok"] = False
            checks["errors"].append(f"{label}_foreground_app:{fields['foreground_app']}")
        if fields["ui_tree_source"] != "app_process":
            checks["ok"] = False
            checks["errors"].append(f"{label}_ui_tree_source:{fields['ui_tree_source']}")
        if fields["app_ui_status"] != "ok":
            checks["ok"] = False
            checks["errors"].append(f"{label}_app_ui_status:{fields['app_ui_status']}")
        if fields["app_ui_bundle_id"] != bundle_id:
            checks["ok"] = False
            checks["errors"].append(f"{label}_app_ui_bundle:{fields['app_ui_bundle_id']}")
        if fields["ui_tree_status"] != "ok":
            checks["ok"] = False
            checks["errors"].append(f"{label}_ui_tree_status:{fields['ui_tree_status']}")
        if not isinstance(fields["element_count"], int) or fields["element_count"] <= 0:
            checks["ok"] = False
            checks["errors"].append(f"{label}_element_count:{fields['element_count']}")
        if not isinstance(fields["text_count"], int) or fields["text_count"] <= 0:
            checks["ok"] = False
            checks["errors"].append(f"{label}_text_count:{fields['text_count']}")
        bad_flags = {"app_ui_state_missing", "app_ui_state_stale", "app_ui_unavailable"}
        present_bad_flags = sorted(flag for flag in fields["risk_flags"] if flag in bad_flags)
        if present_bad_flags:
            checks["ok"] = False
            checks["errors"].append(f"{label}_risk_flags:{','.join(present_bad_flags)}")
        if not isinstance(state, dict) or state.get("status") != "ok":
            checks["ok"] = False
            checks["errors"].append(f"{label}_state_status:{state.get('status') if isinstance(state, dict) else None}")
        elif state.get("bundle_id") != bundle_id:
            checks["ok"] = False
            checks["errors"].append(f"{label}_state_bundle:{state.get('bundle_id')}")
    if not isinstance(intake, dict) or intake.get("status") != "ready":
        checks["ok"] = False
        checks["errors"].append(f"intake_status:{intake.get('status') if isinstance(intake, dict) else None}")
    publish_count = intake.get("publish_count") if isinstance(intake, dict) else None
    if not isinstance(publish_count, int) or publish_count < 2:
        checks["ok"] = False
        checks["errors"].append(f"publish_count:{publish_count}")
    return checks

def check_lockscreen_shape():
    before = read_json("lockscreen-before-screen.json")
    show_passcode = read_json("lockscreen-show-passcode.json")
    after = read_json("lockscreen-after-screen.json")
    status_after = read_json("lockscreen-status-after.json")
    before_fields = app_ui_fields(before)
    after_fields = app_ui_fields(after)
    before_screenshot = screenshot_fields(before)
    after_screenshot = screenshot_fields(after)
    provider_result = show_passcode.get("provider_result") if isinstance(show_passcode.get("provider_result"), dict) else {}
    fallback = provider_result.get("lockscreen_fallback") if isinstance(provider_result.get("lockscreen_fallback"), dict) else {}
    attempts = fallback.get("attempts") if isinstance(fallback.get("attempts"), list) else []
    passcode_visible = any(
        isinstance(attempt, dict) and attempt.get("passcode_visible") is True
        for attempt in attempts
    )
    checks = {
        "ok": True,
        "blocked": False,
        "blocker": "",
        "errors": [],
        "before_locked": before_fields["locked"],
        "after_locked": after_fields["locked"],
        "show_passcode_state": action_state(show_passcode),
        "show_passcode_user_facing_status": show_passcode.get("user_facing_status") if isinstance(show_passcode, dict) else None,
        "provider": provider_result.get("provider") if isinstance(provider_result, dict) else None,
        "activation_method": provider_result.get("activation_method") if isinstance(provider_result, dict) else None,
        "fallback_status": fallback.get("status") if isinstance(fallback, dict) else None,
        "passcode_visible": passcode_visible,
        "attempt_count": len(attempts),
        "before_screenshot": before_screenshot,
        "after_screenshot": after_screenshot,
        "screenshot_hash_changed": (
            bool(before_screenshot.get("sha256"))
            and bool(after_screenshot.get("sha256"))
            and before_screenshot.get("sha256") != after_screenshot.get("sha256")
        ),
        "after_status": status_after.get("status") if isinstance(status_after, dict) else None,
        "after_agent_state": status_after.get("state") if isinstance(status_after, dict) else None,
    }
    if before_fields["locked"] is not True:
        checks["ok"] = False
        checks["blocked"] = True
        checks["blocker"] = "device_unlocked_or_unknown"
        checks["errors"].append("device_unlocked_or_unknown")
        return checks
    if not isinstance(show_passcode, dict) or action_state(show_passcode) != "action.executed":
        checks["ok"] = False
        checks["errors"].append(f"show_passcode_state:{action_state(show_passcode)}")
    if provider_result.get("provider") != "OpenPhoneVolumeTrigger.SpringBoardInput":
        checks["ok"] = False
        checks["errors"].append(f"provider:{provider_result.get('provider')}")
    if fallback.get("status") != "ok":
        checks["ok"] = False
        checks["errors"].append(f"fallback_status:{fallback.get('status')}")
    if not passcode_visible:
        checks["ok"] = False
        checks["errors"].append("passcode_not_visible")
    activation_method = provider_result.get("activation_method")
    if not isinstance(activation_method, str) or "PasscodeLockVisible" not in activation_method:
        checks["ok"] = False
        checks["errors"].append(f"activation_method:{activation_method}")
    if not isinstance(after, dict) or after.get("status") != "ok":
        checks["ok"] = False
        checks["errors"].append(f"after_screen_status:{after.get('status') if isinstance(after, dict) else None}")
    if after_fields["locked"] is not True:
        checks["ok"] = False
        checks["errors"].append(f"after_locked:{after_fields['locked']}")
    if after_screenshot.get("status") != "ok":
        checks["ok"] = False
        checks["errors"].append(f"after_screenshot_status:{after_screenshot.get('status')}")
    if after_screenshot.get("provider") != "OpenPhoneVolumeTrigger.SpringBoardScreenshot":
        checks["ok"] = False
        checks["errors"].append(f"after_screenshot_provider:{after_screenshot.get('provider')}")
    if not after_screenshot.get("sha256"):
        checks["ok"] = False
        checks["errors"].append("after_screenshot_missing_sha256")
    width = after_screenshot.get("width")
    height = after_screenshot.get("height")
    if not isinstance(width, int) or width <= 0 or not isinstance(height, int) or height <= 0:
        checks["ok"] = False
        checks["errors"].append(f"after_screenshot_dimensions:{width}x{height}")
    if status_after.get("status") != "ok":
        checks["ok"] = False
        checks["errors"].append(f"after_agent_status:{status_after.get('status')}")
    return checks

def check_prefs_backend_shape():
    files = read_json("prefs-backend-files.json")
    before = read_json("prefs-backend-status-before.json")
    disable_hardware = read_json("prefs-backend-disable-hardware.json")
    trigger_disabled = read_json("prefs-backend-trigger-disabled.json")
    enable_hardware = read_json("prefs-backend-enable-hardware.json")
    disable_yolo = read_json("prefs-backend-disable-yolo.json")
    trigger_yolo_disabled = read_json("prefs-backend-trigger-yolo-disabled.json")
    enable_yolo = read_json("prefs-backend-enable-yolo.json")
    after = read_json("prefs-backend-status-after.json")

    def control(data):
        return data.get("control") if isinstance(data.get("control"), dict) else {}

    before_control = control(before)
    after_control = control(after)
    checks = {
        "ok": True,
        "errors": [],
        "files": {
            "bundle_executable": files.get("bundle_executable") if isinstance(files, dict) else None,
            "bundle_info": files.get("bundle_info") if isinstance(files, dict) else None,
            "loader_entry": files.get("loader_entry") if isinstance(files, dict) else None,
        },
        "before": {
            "status": before.get("status") if isinstance(before, dict) else None,
            "trigger_policy": before_control.get("trigger_policy"),
            "hardware_triggers_enabled": before_control.get("hardware_triggers_enabled"),
            "yolo_enabled": before_control.get("yolo_enabled"),
        },
        "disable_hardware": {
            "status": disable_hardware.get("status") if isinstance(disable_hardware, dict) else None,
            "hardware_triggers_enabled": control(disable_hardware).get("hardware_triggers_enabled"),
        },
        "trigger_disabled_state": trigger_disabled.get("state") if isinstance(trigger_disabled, dict) else None,
        "enable_hardware": {
            "status": enable_hardware.get("status") if isinstance(enable_hardware, dict) else None,
            "hardware_triggers_enabled": control(enable_hardware).get("hardware_triggers_enabled"),
        },
        "disable_yolo": {
            "status": disable_yolo.get("status") if isinstance(disable_yolo, dict) else None,
            "yolo_enabled": control(disable_yolo).get("yolo_enabled"),
        },
        "trigger_yolo_disabled_state": trigger_yolo_disabled.get("state") if isinstance(trigger_yolo_disabled, dict) else None,
        "enable_yolo": {
            "status": enable_yolo.get("status") if isinstance(enable_yolo, dict) else None,
            "yolo_enabled": control(enable_yolo).get("yolo_enabled"),
        },
        "after": {
            "status": after.get("status") if isinstance(after, dict) else None,
            "paused": after_control.get("paused"),
            "trigger_policy": after_control.get("trigger_policy"),
            "hardware_triggers_enabled": after_control.get("hardware_triggers_enabled"),
            "yolo_enabled": after_control.get("yolo_enabled"),
        },
    }
    for key in ("bundle_executable", "bundle_info", "loader_entry"):
        if files.get(key) is not True:
            checks["ok"] = False
            checks["errors"].append(f"missing_{key}")
    if before.get("status") != "ok":
        checks["ok"] = False
        checks["errors"].append(f"before_status:{before.get('status')}")
    if disable_hardware.get("status") != "ok" or control(disable_hardware).get("hardware_triggers_enabled") is not False:
        checks["ok"] = False
        checks["errors"].append("disable_hardware_failed")
    if trigger_disabled.get("status") != "ok" or trigger_disabled.get("state") != "trigger.disabled":
        checks["ok"] = False
        checks["errors"].append(f"trigger_disabled_state:{trigger_disabled.get('state')}")
    if "agent_task_id" in trigger_disabled or "background_job" in trigger_disabled:
        checks["ok"] = False
        checks["errors"].append("trigger_disabled_created_work")
    if enable_hardware.get("status") != "ok" or control(enable_hardware).get("hardware_triggers_enabled") is not True:
        checks["ok"] = False
        checks["errors"].append("enable_hardware_failed")
    if disable_yolo.get("status") != "ok" or control(disable_yolo).get("yolo_enabled") is not False:
        checks["ok"] = False
        checks["errors"].append("disable_yolo_failed")
    if trigger_yolo_disabled.get("status") != "ok" or trigger_yolo_disabled.get("state") != "trigger.yolo_disabled":
        checks["ok"] = False
        checks["errors"].append(f"trigger_yolo_disabled_state:{trigger_yolo_disabled.get('state')}")
    if "agent_task_id" in trigger_yolo_disabled or "background_job" in trigger_yolo_disabled:
        checks["ok"] = False
        checks["errors"].append("trigger_yolo_disabled_created_work")
    if enable_yolo.get("status") != "ok" or control(enable_yolo).get("yolo_enabled") is not True:
        checks["ok"] = False
        checks["errors"].append("enable_yolo_failed")
    if after.get("status") != "ok":
        checks["ok"] = False
        checks["errors"].append(f"after_status:{after.get('status')}")
    if after_control.get("paused") is not False:
        checks["ok"] = False
        checks["errors"].append(f"after_paused:{after_control.get('paused')}")
    if after_control.get("trigger_policy") != "allow_yolo":
        checks["ok"] = False
        checks["errors"].append(f"after_trigger_policy:{after_control.get('trigger_policy')}")
    if after_control.get("hardware_triggers_enabled") is not True:
        checks["ok"] = False
        checks["errors"].append(f"after_hardware:{after_control.get('hardware_triggers_enabled')}")
    if after_control.get("yolo_enabled") is not True:
        checks["ok"] = False
        checks["errors"].append(f"after_yolo:{after_control.get('yolo_enabled')}")
    return checks

def check_prefs_ui_shape():
    before = read_json("prefs-ui-before-screen.json")
    prepare = read_json("prefs-ui-prepare.json")
    open_url = read_json("prefs-ui-open-url.json")
    url_screen = read_json("prefs-ui-url-screen.json")
    open_settings = read_json("prefs-ui-open-settings.json")
    settings_screen = read_json("prefs-ui-settings-screen.json")
    tap_row = read_json("prefs-ui-tap-row.json")
    pane_screen = read_json("prefs-ui-pane-screen.json")
    disable_hardware = read_json("prefs-ui-disable-hardware.json")
    after_disable_screen = read_json("prefs-ui-after-disable-screen.json")
    status_disabled = read_json("prefs-ui-status-disabled.json")
    enable_hardware = read_json("prefs-ui-enable-hardware.json")
    after_enable_screen = read_json("prefs-ui-after-enable-screen.json")
    status_enabled = read_json("prefs-ui-status-enabled.json")
    final_restore = read_json("prefs-ui-final-restore.json")
    status_after = read_json("prefs-ui-status-after.json")
    row_element = read_text("prefs-ui-row-element.txt").strip()
    hardware_element = read_text("prefs-ui-hardware-element.txt").strip()

    def control(data):
        return data.get("control") if isinstance(data.get("control"), dict) else {}

    def provider(data):
        return data.get("provider_result") if isinstance(data.get("provider_result"), dict) else {}

    def pane_fields(data):
        fields = app_ui_fields(data)
        visible = ui_visible_text(data)
        return {
            "foreground_app": fields["foreground_app"],
            "ui_tree_source": fields["ui_tree_source"],
            "app_ui_status": fields["app_ui_status"],
            "element_count": fields["element_count"],
            "text_count": fields["text_count"],
            "visible_required": {
                "OpenPhone Agent": "OpenPhone Agent" in visible,
                "Hardware Triggers": "Hardware Triggers" in visible,
                "YOLO Execution": "YOLO Execution" in visible,
            },
            "screenshot": screenshot_fields(data),
        }

    before_fields = app_ui_fields(before)
    pane = pane_fields(pane_screen)
    disabled_control = control(status_disabled)
    enabled_control = control(status_enabled)
    after_control = control(status_after)
    disable_provider = provider(disable_hardware)
    enable_provider = provider(enable_hardware)
    checks = {
        "ok": True,
        "blocked": False,
        "errors": [],
        "before_locked": before_fields["locked"],
        "prepare_status": prepare.get("status") if isinstance(prepare, dict) else None,
        "open_url_state": action_state(open_url),
        "url_screen_pane": pane_fields(url_screen),
        "open_settings_state": action_state(open_settings),
        "settings_screen": pane_fields(settings_screen),
        "row_element": row_element,
        "tap_row_state": action_state(tap_row),
        "pane": pane,
        "hardware_element": hardware_element,
        "disable_hardware_state": action_state(disable_hardware),
        "disable_hardware_provider": disable_provider.get("provider") if isinstance(disable_provider, dict) else None,
        "disable_hardware_activation": disable_provider.get("activation_method") if isinstance(disable_provider, dict) else None,
        "after_disable_screen": pane_fields(after_disable_screen),
        "status_disabled": {
            "status": status_disabled.get("status") if isinstance(status_disabled, dict) else None,
            "hardware_triggers_enabled": disabled_control.get("hardware_triggers_enabled"),
            "trigger_policy": disabled_control.get("trigger_policy"),
        },
        "enable_hardware_state": action_state(enable_hardware),
        "enable_hardware_provider": enable_provider.get("provider") if isinstance(enable_provider, dict) else None,
        "enable_hardware_activation": enable_provider.get("activation_method") if isinstance(enable_provider, dict) else None,
        "after_enable_screen": pane_fields(after_enable_screen),
        "status_enabled": {
            "status": status_enabled.get("status") if isinstance(status_enabled, dict) else None,
            "hardware_triggers_enabled": enabled_control.get("hardware_triggers_enabled"),
            "trigger_policy": enabled_control.get("trigger_policy"),
        },
        "final_restore_status": final_restore.get("status") if isinstance(final_restore, dict) else None,
        "after": {
            "status": status_after.get("status") if isinstance(status_after, dict) else None,
            "paused": after_control.get("paused"),
            "trigger_policy": after_control.get("trigger_policy"),
            "hardware_triggers_enabled": after_control.get("hardware_triggers_enabled"),
            "yolo_enabled": after_control.get("yolo_enabled"),
        },
    }
    if before_fields["locked"] is not False:
        checks["ok"] = False
        checks["blocked"] = True
        checks["errors"].append("device_locked_or_unknown")
        return checks
    if prepare.get("status") != "ok":
        checks["ok"] = False
        checks["errors"].append(f"prepare_status:{prepare.get('status')}")
    if not all(pane["visible_required"].values()):
        checks["ok"] = False
        checks["errors"].append("pane_missing_required_text")
    if pane["foreground_app"] != "com.apple.Preferences":
        checks["ok"] = False
        checks["errors"].append(f"pane_foreground:{pane['foreground_app']}")
    if pane["ui_tree_source"] != "app_process":
        checks["ok"] = False
        checks["errors"].append(f"pane_ui_tree_source:{pane['ui_tree_source']}")
    if pane["app_ui_status"] != "ok":
        checks["ok"] = False
        checks["errors"].append(f"pane_app_ui_status:{pane['app_ui_status']}")
    if not isinstance(pane["element_count"], int) or pane["element_count"] <= 0:
        checks["ok"] = False
        checks["errors"].append(f"pane_element_count:{pane['element_count']}")
    if tap_row.get("status") != "skipped" and action_state(tap_row) != "action.executed":
        checks["ok"] = False
        checks["errors"].append(f"tap_row_state:{action_state(tap_row)}")
    if tap_row.get("status") != "skipped" and not row_element:
        checks["ok"] = False
        checks["errors"].append("missing_openphone_agent_row")
    if not hardware_element:
        checks["ok"] = False
        checks["errors"].append("missing_hardware_triggers_element")
    if action_state(disable_hardware) != "action.executed":
        checks["ok"] = False
        checks["errors"].append(f"disable_hardware_state:{action_state(disable_hardware)}")
    if isinstance(disable_provider, dict) and disable_provider.get("provider") != "OpenPhoneAppIntrospector.AppInput":
        checks["ok"] = False
        checks["errors"].append(f"disable_hardware_provider:{disable_provider.get('provider')}")
    if disabled_control.get("hardware_triggers_enabled") is not False:
        checks["ok"] = False
        checks["errors"].append(f"status_disabled_hardware:{disabled_control.get('hardware_triggers_enabled')}")
    if action_state(enable_hardware) != "action.executed":
        checks["ok"] = False
        checks["errors"].append(f"enable_hardware_state:{action_state(enable_hardware)}")
    if isinstance(enable_provider, dict) and enable_provider.get("provider") != "OpenPhoneAppIntrospector.AppInput":
        checks["ok"] = False
        checks["errors"].append(f"enable_hardware_provider:{enable_provider.get('provider')}")
    if enabled_control.get("hardware_triggers_enabled") is not True:
        checks["ok"] = False
        checks["errors"].append(f"status_enabled_hardware:{enabled_control.get('hardware_triggers_enabled')}")
    if final_restore.get("status") != "ok":
        checks["ok"] = False
        checks["errors"].append(f"final_restore_status:{final_restore.get('status')}")
    if status_after.get("status") != "ok":
        checks["ok"] = False
        checks["errors"].append(f"after_status:{status_after.get('status')}")
    if after_control.get("paused") is not False:
        checks["ok"] = False
        checks["errors"].append(f"after_paused:{after_control.get('paused')}")
    if after_control.get("trigger_policy") != "allow_yolo":
        checks["ok"] = False
        checks["errors"].append(f"after_trigger_policy:{after_control.get('trigger_policy')}")
    if after_control.get("hardware_triggers_enabled") is not True:
        checks["ok"] = False
        checks["errors"].append(f"after_hardware:{after_control.get('hardware_triggers_enabled')}")
    if after_control.get("yolo_enabled") is not True:
        checks["ok"] = False
        checks["errors"].append(f"after_yolo:{after_control.get('yolo_enabled')}")
    return checks

def check_visible_effects_shape():
    before = read_json("visible-effects-before-screen.json")
    open_settings = read_json("visible-effects-open-settings.json")
    settings_precheck = read_json("visible-effects-settings-precheck.json")
    settings_reset = read_json("visible-effects-settings-reset.json")
    settings_before = read_json("visible-effects-settings-before.json")
    tap_settings = read_json("visible-effects-tap-settings.json")
    settings_after = read_json("visible-effects-settings-after.json")
    open_safari = read_json("visible-effects-open-safari.json")
    safari_before = read_json("visible-effects-safari-before.json")
    type_safari = read_json("visible-effects-type-safari.json")
    safari_after = read_json("visible-effects-safari-after.json")
    safari_state = read_json("visible-effects-safari-state.json")
    open_notes = read_json("visible-effects-open-notes.json")
    notes_before = read_json("visible-effects-notes-before.json")
    type_notes = read_json("visible-effects-type-notes.json")
    notes_after = read_json("visible-effects-notes-after.json")
    notes_state = read_json("visible-effects-notes-state.json")
    marker = read_text("visible-effects-safari-marker.txt").strip()
    notes_marker = read_text("visible-effects-notes-marker.txt").strip()
    settings_scenario = read_text("visible-effects-settings-scenario.txt").strip()
    settings_target_label = read_text("visible-effects-settings-target-label.txt").strip()
    settings_back_element = read_text("visible-effects-settings-back-element.txt").strip()
    settings_element = read_text("visible-effects-settings-element.txt").strip()
    safari_field = read_text("visible-effects-safari-field.txt").strip()
    notes_field = read_text("visible-effects-notes-field.txt").strip()
    before_fields = app_ui_fields(before)
    settings_before_fields = app_ui_fields(settings_before)
    settings_after_fields = app_ui_fields(settings_after)
    safari_before_fields = app_ui_fields(safari_before)
    safari_after_fields = app_ui_fields(safari_after)
    notes_before_fields = app_ui_fields(notes_before)
    notes_after_fields = app_ui_fields(notes_after)
    settings_before_text = ui_visible_text(settings_before)
    settings_after_text = ui_visible_text(settings_after)
    safari_after_text = ui_visible_text(safari_after)
    notes_after_text = ui_visible_text(notes_after)
    settings_screenshot = screenshot_hash_changed(settings_before, settings_after)
    safari_screenshot = screenshot_hash_changed(safari_before, safari_after)
    notes_screenshot = screenshot_hash_changed(notes_before, notes_after)
    settings_before_has_general_page = "About" in settings_before_text and "Software Update" in settings_before_text
    if not settings_scenario:
        settings_scenario = "general_to_keyboard" if settings_before_has_general_page else "root_to_general"
    if not settings_target_label:
        settings_target_label = "Keyboard" if settings_scenario == "general_to_keyboard" else "General"
    settings_before_expected = False
    settings_after_expected_page = False
    settings_expected_after_name = ""
    if settings_scenario == "root_to_general":
        settings_expected_after_name = "general_page"
        settings_before_expected = "General" in settings_before_text and not settings_before_has_general_page
        settings_after_expected_page = (
            "About" in settings_after_text
            and "Software Update" in settings_after_text
            and "General" in settings_after_text
        )
    elif settings_scenario == "general_to_keyboard":
        settings_expected_after_name = "keyboard_page"
        settings_before_expected = settings_before_has_general_page and "Keyboard" in settings_before_text
        settings_after_expected_page = (
            "Keyboards" in settings_after_text
            and (
                "Text Replacement" in settings_after_text
                or "One-Handed Keyboard" in settings_after_text
                or "Enable Dictation" in settings_after_text
            )
        )
    elif settings_scenario == "keyboard_to_keyboards":
        settings_expected_after_name = "keyboards_page"
        settings_before_expected = (
            "Keyboards" in settings_before_text
            and "Text Replacement" in settings_before_text
            and (
                "Enable Dictation" in settings_before_text
                or "One-Handed Keyboard" in settings_before_text
            )
        )
        settings_after_expected_page = (
            "Add New Keyboard..." in settings_after_text
            or "Add New Keyboard…" in settings_after_text
            or "English (US)" in settings_after_text
            or "Emoji" in settings_after_text
        )
    elif settings_scenario == "keyboards_to_english":
        settings_expected_after_name = "english_keyboard_page"
        settings_before_expected = (
            "Keyboards" in settings_before_text
            and "English (US)" in settings_before_text
            and "Emoji" in settings_before_text
            and ("Add New Keyboard…" in settings_before_text or "Add New Keyboard..." in settings_before_text)
        )
        settings_after_expected_page = (
            "English (US)" in settings_after_text
            and (
                "QWERTY" in settings_after_text
                or "AZERTY" in settings_after_text
                or "QWERTZ" in settings_after_text
                or "Software Keyboard Layout" in settings_after_text
                or "Hardware Keyboard Layout" in settings_after_text
            )
        )
    tap_provider = tap_settings.get("provider_result", {}) if isinstance(tap_settings, dict) else {}
    type_provider = type_safari.get("provider_result", {}) if isinstance(type_safari, dict) else {}
    type_verification = type_safari.get("verification", {}) if isinstance(type_safari, dict) else {}
    type_user_facing_status = type_safari.get("user_facing_status") if isinstance(type_safari, dict) else None
    provider_attempts = type_safari.get("provider_attempts") if isinstance(type_safari, dict) else []
    notes_provider = type_notes.get("provider_result", {}) if isinstance(type_notes, dict) else {}
    notes_verification = type_notes.get("verification", {}) if isinstance(type_notes, dict) else {}
    notes_user_facing_status = type_notes.get("user_facing_status") if isinstance(type_notes, dict) else None
    notes_provider_attempts = type_notes.get("provider_attempts") if isinstance(type_notes, dict) else []
    webcontent_verified = False
    if isinstance(provider_attempts, list):
        for attempt in provider_attempts:
            if not isinstance(attempt, dict):
                continue
            verification = attempt.get("verification", {})
            if (
                attempt.get("provider") == "OpenPhoneAppIntrospector.WebContentInput"
                and attempt.get("status") == "ok"
                and isinstance(verification, dict)
                and verification.get("status") == "verified"
                and verification.get("source") == "web_content_dom_state"
            ):
                webcontent_verified = True
                break
    notes_text_verified = False
    if isinstance(notes_provider_attempts, list):
        for attempt in notes_provider_attempts:
            if not isinstance(attempt, dict):
                continue
            verification = attempt.get("verification", {})
            if (
                attempt.get("provider") == "OpenPhoneAppIntrospector.AppInput"
                and attempt.get("status") == "ok"
                and attempt.get("activation_method") == "text_input_insert"
                and isinstance(verification, dict)
                and verification.get("status") == "verified"
                and verification.get("source") == "app_process_text_state"
            ):
                notes_text_verified = True
                break
    checks = {
        "ok": True,
        "blocked": False,
        "errors": [],
        "before_locked": before_fields["locked"],
        "settings_scenario": settings_scenario,
        "settings_target_label": settings_target_label,
        "settings_element": settings_element,
        "settings_back_element": settings_back_element,
        "settings_open_state": action_state(open_settings),
        "settings_precheck": app_ui_fields(settings_precheck),
        "settings_reset_state": action_state(settings_reset),
        "settings_before": settings_before_fields,
        "settings_tap_state": action_state(tap_settings),
        "settings_tap_provider": tap_provider.get("provider") if isinstance(tap_provider, dict) else None,
        "settings_activation_method": tap_provider.get("activation_method") if isinstance(tap_provider, dict) else None,
        "settings_after": settings_after_fields,
        "settings_before_has_general_page": settings_before_has_general_page,
        "settings_before_expected": settings_before_expected,
        "settings_expected_after_name": settings_expected_after_name,
        "settings_after_expected_page": settings_after_expected_page,
        "settings_after_has_general_page": "About" in settings_after_text and "Software Update" in settings_after_text and "General" in settings_after_text,
        "settings_screenshot_hash": settings_screenshot,
        "safari_field": safari_field,
        "safari_marker": marker,
        "safari_open_state": action_state(open_safari),
        "safari_before": safari_before_fields,
        "safari_type_state": action_state(type_safari),
        "safari_type_user_facing_status": type_user_facing_status,
        "safari_type_provider": type_provider.get("provider") if isinstance(type_provider, dict) else None,
        "safari_type_verification": type_verification,
        "safari_webcontent_verified": webcontent_verified,
        "safari_after": safari_after_fields,
        "safari_marker_visible_after": marker in safari_after_text or json_contains_string(safari_after, marker) or json_contains_string(safari_state, marker),
        "safari_screenshot_hash": safari_screenshot,
        "safari_state_status": safari_state.get("status") if isinstance(safari_state, dict) else None,
        "notes_field": notes_field,
        "notes_marker": notes_marker,
        "notes_open_state": action_state(open_notes),
        "notes_before": notes_before_fields,
        "notes_type_state": action_state(type_notes),
        "notes_type_user_facing_status": notes_user_facing_status,
        "notes_type_provider": notes_provider.get("provider") if isinstance(notes_provider, dict) else None,
        "notes_activation_method": notes_provider.get("activation_method") if isinstance(notes_provider, dict) else None,
        "notes_type_verification": notes_verification,
        "notes_text_verified": notes_text_verified,
        "notes_after": notes_after_fields,
        "notes_marker_visible_after": notes_marker in notes_after_text or json_contains_string(notes_after, notes_marker) or json_contains_string(notes_state, notes_marker),
        "notes_screenshot_hash": notes_screenshot,
        "notes_state_status": notes_state.get("status") if isinstance(notes_state, dict) else None,
    }
    if before_fields["locked"] is not False:
        checks["ok"] = False
        checks["blocked"] = True
        checks["errors"].append("device_locked_or_unknown")
        return checks
    if action_state(open_settings) != "action.executed":
        checks["ok"] = False
        checks["errors"].append(f"settings_open_state:{action_state(open_settings)}")
    if settings_back_element and action_state(settings_reset) != "action.executed":
        checks["ok"] = False
        checks["errors"].append(f"settings_reset_state:{action_state(settings_reset)}")
    if not settings_element:
        checks["ok"] = False
        checks["errors"].append(f"missing_settings_target_element:{settings_target_label}")
    if settings_before_fields["foreground_app"] != "com.apple.Preferences":
        checks["ok"] = False
        checks["errors"].append(f"settings_before_foreground:{settings_before_fields['foreground_app']}")
    if settings_before_fields["ui_tree_source"] != "app_process":
        checks["ok"] = False
        checks["errors"].append(f"settings_before_ui_tree_source:{settings_before_fields['ui_tree_source']}")
    if settings_scenario not in ("root_to_general", "general_to_keyboard", "keyboard_to_keyboards", "keyboards_to_english"):
        checks["ok"] = False
        checks["errors"].append(f"settings_unknown_scenario:{settings_scenario}")
    elif not settings_before_expected:
        checks["ok"] = False
        checks["errors"].append(f"settings_before_unexpected:{settings_scenario}")
    if action_state(tap_settings) != "action.executed":
        checks["ok"] = False
        checks["errors"].append(f"settings_tap_state:{action_state(tap_settings)}")
    if isinstance(tap_provider, dict) and tap_provider.get("provider") != "OpenPhoneAppIntrospector.AppInput":
        checks["ok"] = False
        checks["errors"].append(f"settings_tap_provider:{tap_provider.get('provider')}")
    if not settings_after_expected_page:
        checks["ok"] = False
        checks["errors"].append(f"settings_after_missing_expected_page:{settings_expected_after_name or settings_scenario}")
    if not settings_screenshot["changed"]:
        checks["ok"] = False
        checks["errors"].append(
            "settings_screenshot_hash_not_changed:"
            f"{settings_screenshot['before'].get('status')}:{settings_screenshot['after'].get('status')}"
        )
    if settings_after_fields["foreground_app"] != "com.apple.Preferences":
        checks["ok"] = False
        checks["errors"].append(f"settings_after_foreground:{settings_after_fields['foreground_app']}")
    if settings_after_fields["ui_tree_source"] != "app_process":
        checks["ok"] = False
        checks["errors"].append(f"settings_after_ui_tree_source:{settings_after_fields['ui_tree_source']}")

    if action_state(open_safari) != "action.executed":
        checks["ok"] = False
        checks["errors"].append(f"safari_open_state:{action_state(open_safari)}")
    if not safari_field:
        checks["ok"] = False
        checks["errors"].append("missing_safari_dom_field")
    if safari_before_fields["foreground_app"] != "com.apple.mobilesafari":
        checks["ok"] = False
        checks["errors"].append(f"safari_before_foreground:{safari_before_fields['foreground_app']}")
    if safari_before_fields["ui_tree_source"] != "app_process":
        checks["ok"] = False
        checks["errors"].append(f"safari_before_ui_tree_source:{safari_before_fields['ui_tree_source']}")
    if action_state(type_safari) != "action.executed":
        checks["ok"] = False
        checks["errors"].append(f"safari_type_state:{action_state(type_safari)}")
    if type_user_facing_status != "verified":
        checks["ok"] = False
        checks["errors"].append(f"safari_type_user_facing_status:{type_user_facing_status}")
    if not (
        isinstance(type_verification, dict)
        and type_verification.get("status") == "verified"
        and type_verification.get("source") == "web_content_dom_state"
    ):
        checks["ok"] = False
        checks["errors"].append(f"safari_type_verification:{type_verification.get('status') if isinstance(type_verification, dict) else None}:{type_verification.get('source') if isinstance(type_verification, dict) else None}")
    if not webcontent_verified:
        checks["ok"] = False
        checks["errors"].append("safari_webcontent_attempt_not_verified")
    if not checks["safari_marker_visible_after"]:
        checks["ok"] = False
        checks["errors"].append("safari_marker_not_visible_after")
    if not safari_screenshot["changed"]:
        checks["ok"] = False
        checks["errors"].append(
            "safari_screenshot_hash_not_changed:"
            f"{safari_screenshot['before'].get('status')}:{safari_screenshot['after'].get('status')}"
        )
    if safari_after_fields["foreground_app"] != "com.apple.mobilesafari":
        checks["ok"] = False
        checks["errors"].append(f"safari_after_foreground:{safari_after_fields['foreground_app']}")
    if safari_after_fields["ui_tree_source"] != "app_process":
        checks["ok"] = False
        checks["errors"].append(f"safari_after_ui_tree_source:{safari_after_fields['ui_tree_source']}")
    if isinstance(safari_state, dict) and safari_state.get("status") != "ok":
        checks["ok"] = False
        checks["errors"].append(f"safari_state_status:{safari_state.get('status')}")
    if action_state(open_notes) != "action.executed":
        checks["ok"] = False
        checks["errors"].append(f"notes_open_state:{action_state(open_notes)}")
    if not notes_field:
        checks["ok"] = False
        checks["errors"].append("missing_notes_text_field")
    if notes_before_fields["foreground_app"] != "com.apple.mobilenotes":
        checks["ok"] = False
        checks["errors"].append(f"notes_before_foreground:{notes_before_fields['foreground_app']}")
    if notes_before_fields["ui_tree_source"] != "app_process":
        checks["ok"] = False
        checks["errors"].append(f"notes_before_ui_tree_source:{notes_before_fields['ui_tree_source']}")
    if action_state(type_notes) != "action.executed":
        checks["ok"] = False
        checks["errors"].append(f"notes_type_state:{action_state(type_notes)}")
    if notes_user_facing_status != "verified":
        checks["ok"] = False
        checks["errors"].append(f"notes_type_user_facing_status:{notes_user_facing_status}")
    if not (
        isinstance(notes_verification, dict)
        and notes_verification.get("status") == "verified"
        and notes_verification.get("source") == "app_process_text_state"
    ):
        checks["ok"] = False
        checks["errors"].append(f"notes_type_verification:{notes_verification.get('status') if isinstance(notes_verification, dict) else None}:{notes_verification.get('source') if isinstance(notes_verification, dict) else None}")
    if not notes_text_verified:
        checks["ok"] = False
        checks["errors"].append("notes_app_input_attempt_not_verified")
    if not checks["notes_marker_visible_after"]:
        checks["ok"] = False
        checks["errors"].append("notes_marker_not_visible_after")
    if not notes_screenshot["changed"]:
        checks["ok"] = False
        checks["errors"].append(
            "notes_screenshot_hash_not_changed:"
            f"{notes_screenshot['before'].get('status')}:{notes_screenshot['after'].get('status')}"
        )
    if notes_after_fields["foreground_app"] != "com.apple.mobilenotes":
        checks["ok"] = False
        checks["errors"].append(f"notes_after_foreground:{notes_after_fields['foreground_app']}")
    if notes_after_fields["ui_tree_source"] != "app_process":
        checks["ok"] = False
        checks["errors"].append(f"notes_after_ui_tree_source:{notes_after_fields['ui_tree_source']}")
    if isinstance(notes_state, dict) and notes_state.get("status") != "ok":
        checks["ok"] = False
        checks["errors"].append(f"notes_state_status:{notes_state.get('status')}")
    return checks

health = read_json("health.json")
screen = read_json("get-screen.json")
springboard_state = read_json("springboard-state.json")
springboard_trigger_status = read_json("springboard-trigger-status.json")
markers = read_text("safe-mode-markers.txt").strip()
latest = latest_crash("springboard-crashes.txt")
previous = latest_crash("springboard-crashes.before.txt")
new_crash = bool(previous and latest and latest > previous)
process_lines = [line for line in read_text("processes.txt").splitlines() if "openphone-agentd" in line]

providers = health.get("providers", {}) if isinstance(health, dict) else {}
screen_provider = providers.get("screen", {}) if isinstance(providers, dict) else {}
input_provider = providers.get("input", {}) if isinstance(providers, dict) else {}
bridge = input_provider.get("springboard_bridge", {}) if isinstance(input_provider, dict) else {}
trigger_provider = providers.get("triggers", {}) if isinstance(providers, dict) else {}
volume_combo_provider = trigger_provider.get("volume_combo", {}) if isinstance(trigger_provider, dict) else {}
daemon_springboard_trigger = (
    volume_combo_provider.get("springboard_fallback", {})
    if isinstance(volume_combo_provider, dict)
    else {}
)
springboard_trigger_snapshot = trigger_snapshot(
    springboard_trigger_status if springboard_trigger_status else daemon_springboard_trigger
)
device = health.get("device", {}) if isinstance(health, dict) else {}

context = screen.get("context", {}) if isinstance(screen, dict) else {}
display = context.get("display", {}) if isinstance(context, dict) else {}
ui_tree = context.get("ui_tree", {}) if isinstance(context, dict) else {}
screen_springboard = context.get("springboard_state", {}) if isinstance(context, dict) else {}
lock = context.get("lock", {}) if isinstance(context, dict) else {}

health_ok = health.get("status") == "ok"
stability_ok = not markers and not new_crash
screen_ok = (
    bool(context)
    and display.get("status") in ("available", "ok")
    and screen_springboard.get("status") == "ok"
    and ui_tree.get("status") == "ok"
)

if os.environ.get("OPENPHONE_VALIDATE_INCLUDE_SCREENSHOT") == "1":
    screenshot = read_json("get-screen-screenshot.json")
    screenshot_sanity = read_json("screenshot-sanity.json")
    screenshot_ok = screenshot_sanity.get("status") == "ok"
else:
    screenshot = {}
    screenshot_sanity = {}
    screenshot_ok = None

unlocked_foreground_requested = (
    os.environ.get("OPENPHONE_VALIDATE_INCLUDE_UNLOCKED_FOREGROUND") == "1"
    or os.environ.get("OPENPHONE_VALIDATE_REQUIRE_UNLOCKED") == "1"
)
if unlocked_foreground_requested:
    unlocked_foreground_checks = check_unlocked_foreground_shape()
    if unlocked_foreground_checks.get("blocked"):
        unlocked_foreground = "blocked_locked"
    else:
        unlocked_foreground = "pass" if unlocked_foreground_checks["ok"] else "fail"
else:
    unlocked_foreground_checks = {}
    unlocked_foreground = "not_run"

app_ui_requested = os.environ.get("OPENPHONE_VALIDATE_INCLUDE_APP_UI") == "1"
if app_ui_requested:
    app_ui_checks = check_app_ui_shape()
    if app_ui_checks.get("blocked"):
        app_ui_gate = "blocked_locked"
    else:
        app_ui_gate = "pass" if app_ui_checks["ok"] else "fail"
else:
    app_ui_checks = {}
    app_ui_gate = "not_run"

lockscreen_requested = os.environ.get("OPENPHONE_VALIDATE_INCLUDE_LOCKSCREEN") == "1"
if lockscreen_requested:
    lockscreen_checks = check_lockscreen_shape()
    if lockscreen_checks.get("blocked"):
        blocker = lockscreen_checks.get("blocker") or "blocked"
        lockscreen_gate = "blocked_unlocked" if blocker == "device_unlocked_or_unknown" else "blocked"
    else:
        lockscreen_gate = "pass" if lockscreen_checks["ok"] else "fail"
else:
    lockscreen_checks = {}
    lockscreen_gate = "not_run"

prefs_ui_requested = os.environ.get("OPENPHONE_VALIDATE_INCLUDE_PREFS_UI") == "1"
if prefs_ui_requested:
    prefs_ui_checks = check_prefs_ui_shape()
    if prefs_ui_checks.get("blocked"):
        prefs_ui_gate = "blocked_locked"
    else:
        prefs_ui_gate = "pass" if prefs_ui_checks["ok"] else "fail"
else:
    prefs_ui_checks = {}
    prefs_ui_gate = "not_run"

prefs_backend_requested = os.environ.get("OPENPHONE_VALIDATE_INCLUDE_PREFS_BACKEND") == "1"
if prefs_backend_requested:
    prefs_backend_checks = check_prefs_backend_shape()
    prefs_backend_gate = "pass" if prefs_backend_checks["ok"] else "fail"
else:
    prefs_backend_checks = {}
    prefs_backend_gate = "not_run"

stores_requested = mode == "full" or os.environ.get("OPENPHONE_VALIDATE_INCLUDE_STORES") == "1"
if stores_requested:
    store_checks = {
        "tasks": check_response_shape(
            "list-tasks.json",
            "tasks",
            item_keys=("task_id", "state", "autonomy_mode"),
        ),
        "task_detail": check_task_detail_shape("get-task.json"),
        "trajectory": check_trajectory_shape("get-trajectory.json"),
        "audit": check_response_shape(
            "get-audit.json",
            "events",
            item_keys=("schema", "event_type", "decision", "capability", "event_hash"),
            required_keys=("audit_path",),
        ),
        "memory": check_response_shape(
            "memory-search.json",
            "memories",
            item_keys=("memory_id", "text", "type", "subject"),
            required_keys=("provider", "fts_available"),
        ),
        "context": check_response_shape(
            "context-search.json",
            "events",
            item_keys=("event_id", "type", "body"),
            required_keys=("provider", "fts_available"),
        ),
        "background_jobs": check_response_shape(
            "background-job-list.json",
            "jobs",
            item_keys=("job_id", "status", "title"),
            required_keys=("provider", "runner"),
        ),
        "commitments": check_response_shape(
            "commitment-search.json",
            "commitments",
            item_keys=("commitment_id", "status", "title"),
            required_keys=("provider", "fts_available"),
        ),
        "watchers": check_response_shape(
            "watcher-list.json",
            "watchers",
            item_keys=("watcher_id", "status", "title"),
            required_keys=("provider", "fts_available", "scheduler_status"),
        ),
    }
    stores_gate = "pass" if all(check["ok"] for check in store_checks.values()) else "fail"
else:
    store_checks = {}
    stores_gate = "not_run"

provider_attempts_requested = os.environ.get("OPENPHONE_VALIDATE_INCLUDE_PROVIDER_ATTEMPTS") == "1"
if provider_attempts_requested:
    provider_attempt_checks = {
        "action": check_provider_attempt_sample_shape("provider-attempt-action.json"),
        "trajectory": check_trajectory_shape("provider-attempt-trajectory.json"),
    }
    provider_attempts_gate = "pass" if all(check["ok"] for check in provider_attempt_checks.values()) else "fail"
else:
    provider_attempt_checks = {}
    provider_attempts_gate = "not_run"

visible_effects_requested = os.environ.get("OPENPHONE_VALIDATE_INCLUDE_VISIBLE_EFFECTS") == "1"
if visible_effects_requested:
    visible_effects_checks = check_visible_effects_shape()
    if visible_effects_checks.get("blocked"):
        visible_effects_gate = "blocked_locked"
    else:
        visible_effects_gate = "pass" if visible_effects_checks["ok"] else "fail"
else:
    visible_effects_checks = {}
    visible_effects_gate = "not_run"

memory_lifecycle_requested = os.environ.get("OPENPHONE_VALIDATE_INCLUDE_MEMORY_LIFECYCLE") == "1"
if memory_lifecycle_requested:
    memory_lifecycle_checks = check_memory_lifecycle_shape()
    memory_lifecycle_gate = "pass" if memory_lifecycle_checks["ok"] else "fail"
else:
    memory_lifecycle_checks = {}
    memory_lifecycle_gate = "not_run"

watcher_timer_requested = os.environ.get("OPENPHONE_VALIDATE_INCLUDE_WATCHER_TIMER") == "1"
if watcher_timer_requested:
    watcher_timer_checks = check_watcher_timer_shape()
    watcher_timer_gate = "pass" if watcher_timer_checks["ok"] else "fail"
else:
    watcher_timer_checks = {}
    watcher_timer_gate = "not_run"

watcher_repair_requested = os.environ.get("OPENPHONE_VALIDATE_INCLUDE_WATCHER_REPAIR") == "1"
if watcher_repair_requested:
    watcher_repair_checks = check_watcher_repair_shape()
    watcher_repair_gate = "pass" if watcher_repair_checks["ok"] else "fail"
else:
    watcher_repair_checks = {}
    watcher_repair_gate = "not_run"

job_repair_requested = os.environ.get("OPENPHONE_VALIDATE_INCLUDE_JOB_REPAIR") == "1"
if job_repair_requested:
    job_repair_checks = check_job_repair_shape()
    job_repair_gate = "pass" if job_repair_checks["ok"] else "fail"
else:
    job_repair_checks = {}
    job_repair_gate = "not_run"

restart_recovery_requested = os.environ.get("OPENPHONE_VALIDATE_INCLUDE_RESTART_RECOVERY") == "1"
if restart_recovery_requested:
    restart_recovery_checks = check_restart_recovery_shape()
    restart_recovery_gate = "pass" if restart_recovery_checks["ok"] else "fail"
else:
    restart_recovery_checks = {}
    restart_recovery_gate = "not_run"

model_loop_requested = os.environ.get("OPENPHONE_VALIDATE_INCLUDE_MODEL_LOOP") == "1"
if model_loop_requested:
    model_loop_checks = check_model_loop_shape()
    model_loop_gate = "pass" if model_loop_checks["ok"] else "fail"
else:
    model_loop_checks = {}
    model_loop_gate = "not_run"

provider_model_requested = os.environ.get("OPENPHONE_VALIDATE_INCLUDE_PROVIDER_MODEL") == "1"
if provider_model_requested:
    provider_model_checks = check_provider_model_shape()
    provider_model_gate = "pass" if provider_model_checks["ok"] else "fail"
else:
    provider_model_checks = {}
    provider_model_gate = "not_run"

safari_dom_model_requested = os.environ.get("OPENPHONE_VALIDATE_INCLUDE_SAFARI_DOM_MODEL") == "1"
if safari_dom_model_requested:
    safari_dom_model_checks = check_safari_dom_model_shape()
    if safari_dom_model_checks.get("blocked"):
        safari_dom_model_gate = "blocked_locked"
    else:
        safari_dom_model_gate = "pass" if safari_dom_model_checks["ok"] else "fail"
else:
    safari_dom_model_checks = {}
    safari_dom_model_gate = "not_run"

prompt_bridge_model_requested = os.environ.get("OPENPHONE_VALIDATE_INCLUDE_PROMPT_BRIDGE_MODEL") == "1"
if prompt_bridge_model_requested:
    prompt_bridge_model_checks = check_prompt_bridge_model_shape()
    if prompt_bridge_model_checks.get("blocked"):
        prompt_bridge_model_gate = "blocked_locked"
    else:
        prompt_bridge_model_gate = "pass" if prompt_bridge_model_checks["ok"] else "fail"
else:
    prompt_bridge_model_checks = {}
    prompt_bridge_model_gate = "not_run"

trigger_diagnostics_requested = os.environ.get("OPENPHONE_VALIDATE_INCLUDE_TRIGGER_DIAGNOSTICS") == "1"
if trigger_diagnostics_requested:
    trigger_diagnostics_checks = check_trigger_diagnostics_shape()
    trigger_diagnostics_gate = "pass" if trigger_diagnostics_checks["ok"] else "fail"
else:
    trigger_diagnostics_checks = {}
    trigger_diagnostics_gate = "not_run"

artifact_hygiene = check_artifact_hygiene()
artifact_hygiene_ok = artifact_hygiene.get("status") == "pass"

package_version = ""
if package_path:
    match = re.search(r"com\.openphone\.agentd_(.+?)_iphoneos-arm64\.deb$", pathlib.Path(package_path).name)
    if match:
        package_version = match.group(1)

exit_code = 0
if not health_ok:
    exit_code = 30
elif not stability_ok:
    exit_code = 40
elif not screen_ok:
    exit_code = 50
elif screenshot_ok is False:
    exit_code = 50
elif unlocked_foreground == "fail":
    exit_code = 50
elif app_ui_gate == "fail":
    exit_code = 50
elif lockscreen_gate == "fail":
    exit_code = 60
elif prefs_ui_gate == "fail":
    exit_code = 50
elif provider_attempts_gate == "fail":
    exit_code = 60
elif visible_effects_gate == "fail":
    exit_code = 60
elif prefs_backend_gate == "fail":
    exit_code = 70
elif stores_gate == "fail":
    exit_code = 70
elif memory_lifecycle_gate == "fail":
    exit_code = 70
elif watcher_timer_gate == "fail":
    exit_code = 70
elif watcher_repair_gate == "fail":
    exit_code = 70
elif job_repair_gate == "fail":
    exit_code = 70
elif restart_recovery_gate == "fail":
    exit_code = 70
elif model_loop_gate == "fail":
    exit_code = 70
elif provider_model_gate == "fail":
    exit_code = 100
elif safari_dom_model_gate == "fail":
    exit_code = 100
elif prompt_bridge_model_gate == "fail":
    exit_code = 100
elif trigger_diagnostics_gate == "fail":
    exit_code = 60
elif unlocked_foreground == "blocked_locked":
    exit_code = 80
elif app_ui_gate == "blocked_locked":
    exit_code = 80
elif lockscreen_gate in ("blocked_unlocked", "blocked"):
    exit_code = 80
elif prefs_ui_gate == "blocked_locked":
    exit_code = 80
elif visible_effects_gate == "blocked_locked":
    exit_code = 80
elif safari_dom_model_gate == "blocked_locked":
    exit_code = 80
elif prompt_bridge_model_gate == "blocked_locked":
    exit_code = 80
elif not artifact_hygiene_ok:
    exit_code = 90

report = {
    "schema": "openphone.ios_validation_report.v1",
    "timestamp": datetime.datetime.now(datetime.timezone.utc).astimezone().isoformat(),
    "mode": mode,
    "run_id": os.environ["OPENPHONE_VALIDATE_RUN_ID"],
    "package": {
        "path": package_path,
        "version": package_version,
        "installed": os.environ.get("OPENPHONE_VALIDATE_INSTALLED") == "true",
    },
    "device": {
        "product_type": "iPhone15,3" if "iPhone15,3" in device.get("uname", "") else "",
        "marketing_model": "iPhone 14 Pro Max",
        "ios_darwin": device.get("uname", ""),
    },
    "stability": {
        "safe_mode_marker_present": bool(markers),
        "safe_mode_markers": markers.splitlines(),
        "latest_springboard_crash": latest,
        "previous_springboard_crash": previous,
        "new_crash_during_run": new_crash,
    },
    "daemon": {
        "health_status": health.get("status"),
        "autonomy_mode": health.get("autonomy_mode"),
        "pid_count": len(process_lines),
        "springboard_bridge": bridge.get("status"),
        "springboard_state": screen_springboard.get("status") or screen_provider.get("springboard_state", {}).get("status"),
        "springboard_trigger_status": springboard_trigger_snapshot["status"],
        "springboard_trigger_event": springboard_trigger_snapshot["event"],
        "springboard_trigger_volume_hooked": springboard_trigger_snapshot["volume_hooked"],
        "springboard_trigger_volume_total": springboard_trigger_snapshot["volume_total"],
        "springboard_trigger_button_events_seen": springboard_trigger_snapshot["button_events_seen"],
        "springboard_trigger_combo_events_seen": springboard_trigger_snapshot["combo_events_seen"],
        "springboard_trigger_last_button_event_source": springboard_trigger_snapshot["last_button_event_source"],
        "springboard_trigger_last_trigger_route": springboard_trigger_snapshot["last_trigger_route"],
        "springboard_trigger_volume_notification_installed": springboard_trigger_snapshot["volume_notification"]["installed"],
        "springboard_trigger_volume_notification_seeded": springboard_trigger_snapshot["volume_notification"]["seeded"],
        "springboard_trigger_volume_notification_events_seen": springboard_trigger_snapshot["volume_notification"]["events_seen"],
        "springboard_trigger_volume_notification_last_direction": springboard_trigger_snapshot["volume_notification"]["last_direction"],
    },
    "gates": {
        "screen": "pass" if screen_ok else "fail",
        "screenshot": "pass" if screenshot_ok is True else ("fail" if screenshot_ok is False else "not_run"),
        "trigger": "not_run",
        "input": "not_run",
        "unlocked_foreground": unlocked_foreground,
        "app_ui": app_ui_gate,
        "lockscreen": lockscreen_gate,
        "prefs_ui": prefs_ui_gate,
        "prefs_backend": prefs_backend_gate,
        "stores": stores_gate,
        "provider_attempts": provider_attempts_gate,
        "visible_effects": visible_effects_gate,
        "memory_lifecycle": memory_lifecycle_gate,
        "watcher_timer": watcher_timer_gate,
        "watcher_repair": watcher_repair_gate,
        "job_repair": job_repair_gate,
        "restart_recovery": restart_recovery_gate,
        "model_loop": model_loop_gate,
        "provider_model": provider_model_gate,
        "safari_dom_model": safari_dom_model_gate,
        "prompt_bridge_model": prompt_bridge_model_gate,
        "trigger_diagnostics": trigger_diagnostics_gate,
        "artifact_hygiene": "pass" if artifact_hygiene_ok else "fail",
    },
    "store_checks": store_checks,
    "unlocked_foreground_checks": unlocked_foreground_checks,
    "app_ui_checks": app_ui_checks,
    "lockscreen_checks": lockscreen_checks,
    "prefs_ui_checks": prefs_ui_checks,
    "prefs_backend_checks": prefs_backend_checks,
    "provider_attempt_checks": provider_attempt_checks,
    "visible_effects_checks": visible_effects_checks,
    "memory_lifecycle_checks": memory_lifecycle_checks,
    "watcher_timer_checks": watcher_timer_checks,
    "watcher_repair_checks": watcher_repair_checks,
    "job_repair_checks": job_repair_checks,
    "restart_recovery_checks": restart_recovery_checks,
    "model_loop_checks": model_loop_checks,
    "provider_model_checks": provider_model_checks,
    "safari_dom_model_checks": safari_dom_model_checks,
    "prompt_bridge_model_checks": prompt_bridge_model_checks,
    "trigger_diagnostics_checks": trigger_diagnostics_checks,
    "artifact_hygiene": artifact_hygiene,
    "artifacts": {
        "health_json": str(run_dir / "health.json"),
        "get_screen_json": str(run_dir / "get-screen.json"),
        "screenshot_json": str(run_dir / "get-screen-screenshot.json") if screenshot else "",
        "screenshot_png": str(run_dir / "screenshot.png") if (run_dir / "screenshot.png").exists() else "",
        "screenshot_sanity": screenshot_sanity,
        "unlocked_foreground_before_screen_json": str(run_dir / "unlocked-foreground-before-screen.json") if (run_dir / "unlocked-foreground-before-screen.json").exists() else "",
        "unlocked_foreground_open_safari_json": str(run_dir / "unlocked-foreground-open-safari.json") if (run_dir / "unlocked-foreground-open-safari.json").exists() else "",
        "unlocked_foreground_safari_screen_json": str(run_dir / "unlocked-foreground-safari-screen.json") if (run_dir / "unlocked-foreground-safari-screen.json").exists() else "",
        "unlocked_foreground_home_json": str(run_dir / "unlocked-foreground-home.json") if (run_dir / "unlocked-foreground-home.json").exists() else "",
        "unlocked_foreground_home_screen_json": str(run_dir / "unlocked-foreground-home-screen.json") if (run_dir / "unlocked-foreground-home-screen.json").exists() else "",
        "app_ui_before_screen_json": str(run_dir / "app-ui-before-screen.json") if (run_dir / "app-ui-before-screen.json").exists() else "",
        "app_ui_relaunch_json": str(run_dir / "app-ui-relaunch.json") if (run_dir / "app-ui-relaunch.json").exists() else "",
        "app_ui_open_safari_json": str(run_dir / "app-ui-open-safari.json") if (run_dir / "app-ui-open-safari.json").exists() else "",
        "app_ui_safari_screen_json": str(run_dir / "app-ui-safari-screen.json") if (run_dir / "app-ui-safari-screen.json").exists() else "",
        "app_ui_open_settings_json": str(run_dir / "app-ui-open-settings.json") if (run_dir / "app-ui-open-settings.json").exists() else "",
        "app_ui_settings_screen_json": str(run_dir / "app-ui-settings-screen.json") if (run_dir / "app-ui-settings-screen.json").exists() else "",
        "app_ui_health_json": str(run_dir / "app-ui-health.json") if (run_dir / "app-ui-health.json").exists() else "",
        "app_ui_ls": str(run_dir / "app-ui-ls.txt") if (run_dir / "app-ui-ls.txt").exists() else "",
        "app_ui_safari_state_json": str(run_dir / "app-ui-safari-state.json") if (run_dir / "app-ui-safari-state.json").exists() else "",
        "app_ui_settings_state_json": str(run_dir / "app-ui-settings-state.json") if (run_dir / "app-ui-settings-state.json").exists() else "",
        "app_introspector_log_tail": str(run_dir / "openphone-app-introspector.log.tail") if (run_dir / "openphone-app-introspector.log.tail").exists() else "",
        "lockscreen_before_screen_json": str(run_dir / "lockscreen-before-screen.json") if (run_dir / "lockscreen-before-screen.json").exists() else "",
        "lockscreen_show_passcode_json": str(run_dir / "lockscreen-show-passcode.json") if (run_dir / "lockscreen-show-passcode.json").exists() else "",
        "lockscreen_after_screen_json": str(run_dir / "lockscreen-after-screen.json") if (run_dir / "lockscreen-after-screen.json").exists() else "",
        "lockscreen_status_after_json": str(run_dir / "lockscreen-status-after.json") if (run_dir / "lockscreen-status-after.json").exists() else "",
        "prefs_ui_before_screen_json": str(run_dir / "prefs-ui-before-screen.json") if (run_dir / "prefs-ui-before-screen.json").exists() else "",
        "prefs_ui_prepare_json": str(run_dir / "prefs-ui-prepare.json") if (run_dir / "prefs-ui-prepare.json").exists() else "",
        "prefs_ui_open_url_json": str(run_dir / "prefs-ui-open-url.json") if (run_dir / "prefs-ui-open-url.json").exists() else "",
        "prefs_ui_url_screen_json": str(run_dir / "prefs-ui-url-screen.json") if (run_dir / "prefs-ui-url-screen.json").exists() else "",
        "prefs_ui_open_settings_json": str(run_dir / "prefs-ui-open-settings.json") if (run_dir / "prefs-ui-open-settings.json").exists() else "",
        "prefs_ui_settings_screen_json": str(run_dir / "prefs-ui-settings-screen.json") if (run_dir / "prefs-ui-settings-screen.json").exists() else "",
        "prefs_ui_row_element": str(run_dir / "prefs-ui-row-element.txt") if (run_dir / "prefs-ui-row-element.txt").exists() else "",
        "prefs_ui_tap_row_json": str(run_dir / "prefs-ui-tap-row.json") if (run_dir / "prefs-ui-tap-row.json").exists() else "",
        "prefs_ui_pane_screen_json": str(run_dir / "prefs-ui-pane-screen.json") if (run_dir / "prefs-ui-pane-screen.json").exists() else "",
        "prefs_ui_hardware_element": str(run_dir / "prefs-ui-hardware-element.txt") if (run_dir / "prefs-ui-hardware-element.txt").exists() else "",
        "prefs_ui_disable_hardware_json": str(run_dir / "prefs-ui-disable-hardware.json") if (run_dir / "prefs-ui-disable-hardware.json").exists() else "",
        "prefs_ui_after_disable_screen_json": str(run_dir / "prefs-ui-after-disable-screen.json") if (run_dir / "prefs-ui-after-disable-screen.json").exists() else "",
        "prefs_ui_status_disabled_json": str(run_dir / "prefs-ui-status-disabled.json") if (run_dir / "prefs-ui-status-disabled.json").exists() else "",
        "prefs_ui_enable_hardware_json": str(run_dir / "prefs-ui-enable-hardware.json") if (run_dir / "prefs-ui-enable-hardware.json").exists() else "",
        "prefs_ui_after_enable_screen_json": str(run_dir / "prefs-ui-after-enable-screen.json") if (run_dir / "prefs-ui-after-enable-screen.json").exists() else "",
        "prefs_ui_status_enabled_json": str(run_dir / "prefs-ui-status-enabled.json") if (run_dir / "prefs-ui-status-enabled.json").exists() else "",
        "prefs_ui_final_restore_json": str(run_dir / "prefs-ui-final-restore.json") if (run_dir / "prefs-ui-final-restore.json").exists() else "",
        "prefs_ui_status_after_json": str(run_dir / "prefs-ui-status-after.json") if (run_dir / "prefs-ui-status-after.json").exists() else "",
        "prefs_backend_files_json": str(run_dir / "prefs-backend-files.json") if (run_dir / "prefs-backend-files.json").exists() else "",
        "prefs_backend_status_before_json": str(run_dir / "prefs-backend-status-before.json") if (run_dir / "prefs-backend-status-before.json").exists() else "",
        "prefs_backend_disable_hardware_json": str(run_dir / "prefs-backend-disable-hardware.json") if (run_dir / "prefs-backend-disable-hardware.json").exists() else "",
        "prefs_backend_trigger_disabled_json": str(run_dir / "prefs-backend-trigger-disabled.json") if (run_dir / "prefs-backend-trigger-disabled.json").exists() else "",
        "prefs_backend_enable_hardware_json": str(run_dir / "prefs-backend-enable-hardware.json") if (run_dir / "prefs-backend-enable-hardware.json").exists() else "",
        "prefs_backend_disable_yolo_json": str(run_dir / "prefs-backend-disable-yolo.json") if (run_dir / "prefs-backend-disable-yolo.json").exists() else "",
        "prefs_backend_trigger_yolo_disabled_json": str(run_dir / "prefs-backend-trigger-yolo-disabled.json") if (run_dir / "prefs-backend-trigger-yolo-disabled.json").exists() else "",
        "prefs_backend_enable_yolo_json": str(run_dir / "prefs-backend-enable-yolo.json") if (run_dir / "prefs-backend-enable-yolo.json").exists() else "",
        "prefs_backend_status_after_json": str(run_dir / "prefs-backend-status-after.json") if (run_dir / "prefs-backend-status-after.json").exists() else "",
        "visible_effects_before_screen_json": str(run_dir / "visible-effects-before-screen.json") if (run_dir / "visible-effects-before-screen.json").exists() else "",
        "visible_effects_open_settings_json": str(run_dir / "visible-effects-open-settings.json") if (run_dir / "visible-effects-open-settings.json").exists() else "",
        "visible_effects_settings_precheck_json": str(run_dir / "visible-effects-settings-precheck.json") if (run_dir / "visible-effects-settings-precheck.json").exists() else "",
        "visible_effects_settings_scenario": str(run_dir / "visible-effects-settings-scenario.txt") if (run_dir / "visible-effects-settings-scenario.txt").exists() else "",
        "visible_effects_settings_target_label": str(run_dir / "visible-effects-settings-target-label.txt") if (run_dir / "visible-effects-settings-target-label.txt").exists() else "",
        "visible_effects_settings_back_element": str(run_dir / "visible-effects-settings-back-element.txt") if (run_dir / "visible-effects-settings-back-element.txt").exists() else "",
        "visible_effects_settings_reset_json": str(run_dir / "visible-effects-settings-reset.json") if (run_dir / "visible-effects-settings-reset.json").exists() else "",
        "visible_effects_settings_before_json": str(run_dir / "visible-effects-settings-before.json") if (run_dir / "visible-effects-settings-before.json").exists() else "",
        "visible_effects_settings_element": str(run_dir / "visible-effects-settings-element.txt") if (run_dir / "visible-effects-settings-element.txt").exists() else "",
        "visible_effects_tap_settings_json": str(run_dir / "visible-effects-tap-settings.json") if (run_dir / "visible-effects-tap-settings.json").exists() else "",
        "visible_effects_settings_after_json": str(run_dir / "visible-effects-settings-after.json") if (run_dir / "visible-effects-settings-after.json").exists() else "",
        "visible_effects_open_safari_json": str(run_dir / "visible-effects-open-safari.json") if (run_dir / "visible-effects-open-safari.json").exists() else "",
        "visible_effects_safari_before_json": str(run_dir / "visible-effects-safari-before.json") if (run_dir / "visible-effects-safari-before.json").exists() else "",
        "visible_effects_safari_field": str(run_dir / "visible-effects-safari-field.txt") if (run_dir / "visible-effects-safari-field.txt").exists() else "",
        "visible_effects_safari_marker": str(run_dir / "visible-effects-safari-marker.txt") if (run_dir / "visible-effects-safari-marker.txt").exists() else "",
        "visible_effects_type_safari_json": str(run_dir / "visible-effects-type-safari.json") if (run_dir / "visible-effects-type-safari.json").exists() else "",
        "visible_effects_safari_after_json": str(run_dir / "visible-effects-safari-after.json") if (run_dir / "visible-effects-safari-after.json").exists() else "",
        "visible_effects_safari_state_json": str(run_dir / "visible-effects-safari-state.json") if (run_dir / "visible-effects-safari-state.json").exists() else "",
        "visible_effects_open_notes_json": str(run_dir / "visible-effects-open-notes.json") if (run_dir / "visible-effects-open-notes.json").exists() else "",
        "visible_effects_notes_before_json": str(run_dir / "visible-effects-notes-before.json") if (run_dir / "visible-effects-notes-before.json").exists() else "",
        "visible_effects_notes_field": str(run_dir / "visible-effects-notes-field.txt") if (run_dir / "visible-effects-notes-field.txt").exists() else "",
        "visible_effects_notes_marker": str(run_dir / "visible-effects-notes-marker.txt") if (run_dir / "visible-effects-notes-marker.txt").exists() else "",
        "visible_effects_type_notes_json": str(run_dir / "visible-effects-type-notes.json") if (run_dir / "visible-effects-type-notes.json").exists() else "",
        "visible_effects_notes_after_json": str(run_dir / "visible-effects-notes-after.json") if (run_dir / "visible-effects-notes-after.json").exists() else "",
        "visible_effects_notes_state_json": str(run_dir / "visible-effects-notes-state.json") if (run_dir / "visible-effects-notes-state.json").exists() else "",
        "springboard_crashes": str(run_dir / "springboard-crashes.txt"),
        "safe_mode_markers": str(run_dir / "safe-mode-markers.txt"),
        "agentd_log_tail": str(run_dir / "openphone-agentd.log.tail"),
        "tweak_log_tail": str(run_dir / "openphone-volume-trigger.log.tail"),
        "springboard_trigger_status_json": str(run_dir / "springboard-trigger-status.json") if (run_dir / "springboard-trigger-status.json").exists() else "",
        "trigger_diagnostics_before_status_json": str(run_dir / "trigger-diagnostics-before-status.json") if (run_dir / "trigger-diagnostics-before-status.json").exists() else "",
        "trigger_diagnostics_before_trigger_json": str(run_dir / "trigger-diagnostics-before-trigger.json") if (run_dir / "trigger-diagnostics-before-trigger.json").exists() else "",
        "trigger_diagnostics_after_status_json": str(run_dir / "trigger-diagnostics-after-status.json") if (run_dir / "trigger-diagnostics-after-status.json").exists() else "",
        "trigger_diagnostics_after_trigger_json": str(run_dir / "trigger-diagnostics-after-trigger.json") if (run_dir / "trigger-diagnostics-after-trigger.json").exists() else "",
        "trigger_diagnostics_list_tasks_json": str(run_dir / "trigger-diagnostics-list-tasks.json") if (run_dir / "trigger-diagnostics-list-tasks.json").exists() else "",
        "trigger_diagnostics_latest_trajectory_json": str(run_dir / "trigger-diagnostics-latest-trajectory.json") if (run_dir / "trigger-diagnostics-latest-trajectory.json").exists() else "",
        "trigger_diagnostics_tweak_log_tail": str(run_dir / "trigger-diagnostics-tweak-log-tail.txt") if (run_dir / "trigger-diagnostics-tweak-log-tail.txt").exists() else "",
        "list_tasks_json": str(run_dir / "list-tasks.json") if (run_dir / "list-tasks.json").exists() else "",
        "get_task_json": str(run_dir / "get-task.json") if (run_dir / "get-task.json").exists() else "",
        "get_trajectory_json": str(run_dir / "get-trajectory.json") if (run_dir / "get-trajectory.json").exists() else "",
        "get_audit_json": str(run_dir / "get-audit.json") if (run_dir / "get-audit.json").exists() else "",
        "memory_search_json": str(run_dir / "memory-search.json") if (run_dir / "memory-search.json").exists() else "",
        "context_search_json": str(run_dir / "context-search.json") if (run_dir / "context-search.json").exists() else "",
        "background_job_list_json": str(run_dir / "background-job-list.json") if (run_dir / "background-job-list.json").exists() else "",
        "commitment_search_json": str(run_dir / "commitment-search.json") if (run_dir / "commitment-search.json").exists() else "",
        "watcher_list_json": str(run_dir / "watcher-list.json") if (run_dir / "watcher-list.json").exists() else "",
        "provider_attempt_start_task_json": str(run_dir / "provider-attempt-start-task.json") if (run_dir / "provider-attempt-start-task.json").exists() else "",
        "provider_attempt_action_json": str(run_dir / "provider-attempt-action.json") if (run_dir / "provider-attempt-action.json").exists() else "",
        "provider_attempt_trajectory_json": str(run_dir / "provider-attempt-trajectory.json") if (run_dir / "provider-attempt-trajectory.json").exists() else "",
        "memory_lifecycle_save_primary_json": str(run_dir / "memory-lifecycle-save-primary.json") if (run_dir / "memory-lifecycle-save-primary.json").exists() else "",
        "memory_lifecycle_update_json": str(run_dir / "memory-lifecycle-update.json") if (run_dir / "memory-lifecycle-update.json").exists() else "",
        "memory_lifecycle_save_source_json": str(run_dir / "memory-lifecycle-save-source.json") if (run_dir / "memory-lifecycle-save-source.json").exists() else "",
        "memory_lifecycle_merge_json": str(run_dir / "memory-lifecycle-merge.json") if (run_dir / "memory-lifecycle-merge.json").exists() else "",
        "memory_lifecycle_save_delete_json": str(run_dir / "memory-lifecycle-save-delete.json") if (run_dir / "memory-lifecycle-save-delete.json").exists() else "",
        "memory_lifecycle_delete_json": str(run_dir / "memory-lifecycle-delete.json") if (run_dir / "memory-lifecycle-delete.json").exists() else "",
        "memory_lifecycle_search_json": str(run_dir / "memory-lifecycle-search.json") if (run_dir / "memory-lifecycle-search.json").exists() else "",
        "watcher_timer_create_json": str(run_dir / "watcher-timer-create.json") if (run_dir / "watcher-timer-create.json").exists() else "",
        "watcher_timer_run_due_json": str(run_dir / "watcher-timer-run-due.json") if (run_dir / "watcher-timer-run-due.json").exists() else "",
        "watcher_timer_job_run_due_json": str(run_dir / "watcher-timer-job-run-due.json") if (run_dir / "watcher-timer-job-run-due.json").exists() else "",
        "watcher_timer_job_list_json": str(run_dir / "watcher-timer-job-list.json") if (run_dir / "watcher-timer-job-list.json").exists() else "",
        "watcher_timer_after_list_json": str(run_dir / "watcher-timer-after-list.json") if (run_dir / "watcher-timer-after-list.json").exists() else "",
        "watcher_timer_stop_json": str(run_dir / "watcher-timer-stop.json") if (run_dir / "watcher-timer-stop.json").exists() else "",
        "watcher_repair_create_json": str(run_dir / "watcher-repair-create.json") if (run_dir / "watcher-repair-create.json").exists() else "",
        "watcher_repair_mark_running_json": str(run_dir / "watcher-repair-mark-running.json") if (run_dir / "watcher-repair-mark-running.json").exists() else "",
        "watcher_repair_run_json": str(run_dir / "watcher-repair-run.json") if (run_dir / "watcher-repair-run.json").exists() else "",
        "watcher_repair_run_due_json": str(run_dir / "watcher-repair-run-due.json") if (run_dir / "watcher-repair-run-due.json").exists() else "",
        "watcher_repair_job_run_due_json": str(run_dir / "watcher-repair-job-run-due.json") if (run_dir / "watcher-repair-job-run-due.json").exists() else "",
        "watcher_repair_after_list_json": str(run_dir / "watcher-repair-after-list.json") if (run_dir / "watcher-repair-after-list.json").exists() else "",
        "watcher_repair_stop_json": str(run_dir / "watcher-repair-stop.json") if (run_dir / "watcher-repair-stop.json").exists() else "",
        "job_repair_create_json": str(run_dir / "job-repair-create.json") if (run_dir / "job-repair-create.json").exists() else "",
        "job_repair_mark_running_json": str(run_dir / "job-repair-mark-running.json") if (run_dir / "job-repair-mark-running.json").exists() else "",
        "job_repair_run_json": str(run_dir / "job-repair-run.json") if (run_dir / "job-repair-run.json").exists() else "",
        "job_repair_run_due_json": str(run_dir / "job-repair-run-due.json") if (run_dir / "job-repair-run-due.json").exists() else "",
        "job_repair_list_json": str(run_dir / "job-repair-list.json") if (run_dir / "job-repair-list.json").exists() else "",
        "job_repair_stop_json": str(run_dir / "job-repair-stop.json") if (run_dir / "job-repair-stop.json").exists() else "",
        "restart_recovery_watcher_create_json": str(run_dir / "restart-recovery-watcher-create.json") if (run_dir / "restart-recovery-watcher-create.json").exists() else "",
        "restart_recovery_job_create_json": str(run_dir / "restart-recovery-job-create.json") if (run_dir / "restart-recovery-job-create.json").exists() else "",
        "restart_recovery_watcher_mark_running_json": str(run_dir / "restart-recovery-watcher-mark-running.json") if (run_dir / "restart-recovery-watcher-mark-running.json").exists() else "",
        "restart_recovery_job_mark_running_json": str(run_dir / "restart-recovery-job-mark-running.json") if (run_dir / "restart-recovery-job-mark-running.json").exists() else "",
        "restart_recovery_restart_json": str(run_dir / "restart-recovery-restart.json") if (run_dir / "restart-recovery-restart.json").exists() else "",
        "restart_recovery_after_health_json": str(run_dir / "restart-recovery-after-health.json") if (run_dir / "restart-recovery-after-health.json").exists() else "",
        "restart_recovery_watcher_list_json": str(run_dir / "restart-recovery-watcher-list.json") if (run_dir / "restart-recovery-watcher-list.json").exists() else "",
        "restart_recovery_job_list_json": str(run_dir / "restart-recovery-job-list.json") if (run_dir / "restart-recovery-job-list.json").exists() else "",
        "restart_recovery_watcher_stop_json": str(run_dir / "restart-recovery-watcher-stop.json") if (run_dir / "restart-recovery-watcher-stop.json").exists() else "",
        "restart_recovery_job_stop_json": str(run_dir / "restart-recovery-job-stop.json") if (run_dir / "restart-recovery-job-stop.json").exists() else "",
        "restart_recovery_generated_job_stop_json": str(run_dir / "restart-recovery-generated-job-stop.json") if (run_dir / "restart-recovery-generated-job-stop.json").exists() else "",
        "model_status_json": str(run_dir / "model-status.json") if (run_dir / "model-status.json").exists() else "",
        "model_loop_run_json": str(run_dir / "model-loop-run.json") if (run_dir / "model-loop-run.json").exists() else "",
        "model_loop_trajectory_json": str(run_dir / "model-loop-trajectory.json") if (run_dir / "model-loop-trajectory.json").exists() else "",
        "model_loop_repair_run_json": str(run_dir / "model-loop-repair-run.json") if (run_dir / "model-loop-repair-run.json").exists() else "",
        "model_loop_repair_trajectory_json": str(run_dir / "model-loop-repair-trajectory.json") if (run_dir / "model-loop-repair-trajectory.json").exists() else "",
        "model_loop_cancel_start_json": str(run_dir / "model-loop-cancel-start.json") if (run_dir / "model-loop-cancel-start.json").exists() else "",
        "model_loop_cancel_stop_json": str(run_dir / "model-loop-cancel-stop.json") if (run_dir / "model-loop-cancel-stop.json").exists() else "",
        "model_loop_cancel_run_json": str(run_dir / "model-loop-cancel-run.json") if (run_dir / "model-loop-cancel-run.json").exists() else "",
        "model_loop_cancel_trajectory_json": str(run_dir / "model-loop-cancel-trajectory.json") if (run_dir / "model-loop-cancel-trajectory.json").exists() else "",
        "provider_model_configure_json": str(run_dir / "provider-model-configure.json") if (run_dir / "provider-model-configure.json").exists() else "",
        "provider_model_status_json": str(run_dir / "provider-model-status.json") if (run_dir / "provider-model-status.json").exists() else "",
        "provider_model_run_json": str(run_dir / "provider-model-run.json") if (run_dir / "provider-model-run.json").exists() else "",
        "provider_model_trajectory_json": str(run_dir / "provider-model-trajectory.json") if (run_dir / "provider-model-trajectory.json").exists() else "",
        "provider_model_reset_json": str(run_dir / "provider-model-reset.json") if (run_dir / "provider-model-reset.json").exists() else "",
        "provider_model_broker_log": str(run_dir / "provider-model-broker.log") if (run_dir / "provider-model-broker.log").exists() else "",
        "provider_model_ssh_reverse_log": str(run_dir / "provider-model-ssh-reverse.log") if (run_dir / "provider-model-ssh-reverse.log").exists() else "",
        "safari_dom_model_marker": str(run_dir / "safari-dom-model-marker.txt") if (run_dir / "safari-dom-model-marker.txt").exists() else "",
        "safari_dom_model_backup_json": str(run_dir / "safari-dom-model-backup.json") if (run_dir / "safari-dom-model-backup.json").exists() else "",
        "safari_dom_model_before_screen_json": str(run_dir / "safari-dom-model-before-screen.json") if (run_dir / "safari-dom-model-before-screen.json").exists() else "",
        "safari_dom_model_open_url_json": str(run_dir / "safari-dom-model-open-url.json") if (run_dir / "safari-dom-model-open-url.json").exists() else "",
        "safari_dom_model_pre_screen_json": str(run_dir / "safari-dom-model-pre-screen.json") if (run_dir / "safari-dom-model-pre-screen.json").exists() else "",
        "safari_dom_model_configure_json": str(run_dir / "safari-dom-model-configure.json") if (run_dir / "safari-dom-model-configure.json").exists() else "",
        "safari_dom_model_status_json": str(run_dir / "safari-dom-model-status.json") if (run_dir / "safari-dom-model-status.json").exists() else "",
        "safari_dom_model_run_json": str(run_dir / "safari-dom-model-run.json") if (run_dir / "safari-dom-model-run.json").exists() else "",
        "safari_dom_model_trajectory_json": str(run_dir / "safari-dom-model-trajectory.json") if (run_dir / "safari-dom-model-trajectory.json").exists() else "",
        "safari_dom_model_after_screen_json": str(run_dir / "safari-dom-model-after-screen.json") if (run_dir / "safari-dom-model-after-screen.json").exists() else "",
        "safari_dom_model_safari_state_json": str(run_dir / "safari-dom-model-safari-state.json") if (run_dir / "safari-dom-model-safari-state.json").exists() else "",
        "safari_dom_model_reset_json": str(run_dir / "safari-dom-model-reset.json") if (run_dir / "safari-dom-model-reset.json").exists() else "",
        "prompt_bridge_marker": str(run_dir / "prompt-bridge-marker.txt") if (run_dir / "prompt-bridge-marker.txt").exists() else "",
        "prompt_bridge_request_id": str(run_dir / "prompt-bridge-request-id.txt") if (run_dir / "prompt-bridge-request-id.txt").exists() else "",
        "prompt_bridge_before_screen_json": str(run_dir / "prompt-bridge-before-screen.json") if (run_dir / "prompt-bridge-before-screen.json").exists() else "",
        "prompt_bridge_open_url_json": str(run_dir / "prompt-bridge-open-url.json") if (run_dir / "prompt-bridge-open-url.json").exists() else "",
        "prompt_bridge_pre_screen_json": str(run_dir / "prompt-bridge-pre-screen.json") if (run_dir / "prompt-bridge-pre-screen.json").exists() else "",
        "prompt_bridge_model_status_json": str(run_dir / "prompt-bridge-model-status.json") if (run_dir / "prompt-bridge-model-status.json").exists() else "",
        "prompt_bridge_response_json": str(run_dir / "prompt-bridge-response.json") if (run_dir / "prompt-bridge-response.json").exists() else "",
        "prompt_bridge_agent_status_json": str(run_dir / "prompt-bridge-agent-status.json") if (run_dir / "prompt-bridge-agent-status.json").exists() else "",
        "prompt_bridge_trajectory_json": str(run_dir / "prompt-bridge-trajectory.json") if (run_dir / "prompt-bridge-trajectory.json").exists() else "",
        "prompt_bridge_after_screen_json": str(run_dir / "prompt-bridge-after-screen.json") if (run_dir / "prompt-bridge-after-screen.json").exists() else "",
        "prompt_bridge_safari_state_json": str(run_dir / "prompt-bridge-safari-state.json") if (run_dir / "prompt-bridge-safari-state.json").exists() else "",
        "prompt_bridge_tweak_log": str(run_dir / "prompt-bridge-tweak-log.txt") if (run_dir / "prompt-bridge-tweak-log.txt").exists() else "",
        "validate_log": str(run_dir / "validate.log"),
    },
    "exit_code": exit_code,
}

(run_dir / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
(run_dir / "exit-code.txt").write_text(str(exit_code) + "\n", encoding="utf-8")
print(json.dumps({
    "status": "ok" if exit_code == 0 else "failed",
    "exit_code": exit_code,
    "report": str(run_dir / "report.json"),
    "health": report["daemon"]["health_status"],
    "latest_springboard_crash": latest,
    "safe_mode_marker_present": bool(markers),
    "gates": report["gates"],
    "artifact_hygiene": report["artifact_hygiene"]["status"],
}, indent=2))
PY
}

start_iproxy_if_requested
check_remote_target_identity

if [[ "$mode" != "collect-only" ]]; then
  run_local "git-diff-check" 10 git -C "$repo_root" diff --check
  run_local "smoke-agentd-local" 10 "$repo_root/tools/mac/agentd/smoke-agentd-local.sh"
  run_local "make-package" 20 make -C "$repo_root/agentd" package
  if [[ -z "$package" ]]; then
    package="$(ls -t "$repo_root"/agentd/packages/com.openphone.agentd_*_iphoneos-arm64.deb 2>/dev/null | head -n 1 || true)"
  fi
  if [[ -z "$package" || ! -f "$package" ]]; then
    fail 20 "package not found after build"
  fi
  log "Using package $package"
  collect_safety "before"
  check_preinstall_safety
  log "Installing package"
  if ! OPENPHONE_AGENTD_DEB="$package" \
      OPENPHONE_IOS_HOST="$host" \
      OPENPHONE_IOS_SSH_PORT="$port" \
      OPENPHONE_IOS_USER="$user" \
      OPENPHONE_IOS_PASSWORD="$password" \
      OPENPHONE_IOS_KNOWN_HOSTS="$known_hosts" \
      OPENPHONE_IOS_UDID="$target_udid" \
      "$repo_root/tools/mac/agentd/install-agentd-package.sh" >"$run_dir/install-agentd-package.log" 2>&1; then
    fail 20 "package install failed; see $run_dir/install-agentd-package.log"
  fi
fi

collect_device_state
check_stability_gate
start_provider_broker_if_requested
collect_screenshot_if_requested
collect_unlocked_foreground_sample
collect_app_ui_sample
collect_lockscreen_sample
collect_prefs_backend_sample
collect_prefs_ui_sample
collect_visible_effect_sample
if [[ "$mode" == "full" || "${OPENPHONE_VALIDATE_INCLUDE_STORES:-0}" == "1" ]]; then
  collect_safe_store_state
fi
collect_provider_attempt_sample
collect_memory_lifecycle_sample
collect_voice_status_sample
collect_watcher_timer_sample
collect_watcher_repair_sample
collect_job_repair_sample
collect_restart_recovery_sample
collect_model_loop_sample
collect_provider_model_sample
collect_safari_dom_model_sample
collect_prompt_bridge_model_sample
collect_trigger_diagnostics_sample

generate_report | tee -a "$summary_log"
exit_code="$(cat "$run_dir/exit-code.txt")"
log "Validation report: $run_dir/report.json"
exit "$exit_code"
