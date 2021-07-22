# dart_spawner

[![pub package](https://img.shields.io/pub/v/dart_spawner.svg?logo=dart&logoColor=00b9fc)](https://pub.dartlang.org/packages/dart_spawner)
[![Null Safety](https://img.shields.io/badge/null-safety-brightgreen)](https://dart.dev/null-safety)
[![CI](https://img.shields.io/github/workflow/status/gmpassos/dart_spawner/Dart%20CI/master?logo=github-actions&logoColor=white)](https://github.com/gmpassos/dart_spawner/actions)
[![GitHub Tag](https://img.shields.io/github/v/tag/gmpassos/dart_spawner?logo=git&logoColor=white)](https://github.com/gmpassos/dart_spawner/releases)
[![New Commits](https://img.shields.io/github/commits-since/gmpassos/dart_spawner/latest?logo=git&logoColor=white)](https://github.com/gmpassos/dart_spawner/network)
[![Last Commits](https://img.shields.io/github/last-commit/gmpassos/dart_spawner?logo=git&logoColor=white)](https://github.com/gmpassos/dart_spawner/commits/master)
[![Pull Requests](https://img.shields.io/github/issues-pr/gmpassos/dart_spawner?logo=github&logoColor=white)](https://github.com/gmpassos/dart_spawner/pulls)
[![Code size](https://img.shields.io/github/languages/code-size/gmpassos/dart_spawner?logo=github&logoColor=white)](https://github.com/gmpassos/dart_spawner)
[![License](https://img.shields.io/github/license/gmpassos/dart_spawner?logo=open-source-initiative&logoColor=green)](https://github.com/gmpassos/dart_spawner/blob/master/LICENSE)

Runs a Dart script/file/project inside a new Isolate of the current process.

## Usage

You can run a Dart script (from a `String`) into a new Isolate:

```dart
import 'package:dart_spawner/dart_spawner.dart';

void main() {

}

```

## Running a Project

You also can run a Dart script/file that exists in another Dart project, pointing the project
directory:

```dart
import 'package:dart_spawner/dart_spawner.dart';

void main() {

}

```

- NOTE: It will use the dependencies of the target project and not the ones used in the initial `Isolate`.

## Features and bugs

Please file feature requests and bugs at the [issue tracker][tracker].

[tracker]: https://github.com/gmpassos/dart_spawner/issues

## Author

Graciliano M. Passos: [gmpassos@GitHub][github].

[github]: https://github.com/gmpassos

## License

Dart free & open-source [license](https://github.com/dart-lang/stagehand/blob/master/LICENSE).
