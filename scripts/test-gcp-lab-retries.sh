#!/usr/bin/env bash

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
gcp_common="$root/scripts/lab/gcp/common.sh"
create_vm="$root/scripts/lab/gcp/create-vm.sh"
run_smoke="$root/scripts/lab/gcp/run-smoke.sh"

fail() {
  printf 'test-gcp-lab-retries: FAIL — %s\n' "$*" >&2
  exit 1
}

OPENPHONE_GCP_FALLBACK_ZONES="us-central1-a,us-central1-b"
# shellcheck source=scripts/lab/gcp/common.sh
source "$gcp_common"

inherited_candidates="$(gcp_zone_candidates us-central1-c)"
[[ "$inherited_candidates" == $'us-central1-c\nus-central1-a\nus-central1-b' ]] || {
  fail "omitting fallback zones must use OPENPHONE_GCP_FALLBACK_ZONES"
}

explicit_empty_candidates="$(gcp_zone_candidates us-central1-c "")"
[[ "$explicit_empty_candidates" == "us-central1-c" ]] || {
  fail "an explicit empty fallback list must select only the primary zone"
}

test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/openphone-gcp-retries.XXXXXX")"
attach_test_name="retry-contract-attach-disk"
trap 'rm -rf "$test_tmp" "$root/.worktree/gcp-lab/$attach_test_name"' EXIT

selection_file="$test_tmp/selection.json"
gcp_write_selection_result \
  "$selection_file" \
  "openphone-test-vm" \
  "us-central1-b" \
  "openphone-test-cache-us-central1-b"
selection="$(
  python3 - "$selection_file" <<'PY'
import json
import sys

value = json.load(open(sys.argv[1], encoding="utf-8"))
print("|".join([
    value["vm_name"],
    value["selected_zone"],
    value["selected_cache_disk"],
]))
PY
)"
[[ "$selection" == \
  "openphone-test-vm|us-central1-b|openphone-test-cache-us-central1-b" ]] || {
  fail "selection result must preserve the actual VM, zone, and cache disk"
}

gcloud() {
  printf '%s\n' "$*" >>"$OPENPHONE_GCP_TEST_LOG"
  case "$*" in
    "compute instances describe "*)
      return 1
      ;;
    "compute disks describe "*)
      if [[ "$OPENPHONE_GCP_TEST_SCENARIO" == "attach-capacity" ]]; then
        return 0
      fi
      return 1
      ;;
    "compute disks create "*)
      case "$OPENPHONE_GCP_TEST_SCENARIO" in
        disk-capacity)
          printf 'ERROR: ZONE_RESOURCE_POOL_EXHAUSTED_WITH_DETAILS\n' >&2
          return 1
          ;;
        disk-generic)
          printf 'ERROR: permission denied\n' >&2
          return 23
          ;;
        *)
          printf 'Created test cache disk\n'
          return 0
          ;;
      esac
      ;;
    "compute instances create "*)
      if [[ "$OPENPHONE_GCP_TEST_SCENARIO" == "instance-capacity" ||
        "$OPENPHONE_GCP_TEST_SCENARIO" == "attach-capacity" ]]; then
        printf 'ERROR: RESOURCE_POOL_EXHAUSTED\n' >&2
        return 1
      fi
      printf 'Created test VM\n'
      return 0
      ;;
    "compute disks delete "*)
      return 0
      ;;
    *)
      printf 'unexpected gcloud call: %s\n' "$*" >&2
      return 99
      ;;
  esac
}
export -f gcloud

run_create_case() {
  local scenario="$1"
  local expected_status="$2"
  local output
  local status

  : >"$test_tmp/gcloud.log"
  set +e
  output="$(
    OPENPHONE_GCP_TEST_SCENARIO="$scenario" \
    OPENPHONE_GCP_TEST_LOG="$test_tmp/gcloud.log" \
      "$create_vm" \
        --name "retry-contract-${scenario}" \
        --project test-project \
        --zone test-zone \
        --cache-mode snapshot \
        --cache-source-snapshot warm-snapshot 2>&1
  )"
  status=$?
  set -e

  if [[ "$status" -ne "$expected_status" ]]; then
    printf '%s\n' "$output" >&2
    fail "$scenario returned $status; expected $expected_status"
  fi
}

run_create_case disk-capacity 75
grep -q '^compute disks delete ' "$test_tmp/gcloud.log" || {
  fail "a failed snapshot disk create must attempt cleanup"
}

run_create_case disk-generic 23
run_create_case instance-capacity 75

: >"$test_tmp/gcloud.log"
set +e
attach_output="$(
  OPENPHONE_GCP_FALLBACK_ZONES="us-central1-a,us-central1-b" \
  OPENPHONE_GCP_TEST_SCENARIO="attach-capacity" \
  OPENPHONE_GCP_TEST_LOG="$test_tmp/gcloud.log" \
    "$run_smoke" \
      --name "$attach_test_name" \
      --project test-project \
      --zone us-central1-c \
      --cache-mode attach-disk \
      --cache-disk test-cache \
      --skip-build \
      --skip-smoke 2>&1
)"
attach_status=$?
set -e
if [[ "$attach_status" -ne 75 ]]; then
  printf '%s\n' "$attach_output" >&2
  fail "attach-disk capacity failure returned $attach_status; expected 75"
fi
if grep -q -- '--zone us-central1-[ab]' "$test_tmp/gcloud.log"; then
  fail "attach-disk retry escaped the disk's primary zone"
fi

printf 'GCP retry contract tests passed.\n'
