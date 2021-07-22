import 'package:dart_spawner/dart_spawner.dart';

void main() async {
  var spawner = DartSpawner(logToConsole: true);

  var script = r'''
    void main(List<String> args) {
      print('From Script! Args: $args');
    }
  ''';

  print('Spawning Script: <<<\n\n$script\n>>>');

  var file = await spawner.projectSubFile('test/hello-world.dart');

  print('Spawning file: $file');

  var spawned = await spawner.spawnDart(file, ['a', 'b', 'c']);

  print('Spawned: $spawned');

  var exitCode = await spawned.exitCode;
  print('Exit code: $exitCode');
}
