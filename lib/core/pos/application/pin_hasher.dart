import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// PIN KDF: PBKDF2-HMAC-SHA256 with a per-user salt.
///
/// Stored hash format: `pbkdf2-sha256$<iterations>$<b64-dk>`
/// Legacy SHA-256 hex (64 chars) is still verified, then upgraded on login.
class PinHasher {
  const PinHasher._();

  static const algorithm = 'pbkdf2-sha256';
  static const iterations = 100000;
  static const keyLength = 32;

  static final _legacySha256 = RegExp(r'^[a-f0-9]{64}$');

  static String newSalt() {
    final rand = Random.secure();
    final bytes = List<int>.generate(16, (_) => rand.nextInt(256));
    return base64Encode(bytes);
  }

  static String hash(String pin, String salt, {int iterations = iterations}) {
    final dk = pbkdf2HmacSha256(
      password: utf8.encode(pin.trim()),
      salt: base64Decode(salt),
      iterations: iterations,
      keyLength: keyLength,
    );
    return '$algorithm\$$iterations\$${base64Encode(dk)}';
  }

  static bool isLegacySha256(String stored) => _legacySha256.hasMatch(stored);

  static bool verifyLegacy(String pin, String salt, String stored) {
    final digest = sha256.convert(utf8.encode('$salt:${pin.trim()}')).toString();
    return _constantTimeEquals(utf8.encode(digest), utf8.encode(stored));
  }

  static bool verify(String pin, String salt, String stored) {
    if (isLegacySha256(stored)) {
      return verifyLegacy(pin, salt, stored);
    }
    final parts = stored.split(r'$');
    if (parts.length != 3 || parts[0] != algorithm) return false;
    final iter = int.tryParse(parts[1]) ?? 0;
    if (iter < 1 || iter > 5 * 1000 * 1000) return false;
    final expected = hash(pin, salt, iterations: iter);
    return _constantTimeEquals(utf8.encode(expected), utf8.encode(stored));
  }

  static Uint8List pbkdf2HmacSha256({
    required List<int> password,
    required List<int> salt,
    required int iterations,
    required int keyLength,
  }) {
    const hLen = 32;
    final blockCount = (keyLength / hLen).ceil();
    final out = BytesBuilder(copy: false);
    for (var block = 1; block <= blockCount; block++) {
      final blockSalt = Uint8List(salt.length + 4);
      blockSalt.setAll(0, salt);
      blockSalt[salt.length] = (block >> 24) & 0xff;
      blockSalt[salt.length + 1] = (block >> 16) & 0xff;
      blockSalt[salt.length + 2] = (block >> 8) & 0xff;
      blockSalt[salt.length + 3] = block & 0xff;
      var u = Hmac(sha256, password).convert(blockSalt).bytes;
      final t = Uint8List.fromList(u);
      for (var i = 1; i < iterations; i++) {
        u = Hmac(sha256, password).convert(u).bytes;
        for (var j = 0; j < t.length; j++) {
          t[j] ^= u[j];
        }
      }
      out.add(t);
    }
    return Uint8List.fromList(out.toBytes().sublist(0, keyLength));
  }

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}
