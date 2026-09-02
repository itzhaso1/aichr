/// Safe coercion for JSON / SQLite / API mixed numeric fields.
/// Avoids `type 'String' is not a subtype of type 'num?'` crashes.
library;

int? asInt(dynamic value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    return int.tryParse(trimmed) ?? double.tryParse(trimmed)?.toInt();
  }
  return null;
}

double? asDouble(dynamic value) {
  if (value == null) return null;
  if (value is double) return value;
  if (value is num) return value.toDouble();
  if (value is String) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    return double.tryParse(trimmed);
  }
  return null;
}

int asIntOr(dynamic value, [int fallback = 0]) => asInt(value) ?? fallback;

double asDoubleOr(dynamic value, [double fallback = 0]) =>
    asDouble(value) ?? fallback;
