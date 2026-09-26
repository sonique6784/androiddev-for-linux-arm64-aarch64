#!/usr/bin/env bash
# Waydroid emulator backend. Distribution-specific package installation lives
# in backend_provision_emulator; this module owns image provisioning, services
# and the adb workflow documented in the README.

emulator_validate() {
    if [[ -z "${WAYLAND_DISPLAY:-}" && "${XDG_SESSION_TYPE:-}" != wayland ]]; then
        echo 'Android ARM64 setup: no Wayland session detected; the Waydroid session can only start from a Wayland desktop.' >&2
    fi
    command -v sudo >/dev/null || { echo 'sudo is required to set up the Waydroid emulator.' >&2; return 1; }
}

emulator_install() {
    backend_provision_emulator waydroid "$1"
    command -v waydroid >/dev/null || { echo 'The waydroid command is not on PATH after installation.' >&2; return 1; }
}

# Idempotent: images are only downloaded when /var/lib/waydroid has never been
# initialized, and a different existing image type is reported instead of being
# replaced behind the user's back.
emulator_init() {
    local cfg=/var/lib/waydroid/waydroid.cfg image="$ANDROID_ARM64_WAYDROID_IMAGE"
    if [[ ! -f "$cfg" ]]; then
        echo "Android ARM64 setup: initializing Waydroid with the $image image; this downloads about 1.5 GB."
        sudo waydroid init -s "$image" || {
            echo 'Waydroid initialization failed. Read "waydroid log"; if it reports a missing binder node, run "sudo rmmod binder_linux" and rerun setup.' >&2
            return 1
        }
    elif ! sudo grep -q "/${image}.json" "$cfg"; then
        echo "Waydroid is already initialized with a different Android image. To replace it, run: sudo waydroid init -f -s $image (this re-downloads the images)." >&2
        return 1
    fi
    # auto_adb makes Waydroid run "adb connect" as soon as Android is unlocked,
    # which is what the README's adb install workflow relies on.
    if sudo grep -q '^auto_adb' "$cfg"; then
        sudo sed -i 's/^auto_adb *=.*/auto_adb = True/' "$cfg"
    else
        sudo sed -i '/^\[waydroid\]/a auto_adb = True' "$cfg"
    fi
    _waydroid_apply_display_config
}

# --- internals (not part of the emulator contract) ---

# Persist one [properties] key in waydroid.cfg: exit 0 when it was inserted,
# 1 when it is already configured, so a user's explicit choice is never
# overwritten.
_waydroid_cfg_set_prop() {
    local key=$1 value=$2 cfg=/var/lib/waydroid/waydroid.cfg
    sudo grep -qE "^${key//./\\.}[[:space:]]*=" "$cfg" && return 1
    sudo sed -i "/^\[properties\]/a ${key}=${value}" "$cfg"
}

# Phone-sized window: override the Android display resolution and derive the
# UI density from the 1080x2340 @ 440 dpi reference (width-scaled, so apps
# lay out at a normal ~393 dp phone width) and the window fits a modest
# desktop screen. Idempotent; a change regenerates Waydroid's configs and
# stops a running session so the next start (setup or
# android_arm64_emulator_start) boots with the new display.
_waydroid_apply_display_config() {
    local size="${ANDROID_ARM64_WAYDROID_SIZE:-}" width height density changed=false
    [[ -n "$size" ]] || return 0
    width="${size%x*}"
    height="${size#*x}"
    density=$(( (width * 440 / 1080 + 5) / 10 * 10 ))
    _waydroid_cfg_set_prop persist.waydroid.width "$width" && changed=true
    _waydroid_cfg_set_prop persist.waydroid.height "$height" && changed=true
    _waydroid_cfg_set_prop ro.sf.lcd_density "$density" && changed=true
    if [[ "$changed" == true ]]; then
        echo "Waydroid display set to ${width}x${height} at density ${density} (phone layout, fits the screen)."
        sudo waydroid upgrade -o
        if _waydroid_session_running; then
            echo 'Stopping the Waydroid session so the new display settings take effect.'
            waydroid session stop
        fi
    fi
}

_waydroid_session_running() {
    waydroid status 2>/dev/null | grep -q $'^Session:\tRUNNING'
}

# Waydroid does not request a server-side title bar. GNOME's Mutter does not
# provide one for this surface, but its standard move gesture still works.
_waydroid_window_guidance() {
    local desktops="${XDG_CURRENT_DESKTOP:-}:${XDG_SESSION_DESKTOP:-}"
    if [[ ":${desktops,,}:" == *:gnome:* ]]; then
        echo 'Waydroid has no title bar in GNOME; hold Super and drag the window to move it.'
    fi
}

# dnsmasq writes the container lease world-readable, so boot progress is
# observable without sudo.
_waydroid_lease_ip() {
    awk '{print $3; exit}' /var/lib/misc/dnsmasq.waydroid0.leases 2>/dev/null
}

# Android requesting a DHCP lease is the earliest root-free proof that boot
# reached systemReady, which is exactly where a SurfaceFlinger crash stops it.
_waydroid_wait_boot() {
    local seconds=${1:-60} i
    for ((i = 0; i < seconds; i += 2)); do
        [[ -n "$(_waydroid_lease_ip)" ]] && return 0
        sleep 2
    done
    return 1
}

# SurfaceFlinger crash records are readable here: Waydroid binds Android /data
# from ~/.local/share/waydroid and system uid 1000 maps to this user. Records
# older than 15 minutes describe an earlier state and are ignored.
_waydroid_gpu_crash_evidence() {
    local dir="$HOME/.local/share/waydroid/data" cutoff f content line
    cutoff=$(( $(date +%s) - 900 ))
    for f in "$dir"/tombstones/tombstone_* "$dir"/system/dropbox/SYSTEM_TOMBSTONE@*.txt.gz; do
        [[ -f "$f" && "$f" != *.pb ]] || continue
        (( $(date -r "$f" +%s) >= cutoff )) || continue
        if [[ "$f" == *.gz ]]; then
            content="$(gzip -cd "$f" 2>/dev/null)" || continue
        else
            content="$(<"$f")" || continue
        fi
        grep -qi surfaceflinger <<<"$content" || continue
        grep -qiE 'gpu writeable|gralloc|RenderEngine|GraphicBuffer|EGL_' <<<"$content" || continue
        line="$(grep -m1 'Abort message' <<<"$content" || true)"
        printf '%s: %s\n' "$f" "${line:-GPU-related SurfaceFlinger crash}"
        return 0
    done
    return 1
}

# Start the session if needed and wait until Waydroid reports it RUNNING.
_waydroid_start_session() {
    local log="$ANDROID_ARM64_STATE_ROOT/waydroid-session.log" tries
    mkdir -p "$ANDROID_ARM64_STATE_ROOT"
    if ! _waydroid_session_running; then
        nohup waydroid session start >>"$log" 2>&1 &
        for ((tries = 0; tries < 60; tries++)); do
            _waydroid_session_running && return 0
            sleep 1
        done
        echo "Waydroid session did not start; see $log and 'waydroid log'." >&2
        return 1
    fi
}

# Detect the known VM/unsupported-GPU failure (SurfaceFlinger aborting on GPU
# buffers, which stalls Android before DHCP and therefore before adb) and apply
# Waydroid's documented software-rendering fix. Safe to rerun: it never
# overwrites a GL driver that was chosen explicitly.
emulator_doctor() {
    local cfg=/var/lib/waydroid/waydroid.cfg evidence= running=false
    [[ -f "$cfg" ]] || {
        echo 'Waydroid is not initialized. Run setup-android-arm64.sh --emulator waydroid first.' >&2
        return 1
    }
    _waydroid_session_running && running=true

    evidence="$(_waydroid_gpu_crash_evidence)" || true
    if [[ -z "$evidence" && "$running" == true && -z "$(_waydroid_lease_ip)" ]] \
        && ! pgrep -x surfaceflinger >/dev/null; then
        # No crash record yet, but the runtime symptom matches.
        evidence='SurfaceFlinger is not running while Android never obtained a DHCP lease'
    fi

    if [[ -z "$evidence" ]]; then
        if [[ "$running" == true && -z "$(_waydroid_lease_ip)" ]]; then
            echo 'Graphics look healthy (no recent SurfaceFlinger crash records), but Android has no IP yet.' >&2
            echo 'If this persists, read "waydroid log" and docs.waydro.id/debugging/networking-issues.' >&2
        else
            echo 'Waydroid graphics look healthy.'
        fi
        return 0
    fi

    echo 'Waydroid GPU problem detected:'
    echo "  $evidence"
    if sudo grep -qE '^ro\.hardware\.egl[[:space:]]*=' "$cfg"; then
        echo "ro.hardware.egl is already set in $cfg; not overwriting your choice. Inspect it together with the crash record above." >&2
        return 1
    fi
    echo 'Applying the Waydroid VM/unsupported-GPU fix: ro.hardware.gralloc=default and ro.hardware.egl=swiftshader (software rendering).'
    sudo grep -qE '^ro\.hardware\.gralloc[[:space:]]*=' "$cfg" \
        || sudo sed -i '/^\[properties\]/a ro.hardware.gralloc=default' "$cfg"
    sudo sed -i '/^\[properties\]/a ro.hardware.egl=swiftshader' "$cfg"
    sudo waydroid upgrade -o
    echo 'For hardware acceleration instead, enable virtio-gpu 3D on both the device and the display in QEMU, then remove both properties.'

    if [[ "$running" == true ]]; then
        waydroid session stop || true
        sleep 2
        _waydroid_start_session || return 1
        if _waydroid_wait_boot 120; then
            echo "Android booted after the fix: IP $(_waydroid_lease_ip)."
        else
            echo 'Android still has no IP after the fix; read "waydroid log" and the newest files in ~/.local/share/waydroid/data/tombstones/.' >&2
            return 1
        fi
    else
        echo 'Waydroid was not running; start it with android_arm64_emulator_start, which reruns this check.'
    fi
}

# Start container + session, then verify Android actually boots. Waydroid calls
# the session RUNNING long before Android works, and on VMs without working 3D
# the boot silently stalls on SurfaceFlinger, so route that stall through
# emulator_doctor and let setup and --emulator-start self-heal.
emulator_start() {
    [[ -f /var/lib/waydroid/waydroid.cfg ]] || {
        echo 'Waydroid is not initialized. Run setup-android-arm64.sh --emulator waydroid first.' >&2
        return 1
    }
    sudo systemctl enable --now waydroid-container >/dev/null || {
        echo 'Could not start the waydroid-container systemd service.' >&2
        return 1
    }
    if [[ -z "${WAYLAND_DISPLAY:-}" ]]; then
        echo 'Waydroid container service is running. Start the session from a Wayland desktop with android_arm64_emulator_start.' >&2
        return 0
    fi
    _waydroid_start_session || return 1
    if ! _waydroid_wait_boot 60; then
        echo 'Waydroid is running but Android did not reach the network within 60 s; checking for known graphics failures...' >&2
        emulator_doctor || return 1
    fi
    _waydroid_window_guidance
}

# Emitted into env.sh. Everything below runs in the user's shell: the helpers
# treat Waydroid as a plain adb device, so "adb install -r" keeps working.
emulator_environment() {
    cat <<'EOF'
# Waydroid emulator helpers.
_android_arm64_waydroid_serial() {
    local ip
    ip="$(awk '{print $3; exit}' /var/lib/misc/dnsmasq.waydroid0.leases 2>/dev/null)"
    [[ -n "$ip" ]] || return 1
    printf '%s:5555\n' "$ip"
}
android_arm64_emulator_status() { waydroid status; }
android_arm64_emulator_start() { "$ANDROID_ARM64_LAUNCHER" --emulator-start waydroid; }
android_arm64_emulator_doctor() { "$ANDROID_ARM64_LAUNCHER" --emulator-doctor waydroid; }
android_arm64_emulator_stop() { waydroid session stop; sudo systemctl stop waydroid-container; }
android_arm64_emulator_show_ui() { waydroid show-full-ui; }
android_arm64_emulator_connect() {
    local serial state tries hinted=0
    serial="$(_android_arm64_waydroid_serial)" || {
        echo 'No Waydroid address found. Start the emulator with android_arm64_emulator_start.' >&2
        return 1
    }
    for ((tries = 0; tries < 60; tries++)); do
        adb connect "$serial" >/dev/null 2>&1 || true
        state="$(adb -s "$serial" get-state 2>/dev/null || true)"
        if [[ "$state" == device ]]; then
            if [[ "$(adb -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == 1 ]]; then
                return 0
            fi
        elif [[ "$state" == unauthorized && "$hinted" -eq 0 ]]; then
            hinted=1
            echo 'Accept the USB debugging prompt in the Waydroid window (android_arm64_emulator_show_ui) to authorize adb.' >&2
        fi
        sleep 2
    done
    echo "Could not reach the Waydroid adb device at $serial." >&2
    return 1
}
android_arm64_emulator_install() {
    local apk=${1:-} serial
    [[ -n "$apk" && -f "$apk" ]] || { echo 'Usage: android_arm64_emulator_install /path/to/app.apk' >&2; return 2; }
    android_arm64_emulator_connect || return 1
    serial="$(_android_arm64_waydroid_serial)" || return 1
    adb -s "$serial" install -r "$apk"
}
android_arm64_emulator_launch() {
    local package=${1:-} serial
    [[ -n "$package" ]] || { echo 'Usage: android_arm64_emulator_launch <package.name>' >&2; return 2; }
    android_arm64_emulator_connect || return 1
    serial="$(_android_arm64_waydroid_serial)" || return 1
    adb -s "$serial" shell monkey -p "$package" -c android.intent.category.LAUNCHER 1 >/dev/null
}
android_arm64_emulator_logcat() {
    local serial
    android_arm64_emulator_connect || return 1
    serial="$(_android_arm64_waydroid_serial)" || return 1
    adb -s "$serial" logcat "$@"
}
EOF
}
