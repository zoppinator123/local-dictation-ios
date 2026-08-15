# Architecture

```
Host app (LocalDictation)
  permissions, vocabulary, style, fallback recorder
        | App Group group.com.jackzoppa.LocalDictation
Keyboard extension (LocalDictationKeyboard)
  mic + QWERTY + UITextDocumentProxy.insertText
        |
On-device SFSpeechRecognizer
```

Shared core (`LocalDictationCore`) has no UIKit dependency so it can be tested with SwiftPM on macOS.

The keyboard first tries in-extension audio. If `AVAudioEngine` cannot start, it opens `localdictation://dictate` and later consumes `shared-dictation.json`.
