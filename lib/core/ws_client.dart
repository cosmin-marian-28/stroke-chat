import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';

/// WebSocket client for communicating with the StrokeChat server.
/// Handles auth, session lifecycle, DH key exchange relay, and messaging.
class WSClient {
  final String serverUrl;
  final String userId;

  WebSocketChannel? _channel;
  final _messageController = StreamController<Map<String, dynamic>>.broadcast();
  bool _connected = false;

  WSClient({required this.serverUrl, required this.userId});

  bool get isConnected => _connected;

  /// Stream of all incoming server messages.
  Stream<Map<String, dynamic>> get messages => _messageController.stream;

  /// Filtered streams for specific message types.
  Stream<Map<String, dynamic>> on(String type) =>
      messages.where((msg) => msg['type'] == type);

  /// Connect and authenticate.
  Future<void> connect() async {
    try {
      _channel = WebSocketChannel.connect(Uri.parse(serverUrl));
      _connected = true;

      _channel!.stream.listen(
        (data) {
          final msg = jsonDecode(data as String) as Map<String, dynamic>;
          _messageController.add(msg);
        },
        onDone: () {
          _connected = false;
          // Auto-reconnect after 2 seconds
          Future.delayed(const Duration(seconds: 2), () {
            if (!_messageController.isClosed) connect();
          });
        },
        onError: (_) {
          _connected = false;
        },
      );

      // Authenticate
      _send({'type': 'auth', 'userId': userId});
    } catch (e) {
      _connected = false;
      // Retry connection
      Future.delayed(const Duration(seconds: 2), () {
        if (!_messageController.isClosed) connect();
      });
    }
  }

  /// Request to start a new session with another user.
  void startSession(String convoId, String targetUserId) {
    _send({
      'type': 'start_session',
      'convoId': convoId,
      'targetUserId': targetUserId,
    });
  }

  /// Confirm a session request.
  void confirmSession(String convoId, String sessionId) {
    _send({
      'type': 'confirm_session',
      'convoId': convoId,
      'sessionId': sessionId,
    });
  }

  /// Reject a session request.
  void rejectSession(String convoId, String sessionId) {
    _send({
      'type': 'reject_session',
      'convoId': convoId,
      'sessionId': sessionId,
    });
  }

  /// Send our DH public key to the other party (relayed by server).
  void sendDHPublicKey(String convoId, String sessionId, String publicKey) {
    _send({
      'type': 'dh_exchange',
      'convoId': convoId,
      'sessionId': sessionId,
      'publicKey': publicKey,
    });
  }

  /// Send an encoded stroke message.
  void sendMessage(String convoId, String sessionId, String strokePayload) {
    _send({
      'type': 'message',
      'convoId': convoId,
      'sessionId': sessionId,
      'payload': strokePayload,
    });
  }

  /// End the current session.
  void endSession(String convoId, String sessionId) {
    _send({
      'type': 'end_session',
      'convoId': convoId,
      'sessionId': sessionId,
    });
  }

  void _send(Map<String, dynamic> msg) {
    if (_channel != null && _connected) {
      _channel!.sink.add(jsonEncode(msg));
    }
  }

  Future<void> disconnect() async {
    _connected = false;
    await _channel?.sink.close();
    await _messageController.close();
  }
}
