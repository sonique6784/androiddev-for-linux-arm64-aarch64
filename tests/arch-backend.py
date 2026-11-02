#!/usr/bin/env python3
"""Arch backend behavior checks; never install packages or access the network."""

import hashlib
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class ArchBackendTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="arch backend ")
        self.directory = Path(self.temp.name)
        self.module = self.directory / "arch.sh"
        shutil.copyfile(ROOT / "lib/android-arm64/platforms/arch.sh", self.module)
        self.state = self.directory / "state with spaces"
        self.state.mkdir()
        self.lock = self.directory / "arch-packages.lock"
        digest = hashlib.sha256(b"fixture archive").hexdigest()
        self.lock.write_text(f"fixture 1 arm64 {digest} https://example.invalid/fixture.deb\n")
        self.host = self.state / "host/arch"

    def tearDown(self):
        self.temp.cleanup()

    def run_shell(self, script, success=True):
        prelude = (
            "set -eu -o pipefail\n"
            f"source {shlex.quote(str(self.module))}\n"
            f"ANDROID_ARM64_STATE_ROOT={shlex.quote(str(self.state))}\n"
            "sudo() { echo UNEXPECTED_SUDO >&2; return 99; }\n"
            "curl() { echo UNEXPECTED_DOWNLOAD >&2; return 99; }\n"
        )
        result = subprocess.run(["bash", "-c", prelude + script], text=True, capture_output=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("UNEXPECTED_SUDO", result.stderr)
        self.assertNotIn("UNEXPECTED_DOWNLOAD", result.stderr)
        return result

    def cache_archive(self, content=b"fixture archive"):
        cache = self.host / "debs"
        cache.mkdir(parents=True)
        (cache / "fixture.deb").write_bytes(content)

    def fake_extractor(self, valid=True):
        # Exercise the real staging, checksums, publication and cleanup code.
        return """
bsdtar() {
    case "$1" in
        -tf) echo data.tar.xz ;;
        -xOf) cat "$2" ;;
        -xf) cat >/dev/null; printf extracted > "$4/tool" ;;
    esac
}
""" + ("_arch_check_sysroot() { [[ -f \"$1/tool\" ]]; }\n" if valid else
         "_arch_check_sysroot() { echo 'Unresolved fixture dependency' >&2; return 1; }\n")

    def test_dispatch_without_version_id(self):
        for identity in ("arch", "archarm"):
            with self.subTest(identity=identity):
                script = f"""
ANDROID_ARM64_SCRIPT_DIR={shlex.quote(str(ROOT))}
builtin source "$ANDROID_ARM64_SCRIPT_DIR/lib/android-arm64/common.sh"
uname() {{ echo aarch64; }}
pacman() {{ return 0; }}
source() {{
    if [[ "$1" == /etc/os-release ]]; then ID={identity}; unset VERSION_ID;
    else builtin source "$@"; fi
}}
android_arm64_load_backend
[[ "$ANDROID_ARM64_PLATFORM" == arch ]]
"""
                self.run_shell(script)

    def test_x86_host_rejected(self):
        result = self.run_shell(f"""
builtin source {shlex.quote(str(ROOT / 'lib/android-arm64/common.sh'))}
uname() {{ echo x86_64; }}
android_arm64_load_backend
""", success=False)
        self.assertIn("Linux ARM64 is required", result.stderr)

    def test_install_policy(self):
        result = self.run_shell("""
pacman() { [[ "$1" == -Si ]]; }
sudo() { printf '%s\n' "$*"; }
_arch_install_packages android-tools jdk11-openjdk
""")
        self.assertEqual(result.stdout.strip(), "pacman -S --needed android-tools jdk11-openjdk")

    def test_missing_repository_package(self):
        result = self.run_shell("pacman() { return 1; }; _arch_install_packages unavailable", success=False)
        self.assertIn("Package unavailable", result.stderr)

    def test_skip_reports_native_packages(self):
        result = self.run_shell("pacman() { return 1; }; backend_provision true", success=False)
        self.assertIn("jdk11-openjdk", result.stderr)
        self.assertIn("python-requests", result.stderr)

    def test_skip_without_toolset(self):
        result = self.run_shell("_arch_provision_local_tools true", success=False)
        self.assertIn("Missing complete local Arch Android toolset", result.stderr)
        self.assertFalse(self.host.exists())

    def test_cached_extraction_and_skip_rerun(self):
        self.cache_archive()
        self.run_shell(self.fake_extractor() + "_arch_provision_local_tools false\n_arch_provision_local_tools true\n")
        self.assertTrue((self.host / "sysroot/.complete").is_file())
        self.assertEqual((self.host / "sysroot/tool").read_text(), "extracted")
        self.assertFalse(list((self.host / "sysroots").glob(".extract.*")))

    def test_corrupt_archive_not_extracted(self):
        self.cache_archive(b"corrupt")
        result = self.run_shell(self.fake_extractor() + "_arch_provision_local_tools false", success=False)
        self.assertIn("Checksum mismatch for cached", result.stderr)
        self.assertFalse((self.host / "sysroot").exists())

    def test_corrupt_download_not_cached(self):
        result = self.run_shell("""
curl() {
    while (($#)); do
        if [[ "$1" == --output ]]; then printf corrupt > "$2"; return 0; fi
        shift
    done
    return 1
}
_arch_provision_local_tools false
""", success=False)
        self.assertIn("Checksum mismatch for downloaded", result.stderr)
        self.assertFalse((self.host / "debs/fixture.deb").exists())
        self.assertFalse((self.host / "sysroot").exists())

    def test_wrong_package_architecture_rejected(self):
        self.lock.write_text(self.lock.read_text().replace(" arm64 ", " amd64 "))
        result = self.run_shell("_arch_provision_local_tools false", success=False)
        self.assertIn("Unsupported package architecture", result.stderr)

    def test_extraction_failure_is_not_published(self):
        self.cache_archive()
        result = self.run_shell("""
bsdtar() {
    case "$1" in
        -tf) echo data.tar.xz ;;
        -xOf) return 1 ;;
        -xf) cat >/dev/null ;;
    esac
}
_arch_provision_local_tools false
""", success=False)
        self.assertIn("Could not extract", result.stderr)
        self.assertFalse((self.host / "sysroot").exists())
        self.assertFalse(list((self.host / "sysroots").glob(".extract.*")))

    def test_failed_validation_is_not_published_and_retries(self):
        self.cache_archive()
        self.run_shell(self.fake_extractor(valid=False) + "_arch_provision_local_tools false", success=False)
        self.assertFalse((self.host / "sysroot").exists())
        self.assertFalse(list((self.host / "sysroots").glob(".extract.*")))
        self.run_shell(self.fake_extractor() + "_arch_provision_local_tools false")
        self.assertTrue((self.host / "sysroot/.complete").exists())

    def test_manifest_change_requires_new_toolset(self):
        self.cache_archive()
        self.run_shell(self.fake_extractor() + "_arch_provision_local_tools false")
        original = os.readlink(self.host / "sysroot")
        self.lock.write_text(self.lock.read_text() + "# New toolset revision\n")
        self.run_shell(self.fake_extractor() + "_arch_provision_local_tools true", success=False)
        self.assertEqual(os.readlink(self.host / "sysroot"), original)
        self.run_shell(self.fake_extractor() + "_arch_provision_local_tools false")
        self.assertNotEqual(os.readlink(self.host / "sysroot"), original)

    def test_wrappers_through_sdk_symlinks(self):
        sysroot = self.host / "sysroot"
        (sysroot / "usr/bin").mkdir(parents=True)
        binary = sysroot / "usr/bin/aapt2"
        binary.write_text('#!/bin/bash\nprintf "%s\\n" "$LD_LIBRARY_PATH" "$@"\n')
        binary.chmod(0o755)
        java = self.directory / "custom jdk/bin/java"
        java.parent.mkdir(parents=True)
        java.write_text('#!/bin/bash\nprintf "%s\\n" "$@"\n')
        java.chmod(0o755)
        sdk = self.directory / "SDK build tools"
        sdk.mkdir()
        self.run_shell("_arch_write_wrappers")
        for tool in ("aapt2", "apksigner"):
            (sdk / tool).symlink_to(self.state / "bin" / tool)
        result = self.run_shell(f"""
export LD_LIBRARY_PATH=unrelated
{shlex.quote(str(sdk / 'aapt2'))} 'argument with spaces'
[[ "$LD_LIBRARY_PATH" == unrelated ]]
export JAVA_HOME={shlex.quote(str(java.parent.parent))}
{shlex.quote(str(sdk / 'apksigner'))} version
""")
        self.assertIn(str(sysroot / "usr/lib/7zip"), result.stdout)
        self.assertIn("argument with spaces", result.stdout)
        self.assertIn(str(sysroot / "usr/share/java/apksigner.jar") + ":" + str(sysroot / "usr/share/java/apksig.jar"), result.stdout)
        self.assertIn("com.android.apksigner.ApkSignerTool", result.stdout)

    def test_wrappers_replace_existing_backend_symlinks(self):
        directory = self.state / "bin"
        directory.mkdir()
        old = self.directory / "old binary"
        old.write_text("preserve previous backend")
        for tool in ("aapt", "aapt2", "aidl", "zipalign", "split-select", "sdkmanager", "apksigner"):
            (directory / tool).symlink_to(old)
        self.run_shell("_arch_write_wrappers")
        self.assertEqual(old.read_text(), "preserve previous backend")
        self.assertFalse((directory / "aapt2").is_symlink())
        self.assertTrue(os.access(directory / "aapt2", os.X_OK))

    def test_waydroid_skip_when_present(self):
        self.run_shell("waydroid() { :; }; backend_provision_emulator waydroid true")

    def test_avd_prebuilt_skips_build_dependencies(self):
        self.run_shell("qemu-img() { :; }; ANDROID_ARM64_AVD_QEMU_BINARY=/custom/qemu; backend_provision_emulator avd true")

    def test_avd_build_skip_reports_missing_packages(self):
        result = self.run_shell("qemu-img() { :; }; pacman() { return 1; }; backend_provision_emulator avd true", success=False)
        self.assertIn("repo", result.stderr)
        self.assertIn("gtk3", result.stderr)

    def test_unavailable_qemu_img(self):
        result = self.run_shell("command() { [[ \"$*\" == '-v qemu-img' ]] && return 1; builtin command \"$@\"; }; pacman() { return 1; }; backend_provision_emulator avd false", success=False)
        self.assertIn("Install a native qemu-img separately", result.stderr)


if __name__ == "__main__":
    unittest.main()
