# Changelog

## 2.2.4+8 — file_picker 13 API compatibility

- Fixed the release build error: FilePicker.platform is not available in file_picker 13.
- Migrated file import to FilePicker.pickFile(), which returns PlatformFile? in file_picker 12+.
- Updated selected-file handling to use the returned file directly rather than the removed FilePickerResult wrapper.

## 2.2.3+7 — reproducible Android build

- Replaced the fragile Android scaffold patch workflow with a clean, pinned Flutter 3.38.10 scaffold.
- Stored custom Android manifest and Kotlin sources separately under `android_custom/` so CI no longer depends on stale files under `android/`.
- Added a Gradle preparation script that accepts the Android directory explicitly and detects both `settings.gradle` and `settings.gradle.kts`.
- Added explicit scaffold/Gradle validation, toolchain output and build logs.
- Renamed the workflow to `Gaming DNS Android Build v5` to distinguish it from older runs.
- Preserved the DNS inventory, real DNS tunnel and IPv4/IPv6 converter from 2.2.2.
