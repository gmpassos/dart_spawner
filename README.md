# dart_spawner

[![pub package](https://img.shields.io/pub/v/dart_spawner.svg?logo=dart&logoColor=00b9fc)](https://pub.dartlang.org/packages/dart_spawner)
[![Null Safety](https://img.shields.io/badge/null-safety-brightgreen)](https://dart.dev/null-safety)
[![codecov](https://codecov.io/gh/gmpassos/dart_spawner/branch/master/graph/badge.svg?token=GOHOemF0cr)](https://codecov.io/gh/gmpassos/dart_spawner)
[![CI](https://img.shields.io/github/workflow/status/gmpassos/dart_spawner/Dart%20CI/master?logo=github-actions&logoColor=white)](https://github.com/gmpassos/dart_spawner/actions)
[![GitHub Tag](https://img.shields.io/github/v/tag/gmpassos/dart_spawner?logo=git&logoColor=white)](https://github.com/gmpassos/dart_spawner/releases)
[![New Commits](https://img.shields.io/github/commits-since/gmpassos/dart_spawner/latest?logo=git&logoColor=white)](https://github.com/gmpassos/dart_spawner/network)
[![Last Commits](https://img.shields.io/github/last-commit/gmpassos/dart_spawner?logo=git&logoColor=white)](https://github.com/gmpassos/dart_spawner/commits/master)
[![Pull Requests](https://img.shields.io/github/issues-pr/gmpassos/dart_spawner?logo=github&logoColor=white)](https://github.com/gmpassos/dart_spawner/pulls)
[![Code size](https://img.shields.io/github/languages/code-size/gmpassos/dart_spawner?logo=github&logoColor=white)](https://github.com/gmpassos/dart_spawner)
[![License](https://img.shields.io/github/license/gmpassos/dart_spawner?logo=open-source-initiative&logoColor=green)](https://github.com/gmpassos/dart_spawner/blob/master/LICENSE)

Runs a Dart script/File/Uri inside a new Isolate of the current Dart VM.
It also can spawn a Dart File from another Dart project/package into the current Dart VM.

## Usage

You can run a Dart script (from a `String`) into a new Isolate:

```dart
import 'package:dart_spawner/dart_spawner.dart';

void main() async {
  var spawner = DartSpawner();
  print(spawner);

  var script = r'''
    void main(List<String> args) {
      print('>> From Script! Args: $args');
    }
  ''';

  var spawned = await spawner.spawnDart(script, ['a', 'b', 'c']);
  print('Spawned: $spawned');

  var exitCode = await spawned.exitCode;
  print('Exit code: $exitCode');
}
```

Output:

```text
DartSpawner{ id: 1, spawned: false, finished: false }
>> From Script! Args: [a, b, c]
Spawned: SpawnedIsolate{ id: 1, type: <script>, finished: false, projectDirectory: Directory: '/path/to/current/dart_project' }
Exit code: 0
```

## Spawning a Dart file inside the current Dart project:

To run a Dart File inside the current Dart project (used in the main Dart entry point).

```dart
import 'package:dart_spawner/dart_spawner.dart';

void main() async {
  var spawner = DartSpawner();
  print(spawner);

  var file = await spawner.projectSubFile('test/hello-world.dart');
  print('Spawning file: $file');

  var spawned = await spawner.spawnDart(file, ['x', 'y']);
  print('Spawned: $spawned');

  var exitCode = await spawned.exitCode;
  print('Exit code: $exitCode');
}

```

## Spawning a Dart file in ANOTHER Dart project:

You can also run a Dart script/file that exists in another Dart project/package,
passing the project directory to the `DartSpawner` constructor:

```dart
import 'dart:io';

import 'package:dart_spawner/dart_spawner.dart';

void main() async {
  var spawner = DartSpawner(
    directory: Directory('/path/to/another/dart_project/'),
  );

  print(spawner);

  var file = await spawner.projectSubFile('example/project_example.dart');
  print('Spawning file: $file');

  var spawned = await spawner.spawnDart(file, ['some', 'args']);
  print('Spawned: $spawned');

  var exitCode = await spawned.exitCode;
  print('Exit code: $exitCode');
}
```

- NOTE: It will use the dependencies of the target project and not the ones used in the current `Isolate`.

## Dart VM

Note that `DartSpawner` uses [Isolate.spawnUri][isolate_spawnUri]
to run a Dart Entry Point (script/file/Uri). This is not supported outside the Dart VM
or in a compiled dart file (`dart compile exe foo.dart`)!

[isolate_spawnUri]: https://api.dart.dev/stable/2.13.4/dart-isolate/Isolate/spawnUri.html

## Features and bugs

Please file feature requests and bugs at the [issue tracker][tracker].

[tracker]: https://github.com/gmpassos/dart_spawner/issues

## Author

Graciliano M. Passos: [gmpassos@GitHub][github].

[github]: https://github.com/gmpassos

## License

Dart free & open-source [license](https://github.com/dart-lang/stagehand/blob/master/LICENSE).
