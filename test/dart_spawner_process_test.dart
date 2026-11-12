@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dart_spawner/dart_spawner.dart';
import 'package:path/path.dart' as pack_path;
import 'package:test/test.dart';

/// Tests that need a separate Dart VM (environment variables, signals,
/// process exit codes and output), using `test/fixtures/spawner_runner.dart`.
void main() {
  late String runnerPath;
  late String packageConfigPath;

  setUpAll(() async {
    var projectDir = await DartProject().projectDirectory;
    runnerPath = pack_path.join(
      projectDir.path,
      'test',
      'fixtures',
      'spawner_runner.dart',
    );
    expect(File(runnerPath).existsSync(), isTrue);
    packageConfigPath = (await Isolate.packageConfig)!.toFilePath();
  });

  List<String> runnerArgs(List<String> args) => [
    '--packages=$packageConfigPath',
    runnerPath,
    ...args,
  ];

  group('environment variables', () {
    Future<Map<String, String>> runEnv(Map<String, String> env) async {
      var result = await Process.run(
        Platform.resolvedExecutable,
        runnerArgs(['env']),
        environment: env,
      ).timeout(Duration(seconds: 60));
      expect(result.exitCode, equals(0), reason: '${result.stderr}');
      var out = '${result.stdout}';
      var values = <String, String>{'_stdout': out};
      for (var line in LineSplitter.split(out)) {
        var idx = line.indexOf('=');
        if (idx > 0 && !line.startsWith('**')) {
          values[line.substring(0, idx)] = line.substring(idx + 1);
        }
      }
      return values;
    }

    test('defaults', () async {
      var env = Platform.environment;
      if (env.keys.any((k) => k.startsWith('DART_SPAWNER_'))) {
        markTestSkipped('DART_SPAWNER_* set in the test environment');
        return;
      }
      var v = await runEnv({});
      expect(v['debugMode'], equals('false'));
      expect(v['startupTimeout'], equals('45'));
      expect(v['isolateCheckPingTimeout'], equals('2'));
      expect(v['instance.startupTimeout'], equals('45'));
      expect(v['_stdout'], isNot(contains('Reading environment variable')));
    });

    test('valid values', () async {
      var v = await runEnv({
        'DART_SPAWNER_DEBUG': 'false',
        'DART_SPAWNER_STARTUP_TIMEOUT': ' 10 ',
        'DART_SPAWNER_ISOLATE_CHECK_PING_TIMEOUT': '5',
      });
      expect(v['debugMode'], equals('false'));
      expect(v['startupTimeout'], equals('10'));
      expect(v['isolateCheckPingTimeout'], equals('5'));
      // The constructor uses the default:
      expect(v['instance.startupTimeout'], equals('10'));
      expect(
        v['_stdout'],
        contains(
          '** [DartSpawner] Reading environment variable: '
          '"DART_SPAWNER_STARTUP_TIMEOUT" = " 10 "',
        ),
      );
    });

    test('debug mode', () async {
      for (var value in ['true', '1', 'ON']) {
        var v = await runEnv({'DART_SPAWNER_DEBUG': value});
        expect(v['debugMode'], equals('true'), reason: value);
        // Debug mode raises the ping timeout, unless set explicitly:
        expect(v['isolateCheckPingTimeout'], equals('3600'), reason: value);
        // `logDebug` prints the constructed instance:
        expect(v['_stdout'], contains('** [DartSpawner] DartSpawner{ id: '));
      }

      var v = await runEnv({
        'DART_SPAWNER_DEBUG': 'yes',
        'DART_SPAWNER_ISOLATE_CHECK_PING_TIMEOUT': '7',
      });
      // Only `true`, `1` and `on` enable it:
      expect(v['debugMode'], equals('false'));
      expect(v['isolateCheckPingTimeout'], equals('7'));
      expect(v['_stdout'], isNot(contains('** [DartSpawner] DartSpawner{')));
    });

    test('invalid values fall back to the defaults', () async {
      var v = await runEnv({
        // Below the minimum (2):
        'DART_SPAWNER_STARTUP_TIMEOUT': '1',
        // Below the minimum (1):
        'DART_SPAWNER_ISOLATE_CHECK_PING_TIMEOUT': '0',
      });
      expect(v['startupTimeout'], equals('45'));
      expect(v['isolateCheckPingTimeout'], equals('2'));

      v = await runEnv({
        'DART_SPAWNER_STARTUP_TIMEOUT': 'abc',
        'DART_SPAWNER_ISOLATE_CHECK_PING_TIMEOUT': '1.5',
      });
      expect(v['startupTimeout'], equals('45'));
      expect(v['isolateCheckPingTimeout'], equals('2'));
    });
  });

  group('runProcess / runDartVM', () {
    test('non-zero exit code', () async {
      var project = DartProject();
      var info = await project.runProcess(
        Platform.resolvedExecutable,
        runnerArgs(['exit', '3']),
        resolveCommandPath: false,
        catchOutput: true,
      );
      expect(await info.exitCode.timeout(Duration(seconds: 60)), equals(3));
      expect(await info.checkExitCode(), isFalse);
      expect(await info.checkExitCode(3), isTrue);
      expect(info.toString(), contains('exitCode: 3'));
      // `exitCode` waits for the caught output:
      expect(info.errorOutput, equals('exiting with 3\n'));
      expect(info.output, isEmpty);
    });

    test('arguments are passed verbatim', () async {
      var project = DartProject();
      var args = [
        'with space',
        'quote"s',
        "single'quote",
        r'$dollar',
        'ünïcødé',
        '--flag=x',
        '',
      ];
      var info = await project.runDartVM(runnerPath, [
        'echo-args',
        ...args,
      ], catchOutput: true);
      expect(await info.exitCode.timeout(Duration(seconds: 60)), equals(0));
      expect(info.args.take(2), equals(['run', runnerPath]));
      // The last line: `dart run` may print resolution messages before it.
      var json = LineSplitter.split(info.output.trim()).last;
      expect(jsonDecode(json), equals(args));
    });

    test('a lot of output with catchOutput', () async {
      var project = DartProject();
      const lines = 2048; // 2 MiB
      var info = await project.runProcess(
        Platform.resolvedExecutable,
        runnerArgs(['chatty', '$lines']),
        resolveCommandPath: false,
        catchOutput: true,
        stdoutFilter: (o) => o.replaceAll('x', 'y'),
      );
      expect(await info.exitCode.timeout(Duration(seconds: 60)), equals(0));
      // Complete as soon as `exitCode` completes:
      expect(info.errorOutput, equals('chatty done\n'));
      expect(info.output.length, equals(lines * 1024));
      var outLines = LineSplitter.split(info.output).toList();
      expect(outLines.length, equals(lines));
      expect(outLines.every((l) => l == 'y' * 1023), isTrue);
    });

    test('a lot of output with drainOutput', () async {
      var project = DartProject();
      const lines = 1024; // 1 MiB, well above any OS pipe buffer
      var info = await project.runProcess(
        Platform.resolvedExecutable,
        runnerArgs(['chatty', '$lines']),
        resolveCommandPath: false,
        drainOutput: true,
      );
      try {
        expect(await info.exitCode.timeout(Duration(seconds: 60)), equals(0));
        // Discarded:
        expect(info.output, isEmpty);
        expect(info.errorOutput, isEmpty);
      } finally {
        info.process.kill(ProcessSignal.sigkill);
      }

      // Also through `runDartVM`:
      var info2 = await project.runDartVM(runnerPath, [
        'chatty',
        '$lines',
      ], drainOutput: true);
      try {
        expect(await info2.exitCode.timeout(Duration(seconds: 60)), equals(0));
        expect(info2.output, isEmpty);
      } finally {
        info2.process.kill(ProcessSignal.sigkill);
      }

      // Redundant with `catchOutput` (which already consumes the output):
      var info3 = await project.runProcess(
        Platform.resolvedExecutable,
        runnerArgs(['chatty', '1']),
        resolveCommandPath: false,
        catchOutput: true,
        drainOutput: true,
      );
      expect(await info3.exitCode.timeout(Duration(seconds: 60)), equals(0));
      expect(info3.output.length, equals(1024));
      expect(info3.errorOutput, equals('chatty done\n'));
    });

    // Default behaviour (documented at `runProcess`): without `catchOutput`,
    // `redirectOutput` or `drainOutput`, `runProcess` does not consume the
    // child's stdout/stderr (the caller may read them). A child that writes
    // more than the OS pipe buffer blocks until the caller drains
    // `ProcessInfo.process.stdout`.
    test('a lot of output without catchOutput/redirectOutput', () async {
      var project = DartProject();
      const lines = 1024; // 1 MiB, well above any OS pipe buffer
      var info = await project.runProcess(
        Platform.resolvedExecutable,
        runnerArgs(['chatty', '$lines']),
        resolveCommandPath: false,
      );

      try {
        // Not drained: the child is blocked writing to stdout.
        await expectLater(
          info.exitCode.timeout(Duration(seconds: 3)),
          throwsA(isA<TimeoutException>()),
        );
        expect(info.output, isEmpty);

        // Draining the streams unblocks it:
        var stdoutBytes = info.process.stdout.fold<int>(
          0,
          (n, chunk) => n + chunk.length,
        );
        var stderrDone = info.process.stderr.drain<void>();
        expect(await info.exitCode.timeout(Duration(seconds: 60)), equals(0));
        expect(await stdoutBytes, equals(lines * 1024));
        await stderrDone;
      } finally {
        info.process.kill(ProcessSignal.sigkill);
      }
    });

    test('runDartVM with a kernel (.dill) entrypoint', () async {
      var project = DartProject();

      // Compiled into a temporary directory (not the source tree): nothing is
      // left behind if the test is killed, and parallel runs don't collide.
      var tmpDir = Directory.systemTemp.createTempSync('dart_spawner_dill_');
      var dillPath = pack_path.join(tmpDir.path, 'spawner_runner.dill');

      try {
        var compile = await Process.run(Platform.resolvedExecutable, [
          'compile',
          'kernel',
          runnerPath,
          '-o',
          dillPath,
        ]);
        expect(compile.exitCode, equals(0), reason: '${compile.stderr}');

        // `--packages` resolved automatically (from the current directory,
        // this package), before `run`:
        var info = await project.runDartVM(dillPath, [
          'package-config',
        ], catchOutput: true);
        expect(await info.exitCode.timeout(Duration(seconds: 60)), equals(0));
        expect(
          info.args,
          equals([
            '--packages=${File(packageConfigPath).absolute.path}',
            'run',
            dillPath,
            'package-config',
          ]),
        );
        var line = LineSplitter.split(info.output.trim()).last;
        expect(line, equals('packageConfig=${Uri.file(packageConfigPath)}'));

        // An explicit `packageConfig`:
        var info2 = await project.runDartVM(
          dillPath,
          ['package-config'],
          packageConfig: packageConfigPath,
          catchOutput: true,
        );
        expect(await info2.exitCode.timeout(Duration(seconds: 60)), equals(0));
        expect(info2.args.first, equals('--packages=$packageConfigPath'));

        // A relative `packageConfig` is relative to the current directory,
        // not to `workingDirectory`: passed as an absolute path.
        var info3 = await project.runDartVM(
          dillPath,
          ['package-config'],
          workingDirectory: tmpDir.path,
          packageConfig: pack_path.relative(packageConfigPath),
          catchOutput: true,
        );
        expect(await info3.exitCode.timeout(Duration(seconds: 60)), equals(0));
        expect(
          info3.args.first,
          equals('--packages=${File(packageConfigPath).absolute.path}'),
        );
        var line3 = LineSplitter.split(info3.output.trim()).last;
        expect(line3, equals('packageConfig=${Uri.file(packageConfigPath)}'));
      } finally {
        tmpDir.deleteSync(recursive: true);
      }

      // A `.dart` entrypoint is left to `dart run` (no `--packages`):
      var info4 = await project.runDartVM(runnerPath, [
        'exit',
        '0',
      ], catchOutput: true);
      expect(info4.args.first, equals('run'));
      expect(await info4.exitCode.timeout(Duration(seconds: 60)), equals(0));
    });

    test('resolvePackageConfigFile / isKernelFile', () async {
      expect(DartProject.isKernelFile('a/b.dill'), isTrue);
      expect(DartProject.isKernelFile('a/b.DILL'), isTrue);
      expect(DartProject.isKernelFile('a/b.dart'), isFalse);

      var projectDir = await DartProject().projectDirectory;
      var expected = File(packageConfigPath).absolute.path;

      // From the package root and from a sub-directory (searches parents):
      expect(
        DartProject.resolvePackageConfigFile(workingDirectory: projectDir.path)
            ?.path,
        equals(expected),
      );
      expect(
        DartProject.resolvePackageConfigFile(
          workingDirectory: pack_path.join(projectDir.path, 'test', 'fixtures'),
        )?.path,
        equals(expected),
      );

      // None outside any package:
      var tmp = Directory.systemTemp.createTempSync('dart_spawner_no_pkg_');
      try {
        expect(
          DartProject.resolvePackageConfigFile(workingDirectory: tmp.path),
          isNull,
        );
        // The same directory through `..` segments that pass by this package
        // (`<package>/../../<tmp>`): it's normalized, so this package (not an
        // ancestor of `tmp`) isn't searched:
        var viaPackage = pack_path.join(
          projectDir.path,
          pack_path.relative(tmp.path, from: projectDir.path),
        );
        expect(viaPackage, contains('..'));
        expect(
          DartProject.resolvePackageConfigFile(workingDirectory: viaPackage),
          isNull,
        );
      } finally {
        tmp.deleteSync(recursive: true);
      }
    });

    test('runDartVM with VM service options', () async {
      var project = DartProject();

      // Does not pause: the script has no unhandled exception.
      var info = await project.runDartVM(
        runnerPath,
        ['exit', '0'],
        enableVMService: true,
        pauseIsolatesOnUnhandledExceptions: true,
        catchOutput: true,
      );
      expect(info.args[0], startsWith('--enable-vm-service'));
      expect(info.args[1], equals('--pause-isolates-on-unhandled-exceptions'));
      expect(info.args.sublist(2), equals(['run', runnerPath, 'exit', '0']));
      expect(await info.exitCode.timeout(Duration(seconds: 60)), equals(0));

      // Without the VM service the pause flags are dropped:
      var info2 = await project.runDartVM(
        runnerPath,
        ['exit', '0'],
        pauseIsolatesOnStart: true,
        pauseIsolatesOnExit: true,
        pauseIsolatesOnUnhandledExceptions: true,
        vmServicePort: 8171,
        vmServiceAddress: '127.0.0.1',
        catchOutput: true,
      );
      expect(info2.args, equals(['run', runnerPath, 'exit', '0']));
      expect(await info2.exitCode.timeout(Duration(seconds: 60)), equals(0));

      // Paused on start: never exits by itself.
      var port = await DartProject.getFreeListenPort(
        startPort: 8161,
        endPort: 8199,
        skipPort: [8181],
      );
      var info3 = await project.runDartVM(
        runnerPath,
        ['exit', '0'],
        enableVMService: true,
        vmServicePort: port,
        vmServiceAddress: ' ',
        pauseIsolatesOnStart: true,
        pauseIsolatesOnExit: true,
        catchOutput: true,
      );
      try {
        expect(
          info3.args.take(3),
          equals([
            '--enable-vm-service=$port',
            '--pause-isolates-on-start',
            '--pause-isolates-on-exit',
          ]),
        );
        await expectLater(
          info3.exitCode.timeout(Duration(seconds: 2)),
          throwsA(isA<TimeoutException>()),
        );
      } finally {
        info3.process.kill(ProcessSignal.sigkill);
      }
      expect(await info3.exitCode.timeout(Duration(seconds: 30)), isNot(0));
    });
  });

  group('spawn in a separate VM', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp
          .createTempSync('dart_spawner_process_')
          .absolute;
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    File writeScript(String relativePath, String source) {
      var file = File(pack_path.join(tempDir.path, relativePath));
      file.parent.createSync(recursive: true);
      return file..writeAsStringSync(source);
    }

    const writerScript = r'''
import 'dart:io';

void main(List<String> args) {
  File(args[0]).writeAsStringSync('args:${args.skip(1).join(',')}');
}
''';

    // `Isolate.spawnUri` resolves a relative `Uri` against the runner's
    // script (`test/fixtures/spawner_runner.dart`), not the working
    // directory.
    for (var uri in ['bin/writer.dart', './bin/writer.dart']) {
      test('spawnDartURI: relative Uri `$uri` from another cwd', () async {
        writeScript(pack_path.join('bin', 'writer.dart'), writerScript);
        var resultFile = File(pack_path.join(tempDir.path, 'result.txt'));

        var result = await Process.run(
          Platform.resolvedExecutable,
          runnerArgs(['spawn-relative-uri', uri, resultFile.path, 'rel']),
          workingDirectory: tempDir.path,
        ).timeout(Duration(seconds: 60));

        expect(
          result.exitCode,
          equals(0),
          reason: '${result.stdout}\n${result.stderr}',
        );
        expect('${result.stdout}', contains('EXIT:0'));
        expect(resultFile.readAsStringSync(), equals('args:rel'));
      });
    }

    for (var pauseOnExit in [false, true]) {
      // With `--pause-isolates-on-exit`, `onExit` is only sent when the
      // isolate is resumed: the exit is detected through the VM service
      // (`PauseExit`).
      test('VM service${pauseOnExit ? ' with --pause-isolates-on-exit' : ''}: '
          'a busy script is not reported as exited', () async {
        var script = writeScript('busy.dart', r'''
import 'dart:io';

void main(List<String> args) {
  // Blocks the event loop for longer than `isolateCheckPingTimeout`.
  var sw = Stopwatch()..start();
  while (sw.elapsed < Duration(seconds: 4)) {}
  File(args[0]).writeAsStringSync('done');
}
''');
        var resultFile = File(pack_path.join(tempDir.path, 'result.txt'));

        var result = await Process.run(Platform.resolvedExecutable, [
          '--enable-vm-service=0',
          if (pauseOnExit) '--pause-isolates-on-exit',
          ...runnerArgs(['spawn-wait-exit', script.path, resultFile.path]),
        ]).timeout(Duration(seconds: 60));

        var reason = '${result.stdout}\n${result.stderr}';
        expect(result.exitCode, equals(0), reason: reason);
        var lines = LineSplitter.split('${result.stdout}').toList();
        expect(lines, contains('VM_SERVICE:true'), reason: reason);
        // Not reported as exited while the script was still running:
        expect(lines, contains('RESULT_AT_EXIT:true'), reason: reason);
        expect(lines, contains('EXIT:0'), reason: reason);
      });
    }
  });

  group('signals', skip: Platform.isWindows ? 'POSIX signals' : null, () {
    Future<List<String>> runUntilReady(
      String mode,
      ProcessSignal signal,
    ) async {
      var process = await Process.start(
        Platform.resolvedExecutable,
        runnerArgs([mode]),
      );
      var lines = <String>[];
      var ready = Completer<void>();
      var stdoutDone = process.stdout
          .transform(systemEncoding.decoder)
          .transform(LineSplitter())
          .forEach((l) {
            lines.add(l);
            if (l == 'READY' && !ready.isCompleted) ready.complete();
          });
      var stderrDone = process.stderr.drain<void>();

      try {
        await ready.future.timeout(Duration(seconds: 60));
        process.kill(signal);
        expect(await process.exitCode.timeout(Duration(seconds: 30)), 0);
        await stdoutDone;
        await stderrDone;
      } finally {
        process.kill(ProcessSignal.sigkill);
      }
      return lines;
    }

    for (var signal in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
      test('SpawnedIsolate stops on $signal', () async {
        var lines = await runUntilReady('spawn-and-wait-signal', signal);
        expect(lines, contains('EXIT:0'));
      });

      test('runProcess(handleSignals) forwards $signal', () async {
        var lines = await runUntilReady('process-wait-signal', signal);
        expect(lines, contains('ON_SIGNAL:$signal'));
        // The child was killed by the forwarded signal:
        expect(lines, contains('CHILD_EXIT:-${signal.signalNumber}'));
      });
    }
  });
}
