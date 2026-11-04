@Timeout(Duration(minutes: 1))
library;

import 'dart:async';
import 'dart:isolate';

import 'package:dart_spawner/dart_spawner.dart';
import 'package:test/test.dart';

/// Tests the `spawnedMain` protocol directly, in isolates of the test's own
/// isolate group (`Isolate.spawn`).
///
/// `DartSpawner` uses `Isolate.spawnUri`, which creates a new isolate group,
/// and `dart test --coverage` only collects the test isolate's group: these
/// tests are the ones that make `spawnedMain` visible to coverage.
void main() {
  late ReceivePort parentPort;
  late ReceivePort reportPort;
  late List<Object?> parentMessages;
  late List<Object?> reports;
  Isolate? isolate;

  setUp(() {
    parentPort = ReceivePort();
    reportPort = ReceivePort();
    parentMessages = [];
    reports = [];
    parentPort.listen(parentMessages.add);
    reportPort.listen(reports.add);
  });

  tearDown(() {
    isolate?.kill(priority: Isolate.immediate);
    isolate = null;
    parentPort.close();
    reportPort.close();
  });

  Future<void> spawn(String mode, {String? debugName}) async {
    isolate = await Isolate.spawn(_entry, [
      parentPort.sendPort,
      reportPort.sendPort,
      mode,
    ], debugName: debugName);
  }

  List<String?> statuses() =>
      parentMessages.map((m) => (m as Map)['status'] as String?).toList();

  SendPort startupPort() {
    var ok = parentMessages.first as Map;
    expect(ok['status'], equals('ok'));
    return ok['port'] as SendPort;
  }

  test('sync run without args, no stop callback', () async {
    await spawn('sync-no-args', debugName: 'sync-no-args');
    await _waitFor(() => statuses().contains('stopped'));

    expect(statuses(), equals(['ok', 'stopped']));
    expect(startupPort(), isA<SendPort>());
    expect(reports, equals(['run']));
  });

  test('async run with args and stop callback', () async {
    await spawn('async-args');
    await _waitFor(() => statuses().contains('stopped'));

    expect(statuses(), equals(['ok', 'stopped']));
    // `run` receives the args; `ok` is reported once `run` was called,
    // `stop` runs after the returned Future completes.
    expect(reports, equals(['run:x,y', 'run-done', 'stop']));
  });

  test('stop command while run is pending', () async {
    await spawn('pending');
    await _waitFor(() => parentMessages.isNotEmpty);
    expect(reports, equals(['run']));

    var port = startupPort();
    // Unknown commands are ignored:
    port.send({'cmd': 'other'});
    port.send({'cmd': 'stop'});

    await _waitFor(() => statuses().contains('stopped'));
    expect(statuses(), equals(['ok', 'stopped']));
    expect(reports, equals(['run', 'stop:true']));
  });

  test('run with an unsupported signature is not called', () async {
    await spawn('unsupported-run');
    await _waitFor(() => statuses().contains('stopped'));
    expect(statuses(), equals(['ok', 'stopped']));
    expect(reports, isEmpty);
  });
}

void _entry(List<Object?> message) {
  var parent = message[0] as SendPort;
  var report = message[1] as SendPort;
  var mode = message[2] as String;

  switch (mode) {
    case 'sync-no-args':
      spawnedMain(['a'], parent, 1, () => report.send('run'));
    case 'async-args':
      spawnedMain(
        ['x', 'y'],
        parent,
        2,
        (List<String> a) async {
          report.send('run:${a.join(',')}');
          await Future.delayed(Duration(milliseconds: 50));
          report.send('run-done');
        },
        () {
          report.send('stop');
          return true;
        },
      );
    case 'pending':
      spawnedMain(
        [],
        parent,
        3,
        (List<String> a) {
          report.send('run');
          return Completer<void>().future;
        },
        () async {
          await Future.delayed(Duration(milliseconds: 10));
          report.send('stop:true');
          return true;
        },
      );
    case 'unsupported-run':
      spawnedMain([], parent, 4, (int a, int b) => report.send('run'));
  }
}

Future<void> _waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  var sw = Stopwatch()..start();
  while (!condition()) {
    if (sw.elapsed > timeout) {
      fail('Condition not met within $timeout');
    }
    await Future.delayed(Duration(milliseconds: 10));
  }
}
