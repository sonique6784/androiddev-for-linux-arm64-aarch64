#!/usr/bin/env bash
# Rebuild the Android Emulator ARM64 QEMU target from the prepared shallow
# Repo checkout using the host-specific workarounds that produced our binary.
set -Eeuo pipefail

die() { printf 'android-qemu-build: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
state_root=${ANDROID_QEMU_STATE_ROOT:-"$script_dir/.android-qemu-build-state"}
source_root=${ANDROID_QEMU_SOURCE_ROOT:-"$state_root/cache/android-qemu/source"}
if [[ -n "${ANDROID_QEMU_BUILD_DIR:-}" ]]; then
    build_dir=$ANDROID_QEMU_BUILD_DIR
else
    build_state_link=${ANDROID_QEMU_BUILD_LINK:-"${TMPDIR:-/tmp}/android-qemu-build-state"}
    mkdir -p "$(dirname -- "$build_state_link")"
    if [[ -L "$build_state_link" ]]; then
        link_target=$(readlink -f -- "$build_state_link")
        state_target=$(readlink -f -- "$state_root")
        [[ "$link_target" == "$state_target" ]] || die "Build path shortcut points elsewhere: $build_state_link -> $link_target"
    elif [[ -e "$build_state_link" ]]; then
        die "Build path shortcut already exists and is not a symlink: $build_state_link"
    else
        ln -s -- "$state_root" "$build_state_link"
    fi
    build_dir="$build_state_link/cache/android-qemu/build/objs3"
fi
expected_revision=${ANDROID_QEMU_REVISION:-ae9d18d2b6261179fbd57fffec720a04f7bfb053}
jobs=${ANDROID_QEMU_JOBS:-2}

[[ "$(uname -m)" == aarch64 ]] || die 'Run this script on a Linux AArch64 host.'
for tool in git python3 cmake ninja file; do need "$tool"; done
[[ -d "$source_root/.repo" ]] || die "Shallow Android Repo checkout not found at $source_root. See ANDROID-QEMU-BUILD-REPRO.md for the depth-1 Repo setup."
qemu_checkout="$source_root/external/qemu"
[[ -d "$qemu_checkout/.git" || -f "$qemu_checkout/.git" ]] || die "QEMU project missing from checkout: $qemu_checkout"

actual_revision=$(git -C "$qemu_checkout" rev-parse HEAD)
[[ "$actual_revision" == "$expected_revision" ]] || die "Expected QEMU revision $expected_revision, found $actual_revision. Set ANDROID_QEMU_REVISION only if you have verified another revision."

# Reuse the source path recorded in an existing CMake cache so reruns don't
# invalidate a configured build. Otherwise use a no-space view under /tmp.
if [[ -n "${ANDROID_QEMU_SOURCE_VIEW:-}" ]]; then
    source_view=$ANDROID_QEMU_SOURCE_VIEW
else
    cached_source=$(sed -n 's/^CMAKE_HOME_DIRECTORY:INTERNAL=//p' "$build_dir/CMakeCache.txt" 2>/dev/null | head -n 1 || true)
    if [[ "$cached_source" == */external/qemu && -d "${cached_source%/external/qemu}" ]]; then
        source_view=${cached_source%/external/qemu}
    elif [[ -d "$HOME/android-qemu-source-nospace/external/qemu" ]]; then
        source_view="$HOME/android-qemu-source-nospace"
    else
        source_view="${TMPDIR:-/tmp}/android-qemu-source-nospace"
    fi
fi

if [[ ! -d "$source_view/external/qemu" ]]; then
    [[ ! -e "$source_view" ]] || die "Source view exists but is incomplete: $source_view (choose another with ANDROID_QEMU_SOURCE_VIEW)."
    mkdir -p "$source_view"
    if ! cp -al "$source_root/." "$source_view/"; then
        die "Could not hardlink source into $source_view. Set ANDROID_QEMU_SOURCE_VIEW to a location on the same filesystem as $source_root."
    fi
fi

view_qemu="$source_view/external/qemu"
view_revision=$(git -C "$view_qemu" rev-parse HEAD)
[[ "$view_revision" == "$expected_revision" ]] || die "Source view is at $view_revision, expected $expected_revision. Remove/recreate it or set ANDROID_QEMU_SOURCE_VIEW."

qt_root="$source_view/prebuilts/android-emulator-build/qt"
common_root="$source_view/prebuilts/android-emulator-build/common"
for path in \
    "$qt_root/linux-aarch64/lib/libQt6DBusAndroidEmu.so" \
    "$qt_root/linux-aarch64/libexec/moc" \
    "$qt_root/linux-aarch64/libexec/uic" \
    "$qt_root/linux-aarch64/libexec/rcc" \
    "$common_root/ffmpeg/linux-aarch64/lib/libavcodec.a" \
    "$common_root/libvpx/linux-aarch64/lib/libvpx.a" \
    "$common_root/x264/linux-aarch64/lib/libx264.a" \
    "$common_root/swiftshader/linux-aarch64" \
    "$common_root/virtualscene"; do
    [[ -e "$path" ]] || die "Required shallow-checkout project or prebuilt is missing: $path. Sync prebuilts/android-emulator-build/qt and prebuilts/android-emulator-build/common in the depth-1 Repo checkout, then recreate the no-space view."
done

# These prebuilt Qt tools are ARM64 host tools. CMake's Linux host lookup is
# hard-coded to linux-x86_64 in this Android Emulator branch.
for tool in moc uic rcc; do
    host_tool_dir="$qt_root/linux-x86_64/libexec"
    mkdir -p "$host_tool_dir"
    ln -sfn "../../linux-aarch64/libexec/$tool" "$host_tool_dir/$tool"
done

# The tcmalloc package provides only the versioned runtime soname. Install it
# atomically into the isolated view and supply the unversioned linker name.
tcmalloc_dir="$common_root/tcmalloc/linux-aarch64/lib"
tcmalloc="$tcmalloc_dir/libtcmalloc_minimal.so.4"
mkdir -p "$tcmalloc_dir"
if [[ ! -f "$tcmalloc" ]]; then
    for candidate in \
        /usr/lib/aarch64-linux-gnu/libtcmalloc_minimal.so.4 \
        /lib/aarch64-linux-gnu/libtcmalloc_minimal.so.4; do
        if [[ -f "$candidate" ]]; then
            temp="$tcmalloc.tmp.$$"
            cp -L "$candidate" "$temp"
            mv -f "$temp" "$tcmalloc"
            break
        fi
    done
fi
[[ -f "$tcmalloc" ]] || die 'libtcmalloc_minimal.so.4 not found. Install libtcmalloc-minimal4t64 (arm64); see ANDROID-QEMU-BUILD-REPRO.md.'
ln -sfn libtcmalloc_minimal.so.4 "$tcmalloc_dir/libtcmalloc_minimal.so"

# GCC on this host needs the thread header explicitly. Replace atomically so
# a hardlinked source checkout is never modified.
snapshotter=$(find "$source_view" -type f -name Snapshotter.cpp -print -quit)
[[ -n "$snapshotter" ]] || die 'Could not locate Snapshotter.cpp in the shallow checkout.'
python3 - "$snapshotter" <<'PY'
import os
import stat
import sys
import tempfile

path = sys.argv[1]
with open(path, encoding="utf-8") as source:
    text = source.read()
if "#include <thread>" not in text:
    mode = stat.S_IMODE(os.stat(path).st_mode)
    directory = os.path.dirname(path)
    fd, temporary = tempfile.mkstemp(prefix=".Snapshotter.cpp.", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            output.write("#include <thread>\n")
            output.write(text)
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
PY

# CMake generates this file in the source tree. Unlink it from the hardlink
# view first, if a previous configure created it.
rm -f "$source_view/external/libslirp/src/libslirp-version.h"

toolchain="$view_qemu/android/build/cmake/toolchain-linux-aarch64.cmake"
[[ -f "$toolchain" ]] || die "AArch64 CMake toolchain is missing: $toolchain"
mkdir -p "$build_dir"
dbus_lib="$qt_root/linux-aarch64/lib/libQt6DBusAndroidEmu.so"
python_bin=$(command -v python3)
ninja_bin=$(command -v ninja)

printf 'Configuring Android Emulator QEMU from %s\n' "$view_qemu"
cmake -B "$build_dir" \
    -G Ninja \
    -DOPTION_CRASHUPLOAD=NONE \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_FLAGS= \
    -DCMAKE_EXE_LINKER_FLAGS= \
    -DCMAKE_CXX_STANDARD_LIBRARIES="$dbus_lib" \
    -DCMAKE_TOOLCHAIN_FILE="$toolchain" \
    -DOPTION_SDK_TOOLS_BUILD_NUMBER=standalone-0 \
    -DPython_EXECUTABLE="$python_bin" \
    -DOPTION_SDK_TOOLS_REVISION=35.6.3 \
    -DOPTION_TEST_LOGS="$build_dir/testlogs" \
    -DCMAKE_MAKE_PROGRAM="$ninja_bin" \
    -DGFXSTREAM=FALSE \
    "$view_qemu"

printf 'Building qemu-system-aarch64 with %s Ninja jobs\n' "$jobs"
ENV_CACHE_RUNTIME_OS_DEPENDENCIES='/usr/lib/aarch64-linux-gnu/libstdc++.so.6>lib64/libstdc++.so.6' \
    CMAKE_BUILD_PARALLEL_LEVEL=1 \
    "$ninja_bin" -C "$build_dir" -j"$jobs" qemu-system-aarch64

binary="$build_dir/qemu/linux-aarch64/qemu-system-aarch64"
[[ -x "$binary" ]] || die "Build completed without producing $binary"
file "$binary"
if ! file "$binary" | grep -qi 'ARM aarch64'; then
    die "Output is not an ARM64 executable: $binary"
fi
runtime_libs="$build_dir/lib64:$qt_root/linux-aarch64/lib"
printf '\nBuilt emulator version:\n'
LD_LIBRARY_PATH="$runtime_libs${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$binary" -version
printf '\nBinary: %s\n' "$binary"
