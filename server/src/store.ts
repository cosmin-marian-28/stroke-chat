import { Session, StoredMessage } from './types';

/**
 * In-memory store. Swap for Postgres/SQLite in production.
 * The server only ever stores encrypted stroke gibberish.
 */
class Store {
  private sessions = new Map<string, Session>();
  private messages: StoredMessage[] = [];

  // --- Sessions ---

  createSession(session: Session): void {
    this.sessions.set(session.id, session);
  }

  getSession(sessionId: string): Session | undefined {
    return this.sessions.get(sessionId);
  }

  updateSessionStatus(sessionId: string, status: Session['status']): void {
    const session = this.sessions.get(sessionId);
    if (session) {
      session.status = status;
      if (status === 'ended') session.endedAt = new Date();
    }
  }

  getActiveSession(convoId: string): Session | undefined {
    for (const session of this.sessions.values()) {
      if (session.convoId === convoId && session.status === 'active') {
        return session;
      }
    }
    return undefined;
  }

  // --- Messages ---

  storeMessage(message: StoredMessage): void {
    this.messages.push(message);
  }

  getMessages(convoId: string, sessionId?: string): StoredMessage[] {
    return this.messages.filter(
      (m) => m.convoId === convoId && (!sessionId || m.sessionId === sessionId),
    );
  }
}

export const store = new Store();
