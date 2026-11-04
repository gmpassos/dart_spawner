@Timeout(Duration(minutes: 2))
library;

import 'dart:io';
import 'dart:isolate';

import 'package:dart_spawner/dart_spawner.dart';
import 'package:dart_spawner/src/dart_spawner_tools.dart';
import 'package:path/path.dart' as pack_path;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp
        .createTempSync('dart_spawner_unit_')
        .absolute;
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('extensions', () {
    test('Uri.toFile', () {
      var file = File(pack_path.join(tempDir.path, 'a.dart'));
      expect(file.uri.toFile().path, equals(file.path));
    });

    test('FileSystemEntity.name/pathParts', () {
      var file = File(pack_path.join(tempDir.path, 'x', 'b.dart'));
      expect(file.name, equals('b.dart'));
      expect(file.pathParts.last, equals('b.dart'));
      expect(file.pathParts[file.pathParts.length - 2], equals('x'));
    });

    test('Directory.subFile/subDirectory', () {
      expect(
        tempDir.subFile('a/b.txt').path,
        equals(pack_path.join(tempDir.path, 'a', 'b.txt')),
      );
      expect(
        tempDir.subDirectory('a/c').path,
        equals(pack_path.join(tempDir.path, 'a', 'c')),
      );
    });

    test('Isolate.packageMainDirectory', () async {
      var dir = await Isolate.current.packageMainDirectory;
      expect(
        File(pack_path.join(dir.path, 'pubspec.yaml')).existsSync(),
        isTrue,
      );
    });
  });

  group('tools', () {
    test('isFileInDirectory', () {
      expect(
        isFileInDirectory(tempDir, File(pack_path.join(tempDir.path, 'a'))),
        isTrue,
      );
      expect(
        isFileInDirectory(
          Directory('${tempDir.path}${pack_path.separator}'),
          File(pack_path.join(tempDir.path, 'a')),
        ),
        isTrue,
      );
      // A sibling directory with the same prefix is out of scope:
      expect(
        isFileInDirectory(tempDir, File('${tempDir.path}-other/a')),
        isFalse,
      );
    });

    test('deleteFile', () {
      var file = File(pack_path.join(tempDir.path, 'f.txt'))
        ..writeAsStringSync('x');
      deleteFile(tempDir, file, verbose: true);
      expect(file.existsSync(), isFalse);

      // Missing file: no-op.
      deleteFile(tempDir, file);

      // Empty directory passed as a `File`:
      var dir = Directory(pack_path.join(tempDir.path, 'd'))..createSync();
      deleteFile(tempDir, File(dir.path), verbose: true);
      expect(dir.existsSync(), isFalse);
    });

    test('deleteFile: out of scope', () {
      var outside = File(pack_path.join(Directory.systemTemp.path, 'x.txt'));
      expect(
        () => deleteFile(
          Directory(pack_path.join(tempDir.path, 'scope')),
          outside,
        ),
        throwsStateError,
      );
    });

    test('deleteDirectory recursive', () {
      var root = Directory(pack_path.join(tempDir.path, 'root'));
      Directory(pack_path.join(root.path, 'a', 'b'))
          .createSync(recursive: true);
      File(pack_path.join(root.path, 'a', 'b', 'f1')).writeAsStringSync('1');
      File(pack_path.join(root.path, 'a', 'f2')).writeAsStringSync('2');
      File(pack_path.join(root.path, 'f3')).writeAsStringSync('3');

      deleteDirectory(tempDir, root, recursive: true, verbose: true);
      expect(root.existsSync(), isFalse);
      expect(tempDir.existsSync(), isTrue);
    });
  });

  group('DartProject', () {
    test('logger', () {
      var logs = <String>[];
      var project = DartProject(
        directory: tempDir,
        logger: (t, m) => logs.add('$t:$m'),
      );
      project.log('INFO', 'hello');
      expect(logs, contains('INFO:hello'));

      // `logToConsole` without a logger must not throw:
      DartProject(directory: tempDir, logToConsole: true).log('INFO', 'x');
      DartProject(directory: tempDir).log('INFO', 'x');
    });

    test('projectSub*', () async {
      var project = DartProject(directory: tempDir);
      expect(
        (await project.projectSubUri('bin/main.dart')).toFilePath(),
        equals(pack_path.join(tempDir.path, 'bin', 'main.dart')),
      );
      expect(
        (await project.projectSubFile('a/b.txt')).path,
        equals(pack_path.join(tempDir.path, 'a', 'b.txt')),
      );
      expect(
        (await project.projectSubDirectory('lib')).path,
        equals(pack_path.join(tempDir.path, 'lib')),
      );
      expect(
        (await project.projectPubspecFile).path,
        equals(pack_path.join(tempDir.path, 'pubspec.yaml')),
      );

      // Without a directory: the current package.
      var current = DartProject();
      expect(
        File.fromUri(await current.projectSubUri('pubspec.yaml')).existsSync(),
        isTrue,
      );
    });

    test('relative directory is made absolute', () async {
      var relative = pack_path.relative(tempDir.path);
      expect(pack_path.isRelative(relative), isTrue);
      var project = DartProject(directory: Directory(relative));
      var dir = await project.projectDirectory;
      expect(pack_path.isAbsolute(dir.path), isTrue);
      expect(pack_path.equals(dir.path, tempDir.path), isTrue);
    });

    test('missing pubspec.yaml', () async {
      var project = DartProject(directory: tempDir);
      expect((await project.projectDirectory).path, equals(tempDir.path));
      await expectLater(
        Future(() => project.projectPubspec),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('pubspec.yaml'),
          ),
        ),
      );
    });

    test('pubspec without pub get', () async {
      _writePubspec(tempDir, 'unresolved_proj');
      var project = DartProject(directory: tempDir);

      expect(await project.projectPackageName, equals('unresolved_proj'));
      expect(await project.projectLibraryName, equals('unresolved_proj'));
      // Cached:
      expect((await project.projectPubspec)['name'], equals('unresolved_proj'));

      expect(await project.existsProjectPackageConfigUri(), isFalse);
      await expectLater(
        Future(() => project.projectPackageConfigUri),
        throwsStateError,
      );
      await expectLater(
        Future(() => project.projectPubspecLock),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('pubspec.lock'),
          ),
        ),
      );
      expect(
        (await project.projectResolutionDirectory).path,
        equals(tempDir.path),
      );
    });

    test('legacy .packages', () async {
      _writePubspec(tempDir, 'legacy_proj');
      File(pack_path.join(tempDir.path, '.packages')).writeAsStringSync('');
      var project = DartProject(directory: tempDir);
      expect(
        (await project.projectPackageConfigUri).path,
        endsWith('/.packages'),
      );
      expect(await project.existsProjectPackageConfigUri(), isTrue);
    });

    test('pubspec.lock', () async {
      _writePubspec(tempDir, 'lock_proj');
      File(pack_path.join(tempDir.path, 'pubspec.lock')).writeAsStringSync('''
packages:
  foo:
    dependency: "direct main"
    version: "1.2.3"
sdks:
  dart: ">=3.13.0 <4.0.0"
''');
      var project = DartProject(directory: tempDir);
      expect(await project.getProjectDependencyVersion('foo'), equals('1.2.3'));
      expect(await project.getProjectDependencyVersion('bar'), isNull);
      // Cached:
      expect((await project.projectPubspecLock)['sdks'], isNotNull);
    });

    test('runDartPubGet + ensure + clean', () async {
      _writePubspec(tempDir, 'pub_get_proj');
      var project = DartProject(directory: tempDir);

      expect(await project.existsProjectPackageConfigUri(), isFalse);
      expect(await project.ensureProjectDependenciesResolved(), isTrue);
      expect(await project.existsProjectPackageConfigUri(), isTrue);
      // Already resolved:
      expect(await project.ensureProjectDependenciesResolved(), isTrue);

      var dartTool = Directory(pack_path.join(tempDir.path, '.dart_tool'));
      expect(dartTool.existsSync(), isTrue);

      // Wrong project name: nothing is deleted.
      expect(
        await project.cleanDartPubGetGeneratedFiles(confirmProjectName: 'x'),
        isFalse,
      );
      expect(dartTool.existsSync(), isTrue);

      expect(
        await project.cleanDartPubGetGeneratedFiles(
          confirmProjectName: 'pub_get_proj',
          verbose: true,
        ),
        isTrue,
      );
      expect(dartTool.existsSync(), isFalse);
      expect(
        File(pack_path.join(tempDir.path, 'pubspec.lock')).existsSync(),
        isFalse,
      );
    });

    test('cleanDartPubGetGeneratedFiles: missing directory', () async {
      var project = DartProject(
        directory: Directory(pack_path.join(tempDir.path, 'missing')),
      );
      expect(
        await project.cleanDartPubGetGeneratedFiles(confirmProjectName: 'x'),
        isFalse,
      );
    });

    test('runDartPubGet failure', () async {
      File(pack_path.join(tempDir.path, 'pubspec.yaml')).writeAsStringSync('''
name: broken_proj
environment:
  sdk: ^3.13.0
dependencies:
  missing_dep:
    path: ./does_not_exist
''');
      var project = DartProject(directory: tempDir);
      await expectLater(project.runDartPubGet(), throwsStateError);
    });

    test('executablePath', () async {
      var project = DartProject();
      var dart = await project.executablePath('dart');
      expect(dart, isNotNull);
      // Cached and refreshed:
      expect(await project.executablePath(' dart '), equals(dart));
      expect(await project.executablePath('dart', refresh: true), equals(dart));

      expect(
        await project.executablePath('__dart_spawner_no_such_binary__'),
        isNull,
      );
    });

    test('runProcess', () async {
      var project = DartProject(directory: tempDir);

      var dart = (await project.executablePath('dart'))!;
      var info = await project.runProcess(
        dart,
        ['--version'],
        resolveCommandPath: false,
        catchOutput: true,
        stdoutFilter: (o) => o.toUpperCase(),
        stderrFilter: (o) => o.toUpperCase(),
      );
      expect(await info.exitCode, equals(0));
      expect(await info.checkExitCode(), isTrue);
      expect(await info.checkExitCode(1), isFalse);
      expect('${info.output}${info.errorOutput}', contains('DART SDK VERSION'));
      expect(info.toString(), contains('exitCode: 0'));
      expect(info.binPath, equals(dart));
      expect(info.args, equals(['--version']));
      expect(info.workingDirectory, isNull);

      var failing = await project.runProcess('dart', [
        '__no_such_file__.dart',
      ], workingDirectory: tempDir.path);
      expect(await failing.checkExitCode(), isFalse);
      expect(failing.output, isEmpty);

      await expectLater(
        project.runProcess('__dart_spawner_no_such_binary__', []),
        throwsStateError,
      );
    });

    test('isFreeListenPort / getFreeListenPort', () async {
      var server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      try {
        var busy = server.port;
        expect(await DartProject.isFreeListenPort(busy), isFalse);

        expect(await DartProject.getFreeListenPort(ports: [busy]), isNull);
        expect(
          await DartProject.getFreeListenPort(ports: [busy], skipPort: [busy]),
          isNull,
        );
        expect(await DartProject.getFreeListenPort(), isNull);

        var free = await DartProject.getFreeListenPort(
          startPort: 8199,
          endPort: 8190,
          skipPort: [busy],
          shufflePorts: true,
          testTimeout: Duration(milliseconds: 500),
        );
        expect(
          free,
          allOf(greaterThanOrEqualTo(8190), lessThanOrEqualTo(8199)),
        );
      } finally {
        await server.close();
      }
    });
  });

  group('DartSpawner', () {
    test('constructor', () {
      var spawner = DartSpawner(directory: tempDir);
      expect(spawner.startupTimeout, equals(DartSpawner.defaultStartupTimeout));
      expect(
        spawner.isolateCheckPingTimeout,
        equals(DartSpawner.defaultIsolateCheckPingTimeout),
      );
      expect(spawner.isSpawned, isFalse);
      expect(spawner.isFinished, isFalse);
      expect(spawner.uncaughtError, isNull);
      expect(spawner.spawnError, isNull);
      expect(spawner.toString(), contains('spawned: false'));

      var spawner2 = DartSpawner(
        directory: tempDir,
        startupTimeout: Duration(seconds: 3),
      );
      expect(spawner2.startupTimeout, equals(Duration(seconds: 3)));
      expect(spawner2.id, greaterThan(spawner.id));
    });

    test('isDartFilePath', () {
      var spawner = DartSpawner(directory: tempDir);
      expect(spawner.isDartFilePath('bin/main.dart'), isTrue);
      expect(spawner.isDartFilePath('/abs/path/main.dart'), isTrue);
      expect(spawner.isDartFilePath('main.txt'), isFalse);
      expect(spawner.isDartFilePath('void main() {}\n// a.dart'), isFalse);
      expect(spawner.isDartFilePath(File('a.dart')), isFalse);
    });

    test('spawnDart: unsupported entry point', () {
      var spawner = DartSpawner(directory: tempDir);
      expect(() => spawner.spawnDart(123, []), throwsStateError);
      expect(spawner.isSpawned, isFalse);
    });

    test('supportsLaunchObservatory', () async {
      var spawner = DartSpawner(directory: tempDir);
      var supported = await spawner.supportsLaunchObservatory();
      // Cached:
      expect(await spawner.supportsLaunchObservatory(), equals(supported));
    });
  });
}

void _writePubspec(Directory dir, String name) {
  File(pack_path.join(dir.path, 'pubspec.yaml')).writeAsStringSync('''
name: $name
publish_to: none
environment:
  sdk: ^3.13.0
''');
}
