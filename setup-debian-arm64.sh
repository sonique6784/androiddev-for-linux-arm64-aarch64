#!/usr/bin/env bash
# User-local Debian 13 ARM64 toolchain for RecyclerViewKotlin.
set -Eeuo pipefail
trap 'printf "Setup failed at line %s; rerun after correcting the error.\n" "$LINENO" >&2' ERR

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project="$root/views-widgets-samples/RecyclerViewKotlin"
tool_root="$root/.android-arm64"
sdk_root="$tool_root/sdk"
accept_licenses=false
while (($#)); do
    case "$1" in
        --accept-licenses) accept_licenses=true; shift ;;
        --help) echo "Usage: ./setup-android-arm64.sh [--accept-licenses]"; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

[[ "$(uname -m)" == aarch64 ]] || { echo 'Linux ARM64 is required.' >&2; exit 1; }
. /etc/os-release
[[ "$ID" == debian && "$VERSION_ID" == 13 ]] || { echo 'This path supports Debian 13.' >&2; exit 1; }
[[ -x "$project/gradlew" && -f "$project/app/build.gradle" ]] || {
    echo "Clone android/views-widgets-samples and check out RecyclerViewKotlin at $project first." >&2; exit 1;
}
for program in apt-get dpkg-deb curl python3 sha256sum tar; do
    command -v "$program" >/dev/null || { echo "Missing host tool: $program" >&2; exit 1; }
done

mkdir -p "$tool_root/debs" "$tool_root/sysroot" "$tool_root/bin" "$sdk_root"
packages=(
    aapt aidl zipalign apksigner split-select adb fastboot sdkmanager
    android-libaapt android-libandroidfw android-libbase android-libutils
    android-libcutils android-liblog android-libziparchive android-libboringssl
    android-libsparse android-libbacktrace libzopfli1 libapksig-java
    python3-looseversion
)
missing=()
for package in "${packages[@]}"; do
    if ! compgen -G "$tool_root/debs/${package}_*.deb" >/dev/null; then
        missing+=("$package")
    fi
done
if ((${#missing[@]})); then
    echo 'Downloading native Debian Android packages...'
    (cd "$tool_root/debs" && apt-get download "${missing[@]}")
fi
if [[ ! -f "$tool_root/sysroot/.extracted" ]]; then
    for deb in "$tool_root"/debs/*.deb; do dpkg-deb -x "$deb" "$tool_root/sysroot"; done
    touch "$tool_root/sysroot/.extracted"
fi
sysroot="$tool_root/sysroot/usr"
export LD_LIBRARY_PATH="$sysroot/lib/aarch64-linux-gnu/android:$sysroot/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export PYTHONPATH="$sysroot/lib/python3/dist-packages${PYTHONPATH:+:$PYTHONPATH}"
for program in aapt aapt2 aidl zipalign split-select adb fastboot; do
    ln -sfn "$sysroot/bin/$program" "$tool_root/bin/$program"
done
cat > "$tool_root/bin/apksigner" <<EOF
#!/usr/bin/env bash
exec "\$JAVA_HOME/bin/java" -jar "$sysroot/share/java/apksigner.jar" "\$@"
EOF
chmod +x "$tool_root/bin/apksigner"
cat > "$tool_root/bin/sdkmanager" <<EOF
#!/usr/bin/env bash
exec /usr/bin/python3 "$sysroot/bin/sdkmanager" "\$@"
EOF
chmod +x "$tool_root/bin/sdkmanager"

if [[ ! -x "$tool_root/jdk11/bin/javac" ]]; then
    echo 'Downloading checksum-verified Temurin JDK 11 for Linux ARM64...'
    metadata="$tool_root/jdk11-metadata.json"
    curl --fail --location --retry 3 --output "$metadata" \
        'https://api.adoptium.net/v3/assets/latest/11/hotspot?architecture=aarch64&image_type=jdk&jvm_impl=hotspot&os=linux&vendor=eclipse'
    mapfile -t release < <(python3 - "$metadata" <<'PY'
import json, sys
package = json.load(open(sys.argv[1]))[0]['binary']['package']
print(package['link'])
print(package['checksum'])
PY
)
    archive="$tool_root/jdk11.tar.gz"
    curl --fail --location --retry 3 --output "$archive" "${release[0]}"
    printf '%s  %s\n' "${release[1]}" "$archive" | sha256sum --check
    mkdir -p "$tool_root/jdk11"
    tar -xf "$archive" -C "$tool_root/jdk11" --strip-components=1
fi
export JAVA_HOME="$tool_root/jdk11"
export ANDROID_HOME="$sdk_root"
export ANDROID_SDK_ROOT="$sdk_root"
export GRADLE_USER_HOME="$tool_root/gradle"
export XDG_CACHE_HOME="$tool_root/cache"
export PATH="$JAVA_HOME/bin:$tool_root/bin:$PATH"
mkdir -p "$XDG_CACHE_HOME"

"$JAVA_HOME/bin/java" -version
"$JAVA_HOME/bin/javac" -version
"$tool_root/bin/aapt2" version
"$tool_root/bin/adb" version

if "$accept_licenses"; then
    python3 - "$sdk_root" "$tool_root/bin/sdkmanager" <<'PY'
import subprocess, sys
subprocess.run([sys.argv[2], '--sdk_root', sys.argv[1], '--licenses'],
               input='y\n' * 100, text=True, check=True)
PY
else
    echo 'Review the Android SDK terms, then rerun with --accept-licenses to record your acceptance.' >&2
    exit 2
fi
sdk_cache="$HOME/.cache/sdkmanager"
install_sdk_package() {
    local package=$1 marker=$2 archive=$3 attempt
    for attempt in 1 2; do
        "$tool_root/bin/sdkmanager" --sdk_root "$sdk_root" "$package"
        [[ -f "$marker" ]] && return 0
        # Debian's sdkmanager reports success after BadZipFile. Remove only its
        # cached package archive and retry once with a fresh download.
        rm -f -- "$sdk_cache/$archive"
        echo "Android ARM64 setup: $package did not install; retrying with a fresh archive." >&2
    done
    echo "Android ARM64 setup: $package could not be installed." >&2
    return 1
}
install_sdk_package 'platforms;android-30' "$sdk_root/platforms/android-30/android.jar" 'platform-30_r03.zip'
install_sdk_package 'build-tools;29.0.2' "$sdk_root/build-tools/29.0.2/source.properties" 'build-tools_r29.0.2-linux.zip'
build_tools="$sdk_root/build-tools/29.0.2"
[[ -f "$sdk_root/platforms/android-30/android.jar" && -f "$build_tools/source.properties" ]] || {
    echo 'The Android SDK packages were not installed.' >&2; exit 1;
}
for program in aapt aapt2 aidl zipalign split-select apksigner; do
    ln -sfn "$tool_root/bin/$program" "$build_tools/$program"
done
mkdir -p "$sdk_root/platform-tools" "$GRADLE_USER_HOME"
for program in adb fastboot; do ln -sfn "$tool_root/bin/$program" "$sdk_root/platform-tools/$program"; done
cat > "$sdk_root/platform-tools/source.properties" <<'EOF'
Pkg.Desc=Android SDK Platform-Tools (Debian ARM64)
Pkg.Revision=34.0.5
EOF
cat > "$sdk_root/platform-tools/package.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<common:repository xmlns:common="http://schemas.android.com/repository/android/common/01"
    xmlns:generic="http://schemas.android.com/repository/android/generic/01"
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <localPackage path="platform-tools" obsolete="false">
    <type-details xsi:type="generic:genericDetailsType"/>
    <revision><major>34</major><minor>0</minor><micro>5</micro></revision>
    <display-name>Android SDK Platform-Tools (Debian ARM64)</display-name>
  </localPackage>
</common:repository>
EOF
cat > "$GRADLE_USER_HOME/gradle.properties" <<EOF
org.gradle.java.home=$JAVA_HOME
android.aapt2FromMavenOverride=$tool_root/bin/aapt2
EOF
cat > "$project/local.properties" <<EOF
sdk.dir=$sdk_root
EOF
cat > "$tool_root/env.sh" <<EOF
# Source this file before building RecyclerViewKotlin.
export JAVA_HOME='$JAVA_HOME'
export ANDROID_HOME='$ANDROID_HOME'
export ANDROID_SDK_ROOT='$ANDROID_SDK_ROOT'
export GRADLE_USER_HOME='$GRADLE_USER_HOME'
export XDG_CACHE_HOME='$XDG_CACHE_HOME'
export LD_LIBRARY_PATH='$LD_LIBRARY_PATH'
export PYTHONPATH='$PYTHONPATH'
export PATH="$JAVA_HOME/bin:$tool_root/bin:\$PATH"
EOF
"$tool_root/bin/apksigner" version
echo "Setup complete. Source '$tool_root/env.sh' and build in '$project'."
