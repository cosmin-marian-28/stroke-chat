# StrokeChat

End-to-end encrypted messaging app built with Flutter in 3 days as a proof-of-concept MVP.

## What It Does

A privacy-first chat app with a dual-layer encryption system designed to protect messages against server compromise, RAM-scraping malware, and keylogging trojans.

**Layer 1** — AES-256-GCM end-to-end encryption via ECDH key exchange. The server never sees plaintext.

**Layer 2** — A proprietary visual cipher ("Stroke Encoding") that maps each character to 4 Unicode stroke symbols using a session-seeded PRNG. The mapping is never transmitted — both devices derive it independently from the shared secret. Decoded text only exists inside a `CustomPainter.paint()` call and immediately goes out of scope, so a memory dump won't find it.

## Key Features

- **Vanish-mode key rotation** — pull-up gesture rotates encryption keys mid-conversation, generating a completely new stroke mapping
- **Custom keyboard** — built from scratch to bypass OS-level keyloggers, with iOS-style magnified previews, accent variants, spacebar trackpad, and accelerating backspace
- **Secure storage** — all key material stored in iOS Keychain / Android Keystore, never in app memory longer than necessary
- **Real-time messaging** — Supabase Realtime Broadcast with optimistic UI and read receipts
- **Collaborative drawing board** — shared canvas with multi-page support, 3 brush types, Bézier smoothing, synced via Realtime
- **Sticker Studio** — custom `.sv` format (ZIP with video/image + audio + manifest), with AI background removal via Apple Vision API
- **Encrypted media** — images, videos, and voice messages encrypted with AES-256-GCM before upload
- **Locked images** — password-protected photos with client-side encryption
- **Speech-to-text** — live transcription encoded to stroke text in real-time
- **Glassmorphism UI** — tilt-reactive glass effects driven by accelerometer data, with a performance toggle

## Tech Stack

Flutter 3.11+ · Supabase · PointyCastle (AES-256-GCM, ECDH, SHA-256) · Firebase Cloud Messaging · FFmpeg Kit · Apple Vision API

## Architecture

See [PORTFOLIO_CHAT_APP.md](PORTFOLIO_CHAT_APP.md) for the full technical deep-dive — encryption flows, threat model, rendering pipeline, keyboard implementation, and complete file structure.
