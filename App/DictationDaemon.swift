import AVFoundation
import Foundation
import Network
import Speech
import UIKit

/// Host-side capture. Audio runs only while a dictation is in progress.
@MainActor
final class DictationDaemon: ObservableObject {
    static let shared = DictationDaemon()
    static let port: UInt16 = 18_765

    @Published private(set) var isListening = false

    private var listener: NWListener?
    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private init() {}

    func start() {
        startListener()
    }

    func shutdownAudio() {
        teardownCapture(deactivateSession: true)
    }

    private func teardownCapture(deactivateSession: Bool) {
        recorder?.stop()
        recorder = nil
        fileURL = nil
        isListening = false
        endBackgroundTask()
        if deactivateSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func activateSessionForRecording() throws {
        let session = AVAudioSession.sharedInstance()
        let attempts: [AVAudioSession.CategoryOptions] = [
            [.mixWithOthers, .defaultToSpeaker],
            [.mixWithOthers],
        ]
        var lastError: Error?
        for options in attempts {
            do {
                try session.setCategory(.playAndRecord, mode: .default, options: options)
                try session.setActive(true)
                return
            } catch {
                lastError = error
            }
        }
        throw SpeechCaptureError.engineStartFailed(
            "Couldn't start the mic from the background. Open Local Dictation, then tap again. \(lastError?.localizedDescription ?? "")"
        )
    }

    func startRecording() async throws {
        teardownCapture(deactivateSession: false)
        endBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "local-dictation") { [weak self] in
            self?.shutdownAudio()
        }

        try activateSessionForRecording()

        let session = AVAudioSession.sharedInstance()
        let rates = [session.sampleRate, 44_100.0, 16_000.0].filter { $0 > 0 }
        var lastError: Error?
        for rate in rates {
            do {
                try beginRecorder(sampleRate: rate)
                isListening = true
                return
            } catch {
                lastError = error
            }
        }
        throw SpeechCaptureError.engineStartFailed(lastError?.localizedDescription ?? "Microphone did not start")
    }

    private func beginRecorder(sampleRate: Double) throws {
        recorder?.stop()
        recorder = nil
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-dictation-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.prepareToRecord() else {
            throw SpeechCaptureError.engineStartFailed("prepareToRecord failed")
        }
        guard recorder.record() else {
            throw SpeechCaptureError.engineStartFailed("Microphone did not start")
        }
        self.recorder = recorder
        fileURL = url
    }

    func stopRecording() async throws -> String {
        recorder?.stop()
        let url = fileURL
        recorder = nil
        fileURL = nil
        defer { shutdownAudio() }
        guard let url else {
            throw SpeechCaptureError.engineStartFailed("No audio captured")
        }
        let text = try await transcribe(url: url)
        try? FileManager.default.removeItem(at: url)
        if !text.isEmpty {
            UIPasteboard.general.string = ClipboardDictation.encode(text)
        }
        return text
    }

    private func transcribe(url: URL) async throws -> String {
        let recognizer = SFSpeechRecognizer(locale: Locale.autoupdatingCurrent)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer else {
            throw SpeechCaptureError.engineStartFailed("Speech recognizer unavailable")
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = false
        return try await withCheckedThrowingContinuation { continuation in
            let box = ResumeBox()
            recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    guard box.finish() else { return }
                    continuation.resume(returning: result.bestTranscription.formattedString)
                } else if let error {
                    guard box.finish() else { return }
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func startListener() {
        guard listener == nil else { return }
        do {
            let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Self.port)!)
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .main)
                Task { @MainActor in
                    self?.serve(connection)
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            NSLog("DictationDaemon listen failed: \(error)")
        }
    }

    private func serve(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            Task { @MainActor in
                let body = await self.handle(request)
                let response = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8)
                connection.send(content: response, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    private func handle(_ request: String) async -> String {
        let line = request.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? request
        let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        do {
            switch path {
            case "/health":
                return json(["ok": true, "listening": isListening])
            case "/start":
                try await startRecording()
                return json(["ok": true])
            case "/stop":
                let raw = try await stopRecording()
                let directory = AppGroupPaths.containerURL() ?? FileManager.default.temporaryDirectory
                let settings = (try? FileSettingsPersister(fileURL: directory.appendingPathComponent(AppGroupPaths.settingsFileName)).load()) ?? KeyboardSettings()
                let vocabulary = VocabularyStore(
                    persister: FileVocabularyPersister(fileURL: directory.appendingPathComponent(AppGroupPaths.vocabularyFileName))
                ).replacements()
                let cleaned = TranscriptPipeline(options: CleanupOptions(style: settings.style)).process(raw, vocabulary: vocabulary)
                return json(["ok": true, "text": cleaned])
            default:
                return json(["ok": false, "error": "unknown"])
            }
        } catch {
            shutdownAudio()
            return json(["ok": false, "error": error.localizedDescription])
        }
    }

    private func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            return #"{"ok":false,"error":"json"}"#
        }
        return text
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
}

private final class ResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func finish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
