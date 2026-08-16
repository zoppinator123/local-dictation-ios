# Local Dictation for iPhone

A local-first custom iOS keyboard that works like Wispr Flow on iPhone: switch to it in any text field, tap the microphone, speak, and cleaned text is inserted at the cursor.

This is an independent greenfield app. It does **not** fork Wispr Flow, VoiceInk, or any GPL project.

**Repo:** https://github.com/zoppinator123/local-dictation-ios

## What matches Wispr Flow on iPhone

- Custom system keyboard, available in Messages, Mail, Slack, Notes, Safari, and any other text field
- Globe-key switch, no per-app plugin
- Microphone control on the keyboard
- Hold-to-talk or tap-to-talk
- Inserts at the current caret through `UITextDocumentProxy`
- Compact QWERTY so you can edit without leaving the keyboard
- Full Access + Microphone + Speech Recognition setup in the host app
- Custom vocabulary (Haven, StaydOS, names)
- Writing styles: Raw, Polished, Email
- Bundled on-device WhisperKit `base.en`; no account or API key

## What it does not copy

Wispr Flow’s cloud rewriting, style-learning, quiet-room models, and auto-switchback polish are not claimed. This MVP stays on-device.

## How dictation works on iOS

Apple’s keyboard sandbox cannot start fresh microphone hardware after its host app is suspended:

1. Open Local Dictation and tap **Start Session** while the host is foregrounded.
2. The host owns a persistent `AVAudioEngine` input tap and preloads the bundled WhisperKit model.
3. The keyboard is a thin authenticated localhost client. `/start` opens a logical clip; `/stop` sends the buffered PCM to host-side WhisperKit.
4. The host returns raw text over `127.0.0.1`; the keyboard cleans it once and inserts it through `textDocumentProxy`.
5. Apple Speech remains an on-device fallback for bounded model/inference failures. **Mic off** immediately tears down the host audio session.

Host and keyboard share only a random per-install Keychain token. No transcript or model is stored in the keyboard extension.

## Requirements

- iPhone, iOS 17+
- Xcode 16+ to build and install
- Apple Developer signing for a physical device
- Full Access, Microphone, and Speech Recognition

This Mac mini currently has Command Line Tools only, so the **shared core is verified here**. The iOS app/keyboard targets need Xcode on a Mac that has it (your MacBook).

## Setup on iPhone

1. Install **Local Dictation** from Xcode.
2. Open the app and grant Microphone + Speech Recognition.
3. iOS Settings › General › Keyboard › Keyboards › **Add New Keyboard** › Local Dictation.
4. Tap Local Dictation and enable **Allow Full Access**.
5. Open Messages (or any app), hold the globe, choose Local Dictation.
6. Tap the microphone, speak, then tap again to insert.

## Build

```bash
# Shared core tests (no Xcode required)
chmod +x Scripts/run-tests.sh
./Scripts/run-tests.sh

# iOS app (requires full Xcode)
brew install xcodegen
xcodegen generate
open LocalDictationIOS.xcodeproj
```

Select Team `Q4MSNRURZ4` in Signing & Capabilities for both `LocalDictation` and `LocalDictationKeyboard`. Both targets use App Group `group.com.jackzoppa.LocalDictation` for settings/vocabulary and Keychain access group `Q4MSNRURZ4.com.jackzoppa.LocalDictation.shared` for localhost authentication.

## Layout

- `Shared/` — cleanup, PCM buffering/resampling, state machines, authentication helpers
- `App/` — host audio engine, bundled WhisperKit inference, on-device Apple Speech fallback
- `Keyboard/` — custom keyboard UI, localhost client, and caret insertion
- `Tests/` — SwiftPM harness for the shared core

## Privacy

Audio is used only for the current dictation. Transcripts are not stored as history. Device-local diagnostics record state and timing but never audio or dictated text. See `docs/privacy.md`.
