#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "$BASH_SOURCE")/.." && pwd)"
required='backend_validate backend_provision backend_provision_jdk backend_jdk_path backend_tool_path backend_environment'

for module in "$root"/lib/android-arm64/platforms/*.sh; do
    bash -n "$module"
    for function in $required; do
        rg -q "^$function[[:space:]]*\(\)" "$module" || {
            echo "$module does not implement $function" >&2
            exit 1
        }
    done
done

echo 'Android ARM64 backend contract checks passed.'
