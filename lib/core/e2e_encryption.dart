import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:pointycastle/export.dart';

class E2EEncryption {
  final Uint8List _key;

  E2EEncryption(this._key);

  String encrypt(String plaintext) {
    final iv = _randomBytes(12);
    final plaintextBytes = Uint8List.fromList(utf8.encode(plaintext));

    final cipher = GCMBlockCipher(AESEngine())
      ..init(true, AEADParameters(KeyParameter(_key), 128, iv, Uint8List(0)));

    final output = Uint8List(cipher.getOutputSize(plaintextBytes.length));
    var offset = cipher.processBytes(plaintextBytes, 0, plaintextBytes.length, output, 0);
    offset += cipher.doFinal(output, offset);

    // Pack: iv (12) + ciphertext + tag
    final result = Uint8List(12 + offset);
    result.setAll(0, iv);
    result.setRange(12, 12 + offset, output);

    return base64Encode(result);
  }

  String decrypt(String blob) {
    final packed = base64Decode(blob);
    if (packed.length <= 12) return blob;

    final iv = Uint8List.sublistView(packed, 0, 12);
    final ciphertextAndTag = Uint8List.sublistView(packed, 12);

    final cipher = GCMBlockCipher(AESEngine())
      ..init(false, AEADParameters(KeyParameter(_key), 128, iv, Uint8List(0)));

    final output = Uint8List(cipher.getOutputSize(ciphertextAndTag.length));
    var offset = cipher.processBytes(ciphertextAndTag, 0, ciphertextAndTag.length, output, 0);
    offset += cipher.doFinal(output, offset);

    return utf8.decode(output.sublist(0, offset));
  }

  /// Encrypt raw bytes (for audio/media). Returns iv + ciphertext + tag.
  Uint8List encryptBytes(Uint8List data) {
    final iv = _randomBytes(12);
    final cipher = GCMBlockCipher(AESEngine())
      ..init(true, AEADParameters(KeyParameter(_key), 128, iv, Uint8List(0)));

    final output = Uint8List(cipher.getOutputSize(data.length));
    var offset = cipher.processBytes(data, 0, data.length, output, 0);
    offset += cipher.doFinal(output, offset);

    final result = Uint8List(12 + offset);
    result.setAll(0, iv);
    result.setRange(12, 12 + offset, output);
    return result;
  }

  /// Decrypt raw bytes. Input is iv (12) + ciphertext + tag.
  Uint8List decryptBytes(Uint8List packed) {
    final iv = Uint8List.sublistView(packed, 0, 12);
    final ciphertextAndTag = Uint8List.sublistView(packed, 12);

    final cipher = GCMBlockCipher(AESEngine())
      ..init(false, AEADParameters(KeyParameter(_key), 128, iv, Uint8List(0)));

    final output = Uint8List(cipher.getOutputSize(ciphertextAndTag.length));
    var offset = cipher.processBytes(ciphertextAndTag, 0, ciphertextAndTag.length, output, 0);
    offset += cipher.doFinal(output, offset);

    return output.sublist(0, offset);
  }

  static Uint8List _randomBytes(int length) {
    final rng = Random.secure();
    return Uint8List.fromList(List<int>.generate(length, (_) => rng.nextInt(256)));
  }
}
