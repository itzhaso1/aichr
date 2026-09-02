import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'pin_hasher.dart';

/// AES-256-GCM envelope for on-disk POS backups.
class BackupCrypto {
  const BackupCrypto();

  static const cipherName = 'aes-256-gcm';
  static const kdfName = 'pbkdf2-hmac-sha256';
  static const kdfIterations = 100000;
  static const keyLength = 32;
  static const nonceLength = 12;

  Future<({String saltB64, String nonceB64, String ciphertextB64})> encrypt({
    required String plaintext,
    required String password,
  }) async {
    final salt = _randomBytes(16);
    final nonce = _randomBytes(nonceLength);
    final key = _key(password, salt);
    final box = await AesGcm.with256bits().encrypt(
      utf8.encode(plaintext),
      secretKey: SecretKey(key),
      nonce: nonce,
    );
    final packed = Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
    return (
      saltB64: base64Encode(salt),
      nonceB64: base64Encode(nonce),
      ciphertextB64: base64Encode(packed),
    );
  }

  Future<String> decrypt({
    required String password,
    required String saltB64,
    required String nonceB64,
    required String ciphertextB64,
  }) async {
    late final Uint8List salt;
    late final Uint8List nonce;
    late final Uint8List packed;
    try {
      salt = Uint8List.fromList(base64Decode(saltB64));
      nonce = Uint8List.fromList(base64Decode(nonceB64));
      packed = Uint8List.fromList(base64Decode(ciphertextB64));
    } catch (_) {
      throw const FormatException('تالف');
    }
    if (packed.length < 16) {
      throw const FormatException('تالف');
    }
    final cipherText = packed.sublist(0, packed.length - 16);
    final mac = Mac(packed.sublist(packed.length - 16));
    final key = _key(password, salt);
    try {
      final clear = await AesGcm.with256bits().decrypt(
        SecretBox(cipherText, nonce: nonce, mac: mac),
        secretKey: SecretKey(key),
      );
      return utf8.decode(clear);
    } catch (_) {
      throw const FormatException('مفتاح');
    }
  }

  Uint8List _key(String password, List<int> salt) {
    return PinHasher.pbkdf2HmacSha256(
      password: utf8.encode(password),
      salt: salt,
      iterations: kdfIterations,
      keyLength: keyLength,
    );
  }

  Uint8List _randomBytes(int length) {
    final rand = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => rand.nextInt(256)),
    );
  }
}
