#!/usr/bin/env bash
# Manages ARM64 AVDs with QEMU's ARM system emulator.

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
    [[ -z "$ANDROID_ARM64_AVD_QEMU_BINARY" ]] || _avd_check_qemu "$ANDROID_ARM64_AVD_QEMU_BINARY" || return 1
    _avd_manage create "$1" "$2" || return
    [[ -z "$ANDROID_ARM64_AVD_QEMU_BINARY" ]] || _avd_register_qemu "$ANDROID_ARM64_AVD_QEMU_BINARY"
}

avd_select() {
    [[ -z "$ANDROID_ARM64_AVD_QEMU_BINARY" ]] || _avd_check_qemu "$ANDROID_ARM64_AVD_QEMU_BINARY" || return 1
    _avd_manage select "$1" || return
    [[ -z "$ANDROID_ARM64_AVD_QEMU_BINARY" ]] || _avd_register_qemu "$ANDROID_ARM64_AVD_QEMU_BINARY"
}

avd_tui() {
    python3 "$ANDROID_ARM64_SCRIPT_DIR/lib/android-arm64/emulators/avd_tui.py" "$ANDROID_ARM64_SCRIPT_DIR/setup-android-arm64.sh" "$ANDROID_ARM64_SDK_ROOT"
}

_avd_check_qemu() {
    local binary=$1 devices
    [[ -x "$binary" ]] || { echo "QEMU binary is missing or not executable: $binary" >&2; return 1; }
    python3 - "$binary" <<'PY'
import struct, sys
with open(sys.argv[1], 'rb') as binary:
    header = binary.read(20)
if len(header) < 20 or header[:6] != b'\x7fELF\x02\x01' or struct.unpack_from('<H', header, 18)[0] != 183:
    sys.exit('QEMU binary must be a Linux ARM64 ELF executable.')
PY
    _avd_run_qemu "$binary" --version >/dev/null 2>&1 || { echo "QEMU binary did not run: $binary" >&2; return 1; }
    _avd_run_qemu "$binary" -machine help 2>&1 | grep -q 'virt' || { echo "QEMU binary does not provide the ARM virt machine: $binary" >&2; return 1; }
    devices="$(_avd_run_qemu "$binary" -device help 2>&1 || true)"
    [[ "$devices" == *goldfish_pipe* && "$devices" == *goldfish_fb* ]] || {
        echo 'This QEMU build lacks Android Ranchu devices (goldfish_pipe and goldfish_fb). Use an Android-enabled Linux ARM64 QEMU build with --avd-qemu-binary.' >&2
        return 1
    }
}

_avd_run_qemu() {
    local binary=$1
    shift
    LD_LIBRARY_PATH="$(_avd_qemu_library_path "$binary")" \
        "$binary" "$@"
}

_avd_qemu_library_path() {
    local install_root
    install_root="$(dirname -- "$(dirname -- "$(dirname -- "$(realpath -- "$1")")")")"
    printf '%s\n' "$install_root/lib64:$install_root/lib64/qt/lib:$install_root/lib:$install_root/qemu/linux-aarch64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
}

_avd_register_qemu() {
    _avd_check_qemu "$1" || return 1
    mkdir -p "$(_avd_state)"
    local marker
    marker="$(mktemp "$(_avd_state)/.qemu-binary.XXXXXX")" || return 1
    printf '%s\n' "$(realpath -- "$1")" > "$marker"
    mv -f -- "$marker" "$(_avd_state)/qemu-binary"
    rm -f -- "$(_avd_state)/emulator-package"
}

_avd_check_emulator_package() {
    local launcher=$1 engine root diagnostic
    [[ -x "$launcher" ]] || { echo "Android Emulator launcher is missing: $launcher" >&2; return 1; }
    root="$(dirname -- "$(realpath -- "$launcher")")"
    engine="$root/qemu/linux-aarch64/qemu-system-aarch64"
    [[ -x "$engine" && -f "$root/source.properties" ]] || {
        echo "Incomplete Linux AArch64 Android Emulator package: $root" >&2
        return 1
    }
    python3 - "$launcher" "$engine" <<'PY'
import struct, sys
for path in sys.argv[1:]:
    with open(path, 'rb') as binary:
        header = binary.read(20)
    if len(header) < 20 or header[:6] != b'\x7fELF\x02\x01' or struct.unpack_from('<H', header, 18)[0] != 183:
        sys.exit(f'Expected a Linux AArch64 ELF executable: {path}')
PY
    diagnostic="$("$launcher" -version 2>&1)" || {
        printf 'Android Emulator launcher did not run: %s\n%s\n' "$launcher" "$diagnostic" >&2
        return 1
    }
    diagnostic="$(LD_LIBRARY_PATH="$(_avd_qemu_library_path "$engine")" "$engine" -version 2>&1)" || {
        printf 'Android QEMU engine did not run: %s\n%s\n' "$engine" "$diagnostic" >&2
        return 1
    }
}

_avd_register_emulator_package() {
    local launcher=$1 marker
    _avd_check_emulator_package "$launcher" || return 1
    mkdir -p "$(_avd_state)"
    marker="$(mktemp "$(_avd_state)/.emulator-package.XXXXXX")" || return 1
    printf '%s\n' "$(realpath -- "$launcher")" > "$marker"
    mv -f -- "$marker" "$(_avd_state)/emulator-package"
}

emulator_install() {
    local skip=$1 state binary
    backend_provision_emulator avd "$skip"
    state="$(_avd_state)"
    binary="${ANDROID_ARM64_AVD_QEMU_BINARY:-}"
    if [[ -z "$binary" && -f "$state/emulator-package" ]]; then
        if _avd_check_emulator_package "$(cat "$state/emulator-package")"; then
            echo 'Using registered Android Emulator package.'
            return 0
        fi
    fi
    if [[ -z "$binary" && -f "$state/qemu-binary" ]]; then
        binary="$(cat "$state/qemu-binary")"
        if ! _avd_check_qemu "$binary"; then
            binary=
        fi
    fi
    if [[ -z "$binary" ]]; then
        binary="$(bash "$ANDROID_ARM64_SCRIPT_DIR/lib/android-arm64/emulators/build-android-qemu.sh" \
            "$ANDROID_ARM64_STATE_ROOT" "$ANDROID_ARM64_SCRIPT_DIR")" || return 1
    fi
    _avd_register_qemu "$binary" || return 1
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

_avd_prepare_created_disks() {
    local directory=$1 sysdir=$2 sdk_image="$ANDROID_ARM64_SDK_ROOT/$2" base
    [[ -f "$directory/.android-arm64-created" ]] || return 0
    [[ -f "$directory/userdata-qemu.img.qcow2" ]] && return 0
    if [[ ! -f "$directory/userdata.img" ]]; then
        echo "QEMU cannot initialize this created AVD: $sdk_image has no userdata.img (data/ directory layouts are not yet supported by the QEMU backend)." >&2
        return 1
    fi
    base="$(realpath -- "$directory/userdata.img")"
    qemu-img create -f qcow2 -F raw -b "$base" "$directory/userdata-qemu.img.qcow2" >/dev/null || return 1
    qemu-img create -f qcow2 "$directory/cache.img.qcow2" 256M >/dev/null || return 1
    qemu-img create -f qcow2 "$directory/encryptionkey.img.qcow2" 1M >/dev/null || return 1
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
    [[ -f "$state/name" && -f "$state/sdk-root" ]] || { echo 'AVD boot needs a selected device; run AVD setup first.' >&2; return 1; }
    if [[ -f "$state/emulator-package" ]]; then
        _avd_check_emulator_package "$(_avd_saved emulator-package)" || return 1
    else
        [[ -f "$state/qemu-binary" ]] || { echo 'AVD boot needs a registered emulator or qemu-system-aarch64.' >&2; return 1; }
        _avd_check_qemu "$(_avd_saved qemu-binary)" || return 1
    fi
    name="$(_avd_saved name)"
    sdk="$(_avd_saved sdk-root)"
    [[ -f "$state/home/$name.avd/config.ini" ]] || return 1
    sysdir="$(_avd_config_value "$state/home/$name.avd/config.ini" image.sysdir.1)"
    ANDROID_ARM64_SDK_ROOT=$sdk
    _avd_check_system_image "$sysdir" || return 1
    if [[ ! -f "$state/emulator-package" ]]; then
        _avd_prepare_created_disks "$state/home/$name.avd" "$sysdir" || return 1
        if [[ ! -f "$state/home/$name.avd/.android-arm64-created" ]]; then
            _avd_check_disks "$state/home/$name.avd" || return 1
        fi
    fi
}

_avd_adb_serial() {
    if [[ -f "$(_avd_state)/emulator-package" ]]; then
        printf '%s\n' emulator-5554
    else
        printf '%s\n' 127.0.0.1:5555
    fi
}

_avd_config_value() {
    local config=$1 key=$2
    awk -F= -v key="$key" '{
        name=$1
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
        if (name == key) {
            value=substr($0, index($0, "=") + 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            print value
            exit
        }
    }' "$config"
}

emulator_start() {
    local state binary name log tries pid directory sysdir accel cpu cores memory serial
    local sdk system_image vendor_image kernel ramdisk
    local -a qemu_args
    _avd_runtime_check || return 1
    state="$(_avd_state)"
    if [[ -f "$state/emulator-package" ]]; then
        binary="$(_avd_saved emulator-package)"
    else
        binary="$(_avd_saved qemu-binary)"
    fi
    name="$(_avd_saved name)"
    sdk="$(_avd_saved sdk-root)"
    directory="$state/home/$name.avd"
    log="$state/emulator.log"
    sysdir="$(_avd_config_value "$directory/config.ini" image.sysdir.1)"
    system_image="$sdk/$sysdir/system.img"
    vendor_image="$sdk/$sysdir/vendor.img"
    kernel="$sdk/$sysdir/kernel-ranchu"
    ramdisk="$sdk/$sysdir/ramdisk.img"
    cores="$(_avd_config_value "$directory/config.ini" hw.cpu.ncore)"
    memory="$(_avd_config_value "$directory/config.ini" hw.ramSize)"
    [[ "$cores" =~ ^[1-9][0-9]*$ ]] || cores=4
    [[ "$memory" =~ ^[1-9][0-9]*$ ]] || memory=2048
    [[ -x "$(backend_tool_path adb)" ]] || { echo "Missing adb: $(backend_tool_path adb)" >&2; return 1; }
    serial="$(_avd_adb_serial)"
    if [[ -f "$state/pid" ]] && kill -0 "$(cat "$state/pid")" 2>/dev/null; then
        echo "AVD process is already running; see $log."
    else
        if [[ "$(_avd_adb -s "$serial" get-state 2>/dev/null || true)" == device ]]; then
            echo "ADB device $serial is already in use; stop it before starting this AVD." >&2
            return 1
        fi
        if [[ -f "$state/emulator-package" ]]; then
            local -a emulator_args=(-avd "$name" -ports 5554,5555 -no-snapshot -no-audio -gpu swiftshader_indirect)
            if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
                emulator_args+=(-no-window)
            fi
            nohup env ANDROID_AVD_HOME="$state/home" ANDROID_HOME="$sdk" ANDROID_SDK_ROOT="$sdk" \
                "$binary" "${emulator_args[@]}" > "$log" 2>&1 &
            pid=$!
            printf '%s\n' "$pid" > "$state/pid"
        else
        if [[ -c /dev/kvm && -r /dev/kvm && -w /dev/kvm ]]; then
            accel=kvm; cpu=host
        else
            accel=tcg,thread=multi; cpu=max
            echo 'KVM is unavailable to this user; starting the AVD with TCG software emulation.' >&2
        fi
        qemu_args=(-name "$name" -machine virt,gic-version=3 -accel "$accel" -cpu "$cpu"
            -smp "$cores" -m "$memory" -kernel "$kernel" -initrd "$ramdisk"
            -append 'console=ttyAMA0 androidboot.hardware=ranchu androidboot.adb.tcp.port=5555'
            -drive "if=none,id=system,format=raw,readonly=on,file=$system_image" -device virtio-blk-device,drive=system
            -drive "if=none,id=vendor,format=raw,readonly=on,file=$vendor_image" -device virtio-blk-device,drive=vendor
            -drive "if=none,id=userdata,format=qcow2,file=$directory/userdata-qemu.img.qcow2" -device virtio-blk-device,drive=userdata
            -drive "if=none,id=cache,format=qcow2,file=$directory/cache.img.qcow2" -device virtio-blk-device,drive=cache
            -drive "if=none,id=encryptionkey,format=qcow2,file=$directory/encryptionkey.img.qcow2" -device virtio-blk-device,drive=encryptionkey
            -netdev user,id=net0,hostfwd=tcp:127.0.0.1:5555-:5555 -device virtio-net-device,netdev=net0
            -device virtio-gpu-pci -display gtk,gl=off -serial "file:$state/serial.log" -no-reboot)
        nohup env LD_LIBRARY_PATH="$(_avd_qemu_library_path "$binary")" \
            "$binary" "${qemu_args[@]}" > "$log" 2>&1 &
        pid=$!
        printf '%s\n' "$pid" > "$state/pid"
        fi
    fi
    for ((tries = 0; tries < 300; tries++)); do
        if [[ "$serial" == 127.0.0.1:5555 ]]; then
            _avd_adb connect "$serial" >/dev/null 2>&1 || true
        fi
        if [[ "$(_avd_adb -s "$serial" get-state 2>/dev/null || true)" == device ]] \
            && [[ "$(_avd_adb -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == 1 ]]; then
            echo "AVD booted as $serial."
            return 0
        fi
        kill -0 "$(cat "$state/pid")" 2>/dev/null || break
        sleep 2
    done
    echo "AVD did not finish booting; read $log and $state/serial.log, then run setup-android-arm64.sh --emulator-doctor avd." >&2
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
    _avd_adb -s "$(_avd_adb_serial)" get-state 2>&1 || true
    [[ ! -f "$state/emulator.log" ]] || tail -n 60 "$state/emulator.log"
    [[ ! -f "$state/serial.log" ]] || tail -n 60 "$state/serial.log"
}

emulator_environment() {
    cat <<'EOF'
# Android AVD QEMU helpers.
android_arm64_emulator_start() { "$ANDROID_ARM64_LAUNCHER" --emulator-start avd; }
android_arm64_emulator_doctor() { "$ANDROID_ARM64_LAUNCHER" --emulator-doctor avd; }
android_arm64_emulator_serial() {
    if [[ -f "$ANDROID_ARM64_STATE_ROOT/avd/emulator-package" ]]; then
        printf '%s\n' emulator-5554
    else
        printf '%s\n' 127.0.0.1:5555
    fi
}
android_arm64_emulator_status() { adb -s "$(android_arm64_emulator_serial)" get-state; }
android_arm64_emulator_stop() {
    local state="$ANDROID_ARM64_STATE_ROOT/avd"
    if [[ -f "$state/pid" ]]; then
        kill "$(cat "$state/pid")" 2>/dev/null || true
        rm -f "$state/pid"
    fi
}
android_arm64_emulator_connect() {
    local serial
    serial="$(android_arm64_emulator_serial)"
    [[ "$serial" != 127.0.0.1:5555 ]] || adb connect "$serial" >/dev/null 2>&1 || true
    [[ "$(adb -s "$serial" get-state 2>/dev/null || true)" == device ]] || {
        echo "AVD is not connected as $serial; run android_arm64_emulator_start." >&2
        return 1
    }
}
android_arm64_emulator_install() {
    local apk=${1:-}
    [[ $# -eq 1 && -f "$apk" ]] || { echo 'Usage: android_arm64_emulator_install /path/to/app.apk' >&2; return 2; }
    android_arm64_emulator_connect && adb -s "$(android_arm64_emulator_serial)" install -r "$apk"
}
android_arm64_emulator_launch() {
    local package=${1:-}
    [[ $# -eq 1 && -n "$package" ]] || { echo 'Usage: android_arm64_emulator_launch <package.name>' >&2; return 2; }
    android_arm64_emulator_connect && adb -s "$(android_arm64_emulator_serial)" shell monkey -p "$package" -c android.intent.category.LAUNCHER 1
}
android_arm64_emulator_logcat() { android_arm64_emulator_connect && adb -s "$(android_arm64_emulator_serial)" logcat "$@"; }
EOF
}
