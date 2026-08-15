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

/// File-based capture. Keyboard appexes cannot start AVAudioEngine
/// (no output node / hwFormat). AVAudioRecorder only needs a record session.
public final class SpeechCaptureEngine: @unchecked Sendable {
    private var recorder: AVAudioRecorder?
    private var fileURL: URL?

    public init() {}

    public func start() throws {
        stopAndDelete()

        #if os(iOS)
        try activateRecordSession()
        #endif

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-dictation-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = false
            guard recorder.prepareToRecord(), recorder.record() else {
                throw SpeechCaptureError.engineStartFailed("Microphone did not start")
            }
            self.recorder = recorder
            self.fileURL = url
        } catch let error as SpeechCaptureError {
            throw error
        } catch {
            throw SpeechCaptureError.engineStartFailed(nsErrorText(error))
        }
    }

    public func stop() -> URL? {
        recorder?.stop()
        let url = fileURL
        recorder = nil
        fileURL = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        return url
    }

    public func stopAndDelete() {
        let url = stop()
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
    }

    #if os(iOS)
    private func activateRecordSession() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            throw SpeechCaptureError.engineStartFailed(nsErrorText(error))
        }
    }
    #endif
}

public func nsErrorText(_ error: Error) -> String {
    let ns = error as NSError
    if ns.domain.isEmpty {
        return error.localizedDescription
    }
    return "\(ns.domain) \(ns.code): \(error.localizedDescription)"
}

/// Kept so older call sites compile; unused by the recorder path.
public protocol SFSpeechBufferAppending: AnyObject, Sendable {
    func append(_ buffer: AVAudioPCMBuffer)
    func endAudio()
}
