---
name: android-arm64-distribution-backend
description: Add or update a Linux distribution backend for this repository's ARM64 Android setup installer. Use only when explicitly invoked.
---

# Android ARM64 distribution backend

Use this skill to add a supported Linux distribution to this repository's Android ARM64 installer. Work within the existing shared installer design: keep distribution-specific logic in `lib/android-arm64/platforms/<distribution>.sh`, and put shared behavior in `lib/android-arm64/common.sh` only when every backend needs it.

Read [the backend contract](references/backend-contract.md) before editing. It records the required functions, dispatch registration, provisioning approaches, and validation commands.

## Workflow

1. Inspect `common.sh`, every existing platform module, the contract test, and the README before choosing the implementation.
2. Confirm the distribution's stable identifier from `/etc/os-release`, supported versions, package manager, ARM64 package availability, and whether its Android tools run natively on ARM64.
3. Add the distribution to the dispatcher and create its module. Implement every required backend function with the same paths and command contracts as the existing modules.
4. Verify the distribution's ARM64 repositories provide every command in the required-tool table: `sdkmanager`, `adb`, `fastboot`, `aapt`, `aapt2`, `aidl`, `zipalign`, `split-select`, and `apksigner`. Also verify their runtime dependencies. If any command is unavailable, report the command and repositories checked; do not register the distribution as supported unless a verified user-local alternative is feasible.
5. Keep `--skip-system-packages` useful: it must avoid package-manager installation and fail clearly when prerequisites are absent. Do not add privileged commands to backends that follow the user-local provisioning model.
6. Update the supported-host text and setup documentation. Run the contract and syntax checks, then perform an installation and Gradle build on the target distribution when practical.

Do not weaken version checks or replace native ARM64 tooling with downloaded x86 Linux Android archives. Do not modify generated environment behavior unless the new backend has a concrete compatibility requirement.
