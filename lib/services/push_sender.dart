import 'package:flutter/foundation.dart';
import '../core/supabase_client.dart';

class PushSender {
  PushSender._();
  static final instance = PushSender._();

  Future<void> notify({required String recipientId, String? msgType}) async {
    try {
      final res = await SupaConfig.client.functions.invoke(
        'push',
        body: {
          'recipient_id': recipientId,
          'msg_type': msgType ?? 'text',
        },
      );
      debugPrint('🔔 Push response (${res.status}): ${res.data}');
    } catch (e) {
      debugPrint('🔔 Push invoke error: $e');
    }
  }
}
