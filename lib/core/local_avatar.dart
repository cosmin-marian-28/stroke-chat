import 'dart:convert';
import 'dart:typed_data';
import 'package:image_picker/image_picker.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Stores friend avatar images locally on device — never touches any server.
/// On web: stores base64 in secure storage.
/// On mobile: stores base64 in secure storage (small 256px images).
class LocalAvatar {
  static final _picker = ImagePicker();
  static const _storage = FlutterSecureStorage();

  static String _key(String friendUid) => 'avatar_$friendUid';

  /// Returns the avatar bytes if one exists for this friend.
  static Future<Uint8List?> getBytes(String friendUid) async {
    final b64 = await _storage.read(key: _key(friendUid));
    if (b64 == null) return null;
    return base64Decode(b64);
  }

  /// Opens the image picker, saves the selected image locally.
  /// Returns the image bytes, or null if cancelled.
  static Future<Uint8List?> pickAndSave(String friendUid) async {
    final picked = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 256,
      maxHeight: 256,
      imageQuality: 80,
    );
    if (picked == null) return null;

    final bytes = await picked.readAsBytes();
    await _storage.write(key: _key(friendUid), value: base64Encode(bytes));
    return bytes;
  }
}
