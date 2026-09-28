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

# Emulator packages are the one privileged exception to the native-package
# model: Waydroid needs systemd units and /var/lib/waydroid.
backend_provision_emulator() {
    local emulator=$1 skip=$2 need_build=true tool
    if [[ "$emulator" == avd ]]; then
        [[ -n "$ANDROID_ARM64_AVD_QEMU_BINARY" ]] && need_build=false
        local -a missing=()
        command -v qemu-img >/dev/null || missing+=(qemu-utils)
        if "$need_build"; then
            for tool in repo git python3 cmake ninja make pkg-config cc c++; do
                command -v "$tool" >/dev/null || case "$tool" in
                    repo) missing+=(repo) ;;
                    cmake) missing+=(cmake) ;;
                    ninja) missing+=(ninja-build) ;;
                    make) missing+=(make) ;;
                    pkg-config) missing+=(pkg-config) ;;
                    cc|c++) missing+=(build-essential) ;;
                esac
            done
            missing+=(ca-certificates curl git python3 repo cmake ninja-build make pkg-config build-essential libglib2.0-dev libpixman-1-dev libssl-dev zlib1g-dev libfdt-dev libslirp-dev libusb-1.0-0-dev libncurses-dev libgtk-3-dev)
        fi
        ((${#missing[@]} == 0)) && return 0
        "$skip" && { echo "Missing Android QEMU build prerequisites: ${missing[*]}; rerun without --skip-system-packages." >&2; return 1; }
        sudo apt-get update
        sudo apt-get install -y --no-install-recommends "${missing[@]}"
        command -v qemu-img >/dev/null || { echo 'Missing qemu-img (qemu-utils).' >&2; return 1; }
        if "$need_build"; then
            for tool in repo git python3 cmake ninja make pkg-config cc c++; do
                command -v "$tool" >/dev/null || { echo "Missing Android QEMU build tool: $tool" >&2; return 1; }
            done
        fi
        return
    fi
    [[ "$emulator" == waydroid ]] || { echo "Unsupported emulator for Ubuntu: $emulator" >&2; return 1; }
    command -v waydroid >/dev/null && return 0
    "$skip" && {
        echo 'Missing package: waydroid. Rerun without --skip-system-packages.' >&2
        return 1
    }
    # waydroid entered the Ubuntu archive only with 26.10, so older releases
    # use the official Waydroid repository.
    if ! apt-cache show waydroid >/dev/null 2>&1; then
        sudo apt-get install -y --no-install-recommends curl ca-certificates
        curl -s https://repo.waydro.id | sudo bash
    fi
    sudo apt-get update
    sudo apt-get install -y waydroid
}
