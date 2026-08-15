import Foundation

public enum HostCapturePhase: String, Equatable, Sendable {
    case idle
    case live
    case clipping
    case transcribing
}

public enum HostCaptureCommand: String, Equatable, Sendable {
    case none
    case startHardware
    case stopHardware
    case openClip
    case closeClip
}

public enum HostCaptureError: Error, Equatable, LocalizedError, Sendable {
    case needsForegroundSession
    case alreadyClipping
    case notClipping
    case hardwareStartFromBackground

    public var errorDescription: String? {
        switch self {
        case .needsForegroundSession:
            return "Tap Start session in Local Dictation first."
        case .alreadyClipping:
            return "Already listening."
        case .notClipping:
            return "Not listening."
        case .hardwareStartFromBackground:
            return "Microphone can only start in Local Dictation. Tap Start session, then come back."
        }
    }
}

public struct HostCaptureState: Equatable, Sendable {
    public var phase: HostCapturePhase
    public var lastError: String?
    public var micEngaged: Bool
    public var clipOpen: Bool

    public static let idle = HostCaptureState(phase: .idle, lastError: nil, micEngaged: false, clipOpen: false)
}

/// Legal capture model: hardware starts only in the foreground.
/// Keyboard taps only open/close a clip on an already-live stream.
public struct HostCaptureSession: Equatable, Sendable {
    public private(set) var state: HostCaptureState
    public private(set) var lastCommand: HostCaptureCommand

    public init(state: HostCaptureState = .idle) {
        self.state = state
        self.lastCommand = .none
    }

    public var isLive: Bool { state.micEngaged }
    public var isListening: Bool { state.phase == .clipping }

    @discardableResult
    public mutating func startSession(foreground: Bool) -> Result<HostCaptureCommand, HostCaptureError> {
        guard foreground else {
            lastCommand = .none
            state.lastError = HostCaptureError.hardwareStartFromBackground.errorDescription
            return .failure(.hardwareStartFromBackground)
        }
        if state.micEngaged, state.phase != .idle {
            lastCommand = .none
            state.lastError = nil
            if state.phase == .transcribing {
                state.phase = .live
                state.clipOpen = false
            }
            return .success(.none)
        }
        state = HostCaptureState(phase: .live, lastError: nil, micEngaged: true, clipOpen: false)
        lastCommand = .startHardware
        return .success(.startHardware)
    }

    public mutating func startClip(foreground: Bool) -> Result<HostCaptureCommand, HostCaptureError> {
        if state.phase == .clipping {
            lastCommand = .none
            return .failure(.alreadyClipping)
        }
        guard state.micEngaged else {
            lastCommand = .none
            if !foreground {
                state.lastError = HostCaptureError.needsForegroundSession.errorDescription
                return .failure(.needsForegroundSession)
            }
            return .failure(.needsForegroundSession)
        }
        state.phase = .clipping
        state.clipOpen = true
        state.lastError = nil
        lastCommand = .openClip
        return .success(.openClip)
    }

    public mutating func stopClip() -> Result<HostCaptureCommand, HostCaptureError> {
        guard state.phase == .clipping, state.clipOpen else {
            lastCommand = .none
            state.clipOpen = false
            if state.micEngaged { state.phase = .live }
            return .failure(.notClipping)
        }
        state.phase = .transcribing
        state.clipOpen = false
        lastCommand = .closeClip
        return .success(.closeClip)
    }

    public mutating func finishTranscription(_ text: String) {
        state.lastError = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Didn't catch that. Tap the mic, speak, then tap again."
            : nil
        state.clipOpen = false
        state.phase = state.micEngaged ? .live : .idle
        lastCommand = .none
    }

    public mutating func failTranscription(_ message: String) {
        state.lastError = message
        state.clipOpen = false
        state.phase = state.micEngaged ? .live : .idle
        lastCommand = .none
    }

    @discardableResult
    public mutating func micOff() -> HostCaptureCommand {
        state = .idle
        lastCommand = .stopHardware
        return .stopHardware
    }
}

public enum HostCaptureRoute: String, Equatable, Sendable {
    case health
    case start
    case stop
    case off
    case unknown

    public static func parseHTTP(_ request: String) -> HostCaptureRoute {
        let line = request.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? request
        let token = line.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let path = token.split(separator: "?").first.map(String.init) ?? token
        switch path {
        case "/health": return .health
        case "/start": return .start
        case "/stop": return .stop
        case "/off": return .off
        default: return .unknown
        }
    }
}
