#!/usr/bin/env bash
set -euo pipefail

host="${OPENPHONE_IOS_HOST:-127.0.0.1}"
port="${OPENPHONE_IOS_SSH_PORT:-22}"
user="${OPENPHONE_IOS_USER:-mobile}"
lines="${OPENPHONE_AGENTD_TAIL_LINES:-80}"
if [[ ! "$lines" =~ ^[0-9]+$ ]]; then
  lines=80
fi

ssh -p "$port" "$user@$host" "
set -eu
mkdir -p /var/mobile/Library/OpenPhone
touch /var/mobile/Library/OpenPhone/openphone-agentd.log
tail -n $lines -f /var/mobile/Library/OpenPhone/openphone-agentd.log
"
