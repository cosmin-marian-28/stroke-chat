import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Fully local nickname storage — never touches the server.
class LocalNickname {
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  static String _key(String friendUid) => 'nickname_$friendUid';

  static Future<String?> get(String friendUid) async {
    return _storage.read(key: _key(friendUid));
  }

  static Future<void> set(String friendUid, String nickname) async {
    await _storage.write(key: _key(friendUid), value: nickname);
  }

  static Future<void> remove(String friendUid) async {
    await _storage.delete(key: _key(friendUid));
  }
}
