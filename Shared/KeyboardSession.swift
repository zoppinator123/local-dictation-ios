import Foundation

public enum KeyboardPhase: String, Codable, Equatable, Sendable {
    case idle
    case recording
    case transcribing
    case inserting
    case needsSetup
    case error
}

public enum KeyboardCommand: Equatable, Sendable {
    case beginHold
    case endHold
    case toggle
    case cancel
    case insertReadyTranscript
    case dismissError
}

public struct KeyboardFailure: Equatable, Sendable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct KeyboardSnapshot: Equatable, Sendable {
    public var phase: KeyboardPhase
    public var status: String
    public var canRecord: Bool
    public var canInsert: Bool
    public var lastTranscript: String?
    public var lastError: KeyboardFailure?

    public init(
        phase: KeyboardPhase,
        status: String,
        canRecord: Bool,
        canInsert: Bool,
        lastTranscript: String? = nil,
        lastError: KeyboardFailure? = nil
    ) {
        self.phase = phase
        self.status = status
        self.canRecord = canRecord
        self.canInsert = canInsert
        self.lastTranscript = lastTranscript
        self.lastError = lastError
    }
}

public struct KeyboardSession: Equatable, Sendable {
    public private(set) var phase: KeyboardPhase = .idle
    public private(set) var lastTranscript: String?
    public private(set) var lastError: KeyboardFailure?
    public var readiness: KeyboardReadiness

    public init(readiness: KeyboardReadiness = KeyboardReadiness()) {
        self.readiness = readiness
        if !readiness.canAttemptRecording {
            phase = .needsSetup
        }
    }

    public var snapshot: KeyboardSnapshot {
        KeyboardSnapshot(
            phase: phase,
            status: status,
            canRecord: readiness.canAttemptRecording && (phase == .idle || phase == .error || phase == .needsSetup),
            canInsert: lastTranscript?.isEmpty == false && phase != .recording,
            lastTranscript: lastTranscript,
            lastError: lastError
        )
    }

    public var status: String {
        if let lastError, phase == .error || phase == .needsSetup {
            return lastError.message
        }
        switch phase {
        case .idle: return "Tap the mic and speak"
        case .recording: return "Listening…"
        case .transcribing: return "Transcribing…"
        case .inserting: return "Inserting…"
        case .needsSetup: return readiness.blockingMessage ?? "Finish setup in Local Dictation"
        case .error: return lastError?.message ?? "Dictation failed"
        }
    }

    @discardableResult
    public mutating func handle(_ command: KeyboardCommand) -> Bool {
        switch command {
        case .beginHold:
            return beginRecording()
        case .toggle where phase != .recording:
            return beginRecording()
        case .endHold, .toggle:
            guard phase == .recording else { return false }
            phase = .transcribing
            return true
        case .cancel:
            guard phase == .recording || phase == .transcribing else { return false }
            phase = readiness.canAttemptRecording ? .idle : .needsSetup
            return true
        case .insertReadyTranscript:
            guard phase == .transcribing, lastTranscript?.isEmpty == false else { return false }
            phase = .inserting
            return true
        case .dismissError:
            guard phase == .error || phase == .needsSetup else { return false }
            phase = readiness.canAttemptRecording ? .idle : .needsSetup
            lastError = nil
            return true
        }
    }

    private mutating func beginRecording() -> Bool {
        guard readiness.canAttemptRecording else {
            phase = .needsSetup
            lastError = KeyboardFailure(code: "setup", message: readiness.blockingMessage ?? "Setup required")
            return false
        }
        guard phase == .idle || phase == .error || phase == .needsSetup else { return false }
        lastError = nil
        phase = .recording
        return true
    }

    public mutating func finishTranscription(_ text: String) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        lastTranscript = cleaned.isEmpty ? nil : cleaned
        if phase == .transcribing {
            if cleaned.isEmpty {
                lastError = KeyboardFailure(code: "empty", message: "No speech was captured")
                phase = .error
            } else {
                phase = .inserting
            }
        }
    }

    public mutating func finishInsertion() {
        if phase == .inserting {
            phase = .idle
        }
    }

    public mutating func fail(_ error: KeyboardFailure) {
        lastError = error
        phase = error.code == "setup" ? .needsSetup : .error
    }

    public mutating func applyReadiness(_ next: KeyboardReadiness) {
        readiness = next
        if next.canAttemptRecording, phase == .needsSetup {
            phase = .idle
            lastError = nil
        } else if !next.canAttemptRecording, phase == .idle {
            phase = .needsSetup
        }
    }
}
