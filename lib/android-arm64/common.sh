#!/usr/bin/env bash
# Shared installer logic. Each platform module supplies backend_* functions.

android_arm64_usage() {
    cat <<'EOF'
Usage: ./setup-android-arm64.sh [--sdk-root PATH] [--accept-licenses] [--skip-system-packages]
                                 [--emulator NAME] [--waydroid-image vanilla|gapps]
                                 [--waydroid-size WIDTHxHEIGHT]
                                 [--avd-ini PATH] [--avd-qemu-binary PATH]
                                 [--avd-list-images [--json] | --avd-tui]
                                 [--avd-create NAME --avd-image PACKAGE_ID]
                                 [--avd-list | --avd-select NAME]
                                 [--ensure-jdk 11|17|21] [--emulator-start NAME]
                                 [--emulator-doctor NAME]
Supported hosts: Ubuntu, Debian 13, and Arch Linux / Arch Linux ARM on ARM64.
Android emulators: none (default), waydroid, and avd (requires Android-enabled ARM64 QEMU).
EOF
}

android_arm64_parse_arguments() {
    ANDROID_ARM64_ACCEPT_LICENSES=false
    ANDROID_ARM64_SKIP_SYSTEM_PACKAGES=false
    ANDROID_ARM64_SDK_ROOT="$HOME/.local/share/android-arm64/sdk"
    ANDROID_ARM64_SDK_ROOT_EXPLICIT=false
    ANDROID_ARM64_EMULATOR=none
    ANDROID_ARM64_WAYDROID_IMAGE=GAPPS
    ANDROID_ARM64_WAYDROID_SIZE=320x690
    ANDROID_ARM64_AVD_INI=
    ANDROID_ARM64_AVD_QEMU_BINARY=
    ANDROID_ARM64_AVD_IMAGE=
    ANDROID_ARM64_JSON=false
    ANDROID_ARM64_ACTION=install
    ANDROID_ARM64_ACTION_VALUE=
    local action_count=0
    while (($#)); do
        case "$1" in
            --sdk-root) [[ $# -ge 2 && "$2" == /* && "$2" != / ]] || { echo '--sdk-root needs an absolute, non-root path.' >&2; return 2; }; ANDROID_ARM64_SDK_ROOT="$2"; ANDROID_ARM64_SDK_ROOT_EXPLICIT=true; shift 2 ;;
            --accept-licenses) ANDROID_ARM64_ACCEPT_LICENSES=true; shift ;;
            --skip-system-packages) ANDROID_ARM64_SKIP_SYSTEM_PACKAGES=true; shift ;;
            --emulator) [[ $# -ge 2 ]] || { echo '--emulator needs none, waydroid, or avd.' >&2; return 2; }; ANDROID_ARM64_EMULATOR="$2"; shift 2 ;;
            --waydroid-image) [[ $# -ge 2 ]] || { echo '--waydroid-image needs vanilla or gapps.' >&2; return 2; }; case "$2" in vanilla|gapps) ANDROID_ARM64_WAYDROID_IMAGE="${2^^}" ;; *) echo '--waydroid-image needs vanilla or gapps.' >&2; return 2 ;; esac; shift 2 ;;
            --waydroid-size) [[ $# -ge 2 && "$2" =~ ^[1-9][0-9]{2,3}x[1-9][0-9]{2,3}$ ]] || { echo '--waydroid-size needs WIDTHxHEIGHT, each side 100-9999.' >&2; return 2; }; ANDROID_ARM64_WAYDROID_SIZE="$2"; shift 2 ;;
            --avd-ini) [[ $# -ge 2 && "$2" == /* ]] || { echo '--avd-ini needs an absolute path.' >&2; return 2; }; ANDROID_ARM64_AVD_INI="$2"; shift 2 ;;
            --avd-qemu-binary) [[ $# -ge 2 && "$2" == /* ]] || { echo '--avd-qemu-binary needs an absolute path.' >&2; return 2; }; ANDROID_ARM64_AVD_QEMU_BINARY="$2"; shift 2 ;;
            --avd-image) [[ $# -ge 2 ]] || { echo '--avd-image needs a package ID.' >&2; return 2; }; ANDROID_ARM64_AVD_IMAGE="$2"; shift 2 ;;
            --avd-list-images) ANDROID_ARM64_ACTION=avd-list-images; ((action_count+=1)); shift ;;
            --avd-create) [[ $# -ge 2 ]] || { echo '--avd-create needs a name.' >&2; return 2; }; ANDROID_ARM64_ACTION=avd-create; ANDROID_ARM64_ACTION_VALUE="$2"; ((action_count+=1)); shift 2 ;;
            --avd-tui) ANDROID_ARM64_ACTION=avd-tui; ((action_count+=1)); shift ;;
            --avd-list) ANDROID_ARM64_ACTION=avd-list; ((action_count+=1)); shift ;;
            --avd-select) [[ $# -ge 2 ]] || { echo '--avd-select needs a name.' >&2; return 2; }; ANDROID_ARM64_ACTION=avd-select; ANDROID_ARM64_ACTION_VALUE="$2"; ((action_count+=1)); shift 2 ;;
            --json) ANDROID_ARM64_JSON=true; shift ;;
            --emulator-start) [[ $# -ge 2 ]] || { echo '--emulator-start needs an emulator name.' >&2; return 2; }; ANDROID_ARM64_ACTION=emulator-start; ANDROID_ARM64_EMULATOR="$2"; ((action_count+=1)); shift 2 ;;
            --emulator-doctor) [[ $# -ge 2 ]] || { echo '--emulator-doctor needs an emulator name.' >&2; return 2; }; ANDROID_ARM64_ACTION=emulator-doctor; ANDROID_ARM64_EMULATOR="$2"; ((action_count+=1)); shift 2 ;;
            --ensure-jdk) [[ $# -ge 2 ]] || { echo '--ensure-jdk needs 11, 17, or 21.' >&2; return 2; }; ANDROID_ARM64_ACTION=ensure-jdk; ANDROID_ARM64_ACTION_VALUE=$2; ((action_count+=1)); shift 2 ;;
            --help) android_arm64_usage; return 10 ;;
            *) echo "Unknown argument: $1" >&2; return 2 ;;
        esac
    done
    ((action_count<=1)) || { echo 'Choose only one action.' >&2; return 2; }
    [[ "$ANDROID_ARM64_ACTION" == avd-create && -n "$ANDROID_ARM64_AVD_IMAGE" || "$ANDROID_ARM64_ACTION" != avd-create && -z "$ANDROID_ARM64_AVD_IMAGE" ]] || { echo '--avd-image requires --avd-create, and creation requires --avd-image.' >&2; return 2; }
    [[ "$ANDROID_ARM64_JSON" == false || "$ANDROID_ARM64_ACTION" == avd-list-images ]] || { echo '--json requires --avd-list-images.' >&2; return 2; }
    case "$ANDROID_ARM64_EMULATOR" in
        none|waydroid|avd) ;;
        *) echo "Unsupported emulator: $ANDROID_ARM64_EMULATOR. Add a module under lib/android-arm64/emulators/." >&2; return 2 ;;
    esac
    if [[ -n "$ANDROID_ARM64_AVD_INI" && ( "$ANDROID_ARM64_ACTION" != install || "$ANDROID_ARM64_EMULATOR" != avd ) ]]; then
        echo '--avd-ini requires --emulator avd setup.' >&2
        return 2
    fi
    if [[ -n "$ANDROID_ARM64_AVD_QEMU_BINARY" && ! ( "$ANDROID_ARM64_ACTION" == install && "$ANDROID_ARM64_EMULATOR" == avd ) && "$ANDROID_ARM64_ACTION" != avd-create && "$ANDROID_ARM64_ACTION" != avd-select ]]; then
        echo '--avd-qemu-binary requires AVD setup, creation, or selection.' >&2
        return 2
    fi
    if [[ "$ANDROID_ARM64_ACTION" == avd-* && "$ANDROID_ARM64_EMULATOR" == waydroid ]]; then
        echo 'AVD actions cannot be combined with --emulator waydroid.' >&2
        return 2
    fi
    ANDROID_ARM64_SDK_ROOT="$(realpath -m -- "$ANDROID_ARM64_SDK_ROOT")"
    if [[ "$ANDROID_ARM64_SDK_ROOT_EXPLICIT" == false && "$ANDROID_ARM64_ACTION" == avd-* && -f "$ANDROID_ARM64_STATE_ROOT/avd/sdk-root" ]]; then
        ANDROID_ARM64_SDK_ROOT="$(cat "$ANDROID_ARM64_STATE_ROOT/avd/sdk-root")"
    fi
}

android_arm64_load_backend() {
    [[ "$(uname -m)" == aarch64 ]] || { echo 'Linux ARM64 is required.' >&2; return 1; }
    source /etc/os-release
    case "$ID" in
        ubuntu|debian) ANDROID_ARM64_PLATFORM="$ID" ;;
        arch|archarm) ANDROID_ARM64_PLATFORM=arch ;;
        *) echo "Unsupported distribution: $ID. Add a backend under lib/android-arm64/platforms/." >&2; return 1 ;;
    esac
    source "$ANDROID_ARM64_SCRIPT_DIR/lib/android-arm64/platforms/$ANDROID_ARM64_PLATFORM.sh"
    local name
    for name in backend_validate backend_provision backend_provision_jdk backend_jdk_path backend_tool_path backend_environment backend_provision_emulator; do
        declare -F "$name" >/dev/null || { echo "Backend $ANDROID_ARM64_PLATFORM is missing $name." >&2; return 1; }
    done
    backend_validate
}

android_arm64_load_emulator() {
    local emulator=$1 name
    [[ "$emulator" != none ]] || { echo 'No emulator selected; pass --emulator waydroid or --emulator avd.' >&2; return 2; }
    source "$ANDROID_ARM64_SCRIPT_DIR/lib/android-arm64/emulators/$emulator.sh"
    for name in emulator_validate emulator_install emulator_init emulator_start emulator_doctor emulator_environment; do
        declare -F "$name" >/dev/null || { echo "Emulator $emulator is missing $name." >&2; return 1; }
    done
}

android_arm64_sdkmanager() {
    ANDROID_HOME="$ANDROID_ARM64_SDK_ROOT" ANDROID_SDK_ROOT="$ANDROID_ARM64_SDK_ROOT" \
        "$(backend_tool_path sdkmanager)" --sdk_root "$ANDROID_ARM64_SDK_ROOT" "$@"
}

android_arm64_install_sdk_package() {
    local package=$1 marker=$2 archive=$3 attempt
    for attempt in 1 2; do
        android_arm64_sdkmanager "$package"
        [[ -f "$marker" ]] && return 0
        rm -f -- "$HOME/.cache/sdkmanager/$archive"
        echo "Android ARM64 setup: $package did not install; retrying with a fresh archive." >&2
    done
    echo "Android ARM64 setup: $package could not be installed." >&2
    return 1
}

android_arm64_accept_licenses() {
    "$ANDROID_ARM64_ACCEPT_LICENSES" || { echo 'Review Android SDK terms, then rerun with --accept-licenses.' >&2; return 2; }
    ANDROID_HOME="$ANDROID_ARM64_SDK_ROOT" ANDROID_SDK_ROOT="$ANDROID_ARM64_SDK_ROOT" \
        python3 - "$(backend_tool_path sdkmanager)" "$ANDROID_ARM64_SDK_ROOT" <<'PY'
import subprocess, sys
subprocess.run([sys.argv[1], '--sdk_root', sys.argv[2], '--licenses'], input='y\n' * 100, text=True, check=True)
PY
}

android_arm64_configure_build_tools() {
    local directory="$ANDROID_ARM64_SDK_ROOT/build-tools/$1" tool
    for tool in aapt aapt2 aidl zipalign split-select apksigner; do ln -sfn "$(backend_tool_path "$tool")" "$directory/$tool"; done
}

android_arm64_register_platform_tools() {
    local directory="$ANDROID_ARM64_SDK_ROOT/platform-tools" tool version
    mkdir -p "$directory"
    for tool in adb fastboot; do ln -sfn "$(backend_tool_path "$tool")" "$directory/$tool"; done
    version="$("$(backend_tool_path adb)" version | sed -nE 's/^Version ([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | head -n1)"
    [[ -n "$version" ]] || version=0.0.0
    cat > "$directory/source.properties" <<EOF
Pkg.Desc=Android SDK Platform-Tools ($ANDROID_ARM64_PLATFORM ARM64)
Pkg.Revision=$version
EOF
}

android_arm64_write_runtime() {
    local state="$ANDROID_ARM64_STATE_ROOT" runtime="$ANDROID_ARM64_STATE_ROOT/env.sh"
    mkdir -p "$state/gradle" "$HOME/.config/android-arm64"
    cat > "$state/gradle/gradle.properties" <<EOF
org.gradle.java.home=$(backend_jdk_path 11)
android.aapt2FromMavenOverride=$state/bin/aapt2
EOF
    cat > "$runtime" <<EOF
# Generated by setup-android-arm64.sh.
export ANDROID_HOME='$ANDROID_ARM64_SDK_ROOT'
export ANDROID_SDK_ROOT='$ANDROID_ARM64_SDK_ROOT'
export GRADLE_USER_HOME='$state/gradle'
export JAVA_HOME='$(backend_jdk_path 11)'
export PATH='$state/bin:'"\$JAVA_HOME/bin:\$PATH"
export GRADLE_OPTS="\$GRADLE_OPTS -Dorg.gradle.java.home=\$JAVA_HOME -Dandroid.aapt2FromMavenOverride=$state/bin/aapt2"
export ANDROID_ARM64_LAUNCHER='$ANDROID_ARM64_SCRIPT_DIR/setup-android-arm64.sh'
EOF
    backend_environment >> "$runtime"
    cat >> "$runtime" <<'EOF'
_android_arm64_project="$PWD"
# ${dir%/*} yields "" rather than "/" one level below root, so stop on empty
# as well; otherwise this loop spins forever outside a project.
while [ -n "$_android_arm64_project" ] && [ "$_android_arm64_project" != / ] && [ ! -f "$_android_arm64_project/settings.gradle" ] && [ ! -f "$_android_arm64_project/settings.gradle.kts" ] && [ ! -x "$_android_arm64_project/gradlew" ]; do _android_arm64_project=${_android_arm64_project%/*}; done
if [ -n "$_android_arm64_project" ] && [ "$_android_arm64_project" != / ]; then
  _android_arm64_agp=$(find "$_android_arm64_project" -type f \( -name '*.gradle' -o -name '*.gradle.kts' \) -not -path '*/build/*' -print0 2>/dev/null | xargs -0 -r grep -hE 'com\.android\.tools\.build:gradle:|com\.android\.(application|library).*version' 2>/dev/null | sed -nE 's/.*gradle:([0-9]+).*/\1/p; s/.*version[^0-9]*([0-9]+).*/\1/p' | head -n1)
  case "$_android_arm64_agp" in 8|9|[1-9][0-9]*) _android_arm64_jdk=17;; *) _android_arm64_jdk=11;; esac
  JAVA_HOME=$("$ANDROID_ARM64_LAUNCHER" --ensure-jdk "$_android_arm64_jdk" --skip-system-packages)
  PATH="$JAVA_HOME/bin:$PATH"
  export JAVA_HOME PATH
fi
unset _android_arm64_project _android_arm64_agp _android_arm64_jdk
EOF
    cat > "$HOME/.config/android-arm64/env.sh" <<EOF
# Generated by setup-android-arm64.sh.
. '$runtime'
EOF
}

android_arm64_verify() {
    local jdk
    jdk="$(backend_jdk_path 11)"
    "$jdk/bin/java" -version
    "$jdk/bin/javac" -version
    "$(backend_tool_path aapt2)" version
    "$(backend_tool_path adb)" version
    JAVA_HOME="$jdk" "$(backend_tool_path apksigner)" version
}

android_arm64_ensure_jdk() {
    case "$1" in 11|17|21) ;; *) echo "Unsupported JDK: $1" >&2; return 2 ;; esac
    backend_provision_jdk "$1"
    [[ -x "$(backend_jdk_path "$1")/bin/javac" ]] || { echo "JDK $1 provisioning failed." >&2; return 1; }
}

android_arm64_append_emulator_environment() {
    {
        echo "# $1 emulator helpers, added by setup-android-arm64.sh."
        emulator_environment
    } >> "$ANDROID_ARM64_STATE_ROOT/env.sh"
}

android_arm64_setup_emulator() {
    local emulator="$ANDROID_ARM64_EMULATOR"
    android_arm64_load_emulator "$emulator"
    emulator_validate
    emulator_install "$ANDROID_ARM64_SKIP_SYSTEM_PACKAGES"
    emulator_init
    # Record the choice and emit the helpers before starting: if the start (or
    # its boot check) fails, the user still needs doctor/status/logcat to recover.
    printf '%s\n' "$emulator" > "$ANDROID_ARM64_STATE_ROOT/emulator"
    android_arm64_append_emulator_environment "$emulator"
    emulator_start
    echo "Emulator ready: $emulator. Source '$HOME/.config/android-arm64/env.sh' and run android_arm64_emulator_start."
}

# A rerun without --emulator regenerates env.sh, so re-emit the helpers of an
# emulator that was provisioned earlier. This path is deliberately privileged-
# free: it does not install, initialize or start anything.
android_arm64_restore_emulator_environment() {
    local saved="$ANDROID_ARM64_STATE_ROOT/emulator" emulator
    [[ -f "$saved" ]] || return 0
    read -r emulator < "$saved"
    [[ -n "$emulator" && "$emulator" != none ]] || return 0
    android_arm64_load_emulator "$emulator"
    android_arm64_append_emulator_environment "$emulator"
}

android_arm64_main() {
    ANDROID_ARM64_STATE_ROOT="${ANDROID_ARM64_STATE_ROOT:-$HOME/.local/share/android-arm64}"
    android_arm64_parse_arguments "$@" || { [[ $? -eq 10 ]] && return 0; return $?; }
    android_arm64_load_backend
    case "$ANDROID_ARM64_ACTION" in
        avd-list-images|avd-create|avd-tui|avd-list|avd-select)
            android_arm64_load_emulator avd
            case "$ANDROID_ARM64_ACTION" in
                avd-list-images) avd_list_images ;;
                avd-create) avd_create "$ANDROID_ARM64_ACTION_VALUE" "$ANDROID_ARM64_AVD_IMAGE" ;;
                avd-tui) avd_tui ;;
                avd-list) avd_list ;;
                avd-select) avd_select "$ANDROID_ARM64_ACTION_VALUE" ;;
            esac
            return
            ;;
        emulator-start|emulator-doctor)
            # Starting or repairing an already-provisioned emulator must not
            # touch the package manager, so these actions run before backend_provision.
            android_arm64_load_emulator "$ANDROID_ARM64_EMULATOR"
            emulator_validate
            "${ANDROID_ARM64_ACTION//-/_}"
            return
            ;;
    esac
    backend_provision "$ANDROID_ARM64_SKIP_SYSTEM_PACKAGES"
    if [[ "$ANDROID_ARM64_ACTION" == ensure-jdk ]]; then
        android_arm64_ensure_jdk "$ANDROID_ARM64_ACTION_VALUE"
        backend_jdk_path "$ANDROID_ARM64_ACTION_VALUE"
        return
    fi
    backend_provision_jdk 11
    mkdir -p "$ANDROID_ARM64_SDK_ROOT"
    android_arm64_accept_licenses
    android_arm64_install_sdk_package 'platforms;android-30' "$ANDROID_ARM64_SDK_ROOT/platforms/android-30/android.jar" platform-30_r03.zip
    android_arm64_install_sdk_package 'build-tools;29.0.2' "$ANDROID_ARM64_SDK_ROOT/build-tools/29.0.2/source.properties" build-tools_r29.0.2-linux.zip
    android_arm64_configure_build_tools 29.0.2
    android_arm64_register_platform_tools
    android_arm64_write_runtime
    android_arm64_verify
    if [[ "$ANDROID_ARM64_EMULATOR" != none ]]; then
        android_arm64_setup_emulator
    else
        android_arm64_restore_emulator_environment
    fi
    echo "Setup complete. Source '$HOME/.config/android-arm64/env.sh'."
}
