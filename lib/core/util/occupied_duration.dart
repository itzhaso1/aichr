/// Live occupancy clock for dining tables (`HH:MM:SS`).
DateTime? parseOpenedAt(dynamic raw) {
  if (raw == null) return null;
  if (raw is DateTime) return raw;
  final text = raw.toString().trim();
  if (text.isEmpty) return null;
  return DateTime.tryParse(text);
}

String formatOccupiedDuration(DateTime openedAt, DateTime now) {
  var delta = now.difference(openedAt);
  if (delta.isNegative) delta = Duration.zero;
  final hours = delta.inHours.toString().padLeft(2, '0');
  final minutes = (delta.inMinutes % 60).toString().padLeft(2, '0');
  final seconds = (delta.inSeconds % 60).toString().padLeft(2, '0');
  return '$hours:$minutes:$seconds';
}
