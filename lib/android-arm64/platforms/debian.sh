#!/usr/bin/env bash

backend_validate() { [[ "$VERSION_ID" == 13 ]] || { echo 'Debian 13 is required.' >&2; return 1; }; }

backend_provision() {
    local skip=$1 host="$ANDROID_ARM64_STATE_ROOT/host/debian" sysroot="$ANDROID_ARM64_STATE_ROOT/host/debian/sysroot/usr" item tool
    : "${LD_LIBRARY_PATH:=}"
    : "${PYTHONPATH:=}"
    for tool in apt-get dpkg-deb curl python3 sha256sum tar; do
        command -v "$tool" >/dev/null || { echo "Missing host tool: $tool" >&2; return 1; }
    done
    mkdir -p "$host/debs" "$host/sysroot" "$ANDROID_ARM64_STATE_ROOT/bin"
    local packages='aapt aidl zipalign apksigner split-select adb fastboot sdkmanager android-libaapt android-libandroidfw android-libbase android-libutils android-libcutils android-liblog android-libziparchive android-libboringssl android-libsparse android-libbacktrace libzopfli1 libapksig-java python3-looseversion'
    local missing=''
    for item in $packages; do compgen -G "$host/debs/$item"_'*.deb' >/dev/null || missing="$missing $item"; done
    if [[ -n "$missing" ]]; then
        "$skip" && { echo 'Missing local Debian tool packages; rerun without --skip-system-packages.' >&2; return 1; }
        (cd "$host/debs" && apt-get download $missing)
    fi
    if [[ ! -f "$host/sysroot/.extracted" ]]; then
        for item in "$host"/debs/*.deb; do dpkg-deb -x "$item" "$host/sysroot"; done
        touch "$host/sysroot/.extracted"
    fi
    export LD_LIBRARY_PATH="$sysroot/lib/aarch64-linux-gnu/android:$sysroot/lib:$LD_LIBRARY_PATH"
    export PYTHONPATH="$sysroot/lib/python3/dist-packages:$PYTHONPATH"
    for tool in aapt aapt2 aidl zipalign split-select adb fastboot; do ln -sfn "$sysroot/bin/$tool" "$ANDROID_ARM64_STATE_ROOT/bin/$tool"; done
    cat > "$ANDROID_ARM64_STATE_ROOT/bin/sdkmanager" <<EOF
#!/usr/bin/env bash
export PYTHONPATH='$PYTHONPATH'
exec /usr/bin/python3 '$sysroot/bin/sdkmanager' "\$@"
EOF
    cat > "$ANDROID_ARM64_STATE_ROOT/bin/apksigner" <<EOF
#!/usr/bin/env bash
exec "\$JAVA_HOME/bin/java" -jar '$sysroot/share/java/apksigner.jar' "\$@"
EOF
    chmod +x "$ANDROID_ARM64_STATE_ROOT/bin/sdkmanager" "$ANDROID_ARM64_STATE_ROOT/bin/apksigner"
}

backend_provision_jdk() {
    local version=$1 target="$ANDROID_ARM64_STATE_ROOT/jdks/$1" metadata archive url checksum
    [[ -x "$target/bin/javac" ]] && return 0
    mkdir -p "$target"
    metadata="$ANDROID_ARM64_STATE_ROOT/jdks/temurin-$version.json"
    curl --fail --location --retry 3 --output "$metadata" "https://api.adoptium.net/v3/assets/latest/$version/hotspot?architecture=aarch64&image_type=jdk&jvm_impl=hotspot&os=linux&vendor=eclipse"
    url="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[0]["binary"]["package"]["link"])' "$metadata")"
    checksum="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[0]["binary"]["package"]["checksum"])' "$metadata")"
    archive="$ANDROID_ARM64_STATE_ROOT/jdks/temurin-$version.tar.gz"
    curl --fail --location --retry 3 --output "$archive" "$url"
    printf '%s  %s\n' "$checksum" "$archive" | sha256sum --check
    tar -xf "$archive" -C "$target" --strip-components=1
}

backend_jdk_path() { printf '%s/jdks/%s\n' "$ANDROID_ARM64_STATE_ROOT" "$1"; }
backend_tool_path() { printf '%s/bin/%s\n' "$ANDROID_ARM64_STATE_ROOT" "$1"; }
backend_environment() {
    cat <<EOF
export LD_LIBRARY_PATH='$LD_LIBRARY_PATH'
export PYTHONPATH='$PYTHONPATH'
EOF
}
