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
- On-device speech recognition; no account or API key

## What it does not copy

Wispr Flow’s cloud rewriting, style-learning, quiet-room models, and auto-switchback polish are not claimed. This MVP stays on-device.

## How dictation works on iOS

Apple’s keyboard sandbox is the hard part:

1. The keyboard requests **Full Access** (`RequestsOpenAccess`).
2. When the OS allows it, the keyboard records with `AVAudioEngine` and transcribes with on-device `SFSpeechRecognizer`.
3. If in-keyboard audio is blocked, the keyboard opens the host app (`localdictation://dictate`), which records and writes the cleaned transcript into the App Group. The keyboard inserts it when you return.

iOS 26 can fail to auto-return to the previous app after an extension `openURL`. The host app tells you to switch back; the keyboard then inserts automatically.

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
6. Hold the red microphone and speak.

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

Select your Team in Signing & Capabilities for both `LocalDictation` and `LocalDictationKeyboard`. The App Group is `group.com.jackzoppa.LocalDictation`.

## Layout

- `Shared/` — cleanup, vocabulary, keyboard session, App Group store
- `App/` — host onboarding, permissions, fallback recorder
- `Keyboard/` — custom keyboard UI + in-keyboard dictation
- `Tests/` — SwiftPM harness for the shared core

## Privacy

Audio is used only for the current dictation. Transcripts are not stored as history. Diagnostics are not collected. See `docs/privacy.md`.
