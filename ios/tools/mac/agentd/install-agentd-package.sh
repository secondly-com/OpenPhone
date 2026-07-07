#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
host="${OPENPHONE_IOS_HOST:-127.0.0.1}"
port="${OPENPHONE_IOS_SSH_PORT:-22}"
user="${OPENPHONE_IOS_USER:-mobile}"
password="${OPENPHONE_IOS_PASSWORD:-}"
known_hosts="${OPENPHONE_IOS_KNOWN_HOSTS:-/tmp/openphone-ios-known-hosts}"
remote_deb="${OPENPHONE_AGENTD_REMOTE_DEB:-/var/mobile/openphone-agentd.deb}"
package="${OPENPHONE_AGENTD_DEB:-}"
target_udid="${OPENPHONE_IOS_UDID:-}"
started_iproxy_pid=""

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
  if [[ -n "$started_iproxy_pid" ]]; then
    kill "$started_iproxy_pid" >/dev/null 2>&1 || true
    wait "$started_iproxy_pid" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

start_iproxy_if_requested() {
  if [[ "${OPENPHONE_IOS_START_IPROXY:-0}" != "1" ]]; then
    return
  fi
  if ! command -v iproxy >/dev/null 2>&1; then
    echo "missing required command: iproxy" >&2
    exit 30
  fi
  if [[ -z "$target_udid" && "${OPENPHONE_IOS_ALLOW_UNPINNED_IPROXY:-0}" != "1" ]]; then
    echo "refusing to start or reuse iproxy without OPENPHONE_IOS_UDID; set OPENPHONE_IOS_ALLOW_UNPINNED_IPROXY=1 only for a confirmed single-device setup" >&2
    exit 30
  fi
  if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    if [[ "${OPENPHONE_IOS_ALLOW_EXISTING_IPROXY:-0}" != "1" ]]; then
      echo "local port $port already has a listener; stop it or set OPENPHONE_IOS_ALLOW_EXISTING_IPROXY=1 after confirming it targets the intended iPhone" >&2
      exit 30
    fi
    echo "Using existing listener on local port $port by explicit override"
    return
  fi
  local device_port="${OPENPHONE_IOS_IPROXY_DEVICE_PORT:-22}"
  local -a iproxy_args=()
  if [[ -n "$target_udid" ]]; then
    iproxy_args=(-u "$target_udid")
    echo "Starting temporary pinned iproxy $port:$device_port for UDID $(redact_udid "$target_udid")"
  else
    echo "Starting temporary unpinned iproxy $port:$device_port"
  fi
  iproxy "${iproxy_args[@]}" "$port:$device_port" >/tmp/openphone-install-agentd-iproxy.log 2>&1 &
  started_iproxy_pid="$!"
  sleep 2
  if ! lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "iproxy did not start; see /tmp/openphone-install-agentd-iproxy.log" >&2
    exit 30
  fi
}

if [[ -z "$package" ]]; then
  package="$(ls -t "$repo_root"/agentd/packages/com.openphone.agentd_*_iphoneos-arm64.deb 2>/dev/null | head -n 1 || true)"
fi

if [[ -z "$package" || ! -f "$package" ]]; then
  echo "openphone-agentd package not found. Run: (cd ios/agentd && make package)" >&2
  exit 1
fi

ssh_target="$user@$host"

start_iproxy_if_requested

expect_scp() {
  OPENPHONE_IOS_PASSWORD="$password" expect -f - -- "$package" "$ssh_target:$remote_deb" "$port" "$known_hosts" <<'EXPECT'
set timeout 120
set local_path [lindex $argv 0]
set remote_path [lindex $argv 1]
set port [lindex $argv 2]
set known_hosts [lindex $argv 3]
spawn scp -P $port -o StrictHostKeyChecking=no -o UserKnownHostsFile=$known_hosts $local_path $remote_path
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

expect_ssh_tty() {
  local remote_cmd="$1"
  OPENPHONE_IOS_PASSWORD="$password" expect -f - -- "$port" "$known_hosts" "$ssh_target" "$remote_cmd" <<'EXPECT'
set timeout 120
set port [lindex $argv 0]
set known_hosts [lindex $argv 1]
set target [lindex $argv 2]
set remote_cmd [lindex $argv 3]
spawn ssh -tt -p $port -o StrictHostKeyChecking=no -o UserKnownHostsFile=$known_hosts $target $remote_cmd
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

plain_scp() {
  scp -P "$port" -o StrictHostKeyChecking=no -o UserKnownHostsFile="$known_hosts" \
    "$package" "$ssh_target:$remote_deb"
}

plain_ssh_tty() {
  ssh -tt -p "$port" -o StrictHostKeyChecking=no -o UserKnownHostsFile="$known_hosts" \
    "$ssh_target" "$1"
}

install_cmd="
set -eu
sudo -v
sudo dpkg -i '$remote_deb'
sudo killall Preferences >/dev/null 2>&1 || true
sudo launchctl bootout system/com.openphone.protecteddatahelper >/dev/null 2>&1 || true
sudo launchctl unload /var/jb/Library/LaunchDaemons/com.openphone.protected-data-helper.plist >/dev/null 2>&1 || true
sudo launchctl remove com.openphone.protected-data-helper >/dev/null 2>&1 || true
sudo rm -f /var/jb/Library/LaunchDaemons/com.openphone.protected-data-helper.plist
sudo killall openphone-protected-data-helper >/dev/null 2>&1 || true
sudo rm -f /var/mobile/Library/OpenPhone/protected-data-helper/run/agentd.sock
sudo mkdir -p /var/mobile/Library/OpenPhone/protected-data-helper
sudo launchctl bootstrap system /var/jb/Library/LaunchDaemons/com.openphone.protecteddatahelper.plist >/dev/null 2>&1 || true
sudo launchctl kickstart -k system/com.openphone.protecteddatahelper >/dev/null 2>&1 || true
sudo launchctl unload /var/jb/Library/LaunchDaemons/com.openphone.agentd.plist >/dev/null 2>&1 || true
sudo launchctl load -w /var/jb/Library/LaunchDaemons/com.openphone.agentd.plist
sleep 2
/var/jb/usr/local/bin/openphone-agentctl
"

echo "Installing $package to $ssh_target:$remote_deb"
if [[ -n "$password" ]]; then
  expect_scp
  expect_ssh_tty "$install_cmd"
else
  plain_scp
  plain_ssh_tty "$install_cmd"
fi
