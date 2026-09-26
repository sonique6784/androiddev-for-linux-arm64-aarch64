#!/usr/bin/env bash
# Manages ARM64 AVDs for a native Android Emulator build.

_avd_state() { printf '%s/avd\n' "$ANDROID_ARM64_STATE_ROOT"; }
_avd_saved() { cat "$(_avd_state)/$1"; }
_avd_adb() {
    local sysroot
    if [[ "$ANDROID_ARM64_PLATFORM" == debian ]]; then
        sysroot="$ANDROID_ARM64_STATE_ROOT/host/debian/sysroot/usr"
        LD_LIBRARY_PATH="$sysroot/lib/aarch64-linux-gnu/android:$sysroot/lib:${LD_LIBRARY_PATH:-}" \
            "$(backend_tool_path adb)" "$@"
    else
        "$(backend_tool_path adb)" "$@"
    fi
}

emulator_validate() { :; }

_avd_manage() {
    python3 "$ANDROID_ARM64_SCRIPT_DIR/lib/android-arm64/emulators/avd_manage.py" "$1" "$ANDROID_ARM64_STATE_ROOT" "$ANDROID_ARM64_SDK_ROOT" "${@:2}"
}

avd_list_images() {
    local -a args=(list "$ANDROID_ARM64_SDK_ROOT")
    [[ "$ANDROID_ARM64_JSON" == false ]] || args+=(--json)
    python3 "$ANDROID_ARM64_SCRIPT_DIR/lib/android-arm64/emulators/avd_image.py" "${args[@]}"
}

avd_list() { _avd_manage list; }

avd_create() {
    if [[ -n "$ANDROID_ARM64_AVD_EMULATOR_BINARY" ]]; then
        _avd_check_binary "$ANDROID_ARM64_AVD_EMULATOR_BINARY"
    fi
    _avd_manage create "$1" "$2"
    if [[ -n "$ANDROID_ARM64_AVD_EMULATOR_BINARY" ]]; then
        _avd_register_binary "$ANDROID_ARM64_AVD_EMULATOR_BINARY"
    fi
}

avd_select() {
    if [[ -n "$ANDROID_ARM64_AVD_EMULATOR_BINARY" ]]; then
        _avd_check_binary "$ANDROID_ARM64_AVD_EMULATOR_BINARY"
    fi
    _avd_manage select "$1"
    if [[ -n "$ANDROID_ARM64_AVD_EMULATOR_BINARY" ]]; then
        _avd_register_binary "$ANDROID_ARM64_AVD_EMULATOR_BINARY"
    fi
}

avd_tui() {
    python3 "$ANDROID_ARM64_SCRIPT_DIR/lib/android-arm64/emulators/avd_tui.py" "$ANDROID_ARM64_SCRIPT_DIR/setup-android-arm64.sh" "$ANDROID_ARM64_SDK_ROOT"
}

_avd_check_binary() {
    local binary=$1 version
    [[ -x "$binary" ]] || { echo "AVD emulator binary is missing or not executable: $binary" >&2; return 1; }
    python3 - "$binary" <<'PY'
import struct, sys
with open(sys.argv[1], 'rb') as binary:
    header = binary.read(20)
if len(header) < 20 or header[:6] != b'\x7fELF\x02\x01' or struct.unpack_from('<H', header, 18)[0] != 183:
    sys.exit('AVD emulator binary must be a Linux ARM64 ELF executable.')
PY
    version="$("$binary" -version 2>&1)" || {
        echo "Native Android Emulator did not run: $binary" >&2
        return 1
    }
    [[ "${version,,}" == *'android emulator version'* ]] || {
        echo "Not a Google Android Emulator build: $binary" >&2
        return 1
    }
}

_avd_register_binary() {
    _avd_check_binary "$1"
    mkdir -p "$(_avd_state)"
    printf '%s\n' "$(realpath -- "$1")" > "$(_avd_state)/binary"
}

emulator_install() {
    local skip=$1 state binary
    [[ -r /dev/kvm && -w /dev/kvm ]] || { echo 'AVD requires usable /dev/kvm for this Linux ARM64 user.' >&2; return 1; }
    backend_provision_emulator avd "$skip"
    state="$(_avd_state)"
    binary="${ANDROID_ARM64_AVD_EMULATOR_BINARY:-}"
    if [[ -z "$binary" && -f "$state/binary" ]]; then
        binary="$(_avd_saved binary)"
    fi
    [[ -n "$binary" ]] || {
        echo 'AVD boot requires --avd-emulator-binary /absolute/path/to/a/native/linux-arm64/emulator. No supported Linux ARM64 SDK emulator binary is bundled.' >&2
        return 1
    }
    _avd_register_binary "$binary"
}

_avd_inspect_source() {
    local ini=$1
    [[ -f "$ini" ]] || { echo "AVD .ini file is missing: $ini" >&2; return 1; }
    python3 - "$ini" <<'PY'
from pathlib import Path
import sys

ini = Path(sys.argv[1]).resolve()
def properties(path):
    return dict(line.split('=', 1) for line in path.read_text().splitlines()
                if '=' in line and not line.lstrip().startswith('#'))

outer = properties(ini)
relative = outer.get('path.rel', '')
avd = (ini.parent / relative).resolve() if relative else Path(outer.get('path', '').replace('~/', str(Path.home()) + '/', 1)).resolve()
if not avd.is_dir() or not (avd / 'config.ini').is_file():
    sys.exit(f'AVD directory or config.ini is missing: {avd}')
config = properties(avd / 'config.ini')
name = config.get('AvdId', '')
if not name or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-' for c in name):
    sys.exit(f'Unsupported AVD identifier: {name!r}')
if config.get('abi.type') != 'arm64-v8a' or config.get('hw.cpu.arch') != 'arm64':
    sys.exit('This AVD import requires an arm64-v8a Android system image.')
sysdir = config.get('image.sysdir.1', '').strip('/')
parts = sysdir.split('/')
if len(parts) != 4 or parts[0] != 'system-images' or parts[3] != 'arm64-v8a' or any(p in ('', '.', '..') for p in parts):
    sys.exit(f'Unsupported AVD system image path: {sysdir!r}')
if any('\n' in value for value in (str(ini), str(avd), name, sysdir)):
    sys.exit('Newlines in AVD paths are not supported.')
print(name)
print(avd)
print(sysdir)
PY
}

_avd_check_disks() {
    local directory=$1 image
    for image in userdata-qemu.img.qcow2 encryptionkey.img.qcow2 cache.img.qcow2; do
        [[ -f "$directory/$image" ]] || { echo "AVD disk is missing: $directory/$image" >&2; return 1; }
        qemu-img info -U --backing-chain --output=json "$directory/$image" | python3 -c '
import json, os, sys
root = os.path.realpath(sys.argv[1]) + os.sep
chain = json.load(sys.stdin)
if not chain or chain[0].get("format") != "qcow2":
    sys.exit("AVD writable disk is not qcow2")
for item in chain:
    filename = os.path.realpath(item["filename"])
    if not filename.startswith(root) or not os.path.isfile(filename):
        sys.exit("AVD backing chain escapes its directory or has a missing file: " + filename)
' "$directory" || return 1
    done
}

_avd_check_system_image() {
    local sysdir=$1 directory="$ANDROID_ARM64_SDK_ROOT/$1" part
    for part in kernel-ranchu ramdisk.img system.img vendor.img; do
        [[ -f "$directory/$part" ]] || { echo "AVD system image is missing $directory/$part" >&2; return 1; }
    done
}

emulator_init() {
    local state ini metadata name source sysdir package staging home
    local -a fields
    state="$(_avd_state)"
    ini="${ANDROID_ARM64_AVD_INI:-}"
    if [[ -z "$ini" && -f "$state/active-origin" && "$(_avd_saved active-origin)" == created ]]; then
        [[ -f "$state/name" && -f "$state/home/$(_avd_saved name).avd/config.ini" ]] || { echo 'The selected AVD is missing; use --avd-select NAME.' >&2; return 1; }
        ANDROID_ARM64_SDK_ROOT="$(_avd_saved sdk-root)"
        return 0
    fi
    if [[ -z "$ini" && -f "$state/source-ini" ]]; then
        ini="$(_avd_saved source-ini)"
    fi
    [[ -n "$ini" ]] || { echo 'AVD import requires --avd-ini /absolute/path/name.ini.' >&2; return 2; }
    metadata="$(_avd_inspect_source "$ini")" || return 1
    mapfile -t fields <<< "$metadata"
    name=${fields[0]}
    source=${fields[1]}
    sysdir=${fields[2]}
    _avd_check_disks "$source" || return 1
    package="${sysdir//\//;}"
    if [[ ! -f "$ANDROID_ARM64_SDK_ROOT/$sysdir/system.img" ]]; then
        echo "Resolving required AVD SDK image: $package"
        python3 "$ANDROID_ARM64_SCRIPT_DIR/lib/android-arm64/emulators/avd_image.py" "$ANDROID_ARM64_SDK_ROOT" "$package" "$ANDROID_ARM64_STATE_ROOT/cache/avd-images" || {
            echo "The matching SDK system image could not be installed: $package. The original AVD was not changed." >&2
            return 1
        }
    fi
    _avd_check_system_image "$sysdir" || return 1

    home="$state/home"
    if [[ -e "$home/$name.avd" ]]; then
        [[ -f "$state/source-ini" && "$(realpath -- "$ini")" == "$(_avd_saved source-ini)" ]] || {
            echo "A different AVD named $name is already staged at $home; its data was not replaced." >&2
            return 1
        }
    else
        mkdir -p "$home"
        staging="$home/.$name.avd.partial"
        [[ ! -e "$staging" ]] || { echo "An incomplete AVD import exists at $staging; inspect it before retrying." >&2; return 1; }
        python3 - "$source" "$staging" <<'PY'
from pathlib import Path
import shutil, sys
source, target = map(Path, sys.argv[1:])
if any(p.is_symlink() for p in source.rglob('*')):
    sys.exit('AVD contains symbolic links; refusing to stage data with external dependencies.')
shutil.copytree(source, target, ignore=shutil.ignore_patterns('hardware-qemu.ini', 'emu-launch-params.txt'))
PY
        mv -- "$staging" "$home/$name.avd"
    fi
    cat > "$home/$name.ini" <<EOF
avd.ini.encoding=UTF-8
path=$home/$name.avd
path.rel=$name.avd
target=$(awk -F= '$1 == "target" {print substr($0, index($0, "=") + 1); exit}' "$source/config.ini")
EOF
    printf '%s\n' "$(realpath -- "$ini")" > "$state/source-ini"
    printf '%s\n' "$name" > "$state/name"
    printf '%s\n' "$ANDROID_ARM64_SDK_ROOT" > "$state/sdk-root"
    printf '%s\n' imported > "$state/active-origin"
    _avd_check_disks "$home/$name.avd"
}

_avd_runtime_check() {
    local state name sdk sysdir
    state="$(_avd_state)"
    [[ -r /dev/kvm && -w /dev/kvm ]] || { echo 'AVD requires usable /dev/kvm for this Linux ARM64 user.' >&2; return 1; }
    [[ -f "$state/name" && -f "$state/sdk-root" && -f "$state/binary" ]] || { echo 'AVD boot needs a selected device and a registered native emulator binary; use --avd-select NAME --avd-emulator-binary PATH.' >&2; return 1; }
    _avd_check_binary "$(_avd_saved binary)" || return 1
    name="$(_avd_saved name)"
    sdk="$(_avd_saved sdk-root)"
    [[ -f "$state/home/$name.avd/config.ini" ]] || return 1
    sysdir="$(awk -F= '$1 == "image.sysdir.1" {print substr($0, index($0, "=") + 1); exit}' "$state/home/$name.avd/config.ini")"
    ANDROID_ARM64_SDK_ROOT=$sdk
    _avd_check_system_image "$sysdir" || return 1
    if [[ ! -f "$state/home/$name.avd/.android-arm64-created" ]]; then
        _avd_check_disks "$state/home/$name.avd" || return 1
    fi
}

emulator_start() {
    local state binary name log tries serial=emulator-5580 pid
    _avd_runtime_check || return 1
    state="$(_avd_state)"
    binary="$(_avd_saved binary)"
    name="$(_avd_saved name)"
    log="$state/emulator.log"
    [[ -x "$(backend_tool_path adb)" ]] || { echo "Missing adb: $(backend_tool_path adb)" >&2; return 1; }
    if [[ -f "$state/pid" ]] && kill -0 "$(cat "$state/pid")" 2>/dev/null; then
        echo "AVD process is already running; see $log."
    else
        if [[ "$(_avd_adb -s "$serial" get-state 2>/dev/null || true)" == device ]]; then
            echo "ADB serial $serial is already in use; stop that emulator before starting this AVD." >&2
            return 1
        fi
        ANDROID_HOME="$ANDROID_ARM64_SDK_ROOT" ANDROID_SDK_ROOT="$ANDROID_ARM64_SDK_ROOT" \
            ANDROID_AVD_HOME="$state/home" nohup "$binary" -avd "$name" -no-snapshot -accel on -port 5580 -gpu software > "$log" 2>&1 &
        pid=$!
        printf '%s\n' "$pid" > "$state/pid"
    fi
    for ((tries = 0; tries < 120; tries++)); do
        if [[ "$(_avd_adb -s "$serial" get-state 2>/dev/null || true)" == device ]] \
            && [[ "$(_avd_adb -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == 1 ]]; then
            echo "AVD booted as $serial."
            return 0
        fi
        kill -0 "$(cat "$state/pid")" 2>/dev/null || break
        sleep 2
    done
    echo "AVD did not finish booting; read $log and run setup-android-arm64.sh --emulator-doctor avd." >&2
    return 1
}

emulator_doctor() {
    local state
    state="$(_avd_state)"
    _avd_runtime_check || return 1
    if [[ -f "$state/pid" ]] && kill -0 "$(cat "$state/pid")" 2>/dev/null; then
        echo "AVD process running as PID $(cat "$state/pid")."
    else
        echo 'AVD process is not running.'
    fi
    _avd_adb -s emulator-5580 get-state 2>&1 || true
    [[ ! -f "$state/emulator.log" ]] || tail -n 60 "$state/emulator.log"
}

emulator_environment() {
    cat <<'EOF'
# Android AVD emulator helpers.
android_arm64_emulator_start() { "$ANDROID_ARM64_LAUNCHER" --emulator-start avd; }
android_arm64_emulator_doctor() { "$ANDROID_ARM64_LAUNCHER" --emulator-doctor avd; }
android_arm64_emulator_status() { adb -s emulator-5580 get-state; }
android_arm64_emulator_stop() { adb -s emulator-5580 emu kill; }
android_arm64_emulator_connect() {
    [[ "$(adb -s emulator-5580 get-state 2>/dev/null || true)" == device ]] || {
        echo 'AVD is not connected as emulator-5580; run android_arm64_emulator_start.' >&2
        return 1
    }
}
android_arm64_emulator_install() {
    local apk=${1:-}
    [[ $# -eq 1 && -f "$apk" ]] || { echo 'Usage: android_arm64_emulator_install /path/to/app.apk' >&2; return 2; }
    android_arm64_emulator_connect && adb -s emulator-5580 install -r "$apk"
}
android_arm64_emulator_launch() {
    local package=${1:-}
    [[ $# -eq 1 && -n "$package" ]] || { echo 'Usage: android_arm64_emulator_launch <package.name>' >&2; return 2; }
    android_arm64_emulator_connect && adb -s emulator-5580 shell monkey -p "$package" -c android.intent.category.LAUNCHER 1
}
android_arm64_emulator_logcat() { android_arm64_emulator_connect && adb -s emulator-5580 logcat "$@"; }
EOF
}
