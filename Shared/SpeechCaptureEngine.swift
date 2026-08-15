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
///
/// Keyboard appexes cannot initialize an output node. Create the engine
/// only after a record-only session is active, then never touch outputNode.
public final class SpeechCaptureEngine: @unchecked Sendable {
    private var engine: AVAudioEngine?
    private var request: SFSpeechBufferAppending?
    private var tapInstalled = false

    public init() {}

    public func start(appending request: SFSpeechBufferAppending) throws {
        stop()
        self.request = request

        #if os(iOS)
        try activateRecordSession()
        #endif

        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let format = usableFormat(for: input)
        guard let format else {
            stop()
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
        if tapInstalled, let engine {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if let engine, engine.isRunning {
            engine.stop()
        }
        engine = nil
        request = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    #if os(iOS)
    private func activateRecordSession() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setPreferredSampleRate(16_000)
            try session.setPreferredIOBufferDuration(0.02)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw SpeechCaptureError.engineStartFailed(error.localizedDescription)
        }
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
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
    }
}

/// Tiny seam so Shared does not import Speech.
public protocol SFSpeechBufferAppending: AnyObject, Sendable {
    func append(_ buffer: AVAudioPCMBuffer)
    func endAudio()
}
