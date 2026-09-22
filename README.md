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

### Ubuntu ARM64 command-line setup

Run the installer as your normal user. It uses `sudo` for Ubuntu packages and
installs SDK files under `$HOME/Android/Sdk`:

```bash
./scripts/setup-android-arm64.sh
source "$HOME/.config/android-arm64/env.sh"
./gradlew :app:assembleDebug
```

When sourced inside an Android Gradle project, `env.sh` walks upward to locate
the Gradle root, reads literal `compileSdk`/`compileSdkVersion`,
`buildToolsVersion`, version-catalog keys (`agp` and `androidGradlePlugin`),
direct Android plugin declarations, and a project `org.gradle.java.home`
setting. It
selects JDK 11 for AGP 7 and earlier or JDK 17 for AGP 8 and later; an explicit
JDK 11, 17, or 21 path in the project properties takes precedence. It downloads
a missing declared Android SDK platform and
build-tools package, then replaces the downloaded build-tools executables with
the native ARM64 Ubuntu tools. `compileSdk` and `buildToolsVersion` supplied by a
version catalog (including the standard `libs.versions.toml`) is supported.
Values supplied by variables or convention plugins cannot be determined without
running Gradle, so the script reports that it did not install that package.

Projects that contain `externalNativeBuild`, `CMakeLists.txt`, `Android.mk`, or
an `ndkVersion` are treated as native projects. The activated shell installs the
host CMake/Ninja prerequisites, selects the requested NDK (or the documented
default), verifies its ARM64-host LLVM tools and CMake toolchain, and exports
`ANDROID_NDK_HOME`/`ANDROID_NDK_ROOT` only for that shell. Unsupported NDK
revisions fail explicitly rather than downloading Google's x86-64 Linux NDK.
The downloaded ARM64 NDK archive is checksum-verified before it is installed.
For NDK r29 the installer uses the GNU/Linux AArch64 release (not its
Android/Bionic-host variant) and installs Kitware's checksum-verified AArch64
CMake 4.1.0 alongside the SDK. The CMake directory is prepended to `PATH` only
for native projects; Ninja remains the native Ubuntu package.

For a manually provisioned Ubuntu ARM64 host, the native prerequisites are
`cmake`, `ninja-build`, `make`, `pkg-config`, `build-essential`, `libc6-dev`,
`tar`, and `xz-utils`. These are the same packages installed by
`setup-android-arm64.sh`; CMake 4.2.3 and Ninja 1.13.2 were manually installed
for the NDK sample validation environment on 2026-09-11.

Use `--sdk-root /absolute/path` to choose another SDK directory. For unattended
setup, `--accept-licenses` accepts the Android SDK licenses on your behalf.
The installer requires Ubuntu aarch64, network access, and sudo access. It is
safe to rerun and preserves unrelated shell and Gradle settings.
If an administrator already installed the listed Ubuntu prerequisites, use
`--skip-system-packages` to configure the SDK without invoking sudo.

The installer installs ARM64 OpenJDK 11, 17, and 21, including the Java compilers,
and verifies each installation. This sample continues to use JDK 11.
It uses Ubuntu's Python-based F-Droid `sdkmanager` and native ARM64 tools.
It configures SDK executable links and the user-level Gradle setting
`android.aapt2FromMavenOverride=/usr/bin/aapt2` so AGP does not execute its
downloaded x86-64 AAPT2. It also sets `org.gradle.java.home` to JDK 11; this setting
affects other Gradle projects for this user. New Bash sessions load the environment
automatically. Existing terminals need the `source` command above.

For another project requiring JDK 17, select it for both the Gradle launcher and
daemon (the command-line property overrides the user-level JDK 11 setting):

```bash
source "$HOME/.config/android-arm64/env.sh"
export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-arm64
export PATH="$JAVA_HOME/bin:$PATH"
./gradlew -Dorg.gradle.java.home="$JAVA_HOME" :app:assembleDebug
```

For JDK 21, replace `java-17-openjdk-arm64` with `java-21-openjdk-arm64`.
Use the Java version supported by that project's Gradle and Android Gradle
Plugin versions. Rerun the installer without `--skip-system-packages` to add
JDK 17 and 21 to an existing installation.

The debug APK is `app/build/outputs/apk/debug/app-debug.apk`. Verify or install it:

```bash
apksigner verify --verbose app/build/outputs/apk/debug/app-debug.apk
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

No Android Studio, emulator, or NDK is required for this sample. A connected,
authorized Android device is needed only for the `adb install` step.

Support
-------

- Stack Overflow: http://stackoverflow.com/questions/tagged/android

If you've found an error in this sample, please file an issue:
https://github.com/android/views-widgets

Patches are encouraged, and may be submitted by forking this project and
submitting a pull request through GitHub. Please see CONTRIBUTING.md for more details.