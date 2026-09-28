# Reproducing the Android QEMU ARM64 build

This records the successful manual build performed on the current Linux
AArch64 host. The automated builder in
`lib/android-arm64/emulators/build-android-qemu.sh` describes the intended
managed build, but it was **not** the path used for this successful compile.
The manual build needed local workarounds for the shallow checkout, host Qt
tools, tcmalloc, and Qt DBus linking. It produced the Android Emulator 35.6.3
`qemu-system-aarch64` binary; booting an AVD is a separate, not-yet-verified
step.

## Source and build locations

- Workspace source checkout: `.android-qemu-build-state/cache/android-qemu/source`
- No-space source view used by CMake: `/home/test/android-qemu-source-nospace`
- QEMU project revision used by the successful build: `ae9d18d2b6261179fbd57fffec720a04f7bfb053`
- Manifest branch: `emu-master-dev`
- Build directory: `/tmp/android-qemu-build-state/cache/android-qemu/build/objs3`
- Result: `/tmp/android-qemu-build-state/cache/android-qemu/build/objs3/qemu/linux-aarch64/qemu-system-aarch64`

The CMake project did not handle the workspace path containing a space. A
no-space source view was therefore used. Its local fixes described below are
build-environment workarounds, not changes to the tracked workspace source.

## APT dependencies recorded on this host

The package history records these install commands (they can be combined on a
fresh host):

```bash
sudo apt-get install -y --no-install-recommends \
  ca-certificates curl git python3 cmake ninja-build make pkg-config \
  build-essential libglib2.0-dev libpixman-1-dev libssl-dev zlib1g-dev \
  libfdt-dev libslirp-dev libusb-1.0-0-dev libncurses-dev libgtk-3-dev

sudo apt install autoconf automake libtool
sudo apt install libgbm-dev
sudo apt install libtcmalloc-minimal4t64
```

The tcmalloc package installed on this host was `libtcmalloc-minimal4t64`
version `2.16-1` for `arm64`. It supplies the runtime library but not the
unversioned linker name required by this build.

## Checkout

The checkout used Repo depth 1 / partial clone. The successful build used the
QEMU project revision resolved from the `emu-master-dev` manifest:
`ae9d18d2b6261179fbd57fffec720a04f7bfb053` (35.6.3 Canary).

```bash
repo init -u https://android.googlesource.com/platform/manifest \
  -b emu-master-dev --depth=1 --partial-clone \
  --clone-filter=blob:limit=10M --repo-rev=v2.50
repo sync -c -j4 --no-use-superproject
repo sync -c -j4 --no-use-superproject \
  prebuilts/android-emulator-build/qt \
  prebuilts/android-emulator-build/common
git -C external/qemu fetch --no-tags \
  https://android.googlesource.com/platform/external/qemu \
  ae9d18d2b6261179fbd57fffec720a04f7bfb053
git -C external/qemu checkout --detach \
  ae9d18d2b6261179fbd57fffec720a04f7bfb053
git -C external/qemu submodule update --init --recursive
```

The checkout also needed the `prebuilts/android-emulator-build/qt` and
`prebuilts/android-emulator-build/common` projects. The ARM64 Qt and
common-library prebuilts used were `linux-aarch64`. Netsim was unavailable in
the successful build and disabled by CMake.

The separate managed builder lock at
`lib/android-arm64/emulators/android-qemu.lock` currently names a different
revision (`e915419a...`). The root `android-qemu-build.sh` intentionally pins
the `ae9d18d2...` revision used by this recorded successful compile; those two
build paths should not be treated as interchangeable.

## Local build-view adjustments

These steps were applied only in the no-space source view:

1. Put the downloaded tcmalloc runtime at
   `prebuilts/android-emulator-build/common/tcmalloc/linux-aarch64/lib/` as
   `libtcmalloc_minimal.so.4`, then add the linker name:

   ```bash
   ln -sfn libtcmalloc_minimal.so.4 \
     prebuilts/android-emulator-build/common/tcmalloc/linux-aarch64/lib/libtcmalloc_minimal.so
   ```

2. The ARM64 Qt `moc`, `uic`, and `rcc` tools were used for the build's
   `linux-x86_64/libexec` host-tool lookups. In this host-only view those
   lookups were symlinked to their matching tools under `linux-aarch64`.

3. `Snapshotter.cpp` needed `#include <thread>` for the installed GCC. That
   include was added in the no-space build view using an atomic file replace;
   the tracked checkout file was not edited.

4. The build scripts expect a cross sysroot libstdc++ location that does not
   exist on this native AArch64 machine. The following environment override
   maps the native runtime library into the generated runtime bundle:

   ```bash
   export ENV_CACHE_RUNTIME_OS_DEPENDENCIES='/usr/lib/aarch64-linux-gnu/libstdc++.so.6>lib64/libstdc++.so.6'
   ```

## Configure and build

Configure from the no-space view. `CMAKE_CXX_STANDARD_LIBRARIES` adds the
Qt DBus shared library at the end of C++ link commands, where its Qt Core
references resolve:

```bash
cmake -B /tmp/android-qemu-build-state/cache/android-qemu/build/objs3 \
  -G Ninja \
  -DOPTION_CRASHUPLOAD=NONE \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CXX_FLAGS= \
  -DCMAKE_EXE_LINKER_FLAGS= \
  -DCMAKE_CXX_STANDARD_LIBRARIES=/home/test/android-qemu-source-nospace/prebuilts/android-emulator-build/qt/linux-aarch64/lib/libQt6DBusAndroidEmu.so \
  -DCMAKE_TOOLCHAIN_FILE=/home/test/android-qemu-source-nospace/external/qemu/android/build/cmake/toolchain-linux-aarch64.cmake \
  -DOPTION_SDK_TOOLS_BUILD_NUMBER=standalone-0 \
  -DPython_EXECUTABLE=/usr/bin/python3 \
  -DOPTION_SDK_TOOLS_REVISION=35.6.3 \
  -DOPTION_TEST_LOGS=/tmp/android-qemu-build-state/cache/android-qemu/build/objs3/testlogs \
  -DCMAKE_MAKE_PROGRAM=/usr/bin/ninja \
  -DGFXSTREAM=FALSE \
  /home/test/android-qemu-source-nospace/external/qemu
```

Build with limited parallelism. `CMAKE_BUILD_PARALLEL_LEVEL=1` keeps nested
ExternalProject builds serialized; Ninja itself runs two jobs:

```bash
ENV_CACHE_RUNTIME_OS_DEPENDENCIES='/usr/lib/aarch64-linux-gnu/libstdc++.so.6>lib64/libstdc++.so.6' \
  CMAKE_BUILD_PARALLEL_LEVEL=1 \
  ninja -C /tmp/android-qemu-build-state/cache/android-qemu/build/objs3 \
  -j2 qemu-system-aarch64
```

## Verify the artifact

```bash
file /tmp/android-qemu-build-state/cache/android-qemu/build/objs3/qemu/linux-aarch64/qemu-system-aarch64

LD_LIBRARY_PATH=/tmp/android-qemu-build-state/cache/android-qemu/build/objs3/lib64:/home/test/android-qemu-source-nospace/prebuilts/android-emulator-build/qt/linux-aarch64/lib \
  /tmp/android-qemu-build-state/cache/android-qemu/build/objs3/qemu/linux-aarch64/qemu-system-aarch64 -version
```

The successful result identified as an ELF 64-bit ARM AArch64 executable and
reported Android Emulator version `35.6.3.0` (build ID `standalone-0`). It
recognizes the `-accel` and `-ranchu` options. A guest boot, graphical display,
ADB connection, and Android image compatibility have not yet been verified.

## Launching the `testphone` AVD

When launching the built binary directly, tell Qt where this build's ARM64
plugins live. For a desktop session with X11 or XWayland:

```bash
export ANDROID_AVD_HOME="$HOME/.local/share/android-arm64/avd/home"
export ANDROID_SDK_ROOT="$HOME/.local/share/android-arm64/sdk"
export LD_LIBRARY_PATH="/tmp/android-qemu-build-state/cache/android-qemu/build/objs3/lib64:$HOME/android-qemu-source-nospace/prebuilts/android-emulator-build/qt/linux-aarch64/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export QT_PLUGIN_PATH="$HOME/android-qemu-source-nospace/prebuilts/android-emulator-build/qt/linux-aarch64/plugins"
export QT_QPA_PLATFORM_PLUGIN_PATH="$QT_PLUGIN_PATH/platforms"
export QT_QPA_PLATFORM=xcb

"/tmp/android-qemu-build-state/cache/android-qemu/build/objs3/qemu/linux-aarch64/qemu-system-aarch64" \
  -avd testphone -accel tcg -ranchu -partition-size 2048 -no-snapshot
```

`-partition-size 2048` caps the writable data partition at 2 GB to fit the
available disk space on this host. To inspect Qt plugin discovery if startup
still fails, run the same command with `QT_DEBUG_PLUGINS=1` exported.

## Reproduction caveats

- This build tree is already configured and contains compiled objects; a
  clean rebuild needs substantial free disk space. At the end of this build,
  about 5.4 GB remained on the host filesystem.
- The apt package list is from `/var/log/apt/history.log`; the Android build
  checkout also depends on the Android prebuilts and Repo projects listed
  above.
- The `/tmp` build path and `/home/test/android-qemu-source-nospace` view are
  host-local paths. Recreate equivalent no-space paths or replace them
  consistently in the CMake command and environment.
- This is a record of the successful manual build path. The managed script
  should be updated and validated before treating it as an equivalent,
  one-command reproduction.
- Run `./android-qemu-build.sh` to repeat the configure, build, and artifact
  checks using the prepared shallow checkout. The script does not install APT
  packages or fetch the Android source tree; it reports missing dependencies
  and prints the artifact location.
