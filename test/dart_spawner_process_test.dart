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

    // Known behaviour (documented at `runProcess`): without `catchOutput` or
    // `redirectOutput`, `runProcess` does not consume the child's
    // stdout/stderr. A child that writes more than the OS pipe buffer blocks
    // until the caller drains `ProcessInfo.process.stdout`.
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
