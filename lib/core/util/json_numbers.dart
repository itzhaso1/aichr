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

/// Safe Map coercion — never throws on List/String/null payloads.
Map<String, dynamic> asStringKeyedMap(dynamic raw) {
  if (raw is Map<String, dynamic>) return raw;
  if (raw is Map) return Map<String, dynamic>.from(raw);
  return const {};
}

List<Map<String, dynamic>> asMapList(dynamic raw) {
  if (raw is! List) return const [];
  return raw
      .whereType<Map>()
      .map((e) => Map<String, dynamic>.from(e))
      .toList();
}

/// Read a nested field only when [value] is a Map (avoids String/List crashes).
dynamic nestedField(dynamic value, String key) {
  if (value is Map) return value[key];
  return null;
}

/// Display name from a nested relation that may be Map, String, or null.
String nestedName(dynamic value, {String fallback = '—'}) {
  if (value is Map) {
    final name = value['name'];
    if (name != null && '$name'.trim().isNotEmpty) return '$name'.trim();
  }
  if (value is String && value.trim().isNotEmpty) return value.trim();
  return fallback;
}
