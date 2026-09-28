# Backend contract

Read this reference when adding or changing a distribution module.

## Integration points

`lib/android-arm64/common.sh` selects a backend using the `ID` value from `/etc/os-release`. Register a supported ID there and add `lib/android-arm64/platforms/<id>.sh` with all of these functions:

| Function | Parameters | Required behavior |
| --- | --- | --- |
| `backend_validate` | none | Accept only the distribution releases whose native ARM64 packages have been verified. On rejection, print the supported release requirement to stderr and return nonzero. |
| `backend_provision` | `skip` (`true` or `false`) | Ensure every command in the required-tool table is executable at the path returned by `backend_tool_path`. When `skip=false`, install or create the needed local toolset. When `skip=true`, do not invoke the package manager; identify the missing command or package in the error and return nonzero. Export any library paths needed while provisioning. |
| `backend_provision_jdk` | JDK version: `11`, `17`, or `21` | Ensure an ARM64 JDK is present at `backend_jdk_path "$version"`, with an executable `bin/javac`. The common installer invokes JDK 11 during normal setup and can request 17 or 21 later through `--ensure-jdk`. |
| `backend_jdk_path` | JDK version | Print only the absolute JDK home containing `bin/java` and `bin/javac`. |
| `backend_tool_path` | tool name | Print only the absolute executable path for one supported tool. It must not download, install, or write files. |
| `backend_environment` | none | Emit shell `export` commands needed for the generated `env.sh` to run backend tools in a new shell. Emit nothing when no extra environment is needed. |
| `backend_provision_emulator` | emulator name (`waydroid` or `avd`), skip (`true` or `false`) | Ensure the distribution has the emulator's native prerequisites. Waydroid uses its distro package and may need a repository; AVD needs `qemu-img` and, unless `--avd-qemu-binary` supplies an override, the Android QEMU source-build toolchain. The managed builder fetches a pinned Android QEMU revision with Ranchu devices. When `skip=true`, do not invoke the package manager; name missing prerequisites in the error and return nonzero. |

The common installer calls `backend_provision` before a normal installation and before `--ensure-jdk`. It creates SDK shims, the Gradle AAPT2 override, and `~/.config/android-arm64/env.sh`; a backend must not reimplement those behaviors.

Emulator support is opt-in through `--emulator NAME`. `backend_provision_emulator` owns distribution-specific prerequisites: image downloads, services and runtime helpers live in `lib/android-arm64/emulators/<emulator>.sh`, which implements `emulator_validate`, `emulator_install`, `emulator_init`, `emulator_start`, `emulator_doctor`, and `emulator_environment`. The `--emulator-start` and `--emulator-doctor` actions reuse those functions and, like `--ensure-jdk`, run before `backend_provision`, so restarting or diagnosing a provisioned emulator never touches the package manager. Emulator-specific flags (`--waydroid-image`, `--waydroid-size`, `--avd-ini`, and `--avd-qemu-binary`) are parsed by the common installer and consumed inside the selected module.

## Required native ARM64 Android tools

Before declaring a distribution supported, verify its package repositories provide native ARM64 versions of every required command below. Package names may differ from the command names; record the selected package names in the backend’s provisioning code or comments when that removes ambiguity.

| Command passed to `backend_tool_path` | Used for | Availability requirement |
| --- | --- | --- |
| `sdkmanager` | Downloading Android platforms and build tools; accepting SDK licenses | Required. Its Python or other runtime dependencies must also work after sourcing `env.sh`. |
| `adb` | Android Debug Bridge and generated platform-tools metadata | Required. |
| `fastboot` | Generated platform-tools directory | Required. |
| `aapt` | Build-tools compatibility shim | Required. |
| `aapt2` | Gradle’s ARM64 resource-packaging override | Required; this is essential because older Android Gradle Plugin releases download x86 AAPT2 binaries. |
| `aidl` | Build-tools compatibility shim | Required. |
| `zipalign` | Build-tools compatibility shim | Required. |
| `split-select` | Build-tools compatibility shim | Required. |
| `apksigner` | APK signing and verification | Required; if it is a Java archive wrapper, it must use `JAVA_HOME`. |

Also ensure the selected packages bring in or explicitly provision each runtime dependency required by those commands, including shared libraries, Java libraries, Python modules, and executable interpreters. A package repository that provides only an x86 Android command-line archive does not satisfy this requirement.

If any required command has no compatible ARM64 package or cannot run on the target release, stop the backend work and report the exact missing command, the repositories checked, and whether a verified user-local artifact is feasible. Do not add the distribution to the dispatcher as supported until every required command is available through native packages or an approved verified user-local alternative.

## Existing provisioning models

Ubuntu installs native packages with `apt` and uses system JDK paths. Debian downloads Debian packages into `$ANDROID_ARM64_STATE_ROOT`, extracts a user-local sysroot, and downloads checksum-verified Temurin ARM64 JDK archives. Choose the model that fits the target distribution:

- Use native distribution packages when they include compatible ARM64 Android command-line tools and their runtime libraries.
- Use user-local, checksum-verified artifacts when system packages are unsuitable or privileged installation is not appropriate.
- Keep all backend-owned user-local files below `$ANDROID_ARM64_STATE_ROOT`; do not store installer state in the repository or SDK root.
- If an extracted tool needs library or Python paths, export them in both provisioning and `backend_environment` so the generated environment works in a new shell.

## Change checklist

- Add the `/etc/os-release` ID to `android_arm64_load_backend`.
- Add all seven functions to the new platform module, including `backend_provision_emulator`, and verify that the distribution's repositories actually provide the emulator package it installs.
- Verify every required-tool table command on the distribution’s ARM64 repositories before adding support.
- Make `--skip-system-packages` fail with the missing command or package, without running the package manager.
- Update `android_arm64_usage` and README support text.
- Preserve `--accept-licenses`, `--sdk-root`, and `--ensure-jdk` behavior.
- Avoid SDK packages containing x86-only executables; the shared flow redirects build and platform tools to native backend binaries.
- If a shared-contract change is unavoidable, update every module and `tests/backend-contract.sh` in the same change.

## Validation

Run from the repository root:

```bash
bash -n setup-android-arm64.sh lib/android-arm64/common.sh lib/android-arm64/platforms/*.sh tests/backend-contract.sh
./tests/backend-contract.sh
./setup-android-arm64.sh --help
```

On the supported ARM64 distribution, run the installer with `--accept-licenses`, source `~/.config/android-arm64/env.sh`, confirm each required command is executable, and build an Android Gradle project. Verify the resulting APK with `apksigner verify --verbose` when the project produces one.
