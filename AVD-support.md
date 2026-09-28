# Create and import ARM64 AVDs on Linux ARM64

## Summary

Use `~/avd/Medium_Phone.ini` and `~/avd/Medium_Phone.avd` as the acceptance sample. The AVD targets Android `37.2`, `arm64-v8a`, and the **Google APIs Play Store 16 KB page size** image. Its userdata, encryption key, and cache qcow2 backing chains are intact. The SDK system image is missing, and generated hardware settings contain macOS paths.

## Implementation

- **Prove the QEMU path:** Build/pin an Android-compatible `qemu-system-aarch64` for Linux ARM64 and cold boot a staged AVD with both TCG and KVM where available. Android's QEMU source has Linux ARM64 targets and documents Ranchu devices, but this project's generic `virt` launch has not yet been proven against current SDK images. [AOSP QEMU build configuration](https://android.googlesource.com/platform/external/qemu/+/refs/heads/emu-main-dev/CMakeLists.txt), [Ranchu platform notes](https://android.googlesource.com/platform/external/qemu/+/emu-master-dev/android/docs/ANDROID-KERNEL.TXT)
- **Restore the missing image:** Query Google's published system-image metadata for `system-images;android-37.2;google_apis_playstore_ps16k;arm64-v8a`. Verify its archive checksum before installing into the suite's SDK root. Require its kernel, ramdisk, system, and vendor images; stop if the package is unavailable. The AVD does not record its original system image revision, so successful boot and preserved data are the compatibility check. [Android Emulator file layout](https://developer.android.com/studio/run/emulator-commandline)
- **Stage the AVD safely:** Copy the `.ini` and `.avd` directory to managed state, correct the `.ini` path, preserve the qcow2 overlays and their backing files, and leave the supplied sample untouched.
- **Integrate with setup:** Build Android's QEMU source for Linux AArch64 at a pinned revision, with Ranchu's `goldfish_pipe` and `goldfish_fb`. Keep source/build/install state under the managed state root and allow `--avd-qemu-binary` as a validated override. Provide start, stop, status, doctor, adb, install, launch, and logcat helpers; retain Waydroid as a separate option.

## Acceptance

On Linux ARM64, cold boot the staged sample with TCG and with KVM where available. Confirm adb reports `sys.boot_completed=1`, inspect existing app data, then stop and restart to confirm persistence. Check reruns, missing SDK packages or backing files, acceleration selection, and Waydroid regression. Do not advertise AVD support until this passes.

## Current implementation status

The guarded importer, official SDK image lookup, staged copy, managed pinned Android QEMU source build, QEMU launch path, and diagnostics are implemented in the script suite. The current workspace has no `/dev/kvm`, Android QEMU build environment, or matching SDK system image. The Android 37.2 sample image is not listed in the feed checked when this path was developed. QEMU device compatibility, display, adb transport, boot, and persistence remain unverified; AVD support is experimental until acceptance passes on a Linux ARM64 host.

## New AVD creation

`setup-android-arm64.sh --avd-list-images` lists installed and downloadable `arm64-v8a` SDK images from Google's official Android, Google APIs, and Play Store feeds. `--json` provides the same catalog as structured output. `--avd-create NAME --avd-image PACKAGE_ID` downloads and verifies missing images, then writes a Medium Phone AVD under managed state. `--avd-tui` uses the same creation command; `--avd-list` and `--avd-select NAME` list and switch devices. Creation and selection do not require KVM. QEMU boot uses KVM when the device is accessible and TCG otherwise. The device profile uses 1080×2400, 420 dpi, four cores, 2 GB RAM, and a 10 GB data partition. [AOSP AVD manager handling for images with a data directory](https://android.googlesource.com/platform/tools/base/+/aded20e36ace721c0c3753b3d05d30a4261a2135)

Creation, switching, catalog discovery, and the initial QEMU launcher are implemented. Cold boot, graphical output, adb transport, and persistence checks remain outstanding on Linux ARM64. The sample import's Android `37.2` image blocker also remains.
