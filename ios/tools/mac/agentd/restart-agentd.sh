#!/usr/bin/env bash
set -euo pipefail

host="${OPENPHONE_IOS_HOST:-127.0.0.1}"
port="${OPENPHONE_IOS_SSH_PORT:-22}"
user="${OPENPHONE_IOS_USER:-mobile}"

ssh -p "$port" "$user@$host" '
set -eu
plist=/var/jb/Library/LaunchDaemons/com.openphone.agentd.plist
launchctl unload "$plist" >/dev/null 2>&1 || true
launchctl load -w "$plist"
sleep 1
/var/jb/usr/local/bin/openphone-agentctl
'
