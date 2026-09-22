#!/usr/bin/env bash

backend_validate() { [[ -n "$VERSION_ID" ]] || return 1; }

backend_provision() {
    local skip=$1 tool
    if ! "$skip"; then
        sudo apt-get update
        sudo apt-get install -y --no-install-recommends openjdk-11-jdk-headless openjdk-17-jdk-headless openjdk-21-jdk-headless python3 sdkmanager adb fastboot aapt aidl zipalign apksigner split-select curl unzip file cmake ninja-build make pkg-config build-essential libc6-dev tar xz-utils
    fi
    for tool in python3 sdkmanager adb fastboot aapt aapt2 aidl zipalign apksigner split-select curl tar; do
        command -v "$tool" >/dev/null || { echo "Missing prerequisite: $tool" >&2; return 1; }
    done
    mkdir -p "$ANDROID_ARM64_STATE_ROOT/bin"
    for tool in aapt aapt2 aidl zipalign apksigner split-select adb fastboot sdkmanager; do
        ln -sfn "/usr/bin/$tool" "$ANDROID_ARM64_STATE_ROOT/bin/$tool"
    done
}

backend_provision_jdk() {
    local version=$1 path
    path="$(backend_jdk_path "$version")"
    [[ -x "$path/bin/javac" ]] || { echo "Missing JDK $version. Rerun without --skip-system-packages." >&2; return 1; }
}

backend_jdk_path() { printf '/usr/lib/jvm/java-%s-openjdk-arm64\n' "$1"; }
backend_tool_path() { printf '%s/bin/%s\n' "$ANDROID_ARM64_STATE_ROOT" "$1"; }
backend_environment() { :; }
