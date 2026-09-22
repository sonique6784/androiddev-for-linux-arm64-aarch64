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
different SDK location, and `--skip-system-packages` uses already-provisioned
host prerequisites. The project uses its own Gradle 6.5
wrapper and Android Gradle Plugin 4.1.0; do not use Debian's older `gradle`
package. The installer overrides Gradle's x86-64 AAPT2 download with the
native ARM64 tool.

The public command remains `setup-android-arm64.sh`. Distribution-specific
provisioning lives in internal modules under `lib/android-arm64/platforms/`;
adding another supported Linux distribution requires a new module that
implements the shared backend contract, not another user-facing setup script.

The debug APK is `views-widgets-samples/RecyclerViewKotlin/app/build/outputs/apk/debug/app-debug.apk`.
From the project directory, verify it with:

```bash
apksigner verify --verbose app/build/outputs/apk/debug/app-debug.apk
```

Android Studio, an emulator, and an NDK are not needed. Installing the APK with
`adb install -r` requires a connected, authorized Android device.

Support
-------

- Stack Overflow: http://stackoverflow.com/questions/tagged/android

If you've found an error in this sample, please file an issue:
https://github.com/android/views-widgets

Patches are encouraged, and may be submitted by forking this project and
submitting a pull request through GitHub. Please see CONTRIBUTING.md for more details.
