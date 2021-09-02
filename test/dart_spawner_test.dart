import 'dart:io';
import 'dart:isolate';

import 'package:dart_spawner/dart_spawner.dart';
import 'package:path/path.dart' as pack_path;
import 'package:test/test.dart';

void main() {
  group('Isolate extension', () {
    setUp(() {});

    test('package File/Directory', () async {
      expect((await Isolate.current.packageFile('test/hello_world.dart')).path,
          endsWith('hello_world.dart'));

      var testDir = await Isolate.current.packageDirectory('test');
      expect(testDir.path, endsWith('test'));

      expect(testDir.subFile('hello_world.dart').path,
          endsWith('hello_world.dart'));
    });
  });

  group('DartProject', () {
    setUp(() {});

    test('basics', () async {
      var dartProject = DartProject();

      expect((await dartProject.projectDirectory).toString(), isNotEmpty);

      expect(await dartProject.projectPackageName, equals('dart_spawner'));

      expect((await dartProject.projectPackageConfigUri).toString(),
          matches(RegExp(r'/(?:\.packages|package_config.json)$')));

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

    test('hello_world.dart', () async {
      var spawner = DartSpawner(logToConsole: true);
      print(spawner);

      expect(spawner.isFinished, isFalse);

      var file = await spawner.projectSubFile('test/hello_world.dart');
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

    test('hello_world.dart + stop()', () async {
      var spawner = DartSpawner(logToConsole: true);
      print(spawner);

      expect(spawner.isFinished, isFalse);

      var file = await spawner.projectSubFile('test/hello_world.dart');
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

    test('bin/test_project.dart', () async {
      var currentDir = Directory.current;
      var testDir = currentDir.path.endsWith('test')
          ? currentDir
          : Directory(pack_path.join(currentDir.path, 'test'));

      expect(testDir.existsSync(), isTrue);

      var testProjectDir =
          Directory(pack_path.join(testDir.path, 'test_project'));

      var spawner = DartSpawner(directory: testProjectDir, logToConsole: true);
      print(spawner);

      expect(spawner.isFinished, isFalse);

      expect(
          await spawner.cleanDartPubGetGeneratedFiles(
              confirmProjectName: 'test_project'),
          isTrue);

      var fileTxt = await spawner.projectSubFile('bin/test_project.dart.txt');
      expect(fileTxt.existsSync(), isTrue);

      var fileDart =
          File(pack_path.join(fileTxt.parent.path, 'test_project.dart'));
      fileTxt.copySync(fileDart.path);

      expect(fileDart.existsSync(), isTrue);

      var file = await spawner.projectSubFile('bin/test_project.dart');
      expect(file.existsSync(), isTrue);

      print('Spawning File: $file');

      var spawned = await spawner.spawnDart(
        file,
        ['Test Title', 'English', '11.99'],
        debugName: 'test_project',
      );

      print('Spawned: $spawned');
      expect(spawned, isNotNull);

      print(spawner);

      var exitCode = await spawned.exitCode;
      print('Exit code: $exitCode');
      expect(exitCode, equals(0));

      expect(spawner.isFinished, isTrue);
      expect(spawned.isFinished, isTrue);

      expect(spawner.projectLibraryName, equals('test_project'));

      await testRunDartVM(spawner, redirectOutput: true, catchOutput: true);
      await testRunDartVM(spawner, redirectOutput: false, catchOutput: true);
      await testRunDartVM(spawner, redirectOutput: true, catchOutput: false);

      await testRunDartVM(spawner, vmServicePort: 8171);

      await testRunDartVM(
        spawner,
        enableVMService: true,
        vmServicePort: await DartProject.getFreeListenPort(
            startPort: 8171, endPort: 8191, skipPort: [8181]),
      );

      await testRunDartVM(
        spawner,
        enableVMService: true,
        vmServiceAddress: '0.0.0.0',
        vmServicePort: await DartProject.getFreeListenPort(
            startPort: 8191, endPort: 8171, skipPort: [8181]),
      );

      fileDart.deleteSync();

      expect(
          await spawner.cleanDartPubGetGeneratedFiles(
              confirmProjectName: 'test_project'),
          isTrue);
    });
  });
}

Future<void> testRunDartVM(DartSpawner spawner,
    {bool enableVMService = false,
    String? vmServiceAddress,
    int? vmServicePort,
    bool redirectOutput = true,
    bool catchOutput = true}) async {
  print(
      'Run Dart VM> enableVMService: $enableVMService ; vmServiceAddress: $vmServiceAddress ; vmServicePort: $vmServicePort');

  var processInfo = await spawner.runDartVM(
      'bin/test_project.dart', ['Test Title2', 'English', '22.99'],
      enableVMService: enableVMService,
      vmServiceAddress: vmServiceAddress,
      vmServicePort: vmServicePort,
      redirectOutput: redirectOutput,
      catchOutput: catchOutput,
      handleSignals: true,
      workingDirectory: (await spawner.projectDirectory).path,
      stdoutFilter: (o) => _filterOutputObservatoryListening(o));

  await processInfo.exitCode;

  print(processInfo);

  if (enableVMService) {
    expect(processInfo.binPath.endsWith('dart'), isTrue);

    if (vmServiceAddress != null) {
      vmServicePort ??= 8181;
      expect(processInfo.args[0],
          equals('--enable-vm-service=$vmServicePort/$vmServiceAddress'));
    } else if (vmServicePort != null) {
      expect(processInfo.args[0], equals('--enable-vm-service=$vmServicePort'));
    } else {
      expect(processInfo.args[0], startsWith('--enable-vm-service'));
    }

    expect(processInfo.args[1], equals('run'));
  } else {
    expect(processInfo.binPath.endsWith('dart'), isTrue);
    expect(processInfo.args[0], equals('run'));
  }

  expect(await processInfo.checkExitCode(), isTrue);

  if (catchOutput) {
    var output = _filterOutputObservatoryListening(processInfo.output);
    print('<<$output>>');

    expect(
        processInfo.output, allOf(contains('Test Title2'), contains('22.99')));

    expect(processInfo.errorOutput.trim(), equals('XML Finished: Test Title2'));
  }
}

String _filterOutputObservatoryListening(String s) {
  return s.replaceAll('Observatory listening', '[Observatory listening]');
}
