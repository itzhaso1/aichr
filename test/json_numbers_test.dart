import 'package:flutter_test/flutter_test.dart';
import 'package:hasim_cashier/core/util/json_numbers.dart';

void main() {
  test('asInt accepts int num and numeric strings', () {
    expect(asInt(12), 12);
    expect(asInt(12.9), 12);
    expect(asInt('15'), 15);
    expect(asInt('15.7'), 15);
    expect(asInt(null), isNull);
    expect(asInt(''), isNull);
    expect(asInt('uuid-local'), isNull);
  });

  test('asDouble accepts mixed JSON number encodings', () {
    expect(asDouble(3), 3.0);
    expect(asDouble('4.5'), 4.5);
    expect(asDoubleOr('x', 9), 9);
  });
}
