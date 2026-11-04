@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
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
  });
}

const _writerScript = r'''
import 'dart:io';

void main(List<String> args) {
  File(args[0]).writeAsStringSync('args:${args.skip(1).join(',')}');
}
''';

/// A managed script: `run` writes `run:<args>` to `args[0]`, then executes
/// [runBody]; `stop` writes `stopped` to `stop.txt` next to it.
String _managedScript(int id, String runBody) =>
    '''
import 'dart:io';

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
