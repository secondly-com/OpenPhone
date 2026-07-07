#!/usr/bin/env bash
set -euo pipefail

host="${OPENPHONE_IOS_HOST:-127.0.0.1}"
port="${OPENPHONE_IOS_SSH_PORT:-22}"
user="${OPENPHONE_IOS_USER:-mobile}"

remote_cmd='
set -eu
if [ ! -e /var/jb ]; then
  echo "{\"status\":\"error\",\"reason\":\"rootless_prefix_missing\"}"
  exit 1
fi
if [ ! -x /var/jb/usr/local/bin/openphone-agentctl ]; then
  echo "{\"status\":\"error\",\"reason\":\"openphone-agentctl_missing\"}"
  exit 1
fi
/var/jb/usr/local/bin/openphone-agentctl
'

ssh -p "$port" "$user@$host" "$remote_cmd"
