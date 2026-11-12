## 1.3.1

- `DartProject.runDartVM`:
  - A kernel entrypoint (`.dill`) is run with an explicit `--packages` (the
    `package_config.json` `dart run` uses in the working directory). Since
    Dart 3.14, `dart run <file>.dill` in a package with build hooks starts the
    program with no package config: `Isolate.packageConfig` and
    `Isolate.resolvePackageUri` return `null`, so `package:` resources can't
    be resolved.
  - Added the `packageConfig` parameter (explicit `--packages`).
- Added `DartProject.isKernelFile` and `DartProject.resolvePackageConfigFile`.

## 1.3.0

- `DartSpawner`:
  - `spawnDartURI` (and `spawnDart` with a `Uri`): a relative file `Uri`
    (no scheme, e.g. `Uri.file('bin/main.dart')` or
    `Uri.parse('bin/main.dart')`) is now resolved against the working
    directory. `Isolate.spawnUri` resolved it against the current isolate's
    script URI. `file:`, `package:`, `http(s):`, `data:` and absolute URIs are
    used as they are.
  - Added `resolveRelativeFileUri`.
- `SpawnedIsolate`:
  - Fix the exit detection with the VM service enabled (always the case
    under `dart test --coverage`): an isolate that didn't answer an
    `Isolate.ping` within `isolateCheckPingTimeout` (2s), for example a
    script blocking its event loop or a loaded machine, was taken as exited
    and `exitCode` completed with `0` while it was still running.
    - The `onExit`/`onError` isolate ports are the source of truth for the
      exit.
    - An isolate paused at exit (`--pause-isolates-on-exit`, which delays
      `onExit`) is now detected through the VM service `getIsolate` RPC
      (a `PauseExit` pause event). A failed or timed out request is never
      taken as an exit.
    - `isolateCheckPingTimeout` is now the timeout of that request.
  - `stop`: returns `false` (without stopping again) when another `stop` is
    in progress, or when the isolate exits while it's starting.
- `DartProject`:
  - `runProcess`/`runDartVM`: added `drainOutput` (default `false`), to
    consume and discard the process `stdout`/`stderr`. Without
    `catchOutput`, `redirectOutput` or `drainOutput` the output is still not
    consumed (the caller may read it), and a process that writes more than
    the OS pipe buffer blocks.
- Tests:
  - Relative `Uri` spawned from another working directory.
  - A script blocking its event loop for longer than
    `isolateCheckPingTimeout` with the VM service enabled (with and without
    `--pause-isolates-on-exit`, plain and managed): not reported as exited.
  - `drainOutput` with a 1 MiB child output.

## 1.2.2

- async_extension: ^1.2.24

## 1.2.1

- `DartSpawner`:
  - `spawnDartFile` (and `spawnDart` with a `File` or a file path): fix
    relative paths, which `Isolate.spawnUri` resolved against the current
    isolate's script URI instead of the working directory. The file is now
    resolved with `File.absolute`.
- `ProcessInfo`:
  - `exitCode`: when the output is caught or redirected, also wait (up to 5s
    after the exit) for `stdout`/`stderr` to be consumed, so `output` and
    `errorOutput` are complete once it completes. Previously they could still
    be empty right after `exitCode` completed.
- `DartProject`:
  - `runDartPubGet`: drain the `pub get` output (an undrained process that
    prints more than the OS pipe buffer never exits) and include it in the
    `StateError` thrown on failure.
  - `runProcess`: document that, without `catchOutput`/`redirectOutput`, the
    caller must drain `ProcessInfo.process` `stdout`/`stderr`.
- Tests:
  - `spawnedMain` protocol tests in the test's own isolate group (so they are
    visible to `dart test --coverage`, which only collects that group).
  - Integration tests: arguments, a lot of output, self-terminated isolates,
    concurrent spawns, the same file twice, relative/absolute paths, relative
    project directory, `package:` URIs, stop right after spawn, observatory,
    managed stop timeout and managed scripts exiting without `stopped`.
  - A separate-VM runner (`test/fixtures/spawner_runner.dart`) for the
    `DART_SPAWNER_*` environment variables, SIGINT/SIGTERM handling,
    non-zero exit codes, argument passing and process output draining.
  - `test/test_project`: Dart 3 SDK constraint (`^3.13.0`) and `xml: ^7.1.0`.

## 1.2.0

- `DartSpawner`:
  - Honour the `startupTimeout` constructor parameter (it was ignored), and
    use it for the managed (`usesSpawnedMain`) startup instead of a fixed 45s.
  - An uncaught error in the spawned isolate now completes `exitCode` with
    `uncaughtErrorExitCode` (255, as the `dart` command) instead of `0`.
    The error is available at `uncaughtError` (a `RemoteError`).
  - A failure to spawn (`IsolateSpawnException`, startup timeout, managed
    script exiting before calling `spawnedMain`) closes the isolate ports,
    kills the isolate, completes `exitCode` with 255 and is available at
    `spawnError`.
  - Managed scripts: `exitCode` also completes when the isolate exits without
    reporting `stopped`; `SpawnedIsolate.stop` waits for the script's `stop`
    callback (up to `managedStopTimeout`) and then kills the isolate.
  - Fix the Dart VM detection, which rejected VM service protocol versions
    with a `0` minor version.
- `DartProject`:
  - Added `projectResolutionDirectory`: supports pub workspace members
    (`resolution: workspace`), resolving `projectPackageConfigUri` and
    `projectPubspecLockFile` at the workspace root.
  - `existsProjectPackageConfigUri`: return `false` (instead of throwing) when
    the project directory is resolved asynchronously.
- `SpawnedIsolate`: fix a concurrent modification error when `stop` is called
  after the isolate finished.
- Tests: unit tests for the tools, extensions and `DartProject`; integration
  tests spawning scripts, `File`s and `Uri`s, error propagation, managed
  scripts, a separate project and a pub workspace member.
- Dart CI: `actions/checkout@v7`, `codecov/codecov-action@v7`.
- sdk: ^3.13.0

- path: ^1.9.1
- yaml: ^3.1.4
- async_extension: ^1.2.23
- lints: ^6.1.0
- test: ^1.33.0
- dependency_validator: ^5.1.0
- coverage: ^1.16.0

## 1.1.0

- Dart CI: update and optimize jobs.
- sdk: '>=3.0.0 <4.0.0'

- path: ^1.8.3
- yaml: ^3.1.2
- async_extension: ^1.2.4
- lints: ^2.1.1
- test: ^1.24.6
- dependency_validator: ^3.2.2
- coverage: ^1.6.3

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
