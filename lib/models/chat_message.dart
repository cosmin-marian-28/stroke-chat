class ChatMessage {
  final String id;
  final String senderId;
  final String sessionId;
  final String strokePayload; // The encoded stroke text (what's stored/sent)
  final DateTime timestamp;

  ChatMessage({
    required this.id,
    required this.senderId,
    required this.sessionId,
    required this.strokePayload,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'senderId': senderId,
    'sessionId': sessionId,
    'strokePayload': strokePayload,
    'timestamp': timestamp.toIso8601String(),
  };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
    id: json['id'] as String,
    senderId: json['senderId'] as String,
    sessionId: json['sessionId'] as String,
    strokePayload: json['strokePayload'] as String,
    timestamp: DateTime.parse(json['timestamp'] as String),
  );
}
