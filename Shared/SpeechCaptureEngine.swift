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
        try activateSession()
        #endif

        let input = engine.inputNode
        let format = usableFormat(for: input)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        tapInstalled = true
        engine.prepare()
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

    #if os(iOS)
    private func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        var lastError: Error?
        let attempts: [(AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)] = [
            (.playAndRecord, .spokenAudio, [.duckOthers, .allowBluetooth]),
            (.record, .measurement, [.duckOthers]),
            (.playAndRecord, .default, [.mixWithOthers]),
        ]
        for (category, mode, options) in attempts {
            do {
                try session.setCategory(category, mode: mode, options: options)
                try session.setActive(true, options: .notifyOthersOnDeactivation)
                return
            } catch {
                lastError = error
            }
        }
        throw SpeechCaptureError.engineStartFailed(lastError?.localizedDescription ?? "Audio session failed")
    }
    #endif

    private func usableFormat(for input: AVAudioInputNode) -> AVAudioFormat? {
        let hardware = input.inputFormat(forBus: 0)
        if hardware.channelCount > 0, hardware.sampleRate > 0 {
            return hardware
        }
        let output = input.outputFormat(forBus: 0)
        if output.channelCount > 0, output.sampleRate > 0 {
            return output
        }
        return nil
    }
}

/// Tiny seam so Shared does not import Speech.
public protocol SFSpeechBufferAppending: AnyObject, Sendable {
    func append(_ buffer: AVAudioPCMBuffer)
    func endAudio()
}
