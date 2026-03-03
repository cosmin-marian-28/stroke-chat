# StrokeChat — End-to-End Encrypted Messaging App

## Summary
A privacy-first real-time messaging app built with Flutter in 3 days as a proof-of-concept MVP — the goal was to validate whether a dual-layer encryption system with anti-forensic rendering was feasible in a mobile chat context. It is. The first layer is standard AES-256-GCM end-to-end encryption. The second layer is a proprietary visual cipher called "Stroke Encoding" — a session-rotatable character mapping that transforms plaintext into Unicode stroke symbols, specifically engineered to defeat RAM-scraping malware and keylogging trojans. All cryptographic key material is stored exclusively in iOS Keychain / Android Keystore, never in app memory longer than necessary.

## Tech Stack
- Flutter 3.11+ (Dart), Material 3, fully custom widget library
- Supabase (PostgreSQL, Realtime Broadcast, Storage, Auth, Edge Functions)
- PointyCastle (AES-256-GCM, ECDH secp256r1, SHA-256, HMAC)
- Firebase Cloud Messaging (iOS APNs + Android FCM)
- FFmpeg Kit (video encoding, frame extraction, audio transcoding)
- Apple Vision API via MethodChannel (background removal, iOS only)

---

## Security Architecture

### Threat Model
The app is designed to protect message content against three attack vectors:
1. Server compromise — the server never sees plaintext or shared secrets
2. RAM scraping / memory forensics — decoded text exists only as a local variable inside a CustomPainter's `paint()` method, never stored as a widget field or class property
3. Keylogging trojans — the app uses a fully custom keyboard (not the OS keyboard), so system-level keyloggers cannot intercept input

### Dual-Layer Encryption Flow

**Layer 1 — AES-256-GCM End-to-End Encryption:**
- Each message payload is encrypted with AES-256-GCM before leaving the device
- 12-byte random IV per message, 128-bit authentication tag
- The encryption key is derived from a shared secret via SHA-256
- Encrypted blob is stored in Supabase — the server only ever sees ciphertext

**Layer 2 — Stroke Encoding (Visual Cipher):**
- Each plaintext character maps to a unique combination of 4 Unicode stroke symbols drawn from a pool of 880+ glyphs (ranges: U+27C0–U+27EF, U+2900–U+297F, U+2980–U+29FF, U+2B00–U+2B73, U+2190–U+21FF, U+25A0–U+25FF, U+2300–U+23FF)
- The mapping is deterministic per session: the stroke pool is shuffled using a seeded PRNG, where the seed is derived from `HMAC-SHA256(sharedSecret, sessionId)`
- Both devices independently compute the same mapping from the same shared secret — no mapping data is ever transmitted
- Emojis bypass encoding and pass through unchanged

### Key Exchange
- Elliptic Curve Diffie-Hellman (ECDH) on secp256r1
- Each device generates an ephemeral EC keypair, exchanges public keys via server relay
- The server relays public keys but cannot derive the shared secret
- Shared secret is hashed with SHA-256 to produce a uniform 32-byte symmetric key

### Session Key Rotation (Vanish Mode)
- Users can rotate the encryption key mid-conversation by pulling up on the chat screen (similar to Instagram's vanish mode gesture)
- This increments the session version, derives a new shared secret via `SHA-256(convoId + "_v" + version)`, and generates a completely new stroke mapping
- Old messages remain decryptable — each message stores its session version (`v`), and old mappings are retained in secure storage
- A visual indicator appears in the chat when the key changes
- The pull-up gesture is tracked via pointer events with a threshold, and resets with a spring animation if not triggered

### Secure Storage
- All session mappings, active session IDs, and key material are stored in iOS Keychain (`KeychainAccessibility.first_unlock`) and Android Keystore (`encryptedSharedPreferences: true`) via `flutter_secure_storage`
- Mappings are indexed by `convoId + sessionId` — multiple historical sessions coexist so old messages can still be decoded
- Active session pointer is stored separately and cleared on session end
- Friend avatars and nicknames are also stored locally in secure storage — never uploaded to any server

### Anti-Forensics in the Rendering Pipeline
- The `StrokeText` widget decodes stroke-encoded text inside the `paint()` method of a `CustomPainter`
- The decode table is built as a local variable, used to render, and immediately goes out of scope — it is never stored as a class field, instance variable, or in any persistent data structure
- This means a memory dump of the app process will find only the encoded stroke symbols, not the plaintext or the decode table
- The `_decodePaintOnly()` function duplicates the stroke pool and shuffle logic locally rather than importing `StrokeMapping`, specifically to avoid holding a reference to the mapping object in the widget tree

---

## Real-Time Messaging System

### Message Flow
1. User types on the custom keyboard → each keystroke is immediately stroke-encoded via `SessionManager.encodeChar()` and appended to the stroke text buffer
2. On send, the stroke-encoded payload is encrypted with AES-256-GCM → the encrypted blob is inserted into Supabase `messages` table
3. Supabase Realtime Broadcast notifies the recipient's channel → recipient fetches the new message
4. Recipient decrypts the AES blob → passes the stroke text + session secret to `StrokeText` widget → decoded only at paint time

### Realtime Architecture
- Three Supabase Realtime channels per conversation:
  - `convo:{id}` — message INSERT broadcasts
  - `convo_meta:{id}` — conversation metadata updates (background, theme)
  - `stickers:{id}` — placed sticker INSERT/DELETE events
- Optimistic UI: messages appear instantly with upload progress, pending uploads tracked by temp ID and reconciled when the real message arrives
- Seen/read receipts: messages are marked with `seen_at` timestamp when the recipient opens the conversation, with 5-second polling for status updates

### Push Notifications
- Firebase Cloud Messaging with APNs (iOS) and FCM (Android)
- Device tokens stored in Supabase `device_tokens` table, keyed by `user_id + token`
- Push delivery via Supabase Edge Function (`push`) invoked after each message insert
- Background message handler registered at app level (`@pragma('vm:entry-point')`)
- Token refresh listener for automatic re-registration

---

## Custom Keyboard

Built from scratch — the app never uses the native OS keyboard, which is a deliberate security decision to prevent system-level keyloggers from capturing input.

### Implementation
- Full iOS dark-mode keyboard replica with QWERTY, number, and symbol layers
- Zero-delay key response using raw `Listener` widget (pointer events) instead of `GestureDetector`
- Magnified preview bubble on key press — custom `OverlayEntry` with a `CustomPainter` that draws the iOS-style balloon shape (rounded rect + neck + key body as a single path)
- Long-press accent variant bar: holding a key like "a" shows [ă, â, à, á, ä, æ, ã, å, ā] in a horizontal bar above the key, with drag-to-select and haptic feedback on each selection change
- Spacebar trackpad mode: hold spacebar for 300ms, then drag horizontally to move the cursor (16px per step, with haptic ticks)
- Accelerating backspace: 150ms initial delay, then repeat interval decreases from 80ms down to 30ms the longer you hold
- Shift, caps lock (double-tap shift), number layer (123), symbol layer (#+=)

### Cursor & Selection
- Full cursor positioning with character-level precision
- Text selection via long-press + drag on the input area
- Word-boundary double-tap selection
- Hit-testing uses `ui.ParagraphBuilder` to map touch coordinates to character indices
- Stroke-text cursor offset calculation accounts for variable-width characters (emojis = raw rune count, encoded chars = 4 stroke runes each)

---

## Collaborative Drawing Board

Real-time shared canvas synced between two users via Supabase Realtime Broadcast.

- Multi-page support with animated slide transitions between pages
- Three brush types: round (StrokeCap.round), flat (StrokeCap.butt), soft (MaskFilter.blur)
- Eraser uses `BlendMode.clear` on a `saveLayer` — erases to transparent, not to background color
- Quadratic Bézier path smoothing for natural-looking strokes
- Color palette (12 colors), continuous size slider (1–30px), undo
- Each stroke is broadcast as a JSON payload with points, color, size, brush type, and page index
- Drawings persist to Supabase `drawing_sessions` table as `pages_json` and restore on reopen
- Clear canvas broadcasts a `clear` event that wipes both local and remote strokes

---

## Sticker Studio (.sv Format)

A custom sticker format — `.sv` files are ZIP archives containing a visual (PNG or H.264 MP4), an audio track (Opus 16kbps mono), and a JSON manifest.

### Creation Pipeline
1. Pick source: video (gallery) or image (gallery)
2. Video path: trim clip (max 5s) → crop to square → optional AI background removal (frame-by-frame via Apple Vision API) → encode H.264 200x200
3. Image path: crop to square 256x256 → optional background removal → PNG
4. Audio: extract from source video, pick separate video/audio file, or record from microphone
5. Audio trimmed and encoded to Opus 16kbps mono via FFmpeg
6. Package into ZIP archive with manifest → upload to Supabase Storage under `sv/{userId}/`

### Playback
- `SvCache` service downloads `.sv` files once, extracts visual + audio to temp directory, caches in memory
- Video stickers loop silently in chat, audio plays on first receive or on tap
- Stickers can be dragged and placed on specific messages (anchored by message ID)

---

## Media Features

- Image/video sharing: media is encrypted with AES-256-GCM before upload to Supabase Storage, decrypted on download using the session's E2E key
- Locked images: password-protected photos — the password is SHA-256 hashed to derive an AES key, the image is encrypted client-side, and the password hash is stored alongside the message for verification (the actual password is never stored)
- Voice messages: hold-to-record with Instagram-style overlay (pulsing red dot, timer, slide-to-cancel), encoded and encrypted before upload
- Speech-to-text: live transcription via `speech_to_text` package, with diacritics stripped to ASCII for stroke-encoding compatibility, encoded to stroke text in real-time as the user speaks
- GIF picker with search, sticker picker, and emoji picker
- Video thumbnails generated via `video_thumbnail` package, cached to disk

---

## UI System

### Glassmorphism Design
- Custom `GlassPill` and `GlassContainer` widgets with device-tilt-reactive borders
- Accelerometer data (via `sensors_plus`) drives a `TiltProvider` singleton that computes a smoothed light angle
- Border highlight uses a `SweepGradient` shader that rotates with the tilt angle — the bright arc follows the device's physical orientation
- Inner specular glow moves with tilt direction via `RadialGradient`
- `BackdropFilter` with 24px Gaussian blur for the frosted glass effect
- Performance toggle: "Simple UI" mode in settings disables all glass effects and tilt animations, replacing them with flat dark containers

### Per-Conversation Theming
- Custom chat background: pick from gallery → position with zoom/pan editor (`BgEditorScreen`) → stored as base64 + transform matrix in secure storage
- Custom bubble gradient: configurable per conversation, stored in secure storage
- Bubble accent color picker in friend profile page

### Friend Profiles
- Local-only avatars: picked from gallery, stored in secure storage, never uploaded
- Local-only nicknames: stored in secure storage, never sent to server
- Shared media grid with sent/received filter tabs, decrypted thumbnails cached to disk
- Conversation deletion with confirmation

---

## Architecture
```
lib/
├── core/
│   ├── dh_key_exchange.dart    — ECDH keypair generation + shared secret derivation
│   ├── e2e_encryption.dart     — AES-256-GCM encrypt/decrypt (text + binary)
│   ├── stroke_mapping.dart     — Session-seeded character → 4-symbol encoding
│   ├── session_manager.dart    — Session lifecycle, key rotation, encode/decode orchestration
│   ├── secure_storage.dart     — Keychain/Keystore wrapper for mapping persistence
│   ├── ws_client.dart          — WebSocket client with auto-reconnect
│   ├── tilt_provider.dart      — Accelerometer → smoothed tilt angle for glass effects
│   ├── local_avatar.dart       — Device-local friend avatar storage
│   └── local_nickname.dart     — Device-local friend nickname storage
├── models/
│   └── chat_message.dart       — Message data model
├── screens/
│   ├── auth_screen.dart        — Email/password auth with username registration
│   ├── chat_list_screen.dart   — Conversation list with friend requests badge
│   ├── chat_screen.dart        — Main chat (4000+ lines): messaging, media, voice, stickers, key rotation
│   ├── drawboard_screen.dart   — Collaborative real-time drawing canvas
│   ├── sv_maker_screen.dart    — Sticker Studio: video/image → .sv creation pipeline
│   ├── friend_profile_page.dart— Profile, theming, media grid, nickname editor
│   ├── requests_screen.dart    — Friend request management (accept/reject/cancel)
│   ├── settings_screen.dart    — App settings, Simple UI toggle, SV Maker access
│   ├── camera_screen.dart      — Camera capture
│   ├── media_viewer_screen.dart— Full-screen media viewer
│   ├── bg_editor_screen.dart   — Chat background zoom/pan editor
│   └── video_player_screen.dart— Video playback
├── services/
│   ├── push_notification_service.dart — FCM init, token management, background handler
│   ├── push_sender.dart        — Supabase Edge Function invocation for push delivery
│   ├── sv_cache.dart           — .sv download, extraction, and caching
│   └── bg_removal_service.dart — Apple Vision API bridge for background removal
└── widgets/
    ├── stroke_keyboard.dart    — Custom iOS-style keyboard with accent variants
    ├── stroke_text.dart        — Secure paint-time-only stroke decoding renderer
    ├── glass_pill.dart         — Tilt-reactive glassmorphic pill button
    ├── glass_container.dart    — Tilt-reactive glassmorphic container
    ├── liquid_glass.dart       — iOS 26-style frosted glass container
    ├── voice_recorder.dart     — Hold-to-record overlay with timer and slide-to-cancel
    ├── voice_bubble.dart       — Voice message playback bubble
    ├── gif_picker.dart         — GIF/sticker search and selection
    └── emoji_picker.dart       — Emoji grid picker
```
