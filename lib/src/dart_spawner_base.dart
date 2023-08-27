import 'dart:developer';
import 'dart:io';
import 'dart:isolate';

import 'package:async_extension/async_extension.dart';
import 'package:dart_spawner/dart_spawner.dart';
import 'package:yaml/yaml.dart';

import 'dart_spawner_tools.dart';

typedef DartProjectLogger = void Function(String type, dynamic message);

/// Class to resolve a Dart project directory.
class DartProject {
  /// The target project directory (that contains a `pubspec.yaml` file).
  final Directory? _directory;
  final DartProjectLogger _logger;

  DartProject(
      {Directory? directory,
      DartProjectLogger? logger,
      bool logToConsole = false})
      : _directory = directory,
        _logger = logger ??
            (logToConsole ? ((t, m) => print('[$t] $m')) : ((t, m) {}));

  /// Logs a message.
  void log(String type, dynamic message) => _logger(type, message);

  Directory? _projectDirectory;

  /// The resolved project [Directory].
  FutureOr<Directory> get projectDirectory {
    var projDir = _projectDirectory;
    if (projDir == null) {
      if (_directory != null) {
        _projectDirectory = projDir = _directory!.absolute;
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

  /// The resolved project `pubspec.yaml` [file].
  FutureOr<File> get projectPubspecFile async => projectSubFile('pubspec.yaml');

  Map<String, dynamic>? _pubspec;

  /// The resolved project `pubspec.yaml` [Map].
  FutureOr<Map<String, dynamic>> get projectPubspec {
    var pubspec = _pubspec;
    if (pubspec == null) {
      return projectPubspecFile.resolveMapped((file) {
        if (!file.existsSync()) {
          throw StateError(
              'Failed to locate `pubspec.yaml` in project directory `$projectDirectory`');
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

  /// The resolved project `pubspec.lock` [File].
  FutureOr<File> get projectPubspecLockFile async =>
      projectSubFile('pubspec.lock');

  Map<String, dynamic>? _projectLockFile;

  /// The resolved project `pubspec.lock` file as [YamlMap].
  FutureOr<Map<String, dynamic>> get projectPubspecLock {
    var projLockFile = _projectLockFile;
    if (projLockFile == null) {
      return projectPubspecLockFile.resolveMapped((lockFile) {
        if (!lockFile.existsSync()) {
          throw StateError(
              'No `pubspec.lock` file in project directory `$projectDirectory`. Run `pub get`.');
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
  FutureOr<Uri> get projectPackageConfigUri {
    var uriPackageConfigJson = projectSubUri('.dart_tool/package_config.json');
    var uriPackages = projectSubUri('.packages');

    var filePackageConfigJson =
        uriPackageConfigJson.resolveMapped((uri) => File.fromUri(uri));
    var filePackages = uriPackages.resolveMapped((uri) => File.fromUri(uri));

    return filePackageConfigJson.resolveBoth(filePackages,
        (fileJson, filePack) {
      if (fileJson.existsSync()) {
        return uriPackageConfigJson;
      } else if (filePack.existsSync()) {
        return uriPackages;
      } else {
        throw StateError(
            "Can't resolve project packageConfig: $fileJson ; $filePack");
      }
    });
  }

  /// Returns `true` if [projectPackageConfigUri] exists.
  FutureOr<bool> existsProjectPackageConfigUri() {
    try {
      var packagesConfigUri = projectPackageConfigUri;

      return packagesConfigUri.resolveMapped((uri) {
        return File.fromUri(uri).existsSync();
      });
    } catch (e) {
      return false;
    }
  }

  /// Runs `dart pub get` in the [projectDirectory].
  Future<bool> runDartPubGet() async {
    var workingDir = await projectDirectory;
    var processInfo = await runProcess('dart', ['pub', 'get'],
        workingDirectory: workingDir.path);

    var ok = await processInfo.checkExitCode();
    if (!ok) {
      throw StateError('Error running: dart pub get > $processInfo');
    }

    return ok;
  }

  /// Runs a new Dart VM.
  ///
  /// - [entrypoint] is the Dart entrypoint, usually a Dart file.
  /// - [args] is the arguments to pass to the [entrypoint].
  /// - [workingDirectory] is the [Process] working directory. If `null` will use the current working directory.
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
    bool handleSignals = false,
    bool redirectOutput = false,
    bool catchOutput = false,
    String Function(String o)? stdoutFilter,
    String Function(String o)? stderrFilter,
    void Function(ProcessSignal signal)? onSignal,
  }) async {
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
            ports: [8181, 8171, 8191], startPort: 8161, endPort: 8191);

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
        'run',
        entrypoint,
        ...args
      ],
      workingDirectory: workingDirectory,
      handleSignals: handleSignals,
      redirectOutput: redirectOutput,
      catchOutput: catchOutput,
      stdoutFilter: stdoutFilter,
      stderrFilter: stderrFilter,
      onSignal: onSignal,
    );
  }

  /// Returns a [ServerSocket] port free to listen.
  ///
  /// - [ports] is a [List] of ports to test.
  /// - [startPort] and [endPort] defines a range of ports to check.
  /// - If [shufflePorts] is `true` the ports order will be random.
  static Future<int?> getFreeListenPort(
      {Iterable<int>? ports,
      Iterable<int>? skipPort,
      int? startPort,
      int? endPort,
      bool shufflePorts = false,
      Duration? testTimeout}) async {
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
  static Future<bool> isFreeListenPort(int port,
      {Duration? testTimeout}) async {
    testTimeout ??= Duration(seconds: 1);

    try {
      var socket =
          await Socket.connect('localhost', port, timeout: testTimeout);
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
  Future<ProcessInfo> runProcess(String commandName, List<String> args,
      {bool resolveCommandPath = true,
      String? workingDirectory,
      bool handleSignals = false,
      bool redirectOutput = false,
      bool catchOutput = false,
      String Function(String o)? stdoutFilter,
      String Function(String o)? stderrFilter,
      void Function(ProcessSignal signal)? onSignal}) async {
    String? binPath;
    if (resolveCommandPath) {
      binPath = await executablePath(commandName);
      if (binPath == null) {
        throw StateError('Error resolving `$commandName` binary!');
      }
    } else {
      binPath = commandName;
    }

    log('INFO',
        'Process.start> $binPath $args > workingDirectory: $workingDirectory');

    var process =
        await Process.start(binPath, args, workingDirectory: workingDirectory);

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

    if (catchOutput && redirectOutput) {
      // ignore: unawaited_futures
      process.stdout.transform(outputDecoder).forEach((o) {
        o = stdoutFilterF(o);
        stdout.write(o);
        processInfo.outputBuffer.add(o);
      });
      // ignore: unawaited_futures
      process.stderr.transform(outputDecoder).forEach((o) {
        o = stderrFilterF(o);
        stderr.write(o);
        processInfo.errorOutputBuffer.add(o);
      });
    } else if (catchOutput) {
      // ignore: unawaited_futures
      process.stdout.transform(outputDecoder).forEach((o) {
        o = stdoutFilterF(o);
        processInfo.outputBuffer.add(o);
      });
      // ignore: unawaited_futures
      process.stderr.transform(outputDecoder).forEach((o) {
        o = stderrFilterF(o);
        processInfo.errorOutputBuffer.add(o);
      });
    } else if (redirectOutput) {
      // ignore: unawaited_futures
      process.stdout.transform(outputDecoder).forEach((o) {
        o = stdoutFilterF(o);
        stdout.write(o);
      });
      // ignore: unawaited_futures
      process.stderr.transform(outputDecoder).forEach((o) {
        o = stderrFilterF(o);
        stderr.write(o);
      });
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
  Future<bool> cleanDartPubGetGeneratedFiles(
      {required String confirmProjectName, bool verbose = false}) async {
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
  Future<String?> executablePath(String executableName,
      {bool refresh = false}) async {
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

  /// The [process.exitCode].
  Future<int> get exitCode async => _exitCode ??= await process.exitCode;

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
      seconds: _getEnvAsInt('DART_SPAWNER_STARTUP_TIMEOUT',
              validator: (n) => n >= 2) ??
          45);

  /// The default [Isolate] check ping timeout.
  ///
  /// - Set by environment variable: "DART_SPAWNER_ISOLATE_CHECK_PING_TIMEOUT" (in seconds).
  /// - When on [debugMode] is set to 3600 sec.
  static final Duration defaultIsolateCheckPingTimeout = Duration(
      seconds: _getEnvAsInt('DART_SPAWNER_ISOLATE_CHECK_PING_TIMEOUT',
              validator: (n) => n >= 1) ??
          (debugMode ? 3600 : 2));

  static int _idCounter = 0;

  final int id = ++_idCounter;

  /// The timeout to identify the [Isolate] startup.
  final Duration startupTimeout;

  /// The timeout of a [Isolate] check (calling [Isolate.ping]).
  final Duration isolateCheckPingTimeout;

  /// Constructs a new [DartSpawner].
  ///
  /// - [directory] the target project directory.type
  /// - [startupTimeout] the timeout to identify the [Isolate] startup.
  DartSpawner(
      {Directory? directory,
      DartProjectLogger? logger,
      bool logToConsole = false,
      Duration? startupTimeout})
      : startupTimeout = defaultStartupTimeout,
        isolateCheckPingTimeout = defaultIsolateCheckPingTimeout,
        super(
            directory: directory, logger: logger, logToConsole: logToConsole) {
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
  Future<SpawnedIsolate> spawnDart(dynamic dartEntryPoint, List<String> args,
      {String? debugName,
      bool enableObservatory = false,
      bool runObservatory = false,
      bool usesSpawnedMain = false}) {
    if (dartEntryPoint is File) {
      return spawnDartFile(dartEntryPoint, args,
          debugName: debugName,
          enableObservatory: enableObservatory,
          runObservatory: runObservatory,
          usesSpawnedMain: usesSpawnedMain);
    } else if (dartEntryPoint is Uri) {
      return spawnDartURI(dartEntryPoint, args,
          debugName: debugName,
          enableObservatory: enableObservatory,
          runObservatory: runObservatory,
          usesSpawnedMain: usesSpawnedMain);
    } else if (dartEntryPoint is String) {
      if (isDartFilePath(dartEntryPoint)) {
        var dartFile = File(dartEntryPoint);
        return spawnDartFile(dartFile, args,
            debugName: debugName,
            enableObservatory: enableObservatory,
            runObservatory: runObservatory,
            usesSpawnedMain: usesSpawnedMain);
      } else {
        return spawnDartScript(dartEntryPoint, args,
            debugName: debugName,
            enableObservatory: enableObservatory,
            runObservatory: runObservatory,
            usesSpawnedMain: usesSpawnedMain);
      }
    } else {
      throw StateError(
          'Unsupported Dart entry point! type: ${dartEntryPoint.runtimeType} > $dartEntryPoint');
    }
  }

  /// Spawn a Dart script.
  Future<SpawnedIsolate> spawnDartScript(String dartScript, List<String> args,
      {String? debugName,
      bool enableObservatory = false,
      bool runObservatory = false,
      bool usesSpawnedMain = false}) {
    final dataUri = Uri.parse(
        'data:application/dart;charset=utf-8,${Uri.encodeComponent(dartScript)}');

    return _spawnDart(dartScript, '<script>', dataUri, args,
        debugName: debugName,
        enableObservatory: enableObservatory,
        runObservatory: runObservatory,
        usesSpawnedMain: usesSpawnedMain);
  }

  /// Spawn a Dart [File].
  Future<SpawnedIsolate> spawnDartFile(File dartFile, List<String> args,
          {String? debugName,
          bool enableObservatory = false,
          bool runObservatory = false,
          bool usesSpawnedMain = false}) =>
      _spawnDart(dartFile, 'File', dartFile.uri, args,
          debugName: debugName,
          enableObservatory: enableObservatory,
          runObservatory: runObservatory,
          usesSpawnedMain: usesSpawnedMain);

  /// Spawn a Dart [Uri].
  Future<SpawnedIsolate> spawnDartURI(Uri dartUri, List<String> args,
          {String? debugName,
          bool enableObservatory = false,
          bool runObservatory = false,
          bool usesSpawnedMain = false}) =>
      _spawnDart(dartUri, 'Uri', dartUri, args,
          debugName: debugName,
          enableObservatory: enableObservatory,
          runObservatory: runObservatory,
          usesSpawnedMain: usesSpawnedMain);

  Future<SpawnedIsolate> _spawnDart(
      Object spawnEntry, String spawnType, Uri dartUri, List<String> args,
      {String? debugName,
      bool enableObservatory = false,
      bool runObservatory = false,
      bool usesSpawnedMain = false}) async {
    if (!await _isIsolateSpawnUriSupported()) {
      throw StateError(
          "Can't call `Isolate.spawnUri`, not running in a Dart VM!`");
    }

    if (usesSpawnedMain) {
      return _spawnManaged(spawnEntry, spawnType, dartUri, args, debugName,
          enableObservatory, runObservatory);
    } else {
      return _spawn(spawnEntry, spawnType, dartUri, args, debugName,
          enableObservatory, runObservatory);
    }
  }

  Future<SpawnedIsolate> _spawn(
      Object spawnEntry,
      String spawnType,
      Uri dataUri,
      List<String> args,
      String? debugName,
      bool enableObservatory,
      bool runObservatory) async {
    _markSpawned();

    var projectDirectory = await this.projectDirectory;

    if (!await ensureProjectDependenciesResolved()) {
      throw StateError(
          "Can't ensure that project dependencies are resolved: $projectDirectory");
    }

    var projectPackageConfig = (await projectPackageConfigUri);
    var currentPackageConfig = await Isolate.packageConfig;

    late Isolate isolate;

    var exitPort = ReceivePort();

    var spawnInfo = _spawnInfo(debugName);

    // ignore: unawaited_futures
    exitCode.future.then((code) {
      exitPort.close();
      this.log('INFO', '[$spawnInfo] Exit Code: $code');
    });

    exitPort.listen((msg) {
      var stopped = false;

      if (msg is Map) {
        stopped = msg['status'] == 'stopped';
      } else if (msg == null) {
        stopped = true;
      }

      if (stopped) {
        if (!exitCode.isCompleted) {
          exitCode.complete(0);
        }
        exitPort.close();
      }
    });

    this.log('INFO',
        '[$spawnInfo] Spawning: {type: $spawnType, packageConfig: $projectPackageConfig} ; Dart Entry Point: $dataUri');

    isolate = await Isolate.spawnUri(
      dataUri,
      args,
      null,
      errorsAreFatal: true,
      onExit: exitPort.sendPort,
      packageConfig: (currentPackageConfig == projectPackageConfig
          ? null
          : projectPackageConfig),
      debugName: debugName,
    );

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
      bool runObservatory) async {
    _markSpawned();

    var projectDirectory = await this.projectDirectory;

    if (!await ensureProjectDependenciesResolved()) {
      throw StateError(
          "Can't ensure that project dependencies are resolved: $projectDirectory");
    }

    var projectPackageConfig = await projectPackageConfigUri;
    var currentPackageConfig = await Isolate.packageConfig;

    var errorPort = ReceivePort();
    var messagePort = ReceivePort();

    var spawnInfo = _spawnInfo(debugName);

    // ignore: unawaited_futures
    exitCode.future.then((code) {
      messagePort.close();
      errorPort.close();
      this.log('INFO', '[$spawnInfo] Exit Code: $code');
    });

    final startupCompleter = Completer<SendPort>();

    errorPort.listen((msg) {
      if (msg is List) {
        if (!startupCompleter.isCompleted) {
          startupCompleter.completeError(
              msg.first as Object, StackTrace.fromString(msg.last as String));
        }
      }
    });

    late Isolate isolate;

    messagePort.listen((msg) {
      final message = msg as Map<dynamic, dynamic>;
      switch (message['status'] as String?) {
        case 'ok':
          {
            startupCompleter.complete(message['port'] as SendPort?);
            break;
          }
        case 'stopped':
          {
            exitCode.complete(0);
            Future.delayed(Duration(seconds: 1), () => isolate.kill());
            break;
          }
      }
    });

    this.log('INFO',
        '[$spawnInfo] Spawning Managed: {type: $spawnType, packageConfig: $projectPackageConfig} ; Dart Entry Point: $dataUri');

    isolate = await Isolate.spawnUri(
      dataUri,
      args,
      messagePort.sendPort,
      errorsAreFatal: true,
      onError: errorPort.sendPort,
      packageConfig: (currentPackageConfig == projectPackageConfig
          ? null
          : projectPackageConfig),
      debugName: debugName,
    );

    String? observatoryURL;
    if (enableObservatory) {
      observatoryURL = await _runObservatory(runObservatory);
    }

    final sendPort =
        await startupCompleter.future.timeout(Duration(seconds: 45));

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
        sendPort.send({'cmd': 'stop'});
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
      this.observatoryURL,
      {OnSpawnedIsolateStop? onStop,
      this.stopByKill = false})
      : _onStop = onStop {
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
    await Future.forEach(
        _signalListeners, (StreamSubscription sub) => sub.cancel());
    _signalListeners.clear();
  }

  /// The Dart script/file exit code.
  Future<int> get exitCode => _isolateCompleter.future;

  /// Returns `true` if the spawned Dart script/file have finished.
  bool get isFinished => _isolateCompleter.isCompleted;

  /// Stops the process.
  Future<bool> stop(int exitCode, {String? reason}) async {
    if (_isolateCompleter.isCompleted) {
      await _cancelSignalListeners();
      return false;
    }

    await _cancelSignalListeners();

    if (_onStop != null) {
      await _onStop!(reason ?? 'Terminated normally.');
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

  void _checkIsolate() async {
    if (isFinished) return;

    ++_checkIsolateCount;

    var vmServiceEnabled = await _isVMServiceEnabled();
    if (!vmServiceEnabled) return;

    var paused = await _isIsolatePaused(isolate, _isolateCheckPingTimeout);

    if (paused) {
      if (!_isolateCompleter.isCompleted) {
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
    List<String> args, SendPort parentPort, int id, Function run,
    [FutureOr<bool> Function()? stop]) async {
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

void _stopSpawned(String isolateId, ReceivePort port,
    FutureOr<bool> Function()? stop, SendPort parentPort) async {
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
  return info.majorVersion != 0 && info.minorVersion != 0;
}

Future<bool> _isVMServiceEnabled() async {
  var info = await Service.getInfo();
  return info.serverUri != null;
}

Future<bool> _isIsolatePaused(Isolate isolate, Duration pingTimeout) async {
  var pauseCapability = isolate.pauseCapability;

  if (pauseCapability == null) {
    return false;
  }

  var completer = Completer<bool>();

  var receivePort = RawReceivePort((pong) {
    if (!completer.isCompleted) {
      completer.complete(pong);
    }
  });

  isolate.ping(receivePort.sendPort,
      response: true, priority: Isolate.beforeNextEvent);

  var pong =
      await completer.future.timeout(pingTimeout, onTimeout: () => false);

  receivePort.close();

  return !pong;
}
