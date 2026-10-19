# Gaming DNS — reproducible GitHub Actions build

This package is laid out as a repository root. Upload the **contents** of this folder to the root of the GitHub repository; do not upload the ZIP as a single file and do not put the project inside an extra `dns-main/` directory.

## Important migration from previous builds

Previous workflows attempted to patch `android/settings.gradle` in a project that had not reliably been generated/copied, causing `FileNotFoundError`. This build no longer relies on the repository's old `android/` directory. It generates a fresh Android platform with pinned Flutter 3.38.10, overlays the custom manifest and Kotlin service from `android_custom/`, detects both `settings.gradle` and `settings.gradle.kts`, then patches compatible AGP/Kotlin/Gradle versions.

To prevent a stale workflow from continuing to fail, delete old files under `.github/workflows/` (especially `build_apk.yml`) before adding `.github/workflows/gaming-dns-build.yml`. Only **Gaming DNS Android Build v5** should run for this build.

## Build steps

1. Extract this ZIP.
2. In the GitHub repository, replace the project files with the contents of the extracted folder. Ensure `.github/workflows/gaming-dns-build.yml` is at the repository root under `.github/workflows/`.
3. Delete old workflow files from `.github/workflows/` so an outdated workflow does not run at the same time.
4. Commit and push to `main` or `master`, or open Actions and manually run **Gaming DNS Android Build v5**.
5. On success, download `Gaming-DNS-Release-APK-v5` from the workflow run's Artifacts section.
6. On failure, download `Gaming-DNS-Build-Logs-v5`. It includes the failing command's logs.

## Toolchain

- Flutter 3.38.10 / Dart 3.10.9
- Java 17
- Android Gradle Plugin >= 8.12.1
- Kotlin >= 2.2.0
- Gradle wrapper >= 8.13 for AGP 8.x
- Android minSdk 24 (required by share_plus 13.x)

The workflow uses a fresh Android scaffold and the debug signing configuration for test APKs. For store release, configure a private release keystore using GitHub Secrets; never commit a keystore or password to the repository.

## If the build fails

Open the **Gaming DNS Android Build v5** run, not an older failed run. Download `Gaming-DNS-Build-Logs-v5` and share the log file for the first failing step. The workflow no longer references `android/settings.gradle` directly; it detects Groovy and Kotlin DSL settings files and emits a clear error if Flutter fails to generate them.

For the exact repository replacement steps, see [UPLOAD-CHECKLIST.txt](UPLOAD-CHECKLIST.txt).


## Build Fix v6

The import-file picker was migrated to the file_picker 12+/13 API (`FilePicker.pickFile()` returns `PlatformFile?`). The previous `FilePicker.platform.pickFiles()` call no longer compiles with the dependency version resolved by CI.
