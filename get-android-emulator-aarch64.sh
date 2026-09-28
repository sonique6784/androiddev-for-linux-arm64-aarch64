#!/usr/bin/env bash
# Fetch the latest verified community Android Emulator for a Linux ARM64 host.
set -Eeuo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
state_root="${ANDROID_ARM64_STATE_ROOT:-$HOME/.local/share/android-arm64}"
api_url='https://api.github.com/repos/Changqing-JING/android-emulator-aarch64-linux/releases/latest'

usage() {
    cat <<'EOF'
Usage: ./get-android-emulator-aarch64.sh [--state-root ABSOLUTE_PATH]

Fetch the community project's latest release, verify its published SHA-256,
install it under the managed state root, and register its ARM64 QEMU engine
for this project's AVD backend. Run this again to check for a newer release.
EOF
}

while (($#)); do
    case "$1" in
        --state-root)
            [[ $# -ge 2 && "$2" == /* && "$2" != / ]] || { echo '--state-root needs an absolute, non-root path.' >&2; exit 2; }
            state_root="$2"
            shift 2
            ;;
        --help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ "$(uname -s)" == Linux && "$(uname -m)" == aarch64 ]] || {
    echo 'This installer requires a Linux AArch64 host.' >&2
    exit 1
}
for tool in curl python3 unzip sha256sum stat mktemp; do
    command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done
state_root="$(realpath -m -- "$state_root")"

release_json="$(curl --fail --silent --show-error --location --retry 3 \
    --connect-timeout 15 --max-time 60 --header 'Accept: application/vnd.github+json' "$api_url")"
release_fields="$(python3 -c '
import json, re, sys
from urllib.parse import urlparse

release = json.load(sys.stdin)
tag = release.get("tag_name")
if not isinstance(tag, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", tag):
    sys.exit("Latest release has no safe tag name")
assets = [a for a in release.get("assets", []) if re.fullmatch(
    r"sdk-repo-linux_aarch64-emulator-[A-Za-z0-9._-]+\.zip", a.get("name", ""))]
if len(assets) != 1:
    sys.exit(f"Expected one Linux AArch64 emulator ZIP in release {tag}; found {len(assets)}")
asset = assets[0]
url = asset.get("browser_download_url", "")
parsed = urlparse(url)
if parsed.scheme != "https" or parsed.netloc != "github.com" or not parsed.path.startswith(
    f"/Changqing-JING/android-emulator-aarch64-linux/releases/download/{tag}/"):
    sys.exit("Release asset URL is outside the expected GitHub repository")
digest = asset.get("digest", "")
if not re.fullmatch(r"sha256:[0-9a-fA-F]{64}", digest):
    sys.exit("Release asset lacks a published SHA-256 digest")
size = asset.get("size")
if not isinstance(size, int) or size <= 0:
    sys.exit("Release asset lacks a valid byte count")
print(tag, url, digest[7:].lower(), size, sep="\t")
' <<< "$release_json")"
IFS=$'\t' read -r tag asset_url digest expected_size <<< "$release_fields"

cache_dir="$state_root/cache/community-android-emulator"
install_parent="$state_root/avd/qemu/community/$tag"
install_root="$install_parent/$digest"
archive="$cache_dir/$digest.zip"
launcher="$install_root/emulator"
mkdir -p -- "$cache_dir" "$install_parent"

part=
stage=
cleanup() {
    [[ -z "$part" ]] || rm -f -- "$part"
    [[ -z "$stage" ]] || rm -rf -- "$stage"
}
trap cleanup EXIT

valid_archive() {
    [[ -f "$archive" && ! -L "$archive" ]] || return 1
    [[ "$(stat -c %s -- "$archive")" == "$expected_size" ]] || return 1
    printf '%s  %s\n' "$digest" "$archive" | sha256sum --check --status
}

if [[ -L "$archive" ]]; then
    echo "Refusing symlinked cache archive: $archive" >&2
    exit 1
fi
if valid_archive; then
    echo "Using verified cached archive: $archive"
else
    part="$(mktemp "$cache_dir/.download.XXXXXX")"
    echo "Downloading release $tag from $asset_url"
    curl --fail --location --retry 3 --retry-all-errors --connect-timeout 15 \
        --output "$part" "$asset_url"
    [[ "$(stat -c %s -- "$part")" == "$expected_size" ]] || {
        echo 'Downloaded archive size differs from GitHub release metadata.' >&2
        exit 1
    }
    printf '%s  %s\n' "$digest" "$part" | sha256sum --check --status || {
        echo 'Downloaded archive SHA-256 differs from GitHub release metadata.' >&2
        exit 1
    }
    mv -f -- "$part" "$archive"
    part=
fi

python3 - "$archive" <<'PY'
from pathlib import PurePosixPath
import stat
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    names = []
    for item in archive.infolist():
        path = PurePosixPath(item.filename)
        if path.is_absolute() or ".." in path.parts or not path.parts:
            sys.exit(f"Unsafe ZIP path: {item.filename!r}")
        if stat.S_ISLNK(item.external_attr >> 16):
            sys.exit(f"ZIP contains a symlink: {item.filename!r}")
        names.append(item.filename)
    candidates = (
        "emulator/qemu/linux-aarch64/qemu-system-aarch64",
        "qemu/linux-aarch64/qemu-system-aarch64",
    )
    if not any(name in names for name in candidates):
        sys.exit("ZIP lacks qemu/linux-aarch64/qemu-system-aarch64")
PY
unzip -tqq "$archive"

ANDROID_ARM64_SCRIPT_DIR="$script_dir"
ANDROID_ARM64_STATE_ROOT="$state_root"
source "$script_dir/lib/android-arm64/emulators/avd.sh"

if [[ -e "$install_root" ]]; then
    [[ -d "$install_root" && ! -L "$install_root" && -f "$install_root/.release.json" ]] || {
        echo "Existing installation cannot be verified: $install_root" >&2
        exit 1
    }
    python3 - "$install_root/.release.json" "$tag" "$digest" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    installed = json.load(source)
if installed.get("tag") != sys.argv[2] or installed.get("sha256") != sys.argv[3]:
    sys.exit("Existing installation metadata does not match this release")
PY
else
    stage="$(mktemp -d "$install_parent/.install.XXXXXX")"
    unzip -q "$archive" -d "$stage"
    if [[ -x "$stage/emulator/qemu/linux-aarch64/qemu-system-aarch64" ]]; then
        payload="$stage/emulator"
    elif [[ -x "$stage/qemu/linux-aarch64/qemu-system-aarch64" ]]; then
        payload="$stage"
    else
        echo 'Extracted emulator has no executable Linux AArch64 QEMU engine.' >&2
        exit 1
    fi
    _avd_check_emulator_package "$payload/emulator"
    python3 - "$payload/.release.json" "$tag" "$asset_url" "$digest" "$expected_size" <<'PY'
import json
import sys
with open(sys.argv[1], "w", encoding="utf-8") as output:
    json.dump({"tag": sys.argv[2], "asset_url": sys.argv[3],
               "sha256": sys.argv[4], "size": int(sys.argv[5])}, output, indent=2)
    output.write("\n")
PY
    mv -- "$payload" "$install_root"
fi

_avd_register_emulator_package "$launcher"
echo "Registered Android Emulator: $launcher"
echo "Release: $tag"
echo "SHA-256: $digest"
