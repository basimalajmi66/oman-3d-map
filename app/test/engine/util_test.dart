import 'package:test/test.dart';
import 'package:uata_app/engine/util.dart';

void main() {
  test('roundTo behaves like Python round()', () {
    expect(roundTo(0.75 + 0.3 * 0.545, 3), 0.913); // 0.91349999… exact value
    expect(roundTo(0.125, 2), 0.12); // exact tie → even
    expect(roundTo(0.375, 2), 0.38);
    expect(roundTo(2.5, 0), 2.0);
    expect(roundTo(3.5, 0), 4.0);
    expect(roundTo(-0.125, 2), -0.12);
    expect(roundTo(1.0049999, 2), 1.0);
    expect(roundTo(42123.456789, 1), 42123.5);
  });
}
