## 1.0.6

- Added environment variable:
  - DART_SPAWNER_DEBUG
  - DART_SPAWNER_STARTUP_TIMEOUT
  - DART_SPAWNER_ISOLATE_CHECK_PING_TIMEOUT

## 1.0.5

- Renamed `runCommand` to `runProcess`.
  - Returns a `ProcessInfo`.
- Added `runDartVM`, to start a new Dart VM.

## 1.0.4

- `DartProject.cleanDartPubGetGeneratedFiles`: 
  - Fix `deleteDirectory`.

## 1.0.3

- `projectPackageConfigUri`:
  - Return `.dart_tool/package_config.json`, since `.packages` is deprecated.
- Added `runDartPubGet`, `ensureProjectDependenciesResolved`,
  `existsProjectPackageConfigUri` and `cleanDartPubGetGeneratedFiles`.
- Improve tests:
  - Test spawn of file in a different project (`test/test_project`),
    with different dependencies.
- Change package `pedantic` (deprecated) to `lints`.
- lints: ^1.0.1

## 1.0.2

- Improved `spawnedMain` console logging.

## 1.0.1

- Adjust package description.
- Adjust `README.md`.
  - Added `codecov.io` badge.

## 1.0.0

- Support to spawn Dart entry points: script, file and Uri.
  - Allow the use of another project/package dependencies while
    running a spawned Dart entry point.
- Added code coverage.
- Initial version.
