#!/usr/bin/env bash
# Pull openphone-agentd crash logs + matching JetsamEvent files from the phone
# into artifacts/crashes/<timestamp>/ for triage.
#
# Uses the same env vars as the other agentd tools:
#   OPENPHONE_IOS_HOST     (default 127.0.0.1)
#   OPENPHONE_IOS_SSH_PORT (default 2224)
#   OPENPHONE_IOS_USER     (default mobile)
#   OPENPHONE_IOS_PASSWORD (required for expect-based auth)
#   OPENPHONE_IOS_KNOWN_HOSTS (default /tmp/openphone_ios14_known_hosts)

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
host="${OPENPHONE_IOS_HOST:-127.0.0.1}"
port="${OPENPHONE_IOS_SSH_PORT:-2224}"
user="${OPENPHONE_IOS_USER:-mobile}"
password="${OPENPHONE_IOS_PASSWORD:-}"
known_hosts="${OPENPHONE_IOS_KNOWN_HOSTS:-/tmp/openphone_ios14_known_hosts}"

if [[ -z "$password" ]]; then
  echo "OPENPHONE_IOS_PASSWORD not set" >&2
  exit 1
fi

stamp="$(date +%Y%m%d-%H%M%S)"
out_dir="$repo_root/artifacts/crashes/$stamp"
mkdir -p "$out_dir"

echo "Pulling crash reports into $out_dir ..."

run_remote() {
  OPENPHONE_IOS_PASSWORD="$password" expect <<EOF 2>&1
set timeout 30
log_user 1
spawn -noecho ssh -p $port -o ConnectTimeout=8 -o LogLevel=ERROR -o StrictHostKeyChecking=no -o UserKnownHostsFile=$known_hosts $user@$host "$1"
expect { -nocase -re "assword.*:" { send "\$env(OPENPHONE_IOS_PASSWORD)\r"; exp_continue } eof }
EOF
}

# List crash files.
run_remote 'ls -t /var/mobile/Library/Logs/CrashReporter/ 2>/dev/null | grep -iE "openphone-agentd|JetsamEvent" | head -40' \
  > "$out_dir/file-list.txt"

# Pull each file via scp.
while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  [[ "$file" =~ ^\( ]] && continue
  echo "Fetching $file"
  OPENPHONE_IOS_PASSWORD="$password" expect <<EOF 2>&1 >/dev/null || true
set timeout 60
log_user 0
spawn -noecho scp -P $port -o LogLevel=ERROR -o StrictHostKeyChecking=no -o UserKnownHostsFile=$known_hosts $user@$host:/var/mobile/Library/Logs/CrashReporter/$file $out_dir/
expect { -nocase -re "assword.*:" { send "\$env(OPENPHONE_IOS_PASSWORD)\r"; exp_continue } eof }
EOF
done < "$out_dir/file-list.txt"

echo "Done. Files:"
ls -la "$out_dir" | head
