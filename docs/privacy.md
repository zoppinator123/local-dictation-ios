# Privacy

Local Dictation for iPhone is local-first.

| Data | Stored? | Leaves the device? |
|---|---|---|
| Microphone audio | Only in memory / system speech buffers for the current utterance | No |
| Transcript text | Not kept as history. It is returned directly to the keyboard for insertion | No |
| Vocabulary / style | Device-local app storage | No |
| Account / API key | None | n/a |

Full Access is required by iOS for a keyboard that uses the microphone. Apple shows that switch so you know keystrokes can be read by the keyboard process. This app does not upload keystrokes.

If Apple’s on-device recognizer is unavailable, recognition may fail closed rather than sending audio to a cloud API.
