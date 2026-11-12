import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'dart:isolate';

import 'package:async_extension/async_extension.dart';
import 'package:dart_spawner/dart_spawner.dart';
import 'package:path/path.dart' as pack_path;
import 'package:yaml/yaml.dart';

import 'dart_spawner_tools.dart';

typedef DartProjectLogger = void Function(String type, dynamic message);

/// Class to resolve a Dart project directory.
class DartProject {
  /// The target project directory (that contains a `pubspec.yaml` file).
  final Directory? _directory;
  final DartProjectLogger _logger;

  DartProject({
    this._directory,
    DartProjectLogger? logger,
    bool logToConsole = false,
  }) : _logger =
           logger ??
           (logToConsole ? ((t, m) => print('[$t] $m')) : ((t, m) {}));

  /// Logs a message.
  void log(String type, dynamic message) => _logger(type, message);

  Directory? _projectDirectory;

  /// The resolved project [Directory].
  FutureOr<Directory> get projectDirectory {
    var projDir = _projectDirectory;
    if (projDir == null) {
      final directory = _directory;
      if (directory != null) {
        _projectDirectory = projDir = directory.absolute;
        log('INFO', 'Resolved `projectDirectory`: $projDir');
        return projDir;
      } else {
        return Isolate.current.packageMainDirectory.resolveMapped((dir) {
          _projectDirectory = dir;
          log('INFO', 'Resolved `projectDirectory`: $dir');
          return dir;
        });
      }
    } else {
      return projDir;
    }
  }

  /// Returns a sub-[Uri] inside [projectDirectory].
  FutureOr<Uri> projectSubUri(String filePath) => projectDirectory
      .resolveMapped((projDir) => projDir.uri.resolve(filePath));

  /// Returns a sub-[File] inside [projectDirectory].
  FutureOr<File> projectSubFile(String filePath) =>
      projectDirectory.resolveMapped((projDir) {
        return File.fromUri(projDir.uri.resolve(filePath));
      });

  /// Returns a sub-[Directory] inside [projectDirectory].
  FutureOr<Directory> projectSubDirectory(String filePath) =>
      projectDirectory.resolveMapped((projDir) {
        return Directory.fromUri(projDir.uri.resolve(filePath));
      });

  /// The resolved project `pubspec.yaml` [File].
  FutureOr<File> get projectPubspecFile async => projectSubFile('pubspec.yaml');

  Map<String, dynamic>? _pubspec;

  /// The resolved project `pubspec.yaml` [Map].
  FutureOr<Map<String, dynamic>> get projectPubspec {
    var pubspec = _pubspec;
    if (pubspec == null) {
      return projectPubspecFile.resolveMapped((file) {
        if (!file.existsSync()) {
          throw StateError('Failed to locate `pubspec.yaml` at `${file.path}`');
        }

        var content = file.readAsStringSync();
        final yaml = loadYaml(content) as YamlMap;
        var pubspec = yaml.cast<String, dynamic>();

        _pubspec = pubspec;

        log('INFO', 'Resolved `projectPubspec`: ${pubspec.length} entries');

        return pubspec;
      });
    } else {
      return pubspec;
    }
  }

  /// The directory where `dart pub get` writes the resolution of the project
  /// (`pubspec.lock` and `.dart_tool/package_config.json`).
  ///
  /// Usually this is the [projectDirectory] itself. For a member of a
  /// [pub workspace](https://dart.dev/tools/pub/workspaces)
  /// (`resolution: workspace` in its `pubspec.yaml`) it is the workspace root:
  /// the nearest ancestor directory that holds
  /// `.dart_tool/package_config.json`. If no ancestor holds it yet (`pub get`
  /// not run), the [projectDirectory] is returned.
  FutureOr<Directory> get projectResolutionDirectory =>
      projectDirectory.resolveMapped((projDir) {
        if (_hasPackageConfig(projDir) || !_isWorkspaceMember(projDir)) {
          return projDir;
        }

        var dir = projDir.parent;
        while (true) {
          if (_hasPackageConfig(dir)) {
            log('INFO', 'Resolved workspace root: $dir');
            return dir;
          }
          var parent = dir.parent;
          if (parent.path == dir.path) break;
          dir = parent;
        }

        return projDir;
      });

  static bool _hasPackageConfig(Directory dir) =>
      _packageConfigFile(dir).existsSync();

  /// The `.dart_tool/package_config.json` [File] of [dir] (may not exist).
  /// Shared by [_hasPackageConfig] and [resolvePackageConfigFile].
  static File _packageConfigFile(Directory dir) =>
      File.fromUri(dir.uri.resolve('.dart_tool/package_config.json'));

  static bool _isWorkspaceMember(Directory dir) {
    var pubspecFile = File.fromUri(dir.uri.resolve('pubspec.yaml'));
    if (!pubspecFile.existsSync()) return false;
    try {
      var pubspec = loadYaml(pubspecFile.readAsStringSync());
      return pubspec is YamlMap && pubspec['resolution'] == 'workspace';
    } catch (_) {
      return false;
    }
  }

  /// The resolved project `pubspec.lock` [File].
  ///
  /// See [projectResolutionDirectory].
  FutureOr<File> get projectPubspecLockFile => projectResolutionDirectory
      .resolveMapped((dir) => File.fromUri(dir.uri.resolve('pubspec.lock')));

  Map<String, dynamic>? _projectLockFile;

  /// The resolved project `pubspec.lock` file as [YamlMap].
  FutureOr<Map<String, dynamic>> get projectPubspecLock {
    var projLockFile = _projectLockFile;
    if (projLockFile == null) {
      return projectPubspecLockFile.resolveMapped((lockFile) {
        if (!lockFile.existsSync()) {
          throw StateError(
            'No `pubspec.lock` file at `${lockFile.path}`. Run `pub get`.',
          );
        }

        final yaml = loadYaml(lockFile.readAsStringSync()) as YamlMap;
        var projectLockFile = yaml.cast<String, dynamic>();

        _projectLockFile = projectLockFile;

        log('INFO', 'Resolved `projectPubspecLock`: $projectLockFile');

        return projectLockFile;
      });
    } else {
      return projLockFile;
    }
  }

  /// Returns the version string of [package] at the target project dependencies.
  FutureOr<String?> getProjectDependencyVersion(String package) {
    return projectPubspecLock.resolveMapped((projectLock) {
      final ver = projectLock['packages'][package]?['version'] as String?;
      return ver;
    });
  }

  /// The resolved project library name.
  FutureOr<String?> get projectLibraryName => projectPackageName;

  /// The resolved project package name.
  FutureOr<String?> get projectPackageName =>
      projectPubspec.resolveMapped((pubspec) => pubspec['name'] as String?);

  /// The resolved project `.dart_tool/package_config.json` [Uri].
  ///
  /// For a pub workspace member this is the workspace root's
  /// `.dart_tool/package_config.json` (see [projectResolutionDirectory]).
  /// Falls back to the legacy `.packages` file in the [projectDirectory].
  ///
  /// Throws a [StateError] if none exists (`dart pub get` not run).
  FutureOr<Uri> get projectPackageConfigUri =>
      projectResolutionDirectory.resolveMapped((resolutionDir) {
        var fileJson = File.fromUri(
          resolutionDir.uri.resolve('.dart_tool/package_config.json'),
        );
        if (fileJson.existsSync()) {
          return fileJson.uri;
        }

        return projectSubFile('.packages').resolveMapped((filePack) {
          if (filePack.existsSync()) {
            return filePack.uri;
          }
          throw StateError(
            "Can't resolve project packageConfig: $fileJson ; $filePack",
          );
        });
      });

  /// Returns `true` if [projectPackageConfigUri] exists.
  FutureOr<bool> existsProjectPackageConfigUri() {
    try {
      var exists = projectPackageConfigUri.resolveMapped(
        (uri) => File.fromUri(uri).existsSync(),
      );
      if (exists is Future<bool>) {
        return exists.catchError((_) => false);
      }
      return exists;
    } catch (e) {
      return false;
    }
  }

  /// Runs `dart pub get` in the [projectDirectory].
  ///
  /// Throws a [StateError] (including the `pub` output) if it fails.
  Future<bool> runDartPubGet() async {
    var workingDir = await projectDirectory;
    // `catchOutput` drains the process output: an undrained `pub get` that
    // prints more than the OS pipe buffer would never exit.
    var processInfo = await runProcess(
      'dart',
      ['pub', 'get'],
      workingDirectory: workingDir.path,
      catchOutput: true,
    );

    var ok = await processInfo.checkExitCode();
    if (!ok) {
      var output = '${processInfo.output}\n${processInfo.errorOutput}'.trim();
      throw StateError('Error running: dart pub get > $processInfo\n$output');
    }

    return ok;
  }

  /// Runs a new Dart VM.
  ///
  /// - [entrypoint] is the Dart entrypoint, usually a Dart file.
  /// - [args] is the arguments to pass to the [entrypoint].
  /// - [workingDirectory] is the [Process] working directory. If `null` will use the current working directory.
  /// - [packageConfig] is the `package_config.json` path passed to the VM
  ///   (`--packages`). If `null` and [entrypoint] is a kernel file (`.dill`),
  ///   it's the one `dart run` would use: see [resolvePackageConfigFile].
  ///   Since Dart 3.14, `dart run <file>.dill` in a package with build hooks
  ///   starts the program with no package config (`Isolate.packageConfig` and
  ///   `Isolate.resolvePackageUri` return `null`), so `package:` resources
  ///   can't be resolved; an explicit `--packages` keeps them working.
  ///   A relative [packageConfig] is relative to the current directory (not
  ///   to [workingDirectory]): it's passed as an absolute path.
  /// - [enableVMService] - if `true` runs Dart VM with `--enable-vm-service`.
  ///   - [vmServiceAddress] - the VM Service listen address.
  ///   - [vmServicePort] - the VM Service listen port.
  ///   - [pauseIsolatesOnStart] - if `true` pauses [Isolate] on VM start.
  ///   - [pauseIsolatesOnExit] - if `true` pauses [Isolate] on VM exit.
  ///   - [pauseIsolatesOnUnhandledExceptions] - if `true` pauses [Isolate] on Unhandled Exception.
  /// - If [handleSignals] is `true` kills the [Process] if `SIGINT` or `SIGTERM` is triggered in the host/current process.
  /// - If [redirectOutput] is `true` redirects the [Process] outputs to the host/current [stdout] and [stderr].
  /// - If [catchOutput] is `true` catches the [Process] outputs to [ProcessInfo.outputBuffer] and [ProcessInfo.errorOutputBuffer].
  /// - [stdoutFilter] is a filter for the [Process] `stdout`. Useful to remove sensitive data.
  /// - [stderrFilter] is a filter for the [Process] `stderr`. Useful to remove sensitive data.
  /// - If [drainOutput] is `true` the [Process] outputs are consumed and discarded.
  ///
  /// See [runProcess] (the output must be consumed by one of [redirectOutput],
  /// [catchOutput] and [drainOutput], or by the caller).
  Future<ProcessInfo> runDartVM(
    String entrypoint,
    List<String> args, {
    bool enableVMService = false,
    String? vmServiceAddress,
    int? vmServicePort,
    bool pauseIsolatesOnStart = false,
    bool pauseIsolatesOnExit = false,
    bool pauseIsolatesOnUnhandledExceptions = false,
    String? workingDirectory,
    String? packageConfig,
    bool handleSignals = false,
    bool redirectOutput = false,
    bool catchOutput = false,
    bool drainOutput = false,
    String Function(String o)? stdoutFilter,
    String Function(String o)? stderrFilter,
    void Function(ProcessSignal signal)? onSignal,
  }) async {
    if (packageConfig == null) {
      if (isKernelFile(entrypoint)) {
        packageConfig = resolvePackageConfigFile(
          workingDirectory: workingDirectory,
        )?.path;
      }
    } else {
      // The child VM resolves a relative `--packages` against its own
      // working directory: made absolute here, against the caller's.
      packageConfig = pack_path.normalize(File(packageConfig).absolute.path);
    }

    String vmService = '';
    if (!enableVMService) {
      pauseIsolatesOnStart = false;
      pauseIsolatesOnExit = false;
      pauseIsolatesOnUnhandledExceptions = false;
    } else {
      if (vmServicePort != null && vmServicePort <= 1) {
        vmServicePort = null;
      }

      if (vmServiceAddress != null) {
        vmServiceAddress = vmServiceAddress.trim();
        if (vmServiceAddress.isEmpty) {
          vmServiceAddress = null;
        }
      }

      if (vmServicePort == null) {
        var freePort = await getFreeListenPort(
          ports: [8181, 8171, 8191],
          startPort: 8161,
          endPort: 8191,
        );

        if (freePort != 8181) {
          vmServicePort = freePort;
        }
      }

      if (vmServiceAddress != null) {
        vmServicePort ??= 8181;
        vmService = '=$vmServicePort/$vmServiceAddress';
      } else if (vmServicePort != null) {
        vmService = '=$vmServicePort';
      }
    }

    return runProcess(
      'dart',
      [
        if (enableVMService) '--enable-vm-service$vmService',
        if (pauseIsolatesOnStart) '--pause-isolates-on-start',
        if (pauseIsolatesOnExit) '--pause-isolates-on-exit',
        if (pauseIsolatesOnUnhandledExceptions)
          '--pause-isolates-on-unhandled-exceptions',
        // A VM option: before `run`, so `dart run` still runs the build hooks.
        if (packageConfig != null) '--packages=$packageConfig',
        'run',
        entrypoint,
        ...args,
      ],
      workingDirectory: workingDirectory,
      handleSignals: handleSignals,
      redirectOutput: redirectOutput,
      catchOutput: catchOutput,
      drainOutput: drainOutput,
      stdoutFilter: stdoutFilter,
      stderrFilter: stderrFilter,
      onSignal: onSignal,
    );
  }

  /// Returns `true` if [entrypoint] is a Dart kernel file (`.dill`).
  static bool isKernelFile(String entrypoint) =>
      entrypoint.toLowerCase().endsWith('.dill');

  /// Returns the `.dart_tool/package_config.json` that `dart run` uses in
  /// [workingDirectory] (default: the current directory): the first one
  /// found in it or in a parent directory. Returns `null` if there's none.
  ///
  /// Used by [runDartVM] to pass `--packages` explicitly for a kernel
  /// entrypoint (see its `packageConfig` parameter).
  static File? resolvePackageConfigFile({String? workingDirectory}) {
    // Normalized: `Directory.parent` is lexical, so for an un-normalized path
    // (`/a/pkg/../other`) the walk would visit `/a/pkg`, which isn't an
    // ancestor of `/a/other`, and could pick up the wrong package config.
    var dir = Directory(
      pack_path.normalize(
        (workingDirectory != null
                ? Directory(workingDirectory)
                : Directory.current)
            .absolute
            .path,
      ),
    );

    while (true) {
      var file = _packageConfigFile(dir);
      if (file.existsSync()) return file;

      var parent = dir.parent;
      // The root directory is its own parent:
      if (parent.path == dir.path) return null;
      dir = parent;
    }
  }

  /// Returns a [ServerSocket] port free to listen.
  ///
  /// - [ports] is a [List] of ports to test.
  /// - [startPort] and [endPort] defines a range of ports to check.
  /// - If [shufflePorts] is `true` the ports order will be random.
  static Future<int?> getFreeListenPort({
    Iterable<int>? ports,
    Iterable<int>? skipPort,
    int? startPort,
    int? endPort,
    bool shufflePorts = false,
    Duration? testTimeout,
  }) async {
    var checkPortsSet = <int>{};
    if (ports != null) {
      checkPortsSet.addAll(ports);
    }

    if (startPort != null && endPort != null) {
      if (startPort <= endPort) {
        for (var p = startPort; p <= endPort; ++p) {
          checkPortsSet.add(p);
        }
      } else {
        for (var p = endPort; p <= startPort; ++p) {
          checkPortsSet.add(p);
        }
      }
    }

    var checkPorts = checkPortsSet.toList();

    if (skipPort != null) {
      checkPorts.removeWhere((p) => skipPort.contains(p));
    }

    if (shufflePorts) {
      checkPorts.shuffle();
    }

    for (var port in checkPorts) {
      if (await isFreeListenPort(port, testTimeout: testTimeout)) {
        return port;
      }
    }

    return null;
  }

  /// Returns `true` if [port] is free to listen.
  static Future<bool> isFreeListenPort(
    int port, {
    Duration? testTimeout,
  }) async {
    testTimeout ??= Duration(seconds: 1);

    try {
      var socket = await Socket.connect(
        'localhost',
        port,
        timeout: testTimeout,
      );
      try {
        socket.close();
      } catch (_) {}
      return false;
    } catch (_) {
      return true;
    }
  }

  /// Runs a [Process] command and returns it.
  ///
  /// - [commandName] is the command to be executed to start the [Process].
  /// - [args] is the arguments to pass to the [Process].
  /// - If [resolveCommandPath] is `true` resolves [commandName] to the local path of the command binary, using [executablePath].
  /// - [workingDirectory] is the [Process] working directory. If `null` will use the current working directory.
  /// - If [handleSignals] is `true` kills the [Process] if `SIGINT` or `SIGTERM` is triggered in the host/current process.
  ///   - [onSignal] is the hook for when a `SIGINT` or `SIGTERM` is redirected.
  /// - If [redirectOutput] is `true` redirects the [Process] outputs to the host/current [stdout] and [stderr].
  /// - If [catchOutput] is `true` catches the [Process] outputs to [ProcessInfo.outputBuffer] and [ProcessInfo.errorOutputBuffer].
  /// - [stdoutFilter] is a filter for the [Process] `stdout`. Useful to remove sensitive data.
  /// - [stderrFilter] is a filter for the [Process] `stderr`. Useful to remove sensitive data.
  /// - If [drainOutput] is `true` the [Process] outputs are consumed and
  ///   discarded (when not already consumed by [redirectOutput] or
  ///   [catchOutput]).
  ///
  /// If none of [redirectOutput], [catchOutput] and [drainOutput] is `true`,
  /// the [Process] `stdout` and `stderr` are not consumed (so the caller can
  /// read [ProcessInfo.process] `stdout`/`stderr` itself): the caller must
  /// drain them, otherwise a process that writes more than the OS pipe buffer
  /// blocks and never exits. Pass `drainOutput: true` when the output is not
  /// needed.
  Future<ProcessInfo> runProcess(
    String commandName,
    List<String> args, {
    bool resolveCommandPath = true,
    String? workingDirectory,
    bool handleSignals = false,
    bool redirectOutput = false,
    bool catchOutput = false,
    bool drainOutput = false,
    String Function(String o)? stdoutFilter,
    String Function(String o)? stderrFilter,
    void Function(ProcessSignal signal)? onSignal,
  }) async {
    String? binPath;
    if (resolveCommandPath) {
      binPath = await executablePath(commandName);
      if (binPath == null) {
        throw StateError('Error resolving `$commandName` binary!');
      }
    } else {
      binPath = commandName;
    }

    log(
      'INFO',
      'Process.start> $binPath $args > workingDirectory: $workingDirectory',
    );

    var process = await Process.start(
      binPath,
      args,
      workingDirectory: workingDirectory,
    );

    StreamSubscription<ProcessSignal>? listenSigInt;
    StreamSubscription<ProcessSignal>? listenSigTerm;

    if (handleSignals) {
      listenSigInt = ProcessSignal.sigint.watch().listen((s) {
        if (onSignal != null) onSignal(s);
        process.kill(ProcessSignal.sigint);
      });

      listenSigTerm = ProcessSignal.sigterm.watch().listen((s) {
        if (onSignal != null) onSignal(s);
        process.kill(ProcessSignal.sigterm);
      });
    }

    var processInfo = ProcessInfo(process, binPath, args, workingDirectory);

    var outputDecoder = systemEncoding.decoder;
    final stdoutFilterF = stdoutFilter ?? (o) => o;
    final stderrFilterF = stderrFilter ?? (o) => o;

    if (catchOutput || redirectOutput) {
      // `ProcessInfo.exitCode` waits for these, so the output is complete
      // when it completes.
      processInfo._outputDone.add(
        process.stdout.transform(outputDecoder).forEach((o) {
          o = stdoutFilterF(o);
          if (redirectOutput) stdout.write(o);
          if (catchOutput) processInfo.outputBuffer.add(o);
        }),
      );
      processInfo._outputDone.add(
        process.stderr.transform(outputDecoder).forEach((o) {
          o = stderrFilterF(o);
          if (redirectOutput) stderr.write(o);
          if (catchOutput) processInfo.errorOutputBuffer.add(o);
        }),
      );
    } else if (drainOutput) {
      processInfo._outputDone.add(process.stdout.drain<void>());
      processInfo._outputDone.add(process.stderr.drain<void>());
    }

    process.exitCode.then((_) {
      // ignore: unawaited_futures
      listenSigInt?.cancel();
      // ignore: unawaited_futures
      listenSigTerm?.cancel();
    });

    return processInfo;
  }

  /// Ensures that [projectDirectory] has the dependencies resolved.
  /// If not resolved runs `dart pub get`, calling [runDartPubGet].
  Future<bool> ensureProjectDependenciesResolved() async {
    var resolved = await existsProjectPackageConfigUri();
    if (resolved) {
      return true;
    }

    return runDartPubGet();
  }

  /// Deletes files generated by `dart pub get`:
  ///
  /// - [confirmProjectName] the project name at `pubspec.yaml`, to confirm cleanup.
  ///
  /// Deleted Files:
  /// - %projectDirectory/pubspec.lock
  /// - %projectDirectory/.packages
  /// - %projectDirectory/.dart_tool/**
  ///
  Future<bool> cleanDartPubGetGeneratedFiles({
    required String confirmProjectName,
    bool verbose = false,
  }) async {
    var projDir = await projectDirectory;

    if (!projDir.existsSync()) {
      return false;
    }

    var packageName = await projectPackageName;
    if (packageName != confirmProjectName) {
      return false;
    }

    var filePubspecLock = await projectSubFile('pubspec.lock');
    var filePackages = await projectSubFile('.packages');
    var dirDartTools = await projectSubDirectory('.dart_tool');

    deleteFile(projDir, filePubspecLock, verbose: verbose);
    deleteFile(projDir, filePackages, verbose: verbose);

    if (dirDartTools.existsSync()) {
      deleteDirectory(projDir, dirDartTools, recursive: true, verbose: verbose);
    }

    return true;
  }

  final Map<String, String> _whichExecutables = <String, String>{};

  /// Returns an executable binary path for [executableName].
  Future<String?> executablePath(
    String executableName, {
    bool refresh = false,
  }) async {
    executableName = executableName.trim();

    String? binPath;

    if (!refresh) {
      binPath = _whichExecutables[executableName];
      if (binPath != null && binPath.isNotEmpty) {
        return binPath;
      }
    }

    binPath = await _whichExecutableImpl(executableName);
    binPath ??= '';

    _whichExecutables[executableName] = binPath;

    log('INFO', 'executablePath($executableName): $binPath');

    return binPath.isNotEmpty ? binPath : null;
  }

  Future<String?> _whichExecutableImpl(String executableName) async {
    var locator = Platform.isWindows ? 'where' : 'which';
    var result = await Process.run(locator, [executableName]);

    if (result.exitCode == 0) {
      var binPath = '${result.stdout}'.trim();
      return binPath;
    } else {
      return null;
    }
  }
}

/// Executed [Process] information.
///
/// See [DartProject.runProcess].
class ProcessInfo {
  /// The executed [Process].
  final Process process;

  /// The binary path executed.
  final String binPath;

  /// The arguments passed to the process.
  final List<String> args;

  /// The [Process] working directory.
  final String? workingDirectory;

  ProcessInfo(this.process, this.binPath, this.args, this.workingDirectory);

  int? _exitCode;

  /// Completes when the `stdout`/`stderr` consumers set by
  /// [DartProject.runProcess] (`catchOutput`/`redirectOutput`/`drainOutput`)
  /// are done.
  final List<Future<void>> _outputDone = [];

  /// The [Process.exitCode] of [process].
  ///
  /// When the output is caught, redirected or drained (see
  /// [DartProject.runProcess]),
  /// it also waits (up to 5s after the exit, in case another process keeps
  /// the pipes open) for the output to be consumed, so [output] and
  /// [errorOutput] are complete.
  Future<int> get exitCode async {
    var exitCode = _exitCode;
    if (exitCode != null) return exitCode;

    exitCode = await process.exitCode;

    if (_outputDone.isNotEmpty) {
      await Future.wait(_outputDone.map((f) => f.catchError((_) {})))
          .timeout(Duration(seconds: 5), onTimeout: () => []);
    }

    return _exitCode ??= exitCode;
  }

  /// Returns `true` if [exitCode] matches [expectedExitCode].
  Future<bool> checkExitCode([int expectedExitCode = 0]) async {
    var exitCode = await this.exitCode;
    var ok = exitCode == expectedExitCode;
    return ok;
  }

  /// The [process] `stdout` output buffer.
  ///
  /// Only populated if [DartSpawner.runProcess] is called with `catchOutput: true`.
  List<String> outputBuffer = <String>[];

  /// The [process] `stderr` output buffer.
  ///
  /// Only populated if [DartSpawner.runProcess] is called with `catchOutput: true`.
  List<String> errorOutputBuffer = <String>[];

  /// The [process] `stdout` output as [String]. See [outputBuffer].
  ///
  /// Only populated if [DartSpawner.runProcess] is called with `catchOutput: true`.
  String get output => outputBuffer.join();

  /// The [process] `stderr` output as [String]. See [errorOutputBuffer].
  ///
  /// Only populated if [DartSpawner.runProcess] is called with `catchOutput: true`.
  String get errorOutput => errorOutputBuffer.join();

  @override
  String toString() {
    var exitCode = _exitCode != null ? ', exitCode: $_exitCode' : '';
    return 'ProcessInfo{ binPath: $binPath, args: $args, workingDirectory: $workingDirectory$exitCode }';
  }
}

String? _getEnv(String key) {
  var val = Platform.environment[key];
  if (val != null) {
    print('** [DartSpawner] Reading environment variable: "$key" = "$val"');
  }
  return val;
}

int? _getEnvAsInt(String key, {bool Function(int n)? validator}) {
  var val = _getEnv(key);
  if (val == null) return null;
  var n = int.tryParse(val.trim());
  if (n == null) return null;
  var ok = validator == null || validator(n);
  return ok ? n : null;
}

bool? _getEnvAsBool(String key) {
  var val = _getEnv(key);
  if (val == null) return null;
  val = val.trim().toLowerCase();
  return val == 'true' || val == '1' || val == 'on';
}

/// Class capable to spawn a Dart script/[File]/[Uri] into an [Isolate].
class DartSpawner extends DartProject {
  /// If `true` sets the debug mode, to avoid [Isolate] issues while debugging.
  ///
  /// - Set by environment variable: "DART_SPAWNER_DEBUG".
  static final bool debugMode = _getEnvAsBool('DART_SPAWNER_DEBUG') ?? false;

  /// The default startup timeout.
  ///
  /// - Set by environment variable: "DART_SPAWNER_STARTUP_TIMEOUT" (in seconds).
  static final Duration defaultStartupTimeout = Duration(
    seconds:
        _getEnvAsInt(
          'DART_SPAWNER_STARTUP_TIMEOUT',
          validator: (n) => n >= 2,
        ) ??
        45,
  );

  /// The default [Isolate] check timeout (see [isolateCheckPingTimeout]).
  ///
  /// - Set by environment variable: "DART_SPAWNER_ISOLATE_CHECK_PING_TIMEOUT" (in seconds).
  /// - When on [debugMode] is set to 3600 sec.
  static final Duration defaultIsolateCheckPingTimeout = Duration(
    seconds:
        _getEnvAsInt(
          'DART_SPAWNER_ISOLATE_CHECK_PING_TIMEOUT',
          validator: (n) => n >= 1,
        ) ??
        (debugMode ? 3600 : 2),
  );

  static int _idCounter = 0;

  final int id = ++_idCounter;

  /// The timeout to identify the [Isolate] startup.
  final Duration startupTimeout;

  /// The timeout of an [Isolate] check.
  ///
  /// The exit of a spawned isolate is detected by its `onExit`/`onError`
  /// ports. When the VM service is enabled, the spawned isolate is also
  /// checked periodically, through the VM service `getIsolate` RPC, for a
  /// pause at exit (`--pause-isolates-on-exit`), which delays the `onExit`
  /// message until the isolate is resumed. This is the timeout of that
  /// request: a request that times out (for example, under load) is not
  /// taken as an exit, the check is just retried later.
  ///
  /// (Until 1.2.x it was the timeout of an [Isolate.ping], and a ping timeout
  /// was taken as an exit.)
  final Duration isolateCheckPingTimeout;

  /// Constructs a new [DartSpawner].
  ///
  /// - [directory] the target project directory.
  /// - [startupTimeout] the timeout to identify the [Isolate] startup.
  ///   Defaults to [defaultStartupTimeout].
  DartSpawner({
    super.directory,
    super.logger,
    super.logToConsole,
    Duration? startupTimeout,
  }) : startupTimeout = startupTimeout ?? defaultStartupTimeout,
       isolateCheckPingTimeout = defaultIsolateCheckPingTimeout {
    logDebug(this);
  }

  static void logDebug(Object? m) {
    if (debugMode) {
      print('** [DartSpawner] $m');
    }
  }

  /// The exit code of the spawned Dart script/file.
  final Completer<int> exitCode = Completer<int>();

  /// Returns `true` if the spawned Dart script/file have finished.
  bool get isFinished => exitCode.isCompleted;

  /// The [exitCode] reported when the spawned isolate terminates with an
  /// uncaught error, or fails to start (same exit code the `dart` command
  /// uses for an uncaught exception).
  static const int uncaughtErrorExitCode = 255;

  /// How long [SpawnedIsolate.stop] waits for a managed script
  /// (see `usesSpawnedMain`) to run its `stop` callback before killing
  /// its isolate.
  static const Duration managedStopTimeout = Duration(seconds: 5);

  RemoteError? _uncaughtError;

  /// The uncaught error that terminated the spawned isolate, or `null`.
  ///
  /// When set, [exitCode] completes with [uncaughtErrorExitCode].
  RemoteError? get uncaughtError => _uncaughtError;

  Object? _spawnError;

  /// The error that prevented the spawned isolate from starting
  /// (for example an [IsolateSpawnException] or a [TimeoutException]),
  /// or `null`.
  ///
  /// When set, [exitCode] completes with [uncaughtErrorExitCode].
  Object? get spawnError => _spawnError;

  void _completeExitCode(int code) {
    if (!exitCode.isCompleted) {
      exitCode.complete(code);
    }
  }

  /// Records an error sent by the spawned isolate's `onError` port
  /// (`[error, stackTrace]`, both as [String]s).
  RemoteError _onUncaughtError(String spawnInfo, Object? msg) {
    var error = msg is List && msg.length == 2
        ? RemoteError('${msg[0]}', '${msg[1]}')
        : RemoteError('$msg', '');

    _uncaughtError ??= error;
    this.log('ERROR', '[$spawnInfo] Uncaught error: $error');

    // `errorsAreFatal` is `true`, so the isolate terminates.
    _completeExitCode(uncaughtErrorExitCode);

    return error;
  }

  void _onSpawnFailure(String spawnInfo, Object error) {
    _spawnError ??= error;
    this.log('ERROR', '[$spawnInfo] Spawn failed: $error');
    _completeExitCode(uncaughtErrorExitCode);
  }

  bool _spawned = false;

  /// Returns `true` if this instance already have spawned a script.
  bool get isSpawned => _spawned;

  void _markSpawned() {
    if (_spawned) {
      throw StateError('This instance can only can spawn 1 script!');
    }
    _spawned = true;
  }

  /// The spawned Dart entry.
  Object? spawnedEntry;

  /// The spawned type.
  String? spawnedType;

  static final RegExp filePathReservedChars = RegExp(r'[\r\n|?*":<>]');

  /// Returns `true` if [dartEntryPoint] is a [String] and a [File] path with a '.dart' extension.
  bool isDartFilePath(dynamic dartEntryPoint) {
    return dartEntryPoint is String &&
        !dartEntryPoint.contains(filePathReservedChars) &&
        dartEntryPoint.endsWith('.dart');
  }

  /// Spawn a Dart entry point (script, [File] or [Uri]).
  Future<SpawnedIsolate> spawnDart(
    dynamic dartEntryPoint,
    List<String> args, {
    String? debugName,
    bool enableObservatory = false,
    bool runObservatory = false,
    bool usesSpawnedMain = false,
  }) {
    if (dartEntryPoint is File) {
      return spawnDartFile(
        dartEntryPoint,
        args,
        debugName: debugName,
        enableObservatory: enableObservatory,
        runObservatory: runObservatory,
        usesSpawnedMain: usesSpawnedMain,
      );
    } else if (dartEntryPoint is Uri) {
      return spawnDartURI(
        dartEntryPoint,
        args,
        debugName: debugName,
        enableObservatory: enableObservatory,
        runObservatory: runObservatory,
        usesSpawnedMain: usesSpawnedMain,
      );
    } else if (dartEntryPoint is String) {
      if (isDartFilePath(dartEntryPoint)) {
        var dartFile = File(dartEntryPoint);
        return spawnDartFile(
          dartFile,
          args,
          debugName: debugName,
          enableObservatory: enableObservatory,
          runObservatory: runObservatory,
          usesSpawnedMain: usesSpawnedMain,
        );
      } else {
        return spawnDartScript(
          dartEntryPoint,
          args,
          debugName: debugName,
          enableObservatory: enableObservatory,
          runObservatory: runObservatory,
          usesSpawnedMain: usesSpawnedMain,
        );
      }
    } else {
      throw StateError(
        'Unsupported Dart entry point! type: ${dartEntryPoint.runtimeType} > $dartEntryPoint',
      );
    }
  }

  /// Spawn a Dart script.
  Future<SpawnedIsolate> spawnDartScript(
    String dartScript,
    List<String> args, {
    String? debugName,
    bool enableObservatory = false,
    bool runObservatory = false,
    bool usesSpawnedMain = false,
  }) {
    final dataUri = Uri.parse(
      'data:application/dart;charset=utf-8,${Uri.encodeComponent(dartScript)}',
    );

    return _spawnDart(
      dartScript,
      '<script>',
      dataUri,
      args,
      debugName: debugName,
      enableObservatory: enableObservatory,
      runObservatory: runObservatory,
      usesSpawnedMain: usesSpawnedMain,
    );
  }

  /// Spawn a Dart [File].
  ///
  /// A relative [dartFile] path is resolved against the current working
  /// directory (see [File.absolute]).
  Future<SpawnedIsolate> spawnDartFile(
    File dartFile,
    List<String> args, {
    String? debugName,
    bool enableObservatory = false,
    bool runObservatory = false,
    bool usesSpawnedMain = false,
  }) => _spawnDart(
    dartFile,
    'File',
    // A relative `File.uri` would be resolved by `Isolate.spawnUri` against
    // the current isolate's script URI, not the working directory.
    dartFile.absolute.uri,
    args,
    debugName: debugName,
    enableObservatory: enableObservatory,
    runObservatory: runObservatory,
    usesSpawnedMain: usesSpawnedMain,
  );

  /// Resolves a relative file [uri] (a relative path without a scheme, as
  /// `Uri.file('bin/main.dart')` and `Uri.parse('bin/main.dart')` return)
  /// against the current working directory ([Directory.current]).
  ///
  /// `Isolate.spawnUri` resolves a relative [Uri] against the current
  /// isolate's script URI, not the working directory, which is rarely what
  /// is meant by a relative file path.
  ///
  /// Any other [uri] is returned unchanged: URIs with a scheme (`file:`,
  /// `package:`, `http:`, `https:`, `data:`, ...), with an authority, or with
  /// an absolute path. (Note that Dart always normalizes the path of a
  /// `file:` URI to an absolute one: `Uri.parse('file:bin/main.dart')` is
  /// `file:///bin/main.dart`.)
  static Uri resolveRelativeFileUri(Uri uri) {
    if (uri.hasScheme ||
        uri.hasAuthority ||
        uri.hasAbsolutePath ||
        uri.path.isEmpty) {
      return uri;
    }

    // On Windows `Directory.current.uri` is `file:///C:/...`, and a relative
    // `Uri.file(r'bin\main.dart', windows: true)` has the path `bin/main.dart`.
    return Directory.current.uri.resolveUri(uri);
  }

  /// Spawn a Dart [Uri].
  ///
  /// A relative file [dartUri] (relative path, no scheme) is resolved against
  /// the current working directory (see [resolveRelativeFileUri]).
  /// `file:`, `package:`, `http(s):`, `data:` and absolute URIs are used as
  /// they are.
  Future<SpawnedIsolate> spawnDartURI(
    Uri dartUri,
    List<String> args, {
    String? debugName,
    bool enableObservatory = false,
    bool runObservatory = false,
    bool usesSpawnedMain = false,
  }) => _spawnDart(
    dartUri,
    'Uri',
    resolveRelativeFileUri(dartUri),
    args,
    debugName: debugName,
    enableObservatory: enableObservatory,
    runObservatory: runObservatory,
    usesSpawnedMain: usesSpawnedMain,
  );

  Future<SpawnedIsolate> _spawnDart(
    Object spawnEntry,
    String spawnType,
    Uri dartUri,
    List<String> args, {
    String? debugName,
    bool enableObservatory = false,
    bool runObservatory = false,
    bool usesSpawnedMain = false,
  }) async {
    if (!await _isIsolateSpawnUriSupported()) {
      throw StateError(
        "Can't call `Isolate.spawnUri`, not running in a Dart VM!`",
      );
    }

    if (usesSpawnedMain) {
      return _spawnManaged(
        spawnEntry,
        spawnType,
        dartUri,
        args,
        debugName,
        enableObservatory,
        runObservatory,
      );
    } else {
      return _spawn(
        spawnEntry,
        spawnType,
        dartUri,
        args,
        debugName,
        enableObservatory,
        runObservatory,
      );
    }
  }

  Future<SpawnedIsolate> _spawn(
    Object spawnEntry,
    String spawnType,
    Uri dataUri,
    List<String> args,
    String? debugName,
    bool enableObservatory,
    bool runObservatory,
  ) async {
    _markSpawned();

    var projectDirectory = await this.projectDirectory;

    if (!await ensureProjectDependenciesResolved()) {
      throw StateError(
        "Can't ensure that project dependencies are resolved: $projectDirectory",
      );
    }

    var projectPackageConfig = (await projectPackageConfigUri);
    var currentPackageConfig = await Isolate.packageConfig;

    late Isolate isolate;

    var exitPort = ReceivePort();
    var errorPort = ReceivePort();

    var spawnInfo = _spawnInfo(debugName);

    // ignore: unawaited_futures
    exitCode.future.then((code) {
      exitPort.close();
      errorPort.close();
      this.log('INFO', '[$spawnInfo] Exit Code: $code');
    });

    errorPort.listen((msg) {
      _onUncaughtError(spawnInfo, msg);
    });

    exitPort.listen((msg) {
      var stopped = false;

      if (msg is Map) {
        stopped = msg['status'] == 'stopped';
      } else if (msg == null) {
        stopped = true;
      }

      if (stopped) {
        _completeExitCode(0);
      }
    });

    this.log(
      'INFO',
      '[$spawnInfo] Spawning: {type: $spawnType, packageConfig: $projectPackageConfig} ; Dart Entry Point: $dataUri',
    );

    try {
      isolate = await Isolate.spawnUri(
        dataUri,
        args,
        null,
        errorsAreFatal: true,
        onExit: exitPort.sendPort,
        onError: errorPort.sendPort,
        packageConfig: (currentPackageConfig == projectPackageConfig
            ? null
            : projectPackageConfig),
        debugName: debugName,
      );
    } catch (e) {
      _onSpawnFailure(spawnInfo, e);
      rethrow;
    }

    String? observatoryURL;
    if (enableObservatory) {
      observatoryURL = await _runObservatory(runObservatory);
    }

    var process = SpawnedIsolate(
      id,
      spawnEntry,
      spawnType,
      projectDirectory,
      isolate,
      exitCode,
      isolateCheckPingTimeout,
      observatoryURL,
      stopByKill: true,
      onStop: (_) {
        exitPort.close();
      },
    );

    spawnedEntry = spawnEntry;
    spawnedType = spawnType;

    return process;
  }

  Future<SpawnedIsolate> _spawnManaged(
    Object spawnEntry,
    String spawnType,
    Uri dataUri,
    List<String> args,
    String? debugName,
    bool enableObservatory,
    bool runObservatory,
  ) async {
    _markSpawned();

    var projectDirectory = await this.projectDirectory;

    if (!await ensureProjectDependenciesResolved()) {
      throw StateError(
        "Can't ensure that project dependencies are resolved: $projectDirectory",
      );
    }

    var projectPackageConfig = await projectPackageConfigUri;
    var currentPackageConfig = await Isolate.packageConfig;

    var errorPort = ReceivePort();
    var messagePort = ReceivePort();
    var exitPort = ReceivePort();

    var spawnInfo = _spawnInfo(debugName);

    // ignore: unawaited_futures
    exitCode.future.then((code) {
      messagePort.close();
      errorPort.close();
      exitPort.close();
      this.log('INFO', '[$spawnInfo] Exit Code: $code');
    });

    final startupCompleter = Completer<SendPort>();
    final stoppedCompleter = Completer<void>();
    var stopRequested = false;

    errorPort.listen((msg) {
      var error = _onUncaughtError(spawnInfo, msg);
      if (!startupCompleter.isCompleted) {
        startupCompleter.completeError(error, error.stackTrace);
      }
    });

    late Isolate isolate;

    messagePort.listen((msg) {
      final message = msg as Map<dynamic, dynamic>;
      switch (message['status'] as String?) {
        case 'ok':
          {
            if (!startupCompleter.isCompleted) {
              startupCompleter.complete(message['port'] as SendPort);
            }
            break;
          }
        case 'stopped':
          {
            if (!stoppedCompleter.isCompleted) {
              stoppedCompleter.complete();
            }
            // When `SpawnedIsolate.stop` requested the stop, it completes
            // `exitCode` with the requested code.
            if (!stopRequested) {
              _completeExitCode(0);
            }
            Future.delayed(Duration(seconds: 1), () => isolate.kill());
            break;
          }
      }
    });

    // Completes `exitCode` if the isolate exits without reporting `stopped`
    // (for example, killed or terminated by an uncaught error).
    exitPort.listen((_) {
      if (!startupCompleter.isCompleted) {
        startupCompleter.completeError(
          StateError(
            '[$spawnInfo] Isolate exited before `spawnedMain` reported startup.',
          ),
        );
        _completeExitCode(uncaughtErrorExitCode);
      } else if (!stopRequested || _uncaughtError != null) {
        // A requested stop completes `exitCode` with the requested code.
        _completeExitCode(_uncaughtError != null ? uncaughtErrorExitCode : 0);
      }
    });

    this.log(
      'INFO',
      '[$spawnInfo] Spawning Managed: {type: $spawnType, packageConfig: $projectPackageConfig} ; Dart Entry Point: $dataUri',
    );

    try {
      isolate = await Isolate.spawnUri(
        dataUri,
        args,
        messagePort.sendPort,
        errorsAreFatal: true,
        onError: errorPort.sendPort,
        onExit: exitPort.sendPort,
        packageConfig: (currentPackageConfig == projectPackageConfig
            ? null
            : projectPackageConfig),
        debugName: debugName,
      );
    } catch (e) {
      _onSpawnFailure(spawnInfo, e);
      rethrow;
    }

    String? observatoryURL;
    if (enableObservatory) {
      observatoryURL = await _runObservatory(runObservatory);
    }

    final SendPort sendPort;
    try {
      sendPort = await startupCompleter.future.timeout(startupTimeout);
    } catch (e) {
      isolate.kill(priority: Isolate.immediate);
      _onSpawnFailure(spawnInfo, e);
      rethrow;
    }

    var process = SpawnedIsolate(
      id,
      spawnEntry,
      spawnType,
      projectDirectory,
      isolate,
      exitCode,
      isolateCheckPingTimeout,
      observatoryURL,
      onStop: (_) async {
        stopRequested = true;
        sendPort.send({'cmd': 'stop'});
        // Give `spawnedMain` time to run its `stop` callback, then make sure
        // the isolate does not outlive the stop (its `run` may still be
        // pending).
        await stoppedCompleter.future.timeout(
          managedStopTimeout,
          onTimeout: () {},
        );
        isolate.kill();
      },
    );

    spawnedEntry = spawnEntry;
    spawnedType = spawnType;

    return process;
  }

  String _spawnInfo(String? debugName) =>
      '#$id${debugName != null ? ':$debugName' : ''}';

  Future<String> _runObservatory(bool runObservatory) async {
    final observatory = await Service.controlWebServer(enable: true);

    var url = observatory.serverUri.toString();

    if (runObservatory && await supportsLaunchObservatory()) {
      await launchObservatory(url);
    }

    return url;
  }

  bool? _supportsLaunchObservatory;

  /// Returns `true` if this environment supports observatory launch.
  Future<bool> supportsLaunchObservatory() async {
    if (_supportsLaunchObservatory == null) {
      var result = await executablePath('open');
      _supportsLaunchObservatory = result != null;
    }
    return _supportsLaunchObservatory!;
  }

  /// Launches the observatory [url].
  Future<ProcessResult> launchObservatory(String url) {
    return Process.run('open', [url]);
  }

  @override
  String toString() {
    var projDir = projectDirectory;
    var projDirStr = projDir is Future ? null : projDir.path;
    return 'DartSpawner{ id: $id${projDirStr != null ? ', projectDirectory: $projDirStr' : ''}, spawned: $isSpawned${isSpawned ? ', spawnedType: $spawnedType' : ''}, finished: $isFinished, startupTimeout: $startupTimeout, isolateCheckPingTimeout: $isolateCheckPingTimeout }';
  }
}

typedef OnSpawnedIsolateStop = FutureOr<void> Function(String stopEeason);

/// The spawned Dart script isolate "process".
class SpawnedIsolate {
  /// The ID (same of [DartSpawner.id] source).
  final int id;

  /// The Dart entry used to spawn.
  final Object spawnEntry;

  /// The spawn type.
  final String type;

  /// The target project [Directory].
  final Directory projectDirectory;

  /// The spawned [Isolate].
  final Isolate isolate;

  final Completer<int> _isolateCompleter;

  final Duration _isolateCheckPingTimeout;

  /// The Dart VM Observatory URL.
  final String? observatoryURL;

  final OnSpawnedIsolateStop? _onStop;
  final bool stopByKill;

  SpawnedIsolate(
    this.id,
    this.spawnEntry,
    this.type,
    this.projectDirectory,
    this.isolate,
    this._isolateCompleter,
    this._isolateCheckPingTimeout,
    this.observatoryURL, {
    this._onStop,
    this.stopByKill = false,
  }) {
    _listenSignals();
    _scheduleCheckIsolate();
  }

  final List<StreamSubscription> _signalListeners = [];

  void _listenSignals() {
    var l1 = ProcessSignal.sigint.watch().listen((_) {
      stop(0, reason: 'Process interrupted.');
    });
    _signalListeners.add(l1);

    if (!Platform.isWindows) {
      var l2 = ProcessSignal.sigterm.watch().listen((_) {
        stop(0, reason: 'Process terminated by OS.');
      });
      _signalListeners.add(l2);
    }

    _isolateCompleter.future.then((_) => _cancelSignalListeners());
  }

  Future<void> _cancelSignalListeners() async {
    // Copy and clear before awaiting: this can be called concurrently
    // (by `stop` and by the exit code completion).
    var subscriptions = List.of(_signalListeners);
    _signalListeners.clear();
    await Future.wait(subscriptions.map((sub) => sub.cancel()));
  }

  /// The Dart script/file exit code.
  Future<int> get exitCode => _isolateCompleter.future;

  /// Returns `true` if the spawned Dart script/file have finished.
  bool get isFinished => _isolateCompleter.isCompleted;

  bool _stopping = false;

  /// Stops the process.
  ///
  /// Completes [exitCode] with [exitCode] and returns `true`, or returns
  /// `false` if the isolate had already finished (or another [stop] is in
  /// progress).
  Future<bool> stop(int exitCode, {String? reason}) async {
    if (_isolateCompleter.isCompleted || _stopping) {
      await _cancelSignalListeners();
      return false;
    }

    _stopping = true;

    await _cancelSignalListeners();

    // The isolate may have exited while the listeners were cancelled.
    if (_isolateCompleter.isCompleted) {
      return false;
    }

    final onStop = _onStop;
    if (onStop != null) {
      await onStop(reason ?? 'Terminated normally.');
    }

    if (stopByKill) {
      isolate.kill();
    }

    if (!_isolateCompleter.isCompleted) {
      _isolateCompleter.complete(exitCode);
    }

    return true;
  }

  void _scheduleCheckIsolate() {
    if (isFinished) return;

    int delay;

    if (_checkIsolateCount < 10) {
      delay = 100;
    } else if (_checkIsolateCount < 20) {
      delay = 500;
    } else {
      delay = 1000;
    }

    Future.delayed(Duration(milliseconds: delay), _checkIsolate);
  }

  int _checkIsolateCount = 0;

  /// The exit of the isolate is reported by its `onExit`/`onError` ports
  /// (see [DartSpawner]). This check only covers the case those ports can't:
  /// with the VM service enabled, an isolate paused at exit
  /// (`--pause-isolates-on-exit`, used by debuggers and coverage tools) does
  /// not send its `onExit` message until it is resumed.
  ///
  /// The pause state is read from the VM service (`getIsolate`): only a
  /// `PauseExit` pause event is an exit. A busy isolate, a slow VM service
  /// or a failed/timed out request never complete [exitCode].
  void _checkIsolate() async {
    if (isFinished) return;

    ++_checkIsolateCount;

    var serverUri = await _vmServiceServerUri();
    if (serverUri == null) return;

    if (isFinished) return;

    var pauseKind = await _getIsolatePauseEventKind(
      serverUri,
      isolate,
      _isolateCheckPingTimeout,
    );

    if (pauseKind == 'PauseExit') {
      // Give an `onError` message (sent before the exit) a chance to be
      // delivered first, to report `uncaughtErrorExitCode`.
      await Future.delayed(Duration(milliseconds: 100));
      // A `stop` in progress completes `exitCode` with the requested code.
      if (!_stopping && !_isolateCompleter.isCompleted) {
        _isolateCompleter.complete(0);
      }
    } else {
      _scheduleCheckIsolate();
    }
  }

  @override
  String toString() {
    return 'SpawnedIsolate{ id: $id, type: $type, finished: $isFinished, projectDirectory: $projectDirectory }';
  }
}

/// Helper to executed a spawned Dart script by [DartSpawner].
Future<void> spawnedMain(
  List<String> args,
  SendPort parentPort,
  int id,
  Function run, [
  FutureOr<bool> Function()? stop,
]) async {
  final messagePort = ReceivePort();

  var debugName = Isolate.current.debugName;

  var isolateId = debugName != null ? 'Isolate#$id($debugName)' : 'Isolate#$id';

  messagePort.listen((msg) {
    if (msg['cmd'] == 'stop') {
      _stopSpawned(isolateId, messagePort, stop, parentPort);
    }
  });

  print('[$isolateId] Running: $run');

  FutureOr ret;

  if (run is Function()) {
    ret = run();
  } else if (run is Function(List<String> a)) {
    ret = run(args);
  }

  print('[$isolateId] Return: $ret');

  parentPort.send({'status': 'ok', 'port': messagePort.sendPort});

  if (ret is Future) {
    print('[$isolateId] Waiting return: $ret');
    await ret;
  }

  _stopSpawned(isolateId, messagePort, stop, parentPort);
}

void _stopSpawned(
  String isolateId,
  ReceivePort port,
  FutureOr<bool> Function()? stop,
  SendPort parentPort,
) async {
  print('[$isolateId] Stopping isolate...');
  port.close();

  if (stop != null) {
    print('[$isolateId] triggering stop()');
    var stopOk = await stop();
    print('[$isolateId] stop(): $stopOk');
  }

  print('[$isolateId] Isolate stopped.');
  parentPort.send({'status': 'stopped'});
}

Future<bool> _isIsolateSpawnUriSupported() async {
  var info = await Service.getInfo();
  // Outside a JIT Dart VM (e.g. `dart compile exe`) the VM service reports
  // version `0.0`. A protocol version like `5.0` must still be accepted.
  return info.majorVersion != 0 || info.minorVersion != 0;
}

/// The VM service HTTP server [Uri] (including its auth token), or `null` if
/// the VM service is not enabled.
Future<Uri?> _vmServiceServerUri() async {
  var info = await Service.getInfo();
  return info.serverUri;
}

/// Returns the `kind` of the [isolate]'s current pause event, as reported by
/// the VM service `getIsolate` RPC (`Resume`, `PauseStart`, `PauseExit`,
/// `PauseBreakpoint`, ...), or `null` if it can't be read (VM service
/// unavailable, request failed or timed out, or the isolate is already gone).
///
/// The VM service answers from its own thread, so the answer doesn't depend
/// on the [isolate] being responsive (a busy event loop is still `Resume`).
Future<String?> _getIsolatePauseEventKind(
  Uri serverUri,
  Isolate isolate,
  Duration timeout,
) async {
  var isolateId = Service.getIsolateId(isolate);
  if (isolateId == null) return null;

  var client = HttpClient()..connectionTimeout = timeout;
  try {
    return await () async {
      var path = serverUri.path.endsWith('/')
          ? '${serverUri.path}getIsolate'
          : '${serverUri.path}/getIsolate';
      var uri = serverUri.replace(
        path: path,
        queryParameters: {'isolateId': isolateId},
      );
      var request = await client.getUrl(uri);
      var response = await request.close();
      var body = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) return null;

      var json = jsonDecode(body);
      if (json is! Map) return null;
      var result = json['result'];
      if (result is! Map || result['type'] != 'Isolate') return null;
      var pauseEvent = result['pauseEvent'];
      if (pauseEvent is! Map) return null;
      var kind = pauseEvent['kind'];
      return kind is String ? kind : null;
    }().timeout(timeout);
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}
