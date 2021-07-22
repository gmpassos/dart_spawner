import 'dart:io';
import 'dart:isolate';

import 'package:dart_spawner/dart_spawner.dart';
import 'package:test/test.dart';

void main() {
  group('Isolate extension', () {
    setUp(() {});

    test('package File/Directory', () async {
      expect((await Isolate.current.packageFile('test/hello-world.dart')).path,
          endsWith('hello-world.dart'));

      var testDir = await Isolate.current.packageDirectory('test');
      expect(testDir.path, endsWith('test'));

      expect(testDir.subFile('hello-world.dart').path,
          endsWith('hello-world.dart'));
    });
  });

  group('DartProject', () {
    setUp(() {});

    test('basics', () async {
      var dartProject = DartProject();

      expect((await dartProject.projectDirectory).toString(), isNotEmpty);

      expect(await dartProject.projectPackageName, equals('dart_spawner'));

      expect((await dartProject.projectPackageConfigUri).toString(),
          endsWith('.packages'));

      expect((await dartProject.getProjectDependencyVersion('async_extension')),
          isNotEmpty);

      expect(
          (await dartProject
              .getProjectDependencyVersion('__fake_package_name__')),
          isNull);
    });

    test('executablePath', () async {
      var dartProject = DartProject();

      expect((await dartProject.executablePath('dart')).toString(),
          matches(RegExp(r'dart(?:\.\w+)?$')));
    });
  });

  group('DartSpawner', () {
    setUp(() {
      print('-------------------------------------------------');
    });

    test('supportsLaunchObservatory', () async {
      var spawner = DartSpawner(logToConsole: true);
      print(spawner);

      var shouldSupport = Platform.isMacOS || Platform.isWindows;
      var expectMatcher = shouldSupport ? isTrue : isNotNull;

      expect(await spawner.supportsLaunchObservatory(), expectMatcher);
    });

    test('hello-world.dart', () async {
      var spawner = DartSpawner(logToConsole: true);
      print(spawner);

      expect(spawner.isFinished, isFalse);

      var file = await spawner.projectSubFile('test/hello-world.dart');
      print('Spawning File: $file');

      var spawned = await spawner.spawnDart(
        file,
        ['a', 'b', 'c'],
        debugName: 'hello-world',
      );

      print('Spawned: $spawned');
      expect(spawned, isNotNull);

      print(spawner);

      var exitCode = await spawned.exitCode;
      print('Exit code: $exitCode');
      expect(exitCode, equals(0));

      expect(spawner.isFinished, isTrue);
      expect(spawned.isFinished, isTrue);
    });

    test('hello-world.dart + stop()', () async {
      var spawner = DartSpawner(logToConsole: true);
      print(spawner);

      expect(spawner.isFinished, isFalse);

      var file = await spawner.projectSubFile('test/hello-world.dart');
      print('Spawning File: $file');

      var spawned = await spawner.spawnDart(
        file,
        ['with_stop'],
        debugName: 'hello-world + stop()',
      );

      print('Spawned: $spawned');
      expect(spawned, isNotNull);

      expect(spawned.isFinished, isFalse);

      expect(await spawned.stop(101), isTrue);

      expect(spawned.isFinished, isTrue);

      var exitCode = await spawned.exitCode;
      print('Exit code: $exitCode');
      expect(exitCode, equals(101));

      expect(spawner.isFinished, isTrue);
      expect(spawned.isFinished, isTrue);

      expect(await spawned.stop(101), isFalse);
    });

    test('script', () async {
      var spawner = DartSpawner(logToConsole: true);

      var script = r'''
void main(List<String> args) {
  print('From Script! Args: $args');
}
''';
      print('Spawning Script: <<<\n$script\n>>>');

      var spawned = await spawner.spawnDart(
        script,
        ['A', 'B', 'C'],
        debugName: 'script',
      );

      print('Spawned: $spawned');
      expect(spawned, isNotNull);

      var exitCode = await spawned.exitCode;
      print('Exit code: $exitCode');
      expect(exitCode, equals(0));
    });

    test('managed script', () async {
      var spawner = DartSpawner(logToConsole: true);

      var script = '''
import 'package:dart_spawner/dart_spawner.dart';

void main(List<String> args, dynamic parentPort) {
  spawnedMain(args, parentPort, ${spawner.id}, (a) async {
    print('From Managed Script! Args: \$a');
  });
}
''';
      print('Spawning Managed Script: <<<\n$script\n>>>');

      var spawned = await spawner.spawnDart(
        script,
        ['A', 'B', 'C'],
        usesSpawnedMain: true,
        debugName: 'managed-script',
      );

      print('Spawned: $spawned');
      expect(spawned, isNotNull);

      var exitCode = await spawned.exitCode;
      print('Exit code: $exitCode');
      expect(exitCode, equals(0));
    });
  });
}
