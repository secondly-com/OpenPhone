#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  cat <<'EOF'
Usage:
  scripts/rotate-model-broker-secrets.sh --env-file <path> [--restart-service]
  scripts/rotate-model-broker-secrets.sh --env-file <path> --provider-key <key> [--restart-service]
  scripts/rotate-model-broker-secrets.sh --print-only

Rotates the OpenPhone model broker token-signing secret and admin token.

The default env-file mode updates only:
  OPENPHONE_BROKER_TOKEN_SECRET
  OPENPHONE_BROKER_ADMIN_TOKENS

The --provider-key mode updates only:
  OPENAI_API_KEY

Every env-file mode preserves unrelated broker settings, writes a timestamped
backup next to the env file, and chmods the updated file to 0600.
EOF
}

env_file=""
print_only=false
restart_service=false
provider_key=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file)
      env_file="${2:-}"
      shift 2
      ;;
    --print-only)
      print_only=true
      shift
      ;;
    --provider-key)
      provider_key="${2:-}"
      shift 2
      ;;
    --restart-service)
      restart_service=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$print_only" == true && ( -n "$env_file" || -n "$provider_key" ) ]]; then
  printf '--print-only cannot be combined with --env-file or --provider-key\n' >&2
  exit 2
fi

if [[ "$print_only" == false && -z "$env_file" ]]; then
  usage >&2
  exit 2
fi

generate_secret() {
  python3 - <<'PY'
import secrets

print(secrets.token_urlsafe(48))
PY
}

token_secret="$(generate_secret)"
admin_token="$(generate_secret)"

if [[ -n "$provider_key" && "$provider_key" != sk-* ]]; then
  printf 'provider key should look like an OpenAI sk-* key\n' >&2
  exit 2
fi

if [[ "$print_only" == true ]]; then
  printf 'OPENPHONE_BROKER_TOKEN_SECRET=%s\n' "$token_secret"
  printf 'OPENPHONE_BROKER_ADMIN_TOKENS=%s\n' "$admin_token"
  exit 0
fi

if [[ ! -f "$env_file" ]]; then
  printf 'env file does not exist: %s\n' "$env_file" >&2
  exit 1
fi

backup="$env_file.bak.$(date -u +%Y%m%dT%H%M%SZ)"
tmp="$(mktemp "${env_file}.tmp.XXXXXX")"
cp "$env_file" "$backup"

if [[ -n "$provider_key" ]]; then
  mode="provider"
else
  mode="broker"
fi

# Secrets are passed via the environment rather than argv so they never show
# up in `ps` process listings on the host.
ROTATE_TOKEN_SECRET="$token_secret" \
ROTATE_ADMIN_TOKEN="$admin_token" \
ROTATE_PROVIDER_KEY="$provider_key" \
python3 - <<'PY' "$env_file" "$tmp" "$mode"
import os
import pathlib
import sys

source = pathlib.Path(sys.argv[1])
target = pathlib.Path(sys.argv[2])
mode = sys.argv[3]
token_secret = os.environ["ROTATE_TOKEN_SECRET"]
admin_token = os.environ["ROTATE_ADMIN_TOKEN"]
provider_key = os.environ["ROTATE_PROVIDER_KEY"]

if mode == "provider":
    updates = {"OPENAI_API_KEY": provider_key}
else:
    updates = {
        "OPENPHONE_BROKER_TOKEN_SECRET": token_secret,
        "OPENPHONE_BROKER_ADMIN_TOKENS": admin_token,
    }
seen = set()
lines = []
for line in source.read_text(encoding="utf-8").splitlines():
    stripped = line.strip()
    if stripped and not stripped.startswith("#") and "=" in line:
        key = line.split("=", 1)[0].strip()
        if key in updates:
            lines.append(f"{key}={updates[key]}")
            seen.add(key)
            continue
    lines.append(line)

for key, value in updates.items():
    if key not in seen:
        lines.append(f"{key}={value}")

target.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY

mv "$tmp" "$env_file"
chmod 0600 "$env_file"

printf 'Updated %s\n' "$env_file"
printf 'Backup written to %s\n' "$backup"
if [[ "$mode" == "broker" ]]; then
  printf 'New admin token written to %s (OPENPHONE_BROKER_ADMIN_TOKENS)\n' "$env_file"
else
  printf 'Updated provider key: OPENAI_API_KEY\n'
fi

if [[ "$restart_service" == true ]]; then
  systemctl restart openphone-model-broker.service
  printf 'Restarted openphone-model-broker.service\n'
fi
