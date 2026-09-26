#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
required='backend_validate backend_provision backend_provision_jdk backend_jdk_path backend_tool_path backend_environment backend_provision_emulator'
emulator_required='emulator_validate emulator_install emulator_init emulator_start emulator_doctor emulator_environment'

for module in "$root"/lib/android-arm64/platforms/*.sh; do
    bash -n "$module"
    for function in $required; do
        grep -qE "^$function[[:space:]]*\(\)" "$module" || {
            echo "$module does not implement $function" >&2
            exit 1
        }
    done
done

for module in "$root"/lib/android-arm64/emulators/*.sh; do
    [[ -e "$module" ]] || continue
    bash -n "$module"
    for function in $emulator_required; do
        grep -qE "^$function[[:space:]]*\(\)" "$module" || {
            echo "$module does not implement $function" >&2
            exit 1
        }
    done
done

echo 'Android ARM64 backend contract checks passed.'
