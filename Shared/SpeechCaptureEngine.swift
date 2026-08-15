import AVFoundation
import Foundation

public enum SpeechCaptureError: Error, Equatable, LocalizedError {
    case invalidInputFormat
    case engineStartFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidInputFormat:
            return "Microphone is not ready yet."
        case .engineStartFailed(let message):
            return message
        }
    }
}

/// Owns AVAudioEngine off the main actor. Swift 6 traps if a MainActor
/// type receives the realtime tap callback.
public final class SpeechCaptureEngine: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var request: SFSpeechBufferAppending?
    private var tapInstalled = false

    public init() {}

    public func start(appending request: SFSpeechBufferAppending) throws {
        stop()
        self.request = request

        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw SpeechCaptureError.engineStartFailed(error.localizedDescription)
        }
        #endif

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw SpeechCaptureError.invalidInputFormat
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        tapInstalled = true
        do {
            try engine.start()
        } catch {
            stop()
            throw SpeechCaptureError.engineStartFailed(error.localizedDescription)
        }
    }

    public func endAudio() {
        request?.endAudio()
    }

    public func stop() {
        request?.endAudio()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning {
            engine.stop()
        }
        request = nil
    }
}

/// Tiny seam so Shared does not import Speech.
public protocol SFSpeechBufferAppending: AnyObject, Sendable {
    func append(_ buffer: AVAudioPCMBuffer)
    func endAudio()
}
