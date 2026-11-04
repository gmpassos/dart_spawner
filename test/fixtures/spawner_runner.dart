/// A small runner executed in a separate Dart VM (`Process.start`/`run`) by
/// `test/dart_spawner_process_test.dart`, for the behaviour that depends on
/// process-wide state: environment variables, signals, exit codes and output.
///
/// Usage: `dart test/fixtures/spawner_runner.dart <mode> [args...]`
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_spawner/dart_spawner.dart';

Future<void> main(List<String> args) async {
  // Never outlive the test that started this runner.
  Timer(Duration(seconds: 60), () => exit(99));

  var mode = args.isNotEmpty ? args[0] : '';
  var rest = args.skip(1).toList();

  switch (mode) {
    case 'env':
      print('debugMode=${DartSpawner.debugMode}');
      print('startupTimeout=${DartSpawner.defaultStartupTimeout.inSeconds}');
      print(
        'isolateCheckPingTimeout='
        '${DartSpawner.defaultIsolateCheckPingTimeout.inSeconds}',
      );
      var spawner = DartSpawner();
      print('instance.startupTimeout=${spawner.startupTimeout.inSeconds}');
      exit(0);
    case 'echo-args':
      print(jsonEncode(rest));
      exit(0);
    case 'exit':
      stderr.writeln('exiting with ${rest[0]}');
      exit(int.parse(rest[0]));
    case 'chatty':
      // Writes `<lines>` lines of 1 KiB (1023 chars + '\n') to stdout.
      var lines = int.parse(rest[0]);
      var line = '${'x' * 1023}\n';
      for (var i = 0; i < lines; ++i) {
        stdout.write(line);
      }
      await stdout.flush();
      stderr.writeln('chatty done');
      exit(0);
    case 'sleep':
      print('SLEEPING');
      await Future.delayed(Duration(seconds: 30));
      exit(0);
    case 'spawn-and-wait-signal':
      // Spawns a long running script and waits for `SpawnedIsolate` to stop
      // it on SIGINT/SIGTERM.
      var spawner = DartSpawner();
      var spawned = await spawner.spawnDart(r'''
void main() async {
  await Future.delayed(Duration(seconds: 30));
}
''', []);
      print('READY');
      var code = await spawned.exitCode;
      print('EXIT:$code');
      exit(0);
    case 'process-wait-signal':
      // Runs a child process with `handleSignals: true` and waits for the
      // signal to be forwarded to it.
      var project = DartProject();
      var info = await project.runProcess(
        Platform.resolvedExecutable,
        [Platform.script.toFilePath(), 'sleep'],
        resolveCommandPath: false,
        handleSignals: true,
        catchOutput: true,
        onSignal: (s) => print('ON_SIGNAL:$s'),
      );
      // Wait for the child to be running before reporting ready.
      while (!info.output.contains('SLEEPING')) {
        await Future.delayed(Duration(milliseconds: 20));
      }
      print('READY');
      var code = await info.exitCode;
      print('CHILD_EXIT:$code');
      exit(0);
    default:
      stderr.writeln('Unknown mode: $mode');
      exit(64);
  }
}
