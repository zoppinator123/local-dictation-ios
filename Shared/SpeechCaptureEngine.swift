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

/// File-based capture for keyboard appexes. Do not use AVAudioEngine here:
/// a keyboard cannot initialize an output node.
public final class SpeechCaptureEngine: @unchecked Sendable {
    private var recorder: AVAudioRecorder?
    private var fileURL: URL?

    public init() {}

    public func start() async throws {
        stopAndDelete()

        #if os(iOS)
        let granted = await requestMicPermission()
        guard granted else {
            throw SpeechCaptureError.engineStartFailed("Allow Microphone in the Local Dictation app, then try again.")
        }
        try activateMixedRecordSession()
        #endif

        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let url = directory.appendingPathComponent("local-dictation-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = false
            guard recorder.prepareToRecord() else {
                throw SpeechCaptureError.engineStartFailed("Recorder prepare failed")
            }
            guard recorder.record() else {
                #if os(iOS)
                let perm = String(describing: AVAudioApplication.shared.recordPermission)
                let category = AVAudioSession.sharedInstance().category.rawValue
                throw SpeechCaptureError.engineStartFailed("record() false perm=\(perm) session=\(category)")
                #else
                throw SpeechCaptureError.engineStartFailed("Microphone did not start")
                #endif
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
            (.record, .default, [.mixWithOthers, .duckOthers]),
            (.record, .measurement, []),
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
