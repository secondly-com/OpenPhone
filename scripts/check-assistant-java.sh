#!/usr/bin/env bash

# Compile-checks all OpenPhoneAssistant Java sources with javac against
# android.jar plus small stubs (scripts/javacheck-stubs) for the framework
# OpenPhoneAgentManager, the AIDL-generated interface, androidx.activity,
# generated R, and Kotlin-side classes referenced from Java.
#
# This is a syntax/reference gate, not a real build: it catches unresolved
# symbols (e.g. a helper method referenced but never implemented) that the
# JSON/config checks in check.sh cannot see. The authoritative build is
# still a full Android tree build.
#
# Set OPENPHONE_SKIP_JAVA_CHECK=1 to skip (e.g. environments without an
# Android SDK).

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "${OPENPHONE_SKIP_JAVA_CHECK:-0}" == "1" ]]; then
  echo "check-assistant-java: skipped (OPENPHONE_SKIP_JAVA_CHECK=1)"
  exit 0
fi

if ! command -v javac >/dev/null 2>&1; then
  echo "check-assistant-java: FAIL — javac not found." >&2
  echo "Install a JDK or set OPENPHONE_SKIP_JAVA_CHECK=1 to skip." >&2
  exit 1
fi

find_android_jar() {
  local sdk_roots=()
  [[ -n "${ANDROID_HOME:-}" ]] && sdk_roots+=("$ANDROID_HOME")
  [[ -n "${ANDROID_SDK_ROOT:-}" ]] && sdk_roots+=("$ANDROID_SDK_ROOT")
  sdk_roots+=("$HOME/Library/Android/sdk" "/usr/local/lib/android/sdk" "/opt/android-sdk")
  local android_tree sdk platform
  android_tree="${OPENPHONE_ANDROID_DIR:-$root/.worktree/android}"
  for platform in \
      "$android_tree/prebuilts/sdk/current/public/android.jar" \
      "$android_tree/prebuilts/sdk/36.1/public/android.jar" \
      "$android_tree/prebuilts/sdk/36/public/android.jar"; do
    if [[ -f "$platform" ]]; then
      echo "$platform"
      return 0
    fi
  done
  for sdk in "${sdk_roots[@]}"; do
    [[ -d "$sdk/platforms" ]] || continue
    platform="$(ls -1 "$sdk/platforms" 2>/dev/null | grep -E '^android-[0-9]+$' \
        | sort -t- -k2 -n | tail -1)"
    if [[ -n "$platform" && -f "$sdk/platforms/$platform/android.jar" ]]; then
      echo "$sdk/platforms/$platform/android.jar"
      return 0
    fi
  done
  return 1
}

android_jar="$(find_android_jar)" || {
  echo "check-assistant-java: FAIL — no android.jar found." >&2
  echo "Install an Android SDK platform (or set ANDROID_HOME), or set" >&2
  echo "OPENPHONE_SKIP_JAVA_CHECK=1 to skip." >&2
  exit 1
}

app_src="$root/overlay/packages/apps/OpenPhoneAssistant/src"
stub_src="$root/scripts/javacheck-stubs"
out_dir="$(mktemp -d "${TMPDIR:-/tmp}/openphone-javacheck.XXXXXX")"
trap 'rm -rf "$out_dir"' EXIT

sources=()
while IFS= read -r file; do
  sources+=("$file")
done < <(find "$app_src" "$stub_src" -name '*.java' | sort)

if [[ "${#sources[@]}" -eq 0 ]]; then
  echo "check-assistant-java: FAIL — no Java sources found under $app_src" >&2
  exit 1
fi

if ! javac -nowarn -proc:none \
    -d "$out_dir" \
    -cp "$android_jar" \
    "${sources[@]}"; then
  echo "check-assistant-java: FAIL — assistant Java sources do not compile." >&2
  exit 1
fi

echo "check-assistant-java: OK (${#sources[@]} files against $(basename "$(dirname "$android_jar")"))"
