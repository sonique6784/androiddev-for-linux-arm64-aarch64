#!/usr/bin/env bash

# Arch Linux ARM is rolling release and uses ID=archarm, without VERSION_ID.
backend_validate() {
    command -v pacman >/dev/null || { echo 'Arch Linux requires pacman.' >&2; return 1; }
}

_arch_install_packages() {
    local package
    for package in "$@"; do
        pacman -Si "$package" >/dev/null 2>&1 || {
            echo "Package unavailable in configured Arch ARM64 repositories: $package. Update the system with pacman -Syu and check its repositories." >&2
            return 1
        }
    done
    # Never refresh databases independently: Arch does not support partial upgrades.
    sudo pacman -S --needed "$@"
}

_arch_library_path() {
    printf '%s/usr/lib/aarch64-linux-gnu/android:%s/usr/lib/aarch64-linux-gnu:%s/usr/lib:%s/usr/lib/7zip\n' "$1" "$1" "$1" "$1"
}

# Validate the actual ABI dependency chain, including libprotobuf.so.32 and 7z.so.
_arch_check_sysroot() {
    local sysroot=$1 tool output library_path
    library_path="$(_arch_library_path "$sysroot")"
    for tool in aapt aapt2 aidl zipalign split-select; do
        [[ -x "$sysroot/usr/bin/$tool" ]] || { echo "Incomplete Arch toolset: missing $tool." >&2; return 1; }
        LC_ALL=C readelf -h "$sysroot/usr/bin/$tool" | grep -q 'Machine:.*AArch64' || {
            echo "Arch toolset requires an ARM64 binary: $tool." >&2; return 1;
        }
        if ! output="$(LC_ALL=C LD_LIBRARY_PATH="$library_path" ldd "$sysroot/usr/bin/$tool" 2>&1)" \
            || [[ "$output" == *'not found'* ]]; then
            printf 'Unresolved Arch runtime dependencies for %s:\n%s\n' "$tool" "$output" >&2
            return 1
        fi
    done
    [[ -f "$sysroot/usr/share/java/apksigner.jar" && -f "$sysroot/usr/share/java/apksig.jar" ]] || {
        echo 'Incomplete Arch toolset: missing apksigner Java archives.' >&2; return 1;
    }
    PYTHONPATH="$sysroot/usr/lib/python3/dist-packages" python3 -c 'import sdkmanager, looseversion, requests' || {
        echo 'Missing Arch sdkmanager Python modules (python-requests or local sdkmanager/looseversion).' >&2; return 1;
    }
    "$(backend_jdk_path 11)/bin/java" -cp "$sysroot/usr/share/java/apksigner.jar:$sysroot/usr/share/java/apksig.jar" \
        com.android.apksigner.ApkSignerTool version >/dev/null || {
        echo 'Arch apksigner cannot run with JDK 11.' >&2; return 1;
    }
}

_arch_provision_local_tools() (
    # Work in a subshell so the extraction cleanup trap stays backend-local.
    set -o pipefail
    local skip=$1 host="$ANDROID_ARM64_STATE_ROOT/host/arch" manifest fingerprint target
    local package version architecture checksum url archive stage='' payload
    manifest="${BASH_SOURCE[0]%/*}/arch-packages.lock"
    fingerprint="$(sha256sum "$manifest")" || return 1
    fingerprint="${fingerprint%% *}"
    target="$host/sysroots/$fingerprint"
    if [[ -f "$target/.complete" && "$(cat "$target/.complete")" == "$fingerprint" ]]; then
        _arch_check_sysroot "$target" || return 1
        mkdir -p "$host" || return 1
        ln -sfnT "sysroots/$fingerprint" "$host/sysroot" || return 1
        return 0
    fi
    if "$skip"; then
        echo 'Missing complete local Arch Android toolset (aapt, aapt2, aidl, zipalign, split-select, apksigner, sdkmanager); rerun without --skip-system-packages.' >&2
        return 1
    fi
    mkdir -p "$host/debs" "$host/sysroots" || return 1
    while read -r package version architecture checksum url; do
        [[ -n "$package" && "$package" != \#* ]] || continue
        [[ "$architecture" == arm64 || "$architecture" == all ]] || {
            echo "Unsupported package architecture: $package ($architecture)." >&2; return 1;
        }
        archive="$host/debs/${url##*/}"
        if [[ ! -f "$archive" ]]; then
            curl --fail --location --retry 3 --output "$archive.partial" "$url" || return 1
            printf '%s  %s\n' "$checksum" "$archive.partial" | sha256sum --check --status || {
                echo "Checksum mismatch for downloaded Arch tool package: $package." >&2; return 1;
            }
            mv -- "$archive.partial" "$archive" || return 1
        fi
        printf '%s  %s\n' "$checksum" "$archive" | sha256sum --check --status || {
            echo "Checksum mismatch for cached Arch tool package: $archive. Remove this archive and rerun." >&2; return 1;
        }
    done < "$manifest"

    stage="$(mktemp -d "$host/sysroots/.extract.XXXXXX")" || return 1
    trap '[[ -z "$stage" ]] || rm -rf -- "$stage"' EXIT
    while read -r package version architecture checksum url; do
        [[ -n "$package" && "$package" != \#* ]] || continue
        archive="$host/debs/${url##*/}"
        payload="$(bsdtar -tf "$archive" | grep -E '^data\.tar\.(xz|gz|zst)$')" || {
            echo "Missing Debian data archive: $package." >&2; return 1;
        }
        bsdtar -xOf "$archive" "$payload" | bsdtar -xf - -C "$stage" || {
            echo "Could not extract Arch tool package: $package." >&2; return 1;
        }
    done < "$manifest"
    _arch_check_sysroot "$stage" || return 1
    printf '%s\n' "$fingerprint" > "$stage/.complete" || return 1
    # An incomplete extraction can never be published as the active sysroot.
    if [[ -e "$target" ]]; then
        echo "Incomplete cached Arch sysroot: $target. Remove it and rerun." >&2
        return 1
    fi
    mv -- "$stage" "$target" || return 1
    stage=''
    ln -sfnT "sysroots/$fingerprint" "$host/sysroot"
)

_arch_write_wrappers() (
    local tool directory="$ANDROID_ARM64_STATE_ROOT/bin" staging
    mkdir -p "$directory" || return 1
    staging="$(mktemp -d "$directory/.arch-wrappers.XXXXXX")" || return 1
    trap 'rm -rf -- "$staging"' EXIT
    for tool in aapt aapt2 aidl zipalign split-select; do
        cat > "$staging/$tool" <<'EOF' || return 1
#!/usr/bin/env bash
set -eu
wrapper="$(readlink -f -- "${BASH_SOURCE[0]}")"
state="$(cd -- "$(dirname -- "$wrapper")/.." && pwd)"
sysroot="$state/host/arch/sysroot"
export LD_LIBRARY_PATH="$sysroot/usr/lib/aarch64-linux-gnu/android:$sysroot/usr/lib/aarch64-linux-gnu:$sysroot/usr/lib:$sysroot/usr/lib/7zip"
exec "$sysroot/usr/bin/${wrapper##*/}" "$@"
EOF
        chmod +x "$staging/$tool" || return 1
    done
    cat > "$staging/sdkmanager" <<'EOF' || return 1
#!/usr/bin/env bash
set -eu
wrapper="$(readlink -f -- "${BASH_SOURCE[0]}")"
state="$(cd -- "$(dirname -- "$wrapper")/.." && pwd)"
sysroot="$state/host/arch/sysroot"
export PYTHONPATH="$sysroot/usr/lib/python3/dist-packages"
exec /usr/bin/python3 "$sysroot/usr/bin/sdkmanager" "$@"
EOF
    cat > "$staging/apksigner" <<'EOF' || return 1
#!/usr/bin/env bash
set -eu
wrapper="$(readlink -f -- "${BASH_SOURCE[0]}")"
state="$(cd -- "$(dirname -- "$wrapper")/.." && pwd)"
java_lib="$state/host/arch/sysroot/usr/share/java"
# Debian's JAR manifest references /usr/share/java/apksig.jar absolutely.
exec "${JAVA_HOME:-/usr/lib/jvm/java-11-openjdk}/bin/java" -cp "$java_lib/apksigner.jar:$java_lib/apksig.jar" com.android.apksigner.ApkSignerTool "$@"
EOF
    chmod +x "$staging/sdkmanager" "$staging/apksigner" || return 1
    for tool in aapt aapt2 aidl zipalign split-select sdkmanager apksigner; do
        # Replace a previous backend's symlink rather than writing through it.
        mv -fT -- "$staging/$tool" "$directory/$tool" || return 1
    done
    for tool in adb fastboot; do ln -sfnT "/usr/bin/$tool" "$directory/$tool" || return 1; done
)

backend_provision() {
    local skip=$1 tool package
    local -a packages=(jdk11-openjdk jdk17-openjdk jdk21-openjdk python python-requests
        android-tools ca-certificates curl unzip file tar xz libarchive gnupg
        cmake ninja make pkgconf base-devel glibc gcc-libs expat libpng zlib)
    if ! "$skip"; then
        _arch_install_packages "${packages[@]}" || return 1
    fi
    local -a missing=()
    for package in "${packages[@]}"; do
        pacman -Q "$package" >/dev/null 2>&1 || missing+=("$package")
    done
    for tool in python3 adb fastboot curl unzip file tar bsdtar gpgv sha256sum readelf ldd; do
        command -v "$tool" >/dev/null || missing+=("command:$tool")
    done
    if ((${#missing[@]})); then
        echo "Missing Arch prerequisites: ${missing[*]}; rerun without --skip-system-packages." >&2
        return 1
    fi
    for tool in 11 17 21; do backend_provision_jdk "$tool" || return 1; done
    _arch_provision_local_tools "$skip" || return 1
    _arch_write_wrappers
}

backend_provision_jdk() {
    local path
    case "$1" in 11|17|21) ;; *) echo "Unsupported Arch JDK: $1." >&2; return 1 ;; esac
    path="$(backend_jdk_path "$1")"
    [[ -x "$path/bin/javac" && -x "$path/bin/java" ]] || {
        echo "Missing Arch JDK $1 (jdk$1-openjdk). Rerun without --skip-system-packages." >&2; return 1;
    }
}

backend_jdk_path() { printf '/usr/lib/jvm/java-%s-openjdk\n' "$1"; }
backend_tool_path() { printf '%s/bin/%s\n' "$ANDROID_ARM64_STATE_ROOT" "$1"; }
backend_environment() { :; } # Extra library/Python paths are scoped to wrappers.

backend_provision_emulator() {
    local emulator=$1 skip=$2 package tool
    local -a packages=() missing=()
    case "$emulator" in
        waydroid)
            command -v waydroid >/dev/null && return 0
            "$skip" && { echo 'Missing Arch package: waydroid. Rerun without --skip-system-packages.' >&2; return 1; }
            _arch_install_packages waydroid || return 1
            command -v waydroid >/dev/null || { echo 'Missing waydroid after package installation.' >&2; return 1; }
            ;;
        avd)
            if ! command -v qemu-img >/dev/null; then
                "$skip" && { echo 'Missing qemu-img; rerun without --skip-system-packages or provide a native installation.' >&2; return 1; }
                pacman -Si qemu-img >/dev/null 2>&1 || {
                    echo 'qemu-img is unavailable in configured Arch ARM64 repositories. Install a native qemu-img separately before AVD setup.' >&2; return 1;
                }
                packages+=(qemu-img)
            fi
            if [[ -z "${ANDROID_ARM64_AVD_QEMU_BINARY:-}" ]]; then
                local -a build_packages=(ca-certificates curl git repo python cmake ninja make pkgconf base-devel
                    glib2 pixman openssl zlib dtc libslirp libusb ncurses gtk3)
                for package in "${build_packages[@]}"; do
                    pacman -Q "$package" >/dev/null 2>&1 || missing+=("$package")
                done
                if "$skip" && ((${#missing[@]})); then
                    echo "Missing Arch Android QEMU build packages: ${missing[*]}; rerun without --skip-system-packages." >&2; return 1
                fi
                packages+=("${missing[@]}")
            fi
            if ((${#packages[@]})); then _arch_install_packages "${packages[@]}" || return 1; fi
            command -v qemu-img >/dev/null || { echo 'Missing qemu-img after package installation.' >&2; return 1; }
            if [[ -z "${ANDROID_ARM64_AVD_QEMU_BINARY:-}" ]]; then
                for tool in repo git python3 cmake ninja make pkg-config cc c++; do
                    command -v "$tool" >/dev/null || { echo "Missing Arch Android QEMU build tool: $tool." >&2; return 1; }
                done
            fi
            ;;
        *) echo "Unsupported emulator for Arch: $emulator." >&2; return 1 ;;
    esac
}
