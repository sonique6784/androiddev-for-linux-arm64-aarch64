Android RecyclerView Sample (Kotlin)
====================================

This application implements a RecyclerView in Kotlin with ListAdapter, onClickListener 
and Headers. If you are looking for a simpler sample, look at the RecyclerViewSimple sample
in the directory.


Introduction
------------

Sample demonstrating the use of [RecyclerView][1] to layout elements with a
[LinearLayoutManager][2].

[RecyclerView][1] can display large datasets that can be scrolled
efficiently by recycling a limited number of views. [ListAdapter][3] is used to 
efficiently compute diffs when items are added/removed from the list. Click listeners can be
defined when [ViewHolder][4] views are instantiated. 


[1]: https://developer.android.com/reference/kotlin/androidx/recyclerview/widget/RecyclerView
[2]: https://developer.android.com/reference/androidx/recyclerview/widget/LinearLayoutManager
[3]: https://developer.android.com/reference/androidx/recyclerview/widget/ListAdapter
[4]: https://developer.android.com/reference/androidx/recyclerview/widget/RecyclerView.ViewHolder

Pre-requisites
--------------

- JDK 11
- Android SDK platform 30 and build-tools 29.0.2
- Android Gradle Plugin 4.1.0 (Gradle 6.5 is downloaded by the wrapper)

Screenshots
-------------

![image](https://user-images.githubusercontent.com/46006059/98028846-8b6df700-1dc3-11eb-9f0b-ad93569be189.png)

Getting Started
---------------

To build this project, use "Import Project" in Android Studio.

### Linux ARM64 command-line setup

This workspace keeps the sample in `views-widgets-samples/RecyclerViewKotlin`.
To recreate the clone from an empty workspace, run:

```bash
git clone --depth 1 --filter=blob:none --sparse https://github.com/android/views-widgets-samples.git views-widgets-samples
git -C views-widgets-samples sparse-checkout set RecyclerViewKotlin
```

The sample still declares `jcenter()`, which no longer serves artifacts. Switch
both repository blocks to `mavenCentral()` before building:

```bash
sed -i 's/jcenter()/mavenCentral()/g' views-widgets-samples/RecyclerViewKotlin/build.gradle
```

Run the root installer as your normal user. It supports Ubuntu and Debian 13
on ARM64, selects the matching internal platform backend, and keeps managed
JDKs, native tools, SDK files, and Gradle state under
`~/.local/share/android-arm64/`. Ubuntu installs its host prerequisites with
`sudo apt-get`; Debian keeps its downloaded Android host tools user-local.
Review the Android SDK terms before using the explicit license-acceptance flag.

```bash
./setup-android-arm64.sh --accept-licenses
source "$HOME/.config/android-arm64/env.sh"
cd views-widgets-samples/RecyclerViewKotlin
./gradlew :app:assembleDebug
```

The installer is safe to rerun. `--accept-licenses` records license acceptance
only when you have authorized it. `--sdk-root /absolute/path` selects a
different SDK location, `--skip-system-packages` uses already-provisioned
host prerequisites, and `--emulator waydroid` additionally provisions the
Waydroid emulator described below. `--emulator avd` imports an existing ARM64
Android Virtual Device as described below. The project uses its own Gradle 6.5
wrapper and Android Gradle Plugin 4.1.0; do not use Debian's older `gradle`
package. The installer overrides Gradle's x86-64 AAPT2 download with the
native ARM64 tool.

The public command remains `setup-android-arm64.sh`. Distribution-specific
provisioning lives in internal modules under `lib/android-arm64/platforms/`;
adding another supported Linux distribution requires a new module that
implements the shared backend contract, not another user-facing setup script.
Emulator support follows the same shape under
`lib/android-arm64/emulators/` and is opt-in through `--emulator NAME`.

The debug APK is `views-widgets-samples/RecyclerViewKotlin/app/build/outputs/apk/debug/app-debug.apk`.
From the project directory, verify it with:

```bash
apksigner verify --verbose app/build/outputs/apk/debug/app-debug.apk
```

Android Studio and an NDK are not needed to build. Installing the APK with
`adb install -r` targets a connected, authorized Android device or one of the
opt-in emulators below.

### Android emulator (Waydroid)

`--emulator waydroid` provisions [Waydroid](https://waydro.id/) as the Android
emulator after the normal toolchain install. It is the one step that needs
`sudo`: Debian enables `trixie-backports` (the only archive carrying `waydroid`
and `python3-gbinder`), and Ubuntu adds the official Waydroid repository on
releases that predate the Ubuntu archive copy. Android images are downloaded
once, as GAPPS by default; `--waydroid-image vanilla` selects the smaller image
without Google apps.

```bash
./setup-android-arm64.sh --accept-licenses --emulator waydroid
source "$HOME/.config/android-arm64/env.sh"
android_arm64_emulator_install views-widgets-samples/RecyclerViewKotlin/app/build/outputs/apk/debug/app-debug.apk
android_arm64_emulator_launch <package.name>
```

The generated helpers treat Waydroid as a normal adb device:
`android_arm64_emulator_start`, `android_arm64_emulator_doctor`,
`android_arm64_emulator_stop`, `android_arm64_emulator_status`,
`android_arm64_emulator_connect`, `android_arm64_emulator_install`,
`android_arm64_emulator_launch`, `android_arm64_emulator_logcat`, and
`android_arm64_emulator_show_ui`. The first adb connection raises a USB
debugging prompt inside the Waydroid window; accept it once with
`android_arm64_emulator_show_ui` on screen.

`android_arm64_emulator_start` re-invokes
`setup-android-arm64.sh --emulator-start waydroid`, which never touches the
package manager, so a reboot only needs that one command to bring the emulator
back. Both that command and setup wait for Android to reach the network, and if
it does not, `emulator_doctor` takes over: in a VM without working 3D
acceleration, SurfaceFlinger aborts on GPU buffers, which silently stalls
Android before it ever gets an address, and therefore before adb exists. The
doctor reads the crash records under `~/.local/share/waydroid/data/`, and when
it finds that failure it applies Waydroid's documented software-rendering fix
(`ro.hardware.gralloc=default`, `ro.hardware.egl=swiftshader`, then
`sudo waydroid upgrade -o`) and restarts the session, without ever overwriting
a GL driver you configured yourself. Run it on demand with
`android_arm64_emulator_doctor` or
`setup-android-arm64.sh --emulator-doctor waydroid`. `--skip-system-packages`
likewise makes the emulator step verify-only. Waydroid runs in a Wayland
session: the container service starts anywhere, but the session has to be
started from a Wayland desktop.

The window is phone sized by default: setup writes a display override of
`320x690` pixels plus a derived `ro.sf.lcd_density` of 130 (scaled from the
1080x2340 @ 440 dpi reference, so apps lay out at a normal ~393 dp phone
width) into `/var/lib/waydroid/waydroid.cfg`. That fits a 1280x768 desktop
with room to spare instead of stretching across the whole screen.
`--waydroid-size WIDTHxHEIGHT` (each side 100-9999) picks a different size;
the density follows from the width, and an existing installation picks the
setting up on the next setup run, which restarts the session.

Waydroid does not provide a title-bar setting in `waydroid.cfg`; window
decorations depend on the desktop compositor. Where the compositor decorates
the Waydroid surface, use its title bar to move the window. GNOME does not add
a title bar, but setup prints a reminder that you can hold Super and drag the
window to move it. Desktop shortcuts can also resize or maximize it (for
example, Alt+F8 to resize and Super+Up to maximize in GNOME). Starting a
session never opens a window by itself, so after a reboot run
`android_arm64_emulator_start` and `android_arm64_emulator_show_ui`.

### Android Virtual Devices (experimental)

Create a new Medium Phone AVD from an installed or downloadable ARM64 Android
system image. List image package IDs, then use one with `--avd-create`. The
interactive picker offers the same images and calls the same CLI creation
command, so both routes create the same files. These commands do not need KVM,
an emulator binary, root access, or the rest of the build toolchain:

```bash
./setup-android-arm64.sh --avd-list-images
./setup-android-arm64.sh --avd-create My_Phone \
  --avd-image 'system-images;android-36;google_apis_playstore_ps16k;arm64-v8a'
# Or choose an image and enter a name in the terminal picker:
./setup-android-arm64.sh --avd-tui
./setup-android-arm64.sh --avd-list
```

The package ID above is an example; use an ID currently shown by
`--avd-list-images`. The selected image is downloaded from Google's published
catalog if it is not installed and its declared size and checksum are checked.
Verified ZIP archives are kept under
`~/.local/share/android-arm64/cache/avd-images/` and reused on retries.
`--avd-list-images --json` supplies the picker and scripts. Created AVDs live
under `~/.local/share/android-arm64/avd/home/`; creation never overwrites an
existing name. The newest AVD becomes active. Use
`./setup-android-arm64.sh --avd-select My_Phone` to switch devices after
stopping any running AVD. `--sdk-root /absolute/path` selects another SDK root;
later AVD commands use the saved root by default.

Creation writes a 1080×2400, 420 dpi, 2 GB RAM, four-core Medium Phone
configuration with a 10 GB data partition. Creation accepts SDK images with
either `userdata.img` or an image-provided `data/` directory. The current QEMU
runtime can initialize writable disks only from `userdata.img`; `data/`
directory images can be created but are not yet bootable through this backend.
QEMU startup is experimental. On first AVD setup, the installer fetches the
pinned Android QEMU source and builds its Linux AArch64 engine with Ranchu's
`goldfish_pipe` and `goldfish_fb` devices. The source, build tree, resolved
Android project manifest, and versioned engine are kept under
`~/.local/share/android-arm64/cache/android-qemu/` and
`~/.local/share/android-arm64/avd/qemu/`. This build can take a long time and
needs substantial free disk space; the source checkout uses depth-1 history to
reduce Git storage. KVM is used when `/dev/kvm` is accessible;
otherwise QEMU falls back to TCG software emulation. The machine and Android
image compatibility have not yet passed a boot acceptance test. A compatible
prebuilt binary can override the managed build with `--avd-qemu-binary`.

To fetch a precompiled Linux AArch64 emulator explicitly, run
`./get-android-emulator-aarch64.sh`. This uses the latest release from the
[community Linux AArch64 emulator project](https://github.com/Changqing-JING/android-emulator-aarch64-linux/releases),
which is separate from Google's SDK releases. The script requires the release
asset's published SHA-256, verifies its size and ZIP contents, checks that its
Android Emulator launcher and QEMU engine are Linux AArch64 binaries, and
registers the package for this project's AVD backend. The package launches
through Android Emulator's AVD interface. Verified archives are cached under
`~/.local/share/android-arm64/cache/community-android-emulator/`; installations
and release metadata live under `~/.local/share/android-arm64/avd/qemu/community/`.
Run the script again to check for a newer release. Use `--state-root /absolute/path`
if setup uses a nondefault `ANDROID_ARM64_STATE_ROOT`. An existing registered
package is reused by later AVD setup; without one, setup builds the pinned
Android QEMU source.

```bash
./setup-android-arm64.sh --accept-licenses
./setup-android-arm64.sh --avd-select My_Phone
./setup-android-arm64.sh --emulator avd
```

The `--emulator avd` setup reuses a registered emulator package when present;
otherwise it builds/registers QEMU. It then starts the selected AVD.
Later starts use `--emulator-start avd` or
`android_arm64_emulator_start` from the generated environment.

#### Import an existing AVD

`--emulator avd` stages an existing ARM64 Android Virtual Device separately.
The installer builds the pinned Android `qemu-system-aarch64` engine if it is
not already present, then invokes it directly with the kernel, ramdisk,
system/vendor images, and qcow2 writable disks. The direct QEMU launch has not
passed a boot test. Graphics and the adb TCP property must be validated on a
Linux ARM64 host before this path can be considered supported. Pass
`--avd-qemu-binary` to use a compatible prebuilt Android QEMU instead.

The supplied sample is `~/avd/Medium_Phone.ini` (capital `P`) and
`~/avd/Medium_Phone.avd`. Its configuration requires
`system-images;android-37.2;google_apis_playstore_ps16k;arm64-v8a`, which is
not included with the AVD files. Setup checks Google's published system-image
metadata for that exact package and verifies the downloaded archive checksum.
The package was absent from the current
[Google Play image feed](https://dl.google.com/android/repository/sys-img/google_apis_playstore/sys-img2-2.xml)
when this path was added,
so this sample cannot complete import until it is republished or an exact
image is obtained separately. The AVD does not record its original system
image revision, so boot and app data checks are required before treating a
downloaded replacement as compatible.

```bash
./setup-android-arm64.sh --accept-licenses --emulator avd \
  --avd-ini "$HOME/avd/Medium_Phone.ini"
source "$HOME/.config/android-arm64/env.sh"
android_arm64_emulator_start
android_arm64_emulator_status
```

The installer verifies the three qcow2 backing chains, copies the AVD under
`~/.local/share/android-arm64/avd/home/`, and regenerates its `.ini` with a
Linux path. This importer currently requires the sample's userdata,
encryption-key, and cache overlay layout. The copied AVD is about 4.3 GB. Its
old macOS-generated `hardware-qemu.ini` is left out of the copy. Launch uses a
cold boot, GTK display, and host-forwarded adb TCP port `127.0.0.1:5555`; saved
Quick Boot snapshots are not loaded. The original files under `~/avd/` are
not modified. The usual `android_arm64_emulator_connect`,
`install`, `launch`, `logcat`, `stop`, and `doctor` helpers are available after
sourcing the environment. If startup fails, run
`android_arm64_emulator_doctor` and read the managed `avd/emulator.log`.

A successful import must reach `sys.boot_completed=1` and retain previously
installed app data after a stop and restart. Test both TCG and KVM where
available. This acceptance check must pass before the AVD path can be
considered supported.

Support
-------

- Stack Overflow: http://stackoverflow.com/questions/tagged/android

If you've found an error in this sample, please file an issue:
https://github.com/android/views-widgets

Patches are encouraged, and may be submitted by forking this project and
submitting a pull request through GitHub. Please see CONTRIBUTING.md for more details.
