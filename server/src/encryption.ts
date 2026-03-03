import crypto from 'crypto';

/**
 * Server-side encryption for stored messages.
 * 
 * This encrypts the stroke payloads before writing to DB.
 * The server encryption key is separate from the client-side
 * stroke mapping — this is a second layer. Even if someone
 * gets the DB, they need this key AND the client stroke mapping
 * to read anything.
 * 
 * In production, this key should come from a KMS / env secret.
 */

const ALGORITHM = 'aes-256-gcm';
const IV_LENGTH = 12; // GCM standard
const AUTH_TAG_LENGTH = 16;

// Server-side encryption key — load from env in production
const SERVER_KEY = process.env.ENCRYPTION_KEY
  ? Buffer.from(process.env.ENCRYPTION_KEY, 'hex')
  : crypto.randomBytes(32); // Random per server start if no env key

export function encrypt(plaintext: string): {
  encrypted: string;
  iv: string;
  authTag: string;
} {
  const iv = crypto.randomBytes(IV_LENGTH);
  const cipher = crypto.createCipheriv(ALGORITHM, SERVER_KEY, iv, {
    authTagLength: AUTH_TAG_LENGTH,
  });

  let encrypted = cipher.update(plaintext, 'utf8', 'base64');
  encrypted += cipher.final('base64');
  const authTag = cipher.getAuthTag();

  return {
    encrypted,
    iv: iv.toString('base64'),
    authTag: authTag.toString('base64'),
  };
}

export function decrypt(
  encrypted: string,
  iv: string,
  authTag: string,
): string {
  const decipher = crypto.createDecipheriv(
    ALGORITHM,
    SERVER_KEY,
    Buffer.from(iv, 'base64'),
    { authTagLength: AUTH_TAG_LENGTH },
  );
  decipher.setAuthTag(Buffer.from(authTag, 'base64'));

  let decrypted = decipher.update(encrypted, 'base64', 'utf8');
  decrypted += decipher.final('utf8');
  return decrypted;
}

/**
 * Export the current server key (for logging/debug only).
 * In production, NEVER expose this.
 */
export function getServerKeyHex(): string {
  return SERVER_KEY.toString('hex');
}
