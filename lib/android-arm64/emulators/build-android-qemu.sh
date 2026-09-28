#!/usr/bin/env bash
# Fetch and build the pinned Android QEMU engine for a Linux ARM64 host.
set -Eeuo pipefail

state_root=${1:?Usage: build-android-qemu.sh STATE_ROOT SCRIPT_DIR}
script_dir=${2:?Usage: build-android-qemu.sh STATE_ROOT SCRIPT_DIR}
lock="$script_dir/lib/android-arm64/emulators/android-qemu.lock"
repository=$(awk -F= '$1 == "repository" {print $2}' "$lock")
revision=$(awk -F= '$1 == "revision" {print $2}' "$lock")
manifest_branch=$(awk -F= '$1 == "manifest_branch" {print $2}' "$lock")
target=$(awk -F= '$1 == "target" {print $2}' "$lock")
source_root="$state_root/cache/android-qemu/source"
build_root="$state_root/cache/android-qemu/build"
install_root="$state_root/avd/qemu/$revision"
binary="$install_root/qemu/linux-aarch64/qemu-system-aarch64"

[[ "$(uname -m)" == aarch64 ]] || { echo 'Android QEMU builder requires a Linux AArch64 host.' >&2; exit 1; }
for tool in repo git python3 cmake ninja make; do
    command -v "$tool" >/dev/null || { echo "Missing Android QEMU build tool: $tool" >&2; exit 1; }
done

if [[ -x "$binary" && -f "$install_root/.source-revision" ]] \
    && [[ "$(cat "$install_root/.source-revision")" == "$revision" ]]; then
    printf '%s\n' "$binary"
    exit 0
fi

mkdir -p "$(dirname "$source_root")" "$build_root"
build_log="$build_root/build.log"
run_logged() {
    local description=$1
    shift
    printf '%s\n' "$description" >&2
    if ! "$@" >>"$build_log" 2>&1; then
        tail -n 80 "$build_log" >&2 || true
        return 1
    fi
}
if [[ ! -d "$source_root/.repo" ]]; then
    mkdir -p "$source_root"
    run_logged 'Initializing Android QEMU source checkout.' \
        bash -c 'cd "$1" && repo init -u https://android.googlesource.com/platform/manifest -b "$2" --depth=1 --partial-clone --clone-filter=blob:limit=10M --repo-rev=v2.50' _ "$source_root" "$manifest_branch"
    run_logged 'Synchronizing Android QEMU source projects.' \
        bash -c 'cd "$1" && repo sync -c -j "$2"' _ "$source_root" "${ANDROID_QEMU_SYNC_JOBS:-4}"
    run_logged 'Recording the resolved Android source manifest.' \
        bash -c 'cd "$1" && repo manifest -r -o "$2"' _ "$source_root" "$state_root/cache/android-qemu/manifest.lock.xml"
fi

qemu_source="$source_root/external/qemu"
[[ -e "$qemu_source/.git" ]] || { echo "Android Emulator source project is missing: $qemu_source" >&2; exit 1; }
run_logged 'Fetching the pinned Android QEMU revision.' git -C "$qemu_source" fetch --no-tags "$repository" "$revision"
run_logged 'Checking out the pinned Android QEMU revision.' git -C "$qemu_source" checkout --detach "$revision"
run_logged 'Updating Android QEMU submodules.' git -C "$qemu_source" submodule update --init --recursive

if [[ -f "$source_root/.repo/repo/repo" ]]; then
    run_logged 'Refreshing the resolved Android source manifest.' \
        bash -c 'cd "$1" && repo manifest -r -o "$2"' _ "$source_root" "$state_root/cache/android-qemu/manifest.lock.xml"
fi

rm -rf "$build_root/objs"
run_logged 'Building Android QEMU for the Linux AArch64 host (this can take a while).' \
    env ANDROID_BUILD_TOP="$source_root" "$qemu_source/android/rebuild.sh" \
    --target="$target" --out-dir="$build_root/objs" --no-tests

built_binary="$build_root/objs/qemu/linux-aarch64/qemu-system-aarch64"
[[ -x "$built_binary" ]] || {
    echo "Android QEMU build did not produce the expected ARM64 engine: $built_binary" >&2
    find "$build_root/objs" -type f -name qemu-system-aarch64 -print >&2 2>/dev/null || true
    exit 1
}

stage="$state_root/avd/qemu/.${revision}.partial"
rm -rf "$stage"
mkdir -p "$stage"
cp -a "$build_root/objs/." "$stage/"
printf '%s\n' "$revision" > "$stage/.source-revision"
mkdir -p "$(dirname "$install_root")"
if [[ -e "$install_root" ]]; then
    mv "$install_root" "$install_root.invalid.$(date +%s)"
fi
mv "$stage" "$install_root"

[[ -x "$binary" ]] || { echo "Installed Android QEMU binary is missing: $binary" >&2; exit 1; }
printf '%s\n' "$binary"
