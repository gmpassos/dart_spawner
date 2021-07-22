import 'package:dart_spawner/dart_spawner.dart';

void main() async {
  var spawner = DartSpawner(logToConsole: true);

  var script = r'''
    void main(List<String> args) {
      print('From Script! Args: $args');
    }
  ''';

  print('Spawning Script: <<<\n\n$script\n>>>');

  var spawned = await spawner.spawnDart(script, ['a', 'b', 'c']);

  print('Spawned: $spawned');

  var exitCode = await spawned.exitCode;
  print('Exit code: $exitCode');
}
