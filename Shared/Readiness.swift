import Foundation

public struct KeyboardReadiness: Equatable, Sendable {
    public var keyboardEnabled: Bool
    public var fullAccessGranted: Bool
    public var microphoneGranted: Bool
    public var speechAuthorized: Bool

    public init(
        keyboardEnabled: Bool = false,
        fullAccessGranted: Bool = false,
        microphoneGranted: Bool = false,
        speechAuthorized: Bool = false
    ) {
        self.keyboardEnabled = keyboardEnabled
        self.fullAccessGranted = fullAccessGranted
        self.microphoneGranted = microphoneGranted
        self.speechAuthorized = speechAuthorized
    }

    public var isReady: Bool {
        keyboardEnabled && fullAccessGranted && microphoneGranted && speechAuthorized
    }

    public var blockingMessage: String? {
        if !keyboardEnabled { return "Add Local Dictation in Settings › General › Keyboard." }
        if !fullAccessGranted { return "Turn on Allow Full Access for Local Dictation." }
        if !microphoneGranted { return "Allow Microphone access in Settings." }
        if !speechAuthorized { return "Allow Speech Recognition in Settings." }
        return nil
    }

    public var steps: [ReadinessStep] {
        [
            ReadinessStep(id: "keyboard", title: "Add the keyboard", complete: keyboardEnabled, detail: "Settings › General › Keyboard › Keyboards › Add New Keyboard"),
            ReadinessStep(id: "full-access", title: "Allow Full Access", complete: fullAccessGranted, detail: "Required so the keyboard can use the microphone and insert text."),
            ReadinessStep(id: "microphone", title: "Allow Microphone", complete: microphoneGranted, detail: "Used only while you are dictating."),
            ReadinessStep(id: "speech", title: "Allow Speech Recognition", complete: speechAuthorized, detail: "On-device transcription. Audio is not uploaded."),
        ]
    }
}

public struct ReadinessStep: Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var complete: Bool
    public var detail: String
}

public enum AppRoute: String, Sendable {
    case root = "localdictation://open"
    case dictate = "localdictation://dictate"
    case settings = "localdictation://settings"

    public var url: URL { URL(string: rawValue)! }
}
