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

/// Owns capture off the main actor. Keyboard appexes cannot start a
/// playback graph — never touch outputNode / mainMixerNode.
public final class SpeechCaptureEngine: @unchecked Sendable {
    private var engine: AVAudioEngine?
    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    private var request: SFSpeechBufferAppending?
    private var tapInstalled = false

    public init() {}

    public func startLive(appending request: SFSpeechBufferAppending) async throws {
        stopAndDelete()
        self.request = request
        #if os(iOS)
        try await prepareSession()
        #endif
        try startEngine()
    }

    public func startFile() async throws {
        stopAndDelete()
        #if os(iOS)
        try await prepareSession()
        #endif
        try startRecorder()
    }

    public func endAudio() {
        request?.endAudio()
    }

    public func stop() -> URL? {
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

    private func startEngine() throws {
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let hardware = input.inputFormat(forBus: 0)
        guard hardware.channelCount > 0, hardware.sampleRate > 0 else {
            engine.reset()
            self.engine = nil
            throw SpeechCaptureError.invalidInputFormat
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        tapInstalled = true
        do {
            try engine.start()
        } catch {
            stopAndDelete()
            throw SpeechCaptureError.engineStartFailed("engine \(nsErrorText(error))")
        }
    }

    private func startRecorder() throws {
        #if os(iOS)
        let rate = AVAudioSession.sharedInstance().sampleRate
        let sampleRate = rate > 0 ? rate : 44_100
        #else
        let sampleRate = 44_100.0
        #endif
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let url = directory.appendingPathComponent("local-dictation-\(UUID().uuidString).caf")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        guard recorder.prepareToRecord(), recorder.record() else {
            #if os(iOS)
            let perm: String
            switch AVAudioApplication.shared.recordPermission {
            case .granted: perm = "granted"
            case .denied: perm = "denied"
            default: perm = "undetermined"
            }
            throw SpeechCaptureError.engineStartFailed(
                "record() false perm=\(perm) rate=\(Int(sampleRate))"
            )
            #else
            throw SpeechCaptureError.engineStartFailed("Microphone did not start")
            #endif
        }
        self.recorder = recorder
        self.fileURL = url
    }

    #if os(iOS)
    private func prepareSession() async throws {
        let granted = await requestMicPermission()
        guard granted else {
            throw SpeechCaptureError.engineStartFailed("Allow Microphone in the Local Dictation app, then try again.")
        }
        try activateMixedRecordSession()
        try await Task.sleep(nanoseconds: 80_000_000)
    }

    private func requestMicPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        default:
            return await AVAudioApplication.requestRecordPermission()
        }
    }

    private func activateMixedRecordSession() throws {
        let session = AVAudioSession.sharedInstance()
        var lastError: Error?
        let attempts: [(AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)] = [
            (.playAndRecord, .spokenAudio, [.mixWithOthers, .duckOthers, .defaultToSpeaker]),
            (.playAndRecord, .default, [.mixWithOthers, .defaultToSpeaker]),
            (.record, .measurement, [.mixWithOthers, .duckOthers]),
        ]
        for (category, mode, options) in attempts {
            do {
                try session.setCategory(category, mode: mode, options: options)
                try session.setActive(true)
                return
            } catch {
                lastError = error
            }
        }
        throw SpeechCaptureError.engineStartFailed(nsErrorText(lastError ?? SpeechCaptureError.engineStartFailed("Audio session failed")))
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

public protocol SFSpeechBufferAppending: AnyObject, Sendable {
    func append(_ buffer: AVAudioPCMBuffer)
    func endAudio()
}
