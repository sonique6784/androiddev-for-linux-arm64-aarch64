#!/usr/bin/env bash
# Native Ubuntu ARM64 toolchain for this repository's Gradle 6.5 / AGP 4.1 build.
set -Eeuo pipefail
trap 'printf "\nSetup failed at line %s. Correct the error above and rerun this script.\n" "$LINENO" >&2' ERR

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
sdk_root="$HOME/Android/Sdk"
accept_licenses=false
skip_system_packages=false
while (($#)); do
    case "$1" in
        --sdk-root)
            [[ $# -ge 2 && -n "$2" ]] || { echo '--sdk-root needs a path' >&2; exit 2; }
            sdk_root="$2"; shift 2 ;;
        --accept-licenses) accept_licenses=true; shift ;;
        --skip-system-packages) skip_system_packages=true; shift ;;
        --help)
            echo "Usage: $0 [--sdk-root /absolute/path] [--accept-licenses] [--skip-system-packages]"
            echo 'Run as your normal user. Uses sudo only for Ubuntu packages.'
            echo '--accept-licenses accepts Android SDK licenses without prompting.'
            echo '--skip-system-packages uses prerequisites already installed by an administrator.'
            exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

[[ "$(uname -m)" == aarch64 ]] || { echo 'This installer requires Linux aarch64.' >&2; exit 1; }
[[ $EUID -ne 0 ]] || { echo 'Run as your normal user, not with sudo.' >&2; exit 1; }
source /etc/os-release
[[ "$ID" == ubuntu ]] || { echo 'This installer supports Ubuntu.' >&2; exit 1; }
[[ "$sdk_root" == /* && "$sdk_root" != / && "$sdk_root" != *$'\n'* ]] || {
    echo 'SDK root must be an absolute directory path other than /, without newlines.' >&2; exit 2;
}
sdk_root="$(realpath -m -- "$sdk_root")"

if ! "$skip_system_packages"; then
    echo 'Installing native Ubuntu packages...'
    sudo apt-get update
    sudo apt-get install -y --no-install-recommends \
        openjdk-11-jdk-headless openjdk-17-jdk-headless openjdk-21-jdk-headless \
        python3 sdkmanager adb fastboot \
        aapt aidl zipalign apksigner split-select git curl unzip ca-certificates file \
        cmake ninja-build make pkg-config build-essential libc6-dev tar xz-utils
fi
for tool in python3 sdkmanager adb fastboot aapt aapt2 aidl zipalign apksigner split-select git curl unzip file cmake ninja make pkg-config; do
    command -v "$tool" >/dev/null || { echo "Missing prerequisite: $tool. Run without --skip-system-packages." >&2; exit 1; }
done

export JAVA_HOME=/usr/lib/jvm/java-11-openjdk-arm64
export ANDROID_HOME="$sdk_root"
export PATH="$JAVA_HOME/bin:$PATH"
for jdk_version in 11 17 21; do
    jdk_dir="/usr/lib/jvm/java-${jdk_version}-openjdk-arm64"
    [[ -x "$jdk_dir/bin/java" && -x "$jdk_dir/bin/javac" ]] || {
        echo "ARM64 JDK $jdk_version is missing. Run without --skip-system-packages." >&2; exit 1;
    }
done
[[ -x /usr/bin/aapt2 ]] || { echo 'Ubuntu aapt did not provide /usr/bin/aapt2.' >&2; exit 1; }
/usr/bin/aapt2 version

echo 'Installing Android SDK platform 30 and build-tools 29.0.2...'
mkdir -p -- "$sdk_root"
if "$accept_licenses"; then
    python3 - "$sdk_root" <<'PY'
import subprocess
import sys
subprocess.run(["/usr/bin/sdkmanager", "--sdk_root", sys.argv[1], "--licenses"],
               input="y\n" * 100, text=True, check=True)
PY
else
    /usr/bin/sdkmanager --sdk_root "$sdk_root" --licenses
fi
/usr/bin/sdkmanager --sdk_root "$sdk_root" 'platforms;android-30' 'build-tools;29.0.2'

echo 'Configuring native SDK executables...'
build_tools="$sdk_root/build-tools/29.0.2"
[[ -f "$build_tools/source.properties" && -f "$sdk_root/platforms/android-30/android.jar" ]]
for tool in aapt aapt2 aidl zipalign split-select; do
    [[ -x "/usr/bin/$tool" ]] || { echo "Missing native tool: $tool" >&2; exit 1; }
    ln -sfn -- "/usr/bin/$tool" "$build_tools/$tool"
done
mkdir -p -- "$sdk_root/platform-tools"
for tool in adb fastboot; do
    ln -sfn -- "/usr/bin/$tool" "$sdk_root/platform-tools/$tool"
done
# Register the Ubuntu platform-tools with AGP's SDK manager. Executable links
# alone are not recognized as an installed package and trigger an x86 download.
python3 - "$sdk_root" <<'PY'
from pathlib import Path
import re
import shutil
import subprocess
import sys
import uuid
import xml.etree.ElementTree as ET

sdk = Path(sys.argv[1])
version_output = subprocess.check_output(["/usr/bin/adb", "version"], text=True)
match = re.search(r"^Version (\d+)\.(\d+)\.(\d+)", version_output, re.M)
if match is None:
    raise SystemExit("Cannot determine Ubuntu ADB's platform-tools version")
major, minor, micro = match.groups()
platform = sdk / "platform-tools"
metadata = {
    "source.properties": f"Pkg.Desc=Android SDK Platform-Tools (Ubuntu ARM64)\nPkg.Revision={major}.{minor}.{micro}\n",
    "package.xml": f'''<?xml version="1.0" encoding="UTF-8"?>
<common:repository xmlns:common="http://schemas.android.com/repository/android/common/01"
            xmlns:generic="http://schemas.android.com/repository/android/generic/01"
            xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <localPackage path="platform-tools" obsolete="false">
    <type-details xsi:type="generic:genericDetailsType"/>
    <revision><major>{major}</major><minor>{minor}</minor><micro>{micro}</micro></revision>
    <display-name>Android SDK Platform-Tools (Ubuntu ARM64)</display-name>
  </localPackage>
</common:repository>
''',
}
for name, content in metadata.items():
    path = platform / name
    if not path.exists() or path.read_text() != content:
        path.write_text(content)

# Repair the extra package downloaded by AGP after the initial installer version.
# Preserve it outside the SDK, and only move a verified x86 platform-tools copy.
extra = sdk / "platform-tools-2"
if (extra / "package.xml").is_file() and (extra / "adb").is_file():
    package = ET.parse(extra / "package.xml").getroot().find("localPackage")
    binary = subprocess.check_output(["file", "-Lb", str(extra / "adb")], text=True)
    if package is not None and package.get("path") == "platform-tools" and "x86-64" in binary:
        backup = Path.home() / ".local/share/android-arm64/backups" / ("platform-tools-2-" + uuid.uuid4().hex[:8])
        backup.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(extra), str(backup))
        print(f"Preserved redundant x86 platform-tools at {backup}")
PY

echo 'Saving shell and Gradle configuration...'
python3 - "$sdk_root" "$JAVA_HOME" "$project_dir" <<'PY'
from pathlib import Path
import re
import shlex
import sys

sdk, jdk, project = sys.argv[1:]
home = Path.home()
env_file = home / ".config/android-arm64/env.sh"

def write_if_changed(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    old = path.read_text() if path.exists() else None
    if old != content:
        path.write_text(content)

def managed_block(path, body):
    start, end = "# BEGIN android-arm64 setup", "# END android-arm64 setup"
    old = path.read_text() if path.exists() else ""
    pattern = re.compile(r"(?m)^" + re.escape(start) + r"\n.*?^" + re.escape(end) + r"\n?", re.S)
    clean = pattern.sub("", old).rstrip("\n")
    write_if_changed(path, (clean + "\n\n" if clean else "") + start + "\n" + body + "\n" + end + "\n")

def properties(path, values):
    # Replace only the keys owned by this installer; retain unrelated settings.
    old = path.read_text() if path.exists() else ""
    lines = [line for line in old.splitlines()
             if not any(re.match(r"^\s*" + re.escape(key) + r"\s*[:=]", line) for key in values)]
    def escape(value):
        return value.replace("\\", "\\\\").replace(" ", "\\ ").replace(":", "\\:")
    lines.extend(f"{key}={escape(value)}" for key, value in values.items())
    write_if_changed(path, "\n".join(lines) + "\n")

env_script = r'''# Generated by setup-android-arm64.sh
# Source this from an Android Gradle project directory. It selects the JDK and
# installs SDK packages declared by the project; no action is taken elsewhere.
export ANDROID_HOME=__SDK_ROOT__
export ANDROID_SDK_ROOT="$ANDROID_HOME"

_android_arm64_add_path() {
    case ":$PATH:" in *":$1:"*) ;; *) PATH="$1:$PATH" ;; esac
}

# Add a JVM property once.  env.sh is normally sourced several times in an
# interactive terminal, so blindly appending these options is surprisingly
# costly (and can select an old aapt2 after a project switch).
_android_arm64_gradle_option() {
    _android_arm64_option=$1
    case " ${GRADLE_OPTS:-} " in *" $_android_arm64_option "*) ;; *)
        export GRADLE_OPTS="${GRADLE_OPTS:+$GRADLE_OPTS }$_android_arm64_option" ;; esac
}

_android_arm64_project_root() {
    _android_arm64_dir="$PWD"
    while [ "$_android_arm64_dir" != / ]; do
        if [ -f "$_android_arm64_dir/settings.gradle" ] || [ -f "$_android_arm64_dir/settings.gradle.kts" ] || [ -x "$_android_arm64_dir/gradlew" ]; then
            printf '%s\n' "$_android_arm64_dir"
            return 0
        fi
        _android_arm64_dir=${_android_arm64_dir%/*}
        [ -n "$_android_arm64_dir" ] || _android_arm64_dir=/
    done
    return 1
}

_android_arm64_scan_project() {
    _android_arm64_files=$(find "$1" -type f \( -name '*.gradle' -o -name '*.gradle.kts' -o -name '*.kt' -o -name 'gradle-wrapper.properties' -o -name 'gradle.properties' -o -name 'libs.versions.toml' \) -not -path '*/.gradle/*' -not -path '*/build/*' -print 2>/dev/null)
    _android_arm64_text=$(printf '%s\n' "$_android_arm64_files" | xargs -r grep -hE 'compileSdk(Version)?|buildToolsVersion|com\.android\.tools\.build:gradle:|com\.android\.(application|library|test)|androidGradlePlugin|^[[:space:]]*agp[[:space:]]*=|org\.gradle\.java\.home|ndkVersion|externalNativeBuild|CMakeLists\.txt|Android\.mk|cmake[[:space:]]*\{|const[[:space:]]+val[[:space:]]+(COMPILE_SDK|NDK|CMAKE)' 2>/dev/null || true)
    # First use literals in build files.  The fallback handles conventional
    # [versions] keys in libs.versions.toml, including multiline Kotlin DSL
    # assignments such as compileSdk =\n libs.versions.compileSdk.get().toInt().
    ANDROID_ARM64_COMPILE_SDK=$(printf '%s\n' "$_android_arm64_text" | sed -nE 's/.*compileSdk(Version)?[^0-9]*([0-9]+(\\.[0-9]+)?).*/\2/p' | head -n1)
    [ -n "$ANDROID_ARM64_COMPILE_SDK" ] || ANDROID_ARM64_COMPILE_SDK=$(printf '%s\n' "$_android_arm64_text" | sed -nE 's/^[[:space:]]*(compileSdk|compile-sdk)[[:space:]]*=[[:space:]]*"?([0-9]+(\\.[0-9]+)?)"?.*/\2/p' | head -n1)
    [ -n "$ANDROID_ARM64_COMPILE_SDK" ] || ANDROID_ARM64_COMPILE_SDK=$(printf '%s\n' "$_android_arm64_text" | sed -nE 's/.*const[[:space:]]+val[[:space:]]+COMPILE_SDK[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' | head -n1)
    ANDROID_ARM64_BUILD_TOOLS=$(printf '%s\n' "$_android_arm64_text" | sed -nE 's/.*buildToolsVersion[^0-9]*([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | head -n1)
    ANDROID_ARM64_AGP=$(printf '%s\n' "$_android_arm64_text" | sed -nE 's/.*com\.android\.tools\.build:gradle:([0-9]+(\.[0-9]+){1,3}).*/\1/p; s/.*com\.android\.(application|library|test).*version[^0-9]*([0-9]+(\.[0-9]+){1,3}).*/\2/p; s/.*(androidGradlePlugin|agp)[[:space:]]*=[^0-9]*([0-9]+(\.[0-9]+){1,3}).*/\2/p' | head -n1)
    ANDROID_ARM64_JDK_OVERRIDE=$(printf '%s\n' "$_android_arm64_text" | sed -nE 's/.*org\.gradle\.java\.home[[:space:]]*=[^0-9]*([0-9]{2}).*/\1/p' | head -n1)
    ANDROID_ARM64_NDK_VERSION=$(printf '%s\n' "$_android_arm64_text" | sed -nE 's/.*ndkVersion[[:space:]]*(=|[[:space:]])[^"]*"?([0-9]+(\.[0-9]+)+).*/\2/p; s/.*const[[:space:]]+val[[:space:]]+NDK[[:space:]]*=[[:space:]]*"([0-9]+(\.[0-9]+)+)".*/\1/p' | head -n1)
    ANDROID_ARM64_CMAKE_VERSION=$(printf '%s\n' "$_android_arm64_text" | sed -nE 's/.*cmake[[:space:]]*\{[[:space:]]*version[[:space:]]*(=|[[:space:]])[^"]*"?([0-9]+(\.[0-9]+)+).*/\2/p; s/.*const[[:space:]]+val[[:space:]]+CMAKE[[:space:]]*=[[:space:]]*"([0-9]+(\.[0-9]+)+)".*/\1/p; s/.*version[[:space:]]*(=|[[:space:]])[^"]*"?([0-9]+(\.[0-9]+)+).*/\2/p' | head -n1)
    if find "$1" -type f \( -name CMakeLists.txt -o -name Android.mk \) -print -quit 2>/dev/null | grep -q . || printf '%s\n' "$_android_arm64_text" | grep -qE 'externalNativeBuild|ndkVersion'; then
        ANDROID_ARM64_NEEDS_NDK=1
    else
        ANDROID_ARM64_NEEDS_NDK=
    fi
}

_android_arm64_verify_ndk() {
    _android_arm64_ndk=$1
    [ -x "$_android_arm64_ndk/toolchains/llvm/prebuilt/linux-aarch64/bin/clang" ] &&
    [ -x "$_android_arm64_ndk/toolchains/llvm/prebuilt/linux-aarch64/bin/clang++" ] &&
    [ -x "$_android_arm64_ndk/toolchains/llvm/prebuilt/linux-aarch64/bin/llvm-ar" ] &&
    [ -x "$_android_arm64_ndk/toolchains/llvm/prebuilt/linux-aarch64/bin/llvm-strip" ] &&
    [ -f "$_android_arm64_ndk/build/cmake/android.toolchain.cmake" ]
}

_android_arm64_install_ndk() {
    _android_arm64_ndk_version=$1
    _android_arm64_ndk_dir="$ANDROID_HOME/ndk/$_android_arm64_ndk_version"
    _android_arm64_verify_ndk "$_android_arm64_ndk_dir" && return 0
    # The manifest is deliberately separate from Gradle: Google's Linux NDK
    # archives contain x86-64 host programs.  Set these three values from the
    # published community release manifest when adding a revision.  Do not add
    # an entry without recording its digest here.
    case "$_android_arm64_ndk_version" in
        29.0.14206865)
            # GNU/Linux host build; do not use the aarch64-linux-android
            # artifact, whose Bionic host executables cannot run on Ubuntu.
            _android_arm64_ndk_url='https://github.com/HomuHomu833/android-ndk-custom/releases/download/r29/android-ndk-r29-aarch64-linux-gnu.tar.xz'
            _android_arm64_ndk_sha256='df6e5ab1986631afe8ed9293577d72fb2bcb96ff54257306210d267204be6073' ;;
        *) echo "Android ARM64 setup: NDK $_android_arm64_ndk_version has no supported ARM64-host release. Refusing Google x86-64 NDK binaries." >&2; return 1 ;;
    esac
    _android_arm64_tmp=$(mktemp -d "${TMPDIR:-/tmp}/android-ndk-arm64.XXXXXX") || return 1
    trap 'rm -rf "$_android_arm64_tmp"' RETURN
    echo "Android ARM64 setup: downloading checksum-pinned NDK $_android_arm64_ndk_version"
    curl --fail --location --retry 3 --output "$_android_arm64_tmp/ndk.tar.xz" "$_android_arm64_ndk_url" || return 1
    printf '%s  %s\n' "$_android_arm64_ndk_sha256" "$_android_arm64_tmp/ndk.tar.xz" | sha256sum --check --status || { echo 'Android ARM64 setup: NDK checksum verification failed.' >&2; return 1; }
    mkdir -p "$_android_arm64_tmp/extract" && tar --no-same-owner -xf "$_android_arm64_tmp/ndk.tar.xz" -C "$_android_arm64_tmp/extract" || return 1
    _android_arm64_ndk_source=$(find "$_android_arm64_tmp/extract" -mindepth 1 -maxdepth 1 -type d -print -quit)
    [ -n "$_android_arm64_ndk_source" ] || { echo 'Android ARM64 setup: NDK archive has no top-level directory.' >&2; return 1; }
    # The bionic-host release calls this host tag linux-arm64; AGP expects the
    # upstream spelling linux-aarch64.  The link is contained in the SDK copy.
    if [ -d "$_android_arm64_ndk_source/toolchains/llvm/prebuilt/linux-arm64" ] && [ ! -e "$_android_arm64_ndk_source/toolchains/llvm/prebuilt/linux-aarch64" ]; then
        ln -s linux-arm64 "$_android_arm64_ndk_source/toolchains/llvm/prebuilt/linux-aarch64"
    fi
    _android_arm64_verify_ndk "$_android_arm64_ndk_source" || { echo 'Android ARM64 setup: downloaded NDK has no Linux ARM64 toolchain.' >&2; return 1; }
    grep -qE "^Pkg.Revision[[:space:]]*=[[:space:]]*$_android_arm64_ndk_version[[:space:]]*$" "$_android_arm64_ndk_source/source.properties" || { echo "Android ARM64 setup: NDK source.properties does not identify $_android_arm64_ndk_version." >&2; return 1; }
    mkdir -p "$ANDROID_HOME/ndk" && mv "$_android_arm64_ndk_source" "$_android_arm64_ndk_dir"
}

_android_arm64_verify_cmake() {
    _android_arm64_cmake_dir=$1
    _android_arm64_cmake_version=$2
    [ -x "$_android_arm64_cmake_dir/bin/cmake" ] &&
    command -v ninja >/dev/null &&
    "$_android_arm64_cmake_dir/bin/cmake" --version 2>/dev/null | grep -q "cmake version $_android_arm64_cmake_version"
}

_android_arm64_install_cmake() {
    _android_arm64_cmake_version=$1
    _android_arm64_cmake_dir="$ANDROID_HOME/cmake/$_android_arm64_cmake_version"
    _android_arm64_verify_cmake "$_android_arm64_cmake_dir" "$_android_arm64_cmake_version" && return 0
    case "$_android_arm64_cmake_version" in
        4.1.0)
            _android_arm64_cmake_url='https://github.com/Kitware/CMake/releases/download/v4.1.0/cmake-4.1.0-linux-aarch64.tar.gz'
            _android_arm64_cmake_sha256='37493fc5d25727342977b19ae0a64df68537fa4317a5f30a65c5b13e6afaad6c' ;;
        *) echo "Android ARM64 setup: CMake $_android_arm64_cmake_version has no supported ARM64-host release." >&2; return 1 ;;
    esac
    _android_arm64_cmake_tmp=$(mktemp -d "${TMPDIR:-/tmp}/android-cmake-arm64.XXXXXX") || return 1
    trap 'rm -rf "$_android_arm64_cmake_tmp"' RETURN
    echo "Android ARM64 setup: downloading checksum-pinned CMake $_android_arm64_cmake_version"
    curl --fail --location --retry 3 --output "$_android_arm64_cmake_tmp/cmake.tar.gz" "$_android_arm64_cmake_url" || return 1
    printf '%s  %s\n' "$_android_arm64_cmake_sha256" "$_android_arm64_cmake_tmp/cmake.tar.gz" | sha256sum --check --status || { echo 'Android ARM64 setup: CMake checksum verification failed.' >&2; return 1; }
    mkdir -p "$_android_arm64_cmake_tmp/extract" && tar --no-same-owner -xf "$_android_arm64_cmake_tmp/cmake.tar.gz" -C "$_android_arm64_cmake_tmp/extract" || return 1
    _android_arm64_cmake_source=$(find "$_android_arm64_cmake_tmp/extract" -mindepth 1 -maxdepth 1 -type d -print -quit)
    [ -n "$_android_arm64_cmake_source" ] || { echo 'Android ARM64 setup: CMake archive has no top-level directory.' >&2; return 1; }
    _android_arm64_verify_cmake "$_android_arm64_cmake_source" "$_android_arm64_cmake_version" || { echo 'Android ARM64 setup: downloaded CMake is not a usable Linux ARM64 CMake release.' >&2; return 1; }
    mkdir -p "$ANDROID_HOME/cmake" && mv "$_android_arm64_cmake_source" "$_android_arm64_cmake_dir"
}

_android_arm64_configure_build_tools() {
    _android_arm64_build_tools_dir="$ANDROID_HOME/build-tools/$1"
    for _android_arm64_tool in aapt aapt2 aidl zipalign split-select; do
        [ -x "/usr/bin/$_android_arm64_tool" ] || { echo "Android ARM64 setup: missing /usr/bin/$_android_arm64_tool" >&2; return 1; }
        ln -sfn "/usr/bin/$_android_arm64_tool" "$_android_arm64_build_tools_dir/$_android_arm64_tool" || return 1
    done
    _android_arm64_add_path "$_android_arm64_build_tools_dir"
}

_android_arm64_activate_project() {
    _android_arm64_root=$(_android_arm64_project_root) || return 0
    _android_arm64_scan_project "$_android_arm64_root"
    if [ -z "$ANDROID_ARM64_AGP" ]; then
        echo "Android ARM64 setup: no Android Gradle Plugin version found in $_android_arm64_root; keeping the current JDK." >&2
    else
        _android_arm64_agp_major=${ANDROID_ARM64_AGP%%.*}
        case "$ANDROID_ARM64_JDK_OVERRIDE" in
            11|17|21) ANDROID_ARM64_JDK=$ANDROID_ARM64_JDK_OVERRIDE ;;
            *) case "$_android_arm64_agp_major" in
                ''|*[!0-9]*) echo "Android ARM64 setup: cannot interpret AGP $ANDROID_ARM64_AGP; keeping the current JDK." >&2 ;;
                8|9|[1-9][0-9]*) ANDROID_ARM64_JDK=17 ;;
                *) ANDROID_ARM64_JDK=11 ;;
            esac ;;
        esac
        _android_arm64_jdk_dir="/usr/lib/jvm/java-${ANDROID_ARM64_JDK}-openjdk-arm64"
        if [ ! -x "$_android_arm64_jdk_dir/bin/java" ]; then
            echo "Android ARM64 setup: installing JDK $ANDROID_ARM64_JDK"
            sudo apt-get update && sudo apt-get install -y --no-install-recommends "openjdk-${ANDROID_ARM64_JDK}-jdk-headless" || return 1
        fi
        [ -x "$_android_arm64_jdk_dir/bin/java" ] || { echo "Android ARM64 setup: JDK $ANDROID_ARM64_JDK installation failed." >&2; return 1; }
        export JAVA_HOME="$_android_arm64_jdk_dir"
        _android_arm64_gradle_option "-Dorg.gradle.java.home=$JAVA_HOME"
    fi
    _android_arm64_add_path "$JAVA_HOME/bin"
    _android_arm64_add_path "$ANDROID_HOME/platform-tools"
    if [ -n "$ANDROID_ARM64_COMPILE_SDK" ]; then
        _android_arm64_platform_id="android-$ANDROID_ARM64_COMPILE_SDK"
        case "$ANDROID_ARM64_COMPILE_SDK" in 37|37.0) _android_arm64_platform_id=android-37.0 ;; esac
        if [ ! -f "$ANDROID_HOME/platforms/$_android_arm64_platform_id/android.jar" ]; then
            echo "Android ARM64 setup: installing platforms;$_android_arm64_platform_id"
            sdkmanager --sdk_root "$ANDROID_HOME" "platforms;$_android_arm64_platform_id" || return 1
        fi
    else
        echo "Android ARM64 setup: no literal compileSdk found; no SDK platform was installed." >&2
    fi
    # API 37 requires an AAPT2 newer than Ubuntu's packaged version. A native
    # ARM64 37.0.0 build is installed by the setup script when first needed.
    if { [ "$ANDROID_ARM64_COMPILE_SDK" = 37 ] || [ "$ANDROID_ARM64_COMPILE_SDK" = 37.0 ]; } && [ -x "$ANDROID_HOME/build-tools/37.0.0/aapt2" ]; then
        _android_arm64_gradle_option "-Dandroid.aapt2FromMavenOverride=$ANDROID_HOME/build-tools/37.0.0/aapt2"
    elif [ "$ANDROID_ARM64_COMPILE_SDK" != 37 ] && [ "$ANDROID_ARM64_COMPILE_SDK" != 37.0 ]; then
        _android_arm64_gradle_option '-Dandroid.aapt2FromMavenOverride=/usr/bin/aapt2'
    fi
    if [ -n "$ANDROID_ARM64_BUILD_TOOLS" ]; then
        if [ ! -f "$ANDROID_HOME/build-tools/$ANDROID_ARM64_BUILD_TOOLS/source.properties" ]; then
            echo "Android ARM64 setup: installing build-tools;$ANDROID_ARM64_BUILD_TOOLS"
            sdkmanager --sdk_root "$ANDROID_HOME" "build-tools;$ANDROID_ARM64_BUILD_TOOLS" || return 1
        fi
        _android_arm64_configure_build_tools "$ANDROID_ARM64_BUILD_TOOLS" || return 1
    fi
    if [ -n "$ANDROID_ARM64_NEEDS_NDK" ]; then
        : "${ANDROID_ARM64_NDK_VERSION:=29.0.14206865}"
        : "${ANDROID_ARM64_CMAKE_VERSION:=$(cmake --version | sed -n '1s/.* //p')}"
        _android_arm64_install_ndk "$ANDROID_ARM64_NDK_VERSION" || return 1
        _android_arm64_install_cmake "$ANDROID_ARM64_CMAKE_VERSION" || return 1
        export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/$ANDROID_ARM64_NDK_VERSION"
        export ANDROID_NDK_ROOT="$ANDROID_NDK_HOME"
        _android_arm64_add_path "$ANDROID_HOME/cmake/$ANDROID_ARM64_CMAKE_VERSION/bin"
        _android_arm64_gradle_option "-Dandroid.ndkVersion=$ANDROID_ARM64_NDK_VERSION"
        _android_arm64_gradle_option "-Dandroid.ndkDirectory=$ANDROID_NDK_HOME"
        _android_arm64_gradle_option "-Dandroid.cmake.version=$ANDROID_ARM64_CMAKE_VERSION"
    else
        unset ANDROID_NDK_HOME ANDROID_NDK_ROOT
    fi
    echo "Android ARM64 setup: project=$_android_arm64_root JDK=${ANDROID_ARM64_JDK:-current} compileSdk=${ANDROID_ARM64_COMPILE_SDK:-not-detected} build-tools=${ANDROID_ARM64_BUILD_TOOLS:-AGP-default} NDK=${ANDROID_ARM64_NDK_VERSION:-none} CMake=${ANDROID_ARM64_CMAKE_VERSION:-none}"
}

_android_arm64_activate_project
unset _android_arm64_dir _android_arm64_files _android_arm64_text _android_arm64_root _android_arm64_agp_major _android_arm64_jdk_dir _android_arm64_build_tools_dir _android_arm64_platform_id _android_arm64_tool _android_arm64_option
'''
write_if_changed(env_file, env_script.replace("__SDK_ROOT__", shlex.quote(sdk)))
source_line = f"[ ! -f {shlex.quote(str(env_file))} ] || . {shlex.quote(str(env_file))}"
managed_block(home / ".bashrc", source_line)
# Bash reads only the first existing login file in this order.
login_file = next((home / name for name in (".bash_profile", ".bash_login", ".profile")
                   if (home / name).exists()), home / ".profile")
managed_block(login_file, source_line)
native_aapt2 = Path(sdk) / "build-tools/37.0.0/aapt2"
properties(home / ".gradle/gradle.properties", {
    "org.gradle.java.home": jdk,
    "android.aapt2FromMavenOverride": str(native_aapt2 if native_aapt2.is_file() else Path("/usr/bin/aapt2")),
})
properties(Path(project) / "local.properties", {"sdk.dir": sdk})
PY

source "$HOME/.config/android-arm64/env.sh"
echo 'Verifying installed tools...'
for jdk_version in 11 17 21; do
    jdk_dir="/usr/lib/jvm/java-${jdk_version}-openjdk-arm64"
    echo "Checking JDK $jdk_version..."
    "$jdk_dir/bin/java" -version
    "$jdk_dir/bin/javac" -version
done
file -L /usr/bin/aapt2 /usr/bin/adb /usr/bin/aidl /usr/bin/zipalign
aapt2 version
adb version
python3 - "$build_tools" <<'PY'
from pathlib import Path
import subprocess
import sys
import tempfile
import zipfile

tools = Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix="android-tool-check-") as directory:
    root = Path(directory)
    source = root / "setupcheck/ISetupCheck.aidl"
    source.parent.mkdir()
    source.write_text("package setupcheck; interface ISetupCheck { void ping(); }\n")
    output = root / "generated"
    output.mkdir()
    subprocess.run([str(tools / "aidl"), "-I" + str(root), "-o" + str(output), str(source)], check=True)
    assert (output / "setupcheck/ISetupCheck.java").is_file(), "AIDL did not generate Java"
    original, aligned = root / "original.zip", root / "aligned.zip"
    with zipfile.ZipFile(original, "w") as archive:
        archive.writestr("check.txt", "native zipalign check\n")
    subprocess.run([str(tools / "zipalign"), "4", str(original), str(aligned)], check=True)
    subprocess.run([str(tools / "zipalign"), "-c", "4", str(aligned)], check=True)
print("AIDL compilation and ZIP alignment checks passed.")
PY
apksigner version
echo
echo 'Tool installation complete. Activate it in an existing terminal with:'
echo '  source "$HOME/.config/android-arm64/env.sh"'
echo 'Build from the project directory with:'
echo '  ./gradlew :app:assembleDebug'