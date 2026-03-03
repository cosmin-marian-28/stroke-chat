// --- Protocol Messages ---

// Client → Server
export type ClientMessage =
  | { type: 'auth'; userId: string }
  | { type: 'start_session'; convoId: string; targetUserId: string }
  | { type: 'confirm_session'; convoId: string; sessionId: string }
  | { type: 'reject_session'; convoId: string; sessionId: string }
  | { type: 'dh_exchange'; convoId: string; sessionId: string; publicKey: string }
  | { type: 'message'; convoId: string; sessionId: string; payload: string }
  | { type: 'end_session'; convoId: string; sessionId: string };

// Server → Client
export type ServerMessage =
  | { type: 'auth_ok'; userId: string }
  | { type: 'session_request'; convoId: string; sessionId: string; fromUserId: string }
  | { type: 'session_confirmed'; convoId: string; sessionId: string }
  | { type: 'session_rejected'; convoId: string; sessionId: string }
  | { type: 'dh_exchange'; convoId: string; sessionId: string; publicKey: string }
  | { type: 'message'; convoId: string; sessionId: string; senderId: string; payload: string; timestamp: string; messageId: string }
  | { type: 'session_ended'; convoId: string; sessionId: string; endedBy: string }
  | { type: 'error'; message: string };

// --- Storage Models ---

export interface Session {
  id: string;
  convoId: string;
  participants: [string, string];
  status: 'pending' | 'active' | 'ended';
  createdAt: Date;
  endedAt?: Date;
}

export interface StoredMessage {
  id: string;
  convoId: string;
  sessionId: string;
  senderId: string;
  encryptedPayload: string; // AES-256-GCM encrypted stroke data
  iv: string;              // Initialization vector
  authTag: string;         // GCM auth tag
  timestamp: Date;
}

export interface ConnectedUser {
  userId: string;
  ws: import('ws').WebSocket;
}
