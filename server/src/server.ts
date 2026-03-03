import { WebSocketServer, WebSocket } from 'ws';
import { v4 as uuid } from 'uuid';
import { ClientMessage, ServerMessage, ConnectedUser } from './types';
import { encrypt } from './encryption';
import { store } from './store';

const PORT = Number(process.env.PORT) || 8080;

const wss = new WebSocketServer({ port: PORT });
const users = new Map<string, ConnectedUser>(); // userId → connection

console.log(`🔒 StrokeChat server running on ws://localhost:${PORT}`);

wss.on('connection', (ws: WebSocket) => {
  let currentUserId: string | null = null;

  ws.on('message', (raw: Buffer) => {
    let msg: ClientMessage;
    try {
      msg = JSON.parse(raw.toString()) as ClientMessage;
    } catch {
      send(ws, { type: 'error', message: 'Invalid JSON' });
      return;
    }

    switch (msg.type) {
      case 'auth':
        handleAuth(ws, msg.userId);
        currentUserId = msg.userId;
        break;
      case 'start_session':
        if (!currentUserId) return sendAuthError(ws);
        handleStartSession(currentUserId, msg.convoId, msg.targetUserId);
        break;
      case 'confirm_session':
        if (!currentUserId) return sendAuthError(ws);
        handleConfirmSession(currentUserId, msg.convoId, msg.sessionId);
        break;
      case 'reject_session':
        if (!currentUserId) return sendAuthError(ws);
        handleRejectSession(currentUserId, msg.convoId, msg.sessionId);
        break;
      case 'dh_exchange':
        if (!currentUserId) return sendAuthError(ws);
        handleDHExchange(currentUserId, msg.convoId, msg.sessionId, msg.publicKey);
        break;
      case 'message':
        if (!currentUserId) return sendAuthError(ws);
        handleMessage(currentUserId, msg.convoId, msg.sessionId, msg.payload);
        break;
      case 'end_session':
        if (!currentUserId) return sendAuthError(ws);
        handleEndSession(currentUserId, msg.convoId, msg.sessionId);
        break;
    }
  });

  ws.on('close', () => {
    if (currentUserId) {
      users.delete(currentUserId);
      console.log(`← ${currentUserId} disconnected`);
    }
  });
});

// --- Handlers ---

function handleAuth(ws: WebSocket, userId: string) {
  users.set(userId, { userId, ws });
  send(ws, { type: 'auth_ok', userId });
  console.log(`→ ${userId} connected`);
}

function handleStartSession(
  fromUserId: string,
  convoId: string,
  targetUserId: string,
) {
  // Check if there's already an active session
  const existing = store.getActiveSession(convoId);
  if (existing) {
    sendToUser(fromUserId, {
      type: 'error',
      message: 'Session already active for this conversation',
    });
    return;
  }

  const sessionId = uuid();
  store.createSession({
    id: sessionId,
    convoId,
    participants: [fromUserId, targetUserId],
    status: 'pending',
    createdAt: new Date(),
  });

  // Notify the target user
  sendToUser(targetUserId, {
    type: 'session_request',
    convoId,
    sessionId,
    fromUserId,
  });

  console.log(`📨 ${fromUserId} → session request → ${targetUserId} (${sessionId.slice(0, 8)})`);
}

function handleConfirmSession(
  userId: string,
  convoId: string,
  sessionId: string,
) {
  const session = store.getSession(sessionId);
  if (!session || session.convoId !== convoId) {
    sendToUser(userId, { type: 'error', message: 'Session not found' });
    return;
  }

  store.updateSessionStatus(sessionId, 'active');

  // Notify both participants
  for (const participantId of session.participants) {
    sendToUser(participantId, {
      type: 'session_confirmed',
      convoId,
      sessionId,
    });
  }

  console.log(`✅ Session ${sessionId.slice(0, 8)} confirmed by ${userId}`);
}

function handleRejectSession(
  userId: string,
  convoId: string,
  sessionId: string,
) {
  const session = store.getSession(sessionId);
  if (!session) return;

  store.updateSessionStatus(sessionId, 'ended');

  for (const participantId of session.participants) {
    sendToUser(participantId, {
      type: 'session_rejected',
      convoId,
      sessionId,
    });
  }

  console.log(`❌ Session ${sessionId.slice(0, 8)} rejected by ${userId}`);
}

function handleDHExchange(
  fromUserId: string,
  convoId: string,
  sessionId: string,
  publicKey: string,
) {
  const session = store.getSession(sessionId);
  if (!session) return;

  // Relay the DH public key to the other participant.
  // The server sees the public values but CANNOT derive the shared secret.
  const otherUserId = session.participants.find((id) => id !== fromUserId);
  if (!otherUserId) return;

  sendToUser(otherUserId, {
    type: 'dh_exchange',
    convoId,
    sessionId,
    publicKey,
  });

  console.log(`🔑 DH relay ${fromUserId} → ${otherUserId} (${sessionId.slice(0, 8)})`);
}

function handleMessage(
  senderId: string,
  convoId: string,
  sessionId: string,
  payload: string, // Already stroke-encoded by the client
) {
  const session = store.getSession(sessionId);
  if (!session || session.status !== 'active') {
    sendToUser(senderId, { type: 'error', message: 'No active session' });
    return;
  }

  const messageId = uuid();
  const timestamp = new Date();

  // Encrypt the stroke payload before storing.
  // The payload is ALREADY stroke gibberish from the client.
  // This encryption is a second layer — even the stroke gibberish
  // is encrypted at rest in the DB.
  const { encrypted, iv, authTag } = encrypt(payload);

  store.storeMessage({
    id: messageId,
    convoId,
    sessionId,
    senderId,
    encryptedPayload: encrypted,
    iv,
    authTag,
    timestamp,
  });

  // Forward the ORIGINAL stroke payload to the other user (not the server-encrypted version).
  // The wire is already protected by WSS/TLS. The server encryption is only for at-rest storage.
  const otherUserId = session.participants.find((id) => id !== senderId);
  if (otherUserId) {
    sendToUser(otherUserId, {
      type: 'message',
      convoId,
      sessionId,
      senderId,
      payload,
      timestamp: timestamp.toISOString(),
      messageId,
    });
  }

  // Echo back to sender as confirmation
  sendToUser(senderId, {
    type: 'message',
    convoId,
    sessionId,
    senderId,
    payload,
    timestamp: timestamp.toISOString(),
    messageId,
  });

  console.log(`💬 ${senderId} → msg (${sessionId.slice(0, 8)}) [${payload.length} stroke chars]`);
}

function handleEndSession(
  userId: string,
  convoId: string,
  sessionId: string,
) {
  const session = store.getSession(sessionId);
  if (!session) return;

  store.updateSessionStatus(sessionId, 'ended');

  // Notify both participants
  for (const participantId of session.participants) {
    sendToUser(participantId, {
      type: 'session_ended',
      convoId,
      sessionId,
      endedBy: userId,
    });
  }

  console.log(`🔚 Session ${sessionId.slice(0, 8)} ended by ${userId}`);
}

// --- Helpers ---

function send(ws: WebSocket, msg: ServerMessage) {
  if (ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify(msg));
  }
}

function sendToUser(userId: string, msg: ServerMessage) {
  const user = users.get(userId);
  if (user) send(user.ws, msg);
}

function sendAuthError(ws: WebSocket) {
  send(ws, { type: 'error', message: 'Not authenticated' });
}
