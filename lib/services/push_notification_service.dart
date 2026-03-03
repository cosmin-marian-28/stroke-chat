import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import '../core/supabase_client.dart';

/// Top-level handler for background FCM messages (must be top-level function).
@pragma('vm:entry-point')
Future<void> _firebaseBackgroundHandler(RemoteMessage message) async {
  // Nothing to do — the OS shows the notification automatically.
  debugPrint('🔔 BG message: ${message.messageId}');
}

class PushNotificationService {
  PushNotificationService._();
  static final instance = PushNotificationService._();

  bool _initialized = false;

  Future<void> init() async {
    if (_initialized || kIsWeb) return;
    _initialized = true;

    final messaging = FirebaseMessaging.instance;

    // Request permission (iOS will show the system prompt)
    final settings = await messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    debugPrint('🔔 Push auth: ${settings.authorizationStatus}');

    // Register background handler
    FirebaseMessaging.onBackgroundMessage(_firebaseBackgroundHandler);

    // Get APNs token first (iOS requirement)
    final apnsToken = await messaging.getAPNSToken();
    debugPrint('🔔 APNs token: ${apnsToken != null ? "OK" : "null"}');

    // Get FCM token and store it
    final token = await messaging.getToken();
    debugPrint('🔔 FCM token: ${token?.substring(0, 20)}...');
    if (token != null) await _saveToken(token);

    // Listen for token refresh
    messaging.onTokenRefresh.listen(_saveToken);

    // Foreground messages — just log, no UI needed
    FirebaseMessaging.onMessage.listen((message) {
      debugPrint('🔔 FG message: ${message.notification?.title}');
    });
  }

  Future<void> _saveToken(String token) async {
    try {
      final uid = SupaConfig.client.auth.currentUser?.id;
      if (uid == null) return;

      await SupaConfig.client.from('device_tokens').upsert({
        'user_id': uid,
        'token': token,
        'platform': defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android',
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'user_id,token');

      debugPrint('🔔 Token saved to Supabase');
    } catch (e) {
      debugPrint('🔔 Token save error: $e');
    }
  }
}
