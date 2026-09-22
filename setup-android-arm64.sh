#!/usr/bin/env bash
# Public entry point for native Linux ARM64 Android builds.
set -Eeuo pipefail
trap 'printf "Android ARM64 setup failed at line %s.\n" "$LINENO" >&2' ERR

ANDROID_ARM64_SCRIPT_DIR="$(cd -- "$(dirname -- "$BASH_SOURCE")" && pwd)"
source "$ANDROID_ARM64_SCRIPT_DIR/lib/android-arm64/common.sh"
android_arm64_main "$@"
