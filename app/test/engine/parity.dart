// Helpers for parity tests: the on-device Dart engine must give the same answers as the
// Python engine on the same input. Runs when UATA_BACKEND_DIR points at backend/.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:test/test.dart';

final backendDir = Platform.environment['UATA_BACKEND_DIR'];
final Object paritySkip = backendDir == null ? 'set UATA_BACKEND_DIR to compare with the Python engine' : false;

Future<dynamic> python(Map<String, dynamic> request) async {
  final p = await Process.start('python3', ['tools/parity_cli.py'], workingDirectory: backendDir);
  p.stdin.write(jsonEncode(request));
  await p.stdin.close();
  final out = await p.stdout.transform(utf8.decoder).join();
  final err = await p.stderr.transform(utf8.decoder).join();
  if (await p.exitCode != 0) throw StateError('python failed: $err');
  return jsonDecode(out);
}

/// Deterministic OHLC series (trending, ranging, volatile) — the same numbers go to both engines.
List<Map<String, double>> series(int seed, {int n = 200, double drift = 0, double vol = 0.0008, double start = 1.1}) {
  var state = seed * 2654435761 % 4294967296;
  double rnd() {
    state = (1664525 * state + 1013904223) % 4294967296;
    return state / 4294967296;
  }

  double gauss() => math.sqrt(-2 * math.log(rnd() + 1e-12)) * math.cos(2 * math.pi * rnd());
  final out = <Map<String, double>>[];
  var p = start;
  for (var i = 0; i < n; i++) {
    final o = p;
    final shock = i % 37 == 36 ? 5.0 : 1.0; // occasional sudden moves
    final c = o + drift + gauss() * vol * shock;
    final h = math.max(o, c) + rnd() * vol;
    final l = math.min(o, c) - rnd() * vol;
    out.add({'open': o, 'high': h, 'low': l, 'close': c});
    p = c;
  }
  return out;
}

/// Deep comparison with a float tolerance; reports the first differing path.
void expectSame(dynamic dart, dynamic py, {String path = r'$', double tol = 1e-6}) {
  if (py is num && dart is num) {
    final d = (dart - py).abs();
    expect(d <= tol * math.max(1.0, py.abs()), isTrue, reason: '$path: dart=$dart python=$py');
    return;
  }
  if (py is Map) {
    expect(dart, isA<Map>(), reason: path);
    expect((dart as Map).keys.toSet(), py.keys.toSet(), reason: '$path keys');
    for (final k in py.keys) {
      expectSame(dart[k], py[k], path: '$path.$k', tol: tol);
    }
    return;
  }
  if (py is List) {
    expect(dart, isA<List>(), reason: path);
    expect((dart as List).length, py.length, reason: '$path length');
    for (var i = 0; i < py.length; i++) {
      expectSame(dart[i], py[i], path: '$path[$i]', tol: tol);
    }
    return;
  }
  expect(dart, py, reason: path);
}
