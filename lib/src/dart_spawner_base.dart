import 'dart:async';
import 'dart:developer';
import 'dart:io';
import 'dart:isolate';

import 'package:async_extension/async_extension.dart';
import 'package:dart_spawner/dart_spawner.dart';
import 'package:yaml/yaml.dart';

typedef _Logger = void Function(String type, dynamic message);

/// Class to resolve a Dart project directory.
class DartProject {
  /// The target project directory (that contains a `pubspec.yaml` file).
  final Directory? _directory;
  final _Logger _logger;

  DartProject(
      {Directory? directory, _Logger? logger, bool logToConsole = false})
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

  /// The resolved project `.packages` [Uri].
  FutureOr<Uri> get projectPackageConfigUri => projectSubUri('.packages');

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

/// Class capable to spawn a Dart script/[File]/[Uri] into an [Isolate].
class DartSpawner extends DartProject {
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
      _Logger? logger,
      bool logToConsole = false,
      Duration? startupTimeout})
      : startupTimeout = Duration(seconds: 45),
        isolateCheckPingTimeout = Duration(seconds: 2),
        super(directory: directory, logger: logger, logToConsole: logToConsole);

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

  static final RegExp FILE_PATH_RESERVED_CHARS = RegExp(r'[\r\n\|\?\*\":<>]');

  /// Returns `true` if [dartEntryPoint] is a [String] and a [File] path with a '.dart' extension.
  bool isDartFilePath(dynamic dartEntryPoint) {
    return dartEntryPoint is String &&
        !dartEntryPoint.contains(FILE_PATH_RESERVED_CHARS) &&
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
    var projectPackageConfig = await projectPackageConfigUri;

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
      packageConfig: projectPackageConfig,
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
    var projectPackageConfig = await projectPackageConfigUri;

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
          }
          break;
        case 'stopped':
          {
            exitCode.complete(0);
            Future.delayed(Duration(seconds: 1), () => isolate.kill());
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
      packageConfig: projectPackageConfig,
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
    return 'DartSpawner{ id: $id${projDirStr != null ? ', projectDirectory: $projDirStr' : ''}, spawned: $isSpawned${isSpawned ? ', spawnedType: $spawnedType' : ''}, finished: $isFinished }';
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
void spawnedMain(List<String> args, SendPort parentPort, int id, Function run,
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
