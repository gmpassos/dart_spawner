@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:developer';
import 'dart:io';
import 'dart:isolate';

import 'package:dart_spawner/dart_spawner.dart';
import 'package:path/path.dart' as pack_path;
import 'package:test/test.dart';

/// Integration tests that really spawn isolates.
///
/// Scripts report back by writing a result file, whose path is passed as
/// the first argument.
void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp
        .createTempSync('dart_spawner_spawn_')
        .absolute;
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  String resultPath([String name = 'result.txt']) =>
      pack_path.join(tempDir.path, name);

  String readResult([String name = 'result.txt']) =>
      File(resultPath(name)).readAsStringSync();

  group('current project', () {
    test('script', () async {
      var spawner = DartSpawner();
      var spawned = await spawner.spawnDart(_writerScript, [
        resultPath(),
        'a',
        'b',
      ], debugName: 'writer-script');

      expect(spawned.type, equals('<script>'));
      expect(spawner.spawnedType, equals('<script>'));
      expect(spawner.spawnedEntry, equals(_writerScript));
      expect(spawner.isSpawned, isTrue);
      expect(spawner.toString(), contains('spawnedType: <script>'));

      expect(await spawned.exitCode, equals(0));
      expect(readResult(), equals('args:a,b'));
      expect(spawner.isFinished, isTrue);
      expect(spawned.isFinished, isTrue);
      expect(spawner.uncaughtError, isNull);
      expect(await spawned.stop(1), isFalse);
      expect(await spawned.exitCode, equals(0));
    });

    test('only one spawn per instance', () async {
      var spawner = DartSpawner();
      var spawned = await spawner.spawnDart(_writerScript, [resultPath()]);
      await expectLater(
        spawner.spawnDart(_writerScript, [resultPath('2.txt')]),
        throwsStateError,
      );
      expect(await spawned.exitCode, equals(0));
    });

    test('File, Uri and path', () async {
      var file = File(pack_path.join(tempDir.path, 'writer.dart'))
        ..writeAsStringSync(_writerScript);

      var s1 = DartSpawner();
      var p1 = await s1.spawnDart(file, [resultPath('1.txt'), 'file']);
      expect(p1.type, equals('File'));
      expect(p1.spawnEntry, equals(file));

      var s2 = DartSpawner();
      var p2 = await s2.spawnDart(file.uri, [resultPath('2.txt'), 'uri']);
      expect(p2.type, equals('Uri'));

      var s3 = DartSpawner();
      var p3 = await s3.spawnDartURI(file.uri, [resultPath('3.txt'), 'uri2']);
      expect(p3.type, equals('Uri'));

      var s4 = DartSpawner();
      var p4 = await s4.spawnDart(file.path, [resultPath('4.txt'), 'path']);
      expect(p4.type, equals('File'));

      expect(
        await Future.wait([p1.exitCode, p2.exitCode, p3.exitCode, p4.exitCode]),
        equals([0, 0, 0, 0]),
      );
      expect(readResult('1.txt'), equals('args:file'));
      expect(readResult('2.txt'), equals('args:uri'));
      expect(readResult('3.txt'), equals('args:uri2'));
      expect(readResult('4.txt'), equals('args:path'));
    });

    test('uncaught error', () async {
      var spawner = DartSpawner();
      var spawned = await spawner.spawnDart(r'''
void main() {
  throw StateError('sync boom');
}
''', []);

      expect(await spawned.exitCode, equals(DartSpawner.uncaughtErrorExitCode));
      expect(spawner.uncaughtError, isA<RemoteError>());
      expect(spawner.uncaughtError.toString(), contains('sync boom'));
      expect(spawner.uncaughtError!.stackTrace.toString(), contains('main'));
    });

    test('uncaught async error', () async {
      var spawner = DartSpawner();
      var spawned = await spawner.spawnDart(r'''
void main() async {
  await Future.delayed(Duration(milliseconds: 100));
  throw ArgumentError('async boom');
}
''', []);

      expect(spawned.isFinished, isFalse);
      expect(await spawned.exitCode, equals(DartSpawner.uncaughtErrorExitCode));
      expect(spawner.uncaughtError.toString(), contains('async boom'));
    });

    test('compilation error', () async {
      var spawner = DartSpawner();
      await expectLater(
        spawner.spawnDart('void main() { int x = "not an int"; }', []),
        throwsA(isA<IsolateSpawnException>()),
      );
      expect(spawner.isFinished, isTrue);
      expect(spawner.spawnError, isA<IsolateSpawnException>());
      expect(
        await spawner.exitCode.future,
        equals(DartSpawner.uncaughtErrorExitCode),
      );
    });

    test('missing file', () async {
      var spawner = DartSpawner();
      await expectLater(
        spawner.spawnDart(
          File(pack_path.join(tempDir.path, 'missing.dart')),
          [],
        ),
        throwsA(isA<IsolateSpawnException>()),
      );
      expect(spawner.isFinished, isTrue);
    });

    test('stop() kills a running script', () async {
      var spawner = DartSpawner();
      var spawned = await spawner.spawnDart(r'''
void main() async {
  await Future.delayed(Duration(seconds: 60));
}
''', []);

      expect(spawned.isFinished, isFalse);
      expect(await spawned.stop(42, reason: 'test'), isTrue);
      expect(await spawned.exitCode, equals(42));
      expect(spawner.isFinished, isTrue);
    });
  });

  group('managed (spawnedMain)', () {
    test('runs and stops normally', () async {
      var spawner = DartSpawner();
      var spawned = await spawner.spawnDart(
        _managedScript(spawner.id, 'await Future.delayed(Duration.zero);'),
        [resultPath(), 'x', 'y'],
        usesSpawnedMain: true,
        debugName: 'managed-ok',
      );

      expect(spawned.stopByKill, isFalse);
      expect(await spawned.exitCode, equals(0));
      expect(readResult(), equals('run:x,y'));
      expect(readResult('stop.txt'), equals('stopped'));
    });

    test('stop() with a pending run', () async {
      var spawner = DartSpawner();
      var spawned = await spawner.spawnDart(
        _managedScript(
          spawner.id,
          'await Future.delayed(Duration(seconds: 60));',
        ),
        [resultPath(), 'long'],
        usesSpawnedMain: true,
      );

      expect(readResult(), equals('run:long'));
      expect(spawned.isFinished, isFalse);

      expect(await spawned.stop(7), isTrue);
      expect(await spawned.exitCode, equals(7));
      // The script's `stop` callback ran before `stop()` returned:
      expect(readResult('stop.txt'), equals('stopped'));
    });

    test('error before startup', () async {
      var spawner = DartSpawner();
      await expectLater(
        spawner.spawnDart(
          '''
import 'package:dart_spawner/dart_spawner.dart';

void main(List<String> args, dynamic parentPort) {
  spawnedMain(args, parentPort, ${spawner.id}, () {
    throw StateError('startup boom');
  });
}
''',
          [],
          usesSpawnedMain: true,
        ),
        throwsA(
          isA<RemoteError>().having(
            (e) => e.toString(),
            'toString',
            contains('startup boom'),
          ),
        ),
      );
      expect(
        await spawner.exitCode.future,
        equals(DartSpawner.uncaughtErrorExitCode),
      );
    });

    test('error after startup', () async {
      var spawner = DartSpawner();
      var spawned = await spawner.spawnDart(
        _managedScript(
          spawner.id,
          "await Future.delayed(Duration(milliseconds: 200)); "
          "throw StateError('late boom');",
        ),
        [resultPath()],
        usesSpawnedMain: true,
      );

      expect(await spawned.exitCode, equals(DartSpawner.uncaughtErrorExitCode));
      expect(spawner.uncaughtError.toString(), contains('late boom'));
    });

    test('script exits without calling spawnedMain', () async {
      var spawner = DartSpawner();
      await expectLater(
        spawner.spawnDart(
          'void main(List<String> args, dynamic port) {}',
          [],
          usesSpawnedMain: true,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('spawnedMain'),
          ),
        ),
      );
      expect(await spawner.exitCode.future, isNot(0));
    });

    test('startupTimeout', () async {
      var spawner = DartSpawner(startupTimeout: Duration(seconds: 2));
      var sw = Stopwatch()..start();
      await expectLater(
        spawner.spawnDart(
          r'''
void main(List<String> args, dynamic port) async {
  await Future.delayed(Duration(seconds: 60));
}
''',
          [],
          usesSpawnedMain: true,
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(sw.elapsed, lessThan(Duration(seconds: 30)));
      expect(spawner.spawnError, isA<TimeoutException>());
      expect(
        await spawner.exitCode.future,
        equals(DartSpawner.uncaughtErrorExitCode),
      );
    });
  });

  group('separate project', () {
    test('own package_config', () async {
      var projDir = _createProject(tempDir, 'sep_proj');

      var spawner = DartSpawner(directory: projDir);
      expect(await spawner.existsProjectPackageConfigUri(), isFalse);

      var file = await spawner.projectSubFile('bin/main.dart');
      var spawned = await spawner.spawnDart(file, [resultPath(), 'World']);

      // `dart pub get` was run for the project:
      var packageConfig = await spawner.projectPackageConfigUri;
      expect(
        packageConfig.toFilePath(),
        equals(
          pack_path.join(projDir.path, '.dart_tool', 'package_config.json'),
        ),
      );
      expect(packageConfig, isNot(equals(await Isolate.packageConfig)));

      expect(await spawned.exitCode, equals(0));
      expect(readResult(), equals('Hello World from sep_proj'));
      expect(spawned.projectDirectory.path, equals(projDir.path));

      expect(
        await spawner.cleanDartPubGetGeneratedFiles(
          confirmProjectName: 'sep_proj',
        ),
        isTrue,
      );
      expect(await spawner.existsProjectPackageConfigUri(), isFalse);
    });

    test('pub workspace member', () async {
      var root = tempDir;
      File(pack_path.join(root.path, 'pubspec.yaml')).writeAsStringSync('''
name: ws_root
publish_to: none
environment:
  sdk: ^3.13.0
workspace:
  - pkgs/ws_app
''');
      var appDir = _createProject(
        Directory(pack_path.join(root.path, 'pkgs'))..createSync(),
        'ws_app',
        workspaceMember: true,
      );

      var spawner = DartSpawner(directory: appDir);
      var file = await spawner.projectSubFile('bin/main.dart');
      var spawned = await spawner.spawnDart(file, [resultPath(), 'Workspace']);

      expect((await spawner.projectResolutionDirectory).path, root.path);
      expect(
        (await spawner.projectPackageConfigUri).toFilePath(),
        equals(pack_path.join(root.path, '.dart_tool', 'package_config.json')),
      );
      expect(
        (await spawner.projectPubspecLockFile).path,
        equals(pack_path.join(root.path, 'pubspec.lock')),
      );
      expect(await spawner.projectPackageName, equals('ws_app'));

      expect(await spawned.exitCode, equals(0));
      expect(readResult(), equals('Hello Workspace from ws_app'));
    });

    test('package: Uri', () async {
      var projDir = _createProject(tempDir, 'pkg_uri_proj');
      File(pack_path.join(projDir.path, 'lib', 'entry.dart'))
          .writeAsStringSync(_packageEntryScript('pkg_uri_proj'));

      var spawner = DartSpawner(directory: projDir);
      var spawned = await spawner
          .spawnDart(Uri.parse('package:pkg_uri_proj/entry.dart'), [
            resultPath(),
            'Package',
          ])
          .timeout(_spawnTimeout);
      expect(spawned.type, equals('Uri'));
      expect(await spawned.exitCode.timeout(_spawnTimeout), equals(0));
      expect(readResult(), equals('Hello Package from pkg_uri_proj'));
    });

    test('package: Uri of an unknown package', () async {
      var projDir = _createProject(tempDir, 'pkg_unknown_proj');
      var spawner = DartSpawner(directory: projDir);
      await expectLater(
        spawner
            .spawnDart(Uri.parse('package:__no_such_package__/main.dart'), [])
            .timeout(_spawnTimeout),
        throwsA(isA<IsolateSpawnException>()),
      );
      expect(
        await spawner.exitCode.future,
        equals(DartSpawner.uncaughtErrorExitCode),
      );
    });
  });

  group('scenarios', () {
    test('package: Uri of the current project (no main)', () async {
      var spawner = DartSpawner();
      await expectLater(
        spawner
            .spawnDart(Uri.parse('package:dart_spawner/dart_spawner.dart'), [])
            .timeout(_spawnTimeout),
        throwsA(isA<IsolateSpawnException>()),
      );
      expect(spawner.spawnError, isA<IsolateSpawnException>());
    });

    test('arguments', () async {
      var args = [
        'with space',
        'quote"s',
        "single'quote",
        r'$dollar',
        'ünïcødé',
        '--flag=x',
        '',
        'a,b',
      ];
      var spawner = DartSpawner();
      var spawned = await spawner
          .spawnDart(_jsonArgsScript, [resultPath(), ...args])
          .timeout(_spawnTimeout);
      expect(await spawned.exitCode.timeout(_spawnTimeout), equals(0));
      expect(jsonDecode(readResult()), equals(args));
    });

    test('no arguments', () async {
      var file = File(pack_path.join(tempDir.path, 'no_args.dart'))
        ..writeAsStringSync('''
import 'dart:io';

void main(List<String> args) {
  File(${jsonEncode(resultPath())}).writeAsStringSync('args:\${args.length}');
}
''');
      var spawned = await DartSpawner()
          .spawnDart(file, [])
          .timeout(_spawnTimeout);
      expect(await spawned.exitCode.timeout(_spawnTimeout), equals(0));
      expect(readResult(), equals('args:0'));
    });

    test('a script that prints a lot', () async {
      var spawner = DartSpawner();
      var spawned = await spawner
          .spawnDart(
            r'''
import 'dart:io';

void main(List<String> args) {
  for (var i = 0; i < 2000; ++i) {
    print('[dart_spawner test] chatty line $i');
  }
  File(args[0]).writeAsStringSync('printed:2000');
}
''',
            [resultPath()],
          )
          .timeout(_spawnTimeout);
      expect(await spawned.exitCode.timeout(_spawnTimeout), equals(0));
      expect(readResult(), equals('printed:2000'));
    });

    test('a script that kills its own isolate', () async {
      // An isolate cannot report a process exit code (`exit(n)` would end
      // the whole host VM): a self-terminated isolate reports `0`.
      var spawner = DartSpawner();
      var spawned = await spawner
          .spawnDart(
            r'''
import 'dart:io';
import 'dart:isolate';

void main(List<String> args) async {
  File(args[0]).writeAsStringSync('before');
  Isolate.current.kill();
  await Future.delayed(Duration(seconds: 5));
  File(args[0]).writeAsStringSync('after');
}
''',
            [resultPath()],
          )
          .timeout(_spawnTimeout);
      expect(await spawned.exitCode.timeout(_spawnTimeout), equals(0));
      expect(readResult(), equals('before'));
      expect(spawner.uncaughtError, isNull);
    });

    test('concurrent spawns', () async {
      const n = 6;
      var spawners = List.generate(n, (_) => DartSpawner());
      var spawned = await Future.wait([
        for (var i = 0; i < n; ++i)
          spawners[i].spawnDart(_writerScript, [
            resultPath('c$i.txt'),
            'n$i',
          ], debugName: 'concurrent-$i'),
      ]).timeout(_spawnTimeout);

      expect(spawned.map((s) => s.id).toSet().length, equals(n));
      expect(
        await Future.wait(spawned.map((s) => s.exitCode))
            .timeout(_spawnTimeout),
        equals(List.filled(n, 0)),
      );
      for (var i = 0; i < n; ++i) {
        expect(readResult('c$i.txt'), equals('args:n$i'));
        expect(spawners[i].isFinished, isTrue);
      }
    });

    test('the same file twice', () async {
      var file = File(pack_path.join(tempDir.path, 'twice.dart'))
        ..writeAsStringSync(_writerScript);

      var s1 = DartSpawner();
      var s2 = DartSpawner();
      var spawned = await Future.wait([
        s1.spawnDart(file, [resultPath('t1.txt'), 'first']),
        s2.spawnDart(file, [resultPath('t2.txt'), 'second']),
      ]).timeout(_spawnTimeout);

      expect(spawned[0].spawnEntry, equals(spawned[1].spawnEntry));
      expect(
        await Future.wait([spawned[0].exitCode, spawned[1].exitCode])
            .timeout(_spawnTimeout),
        equals([0, 0]),
      );
      expect(readResult('t1.txt'), equals('args:first'));
      expect(readResult('t2.txt'), equals('args:second'));
    });

    test('relative and absolute paths', () async {
      var file = File(pack_path.join(tempDir.path, 'rel.dart'))
        ..writeAsStringSync(_writerScript);
      var relativePath = pack_path.relative(file.path);
      expect(pack_path.isRelative(relativePath), isTrue);

      var entries = <Object>[
        file.path,
        relativePath,
        File(relativePath),
        File(file.path),
      ];
      for (var i = 0; i < entries.length; ++i) {
        var spawner = DartSpawner();
        var spawned = await spawner
            .spawnDart(entries[i], [resultPath('p$i.txt'), 'p$i'])
            .timeout(_spawnTimeout);
        expect(spawned.type, equals('File'), reason: '${entries[i]}');
        expect(
          await spawned.exitCode.timeout(_spawnTimeout),
          equals(0),
          reason: '${entries[i]}',
        );
        expect(readResult('p$i.txt'), equals('args:p$i'));
      }
    });

    test('relative project directory', () async {
      var projDir = _createProject(tempDir, 'rel_proj');
      var spawner = DartSpawner(
        directory: Directory(pack_path.relative(projDir.path)),
      );
      expect(
        pack_path.equals((await spawner.projectDirectory).path, projDir.path),
        isTrue,
      );
      var file = await spawner.projectSubFile('bin/main.dart');
      var spawned = await spawner
          .spawnDart(file, [resultPath(), 'Relative'])
          .timeout(_spawnTimeout);
      expect(await spawned.exitCode.timeout(_spawnTimeout), equals(0));
      expect(readResult(), equals('Hello Relative from rel_proj'));
    });

    test('stop right after spawn, before the script runs', () async {
      var spawner = DartSpawner();
      var spawned = await spawner
          .spawnDart(
            r'''
import 'dart:io';

void main(List<String> args) async {
  await Future.delayed(Duration(milliseconds: 500));
  File(args[0]).writeAsStringSync('ran');
}
''',
            [resultPath()],
          )
          .timeout(_spawnTimeout);

      expect(await spawned.stop(9, reason: 'early'), isTrue);
      expect(await spawned.exitCode, equals(9));
      expect(spawner.isFinished, isTrue);

      await Future.delayed(Duration(seconds: 1));
      expect(File(resultPath()).existsSync(), isFalse);
      // Further stops are no-ops:
      expect(await spawned.stop(10), isFalse);
      expect(await spawned.exitCode, equals(9));
    });

    test('enableObservatory', () async {
      var wasEnabled = (await Service.getInfo()).serverUri != null;
      try {
        var spawner = DartSpawner();
        var spawned = await spawner
            .spawnDart(_writerScript, [
              resultPath(),
              'obs',
            ], enableObservatory: true)
            .timeout(_spawnTimeout);
        expect(spawned.observatoryURL, startsWith('http'));
        expect(
          spawned.observatoryURL,
          equals((await Service.getInfo()).serverUri.toString()),
        );
        expect(await spawned.exitCode.timeout(_spawnTimeout), equals(0));

        var spawner2 = DartSpawner();
        var spawned2 = await spawner2
            .spawnDart(
              _managedScript(spawner2.id, ''),
              [resultPath('m.txt'), 'obs'],
              usesSpawnedMain: true,
              enableObservatory: true,
            )
            .timeout(_spawnTimeout);
        expect(spawned2.observatoryURL, equals(spawned.observatoryURL));
        expect(await spawned2.exitCode.timeout(_spawnTimeout), equals(0));
      } finally {
        if (!wasEnabled) {
          await Service.controlWebServer(enable: false);
        }
      }
    });

    // With the VM service enabled (always the case under `--coverage`), a
    // script that blocks its event loop for longer than
    // `isolateCheckPingTimeout` must not be reported as exited (1.2.x took a
    // ping timeout as an exit and completed `exitCode` with 0).
    for (var managed in [false, true]) {
      test('VM service: a busy ${managed ? 'managed ' : ''}script is not '
          'reported as exited', () async {
        var wasEnabled = (await Service.getInfo()).serverUri != null;
        if (!wasEnabled) {
          await Service.controlWebServer(enable: true);
        }
        try {
          expect((await Service.getInfo()).serverUri, isNotNull);
          var busyMillis =
              DartSpawner.defaultIsolateCheckPingTimeout.inMilliseconds * 2;
          var spawner = DartSpawner();
          var busy =
              'var sw = Stopwatch()..start(); '
              'while (sw.elapsedMilliseconds < $busyMillis) {} '
              "File(args[0]).writeAsStringSync('done');";
          var spawned = await spawner
              .spawnDart(
                managed
                    ? '''
import 'dart:io';

import 'package:dart_spawner/dart_spawner.dart';

void main(List<String> args, dynamic parentPort) {
  spawnedMain(args, parentPort, ${spawner.id}, () async {
    await Future.delayed(Duration(milliseconds: 50));
    $busy
  });
}
'''
                    : '''
import 'dart:io';

void main(List<String> args) {
  $busy
}
''',
                [resultPath()],
                usesSpawnedMain: managed,
              )
              .timeout(_spawnTimeout);

          var code = await spawned.exitCode.timeout(_spawnTimeout);
          // The script had finished when the exit was reported:
          expect(File(resultPath()).existsSync(), isTrue);
          expect(code, equals(0));
          expect(spawner.uncaughtError, isNull);
        } finally {
          if (!wasEnabled) {
            await Service.controlWebServer(enable: false);
          }
        }
      });
    }

    test('stop() while the VM service is enabled', () async {
      var wasEnabled = (await Service.getInfo()).serverUri != null;
      if (!wasEnabled) {
        await Service.controlWebServer(enable: true);
      }
      try {
        var spawner = DartSpawner();
        var spawned = await spawner
            .spawnDart(r'''
void main() async {
  await Future.delayed(Duration(seconds: 30));
}
''', [])
            .timeout(_spawnTimeout);
        // Let a few VM service checks run:
        await Future.delayed(Duration(milliseconds: 1500));
        expect(spawned.isFinished, isFalse);
        expect(await spawned.stop(7), isTrue);
        expect(await spawned.exitCode, equals(7));
        // Concurrent/late stops are no-ops:
        expect(await spawned.stop(8), isFalse);
      } finally {
        if (!wasEnabled) {
          await Service.controlWebServer(enable: false);
        }
      }
    });

    test('without enableObservatory', () async {
      var spawned = await DartSpawner()
          .spawnDart(_writerScript, [resultPath()])
          .timeout(_spawnTimeout);
      expect(spawned.observatoryURL, isNull);
      expect(await spawned.exitCode.timeout(_spawnTimeout), equals(0));
    });
  });

  group('managed scenarios', () {
    test('sync run without args, async stop callback', () async {
      var spawner = DartSpawner();
      var spawned = await spawner
          .spawnDart(
            '''
import 'dart:io';

import 'package:dart_spawner/dart_spawner.dart';

void main(List<String> args, dynamic parentPort) {
  spawnedMain(args, parentPort, ${spawner.id}, () {
    File(args[0]).writeAsStringSync('run');
  }, () async {
    await Future.delayed(Duration(milliseconds: 50));
    File(args[0]).writeAsStringSync('stopped');
    return true;
  });
}
''',
            [resultPath()],
            usesSpawnedMain: true,
          )
          .timeout(_spawnTimeout);
      expect(await spawned.exitCode.timeout(_spawnTimeout), equals(0));
      expect(readResult(), equals('stopped'));
    });

    test('isolate exits without reporting stopped', () async {
      var spawner = DartSpawner();
      var spawned = await spawner
          .spawnDart(
            _managedScript(
              spawner.id,
              'await Future.delayed(Duration(milliseconds: 100)); '
              'Isolate.current.kill(priority: Isolate.immediate); '
              'await Future.delayed(Duration(seconds: 5));',
              extraImports: "import 'dart:isolate';",
            ),
            [resultPath(), 'self-kill'],
            usesSpawnedMain: true,
          )
          .timeout(_spawnTimeout);

      expect(await spawned.exitCode.timeout(_spawnTimeout), equals(0));
      expect(readResult(), equals('run:self-kill'));
      // Killed before `spawnedMain` could call `stop`:
      expect(File(resultPath('stop.txt')).existsSync(), isFalse);
      expect(spawner.uncaughtError, isNull);
    });

    test('compilation error', () async {
      var spawner = DartSpawner();
      await expectLater(
        spawner
            .spawnDart(
              'void main(List<String> args, dynamic port) { int x = ""; }',
              [],
              usesSpawnedMain: true,
            )
            .timeout(_spawnTimeout),
        throwsA(isA<IsolateSpawnException>()),
      );
      expect(spawner.spawnError, isA<IsolateSpawnException>());
      expect(
        await spawner.exitCode.future,
        equals(DartSpawner.uncaughtErrorExitCode),
      );
    });

    test('stop callback slower than managedStopTimeout', () async {
      var spawner = DartSpawner();
      var spawned = await spawner
          .spawnDart(
            '''
import 'package:dart_spawner/dart_spawner.dart';

void main(List<String> args, dynamic parentPort) {
  spawnedMain(args, parentPort, ${spawner.id}, (List<String> a) async {
    await Future.delayed(Duration(seconds: 60));
  }, () async {
    await Future.delayed(Duration(seconds: 60));
    return true;
  });
}
''',
            [],
            usesSpawnedMain: true,
          )
          .timeout(_spawnTimeout);

      var sw = Stopwatch()..start();
      expect(await spawned.stop(5).timeout(_spawnTimeout), isTrue);
      expect(sw.elapsed, greaterThanOrEqualTo(DartSpawner.managedStopTimeout));
      expect(sw.elapsed, lessThan(Duration(seconds: 30)));
      expect(await spawned.exitCode, equals(5));
    });

    test('the same managed file twice', () async {
      var file = File(pack_path.join(tempDir.path, 'managed.dart'));
      // The `id` argument of `spawnedMain` is only used for logging.
      file.writeAsStringSync(_managedScript(0, ''));

      var s1 = DartSpawner();
      var s2 = DartSpawner();
      var spawned = await Future.wait([
        s1.spawnDart(file, [
          resultPath('m1.txt'),
          'one',
        ], usesSpawnedMain: true),
        s2.spawnDart(file, [
          resultPath('m2.txt'),
          'two',
        ], usesSpawnedMain: true),
      ]).timeout(_spawnTimeout);
      expect(
        await Future.wait(spawned.map((s) => s.exitCode))
            .timeout(_spawnTimeout),
        equals([0, 0]),
      );
      expect(readResult('m1.txt'), equals('run:one'));
      expect(readResult('m2.txt'), equals('run:two'));
    });
  });
}

const _spawnTimeout = Duration(seconds: 60);

const _jsonArgsScript = r'''
import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  File(args[0]).writeAsStringSync(jsonEncode(args.skip(1).toList()));
}
''';

String _packageEntryScript(String name) =>
    '''
import 'dart:io';

import 'package:$name/$name.dart';

void main(List<String> args) {
  File(args[0]).writeAsStringSync(greet(args[1]));
}
''';

const _writerScript = r'''
import 'dart:io';

void main(List<String> args) {
  File(args[0]).writeAsStringSync('args:${args.skip(1).join(',')}');
}
''';

/// A managed script: `run` writes `run:<args>` to `args[0]`, then executes
/// [runBody]; `stop` writes `stopped` to `stop.txt` next to it.
String _managedScript(int id, String runBody, {String extraImports = ''}) =>
    '''
import 'dart:io';
$extraImports

import 'package:dart_spawner/dart_spawner.dart';

void main(List<String> args, dynamic parentPort) {
  var out = File(args[0]);
  spawnedMain(args, parentPort, $id, (List<String> a) async {
    out.writeAsStringSync('run:\${a.skip(1).join(',')}');
    $runBody
  }, () {
    File('\${out.parent.path}/stop.txt').writeAsStringSync('stopped');
    return true;
  });
}
''';

/// Creates a project with a library and a `bin/main.dart` that imports it
/// through a `package:` URI (so it needs the project's own package config).
Directory _createProject(
  Directory parent,
  String name, {
  bool workspaceMember = false,
}) {
  var dir = Directory(pack_path.join(parent.path, name))..createSync();
  File(pack_path.join(dir.path, 'pubspec.yaml')).writeAsStringSync('''
name: $name
publish_to: none
environment:
  sdk: ^3.13.0
${workspaceMember ? 'resolution: workspace' : ''}
''');
  Directory(pack_path.join(dir.path, 'lib')).createSync();
  File(pack_path.join(dir.path, 'lib', '$name.dart')).writeAsStringSync('''
String greet(String who) => 'Hello \$who from $name';
''');
  Directory(pack_path.join(dir.path, 'bin')).createSync();
  File(pack_path.join(dir.path, 'bin', 'main.dart')).writeAsStringSync('''
import 'dart:io';

import 'package:$name/$name.dart';

void main(List<String> args) {
  File(args[0]).writeAsStringSync(greet(args[1]));
}
''');
  return dir;
}
