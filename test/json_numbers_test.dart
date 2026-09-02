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

  test('nestedName tolerates Map String and null without crash', () {
    expect(nestedName({'name': 'طاولة 1'}), 'طاولة 1');
    expect(nestedName('طاولة نصية'), 'طاولة نصية');
    expect(nestedName(null), '—');
    expect(nestedName(['not-a-map']), '—');
    expect(nestedField('string', 'name'), isNull);
    expect(nestedField({'name': 'x'}, 'name'), 'x');
  });

  test('asStringKeyedMap and asMapList never throw on bad payloads', () {
    expect(asStringKeyedMap(null), isEmpty);
    expect(asStringKeyedMap('bad'), isEmpty);
    expect(asMapList(null), isEmpty);
    expect(asMapList('bad'), isEmpty);
    expect(
      asMapList([
        {'a': 1},
        'skip',
      ]),
      hasLength(1),
    );
  });
}
