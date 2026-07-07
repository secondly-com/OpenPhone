#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
host="${OPENPHONE_IOS_HOST:-127.0.0.1}"
port="${OPENPHONE_IOS_SSH_PORT:-22}"
user="${OPENPHONE_IOS_USER:-mobile}"

agentd_bin="${OPENPHONE_AGENTD_BIN:-}"
agentctl_bin="${OPENPHONE_AGENTCTL_BIN:-}"

if [[ -z "$agentd_bin" ]]; then
  for candidate in \
    "$repo_root/agentd/.theos/obj/debug/openphone-agentd" \
    "$repo_root/agentd/.theos/obj/openphone-agentd"; do
    if [[ -x "$candidate" ]]; then
      agentd_bin="$candidate"
      break
    fi
  done
fi

if [[ -z "$agentctl_bin" ]]; then
  for candidate in \
    "$repo_root/agentd/.theos/obj/debug/openphone-agentctl" \
    "$repo_root/agentd/.theos/obj/openphone-agentctl"; do
    if [[ -x "$candidate" ]]; then
      agentctl_bin="$candidate"
      break
    fi
  done
fi

if [[ -z "$agentd_bin" || ! -x "$agentd_bin" ]]; then
  echo "openphone-agentd binary not found. Build ios/agentd first or set OPENPHONE_AGENTD_BIN." >&2
  exit 1
fi

if [[ -z "$agentctl_bin" || ! -x "$agentctl_bin" ]]; then
  echo "openphone-agentctl binary not found. Build ios/agentd first or set OPENPHONE_AGENTCTL_BIN." >&2
  exit 1
fi

ssh_target="$user@$host"
ssh_base=(ssh -p "$port" "$ssh_target")
scp_base=(scp -P "$port")

"${ssh_base[@]}" 'mkdir -p /tmp/openphone-agentd-upload'
"${scp_base[@]}" "$agentd_bin" "$ssh_target:/tmp/openphone-agentd-upload/openphone-agentd"
"${scp_base[@]}" "$agentctl_bin" "$ssh_target:/tmp/openphone-agentd-upload/openphone-agentctl"
"${scp_base[@]}" "$repo_root/agentd/launchd/com.openphone.agentd.plist" \
  "$ssh_target:/tmp/openphone-agentd-upload/com.openphone.agentd.plist"

"${ssh_base[@]}" '
set -eu
mkdir -p /var/mobile/Library/OpenPhone
if [ -d /var/jb/usr/local/bin ] && [ -w /var/jb/usr/local/bin ]; then
  install -m 0755 /tmp/openphone-agentd-upload/openphone-agentd /var/jb/usr/local/bin/openphone-agentd
  install -m 0755 /tmp/openphone-agentd-upload/openphone-agentctl /var/jb/usr/local/bin/openphone-agentctl
else
  sudo mkdir -p /var/jb/usr/local/bin
  sudo install -m 0755 /tmp/openphone-agentd-upload/openphone-agentd /var/jb/usr/local/bin/openphone-agentd
  sudo install -m 0755 /tmp/openphone-agentd-upload/openphone-agentctl /var/jb/usr/local/bin/openphone-agentctl
fi

if [ -d /var/jb/Library/LaunchDaemons ] && [ -w /var/jb/Library/LaunchDaemons ]; then
  install -m 0644 /tmp/openphone-agentd-upload/com.openphone.agentd.plist /var/jb/Library/LaunchDaemons/com.openphone.agentd.plist
else
  sudo mkdir -p /var/jb/Library/LaunchDaemons
  sudo install -m 0644 /tmp/openphone-agentd-upload/com.openphone.agentd.plist /var/jb/Library/LaunchDaemons/com.openphone.agentd.plist
fi

launchctl unload /var/jb/Library/LaunchDaemons/com.openphone.agentd.plist >/dev/null 2>&1 || true
launchctl load -w /var/jb/Library/LaunchDaemons/com.openphone.agentd.plist
sleep 1
/var/jb/usr/local/bin/openphone-agentctl
'
