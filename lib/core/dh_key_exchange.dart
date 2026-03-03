import 'dart:math';
import 'dart:typed_data';
import 'package:pointycastle/export.dart';

/// Diffie-Hellman key exchange using Elliptic Curve (X25519-like via pointycastle).
/// Each side generates a keypair, exchanges public keys, and derives
/// the same shared secret independently. The server relays the public
/// keys but cannot derive the secret.
class DHKeyExchange {
  late AsymmetricKeyPair<PublicKey, PrivateKey> _keyPair;
  Uint8List? _sharedSecret;

  DHKeyExchange() {
    _generateKeyPair();
  }

  void _generateKeyPair() {
    final keyGen = ECKeyGenerator()
      ..init(ParametersWithRandom(
        ECKeyGeneratorParameters(ECCurve_secp256r1()),
        _secureRandom(),
      ));
    _keyPair = keyGen.generateKeyPair();
  }

  /// Get our public key as a base64 string to send to the other party.
  String get publicKeyBase64 {
    final ecPublicKey = _keyPair.publicKey as ECPublicKey;
    final encoded = ecPublicKey.Q!.getEncoded(false);
    return _bytesToBase64(encoded);
  }

  /// Compute the shared secret from the other party's public key.
  Uint8List computeSharedSecret(String otherPublicKeyBase64) {
    final otherBytes = _base64ToBytes(otherPublicKeyBase64);
    final curve = ECCurve_secp256r1();
    final otherPoint = curve.curve.decodePoint(otherBytes);
    final otherPublicKey = ECPublicKey(otherPoint, curve);

    final agreement = ECDHBasicAgreement()
      ..init(_keyPair.privateKey as ECPrivateKey);

    final secret = agreement.calculateAgreement(otherPublicKey);
    final secretBytes = _bigIntToBytes(secret);

    // Hash the raw secret to get a uniform 32-byte key
    final digest = SHA256Digest();
    _sharedSecret = Uint8List(digest.digestSize);
    digest.update(secretBytes, 0, secretBytes.length);
    digest.doFinal(_sharedSecret!, 0);

    return _sharedSecret!;
  }

  Uint8List? get sharedSecret => _sharedSecret;

  // --- Helpers ---

  static SecureRandom _secureRandom() {
    final secureRandom = FortunaRandom();
    final random = Random.secure();
    final seeds = List<int>.generate(32, (_) => random.nextInt(256));
    secureRandom.seed(KeyParameter(Uint8List.fromList(seeds)));
    return secureRandom;
  }

  static String _bytesToBase64(Uint8List bytes) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    final buffer = StringBuffer();
    for (var i = 0; i < bytes.length; i += 3) {
      final b0 = bytes[i];
      final b1 = i + 1 < bytes.length ? bytes[i + 1] : 0;
      final b2 = i + 2 < bytes.length ? bytes[i + 2] : 0;
      buffer.write(chars[(b0 >> 2) & 0x3F]);
      buffer.write(chars[((b0 << 4) | (b1 >> 4)) & 0x3F]);
      buffer.write(i + 1 < bytes.length ? chars[((b1 << 2) | (b2 >> 6)) & 0x3F] : '=');
      buffer.write(i + 2 < bytes.length ? chars[b2 & 0x3F] : '=');
    }
    return buffer.toString();
  }

  static Uint8List _base64ToBytes(String base64) {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    final bytes = <int>[];
    for (var i = 0; i < base64.length; i += 4) {
      final c0 = chars.indexOf(base64[i]);
      final c1 = chars.indexOf(base64[i + 1]);
      final c2 = base64[i + 2] == '=' ? 0 : chars.indexOf(base64[i + 2]);
      final c3 = base64[i + 3] == '=' ? 0 : chars.indexOf(base64[i + 3]);
      bytes.add((c0 << 2) | (c1 >> 4));
      if (base64[i + 2] != '=') bytes.add(((c1 << 4) | (c2 >> 2)) & 0xFF);
      if (base64[i + 3] != '=') bytes.add(((c2 << 6) | c3) & 0xFF);
    }
    return Uint8List.fromList(bytes);
  }

  static Uint8List _bigIntToBytes(BigInt number) {
    final hex = number.toRadixString(16).padLeft(64, '0');
    final bytes = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return Uint8List.fromList(bytes);
  }
}
