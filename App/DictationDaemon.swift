import AVFoundation
import Foundation
import Network
import Speech
import UIKit

/// Keyboard talks to this over localhost. Mic runs only during a take.
@MainActor
final class DictationDaemon: ObservableObject {
    static let shared = DictationDaemon()
    static let port: UInt16 = 18_765

    @Published private(set) var isArmed = false
    @Published private(set) var isListening = false
    @Published private(set) var lastError: String?

    private var listener: NWListener?
    private var recorder: AVAudioRecorder?
    private var fileURL: URL?
    private var sessionPrimed = false
    private var retainTask: UIBackgroundTaskIdentifier = .invalid

    private init() {}

    func start() {
        startListener()
        retainInBackground()
    }

    func primeSession() {
        startListener()
        retainInBackground()
        do {
            try activateSession()
            sessionPrimed = true
            isArmed = true
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            sessionPrimed = false
            isArmed = false
        }
    }

    func shutdownAudio() {
        recorder?.stop()
        recorder = nil
        fileURL = nil
        isListening = false
        sessionPrimed = false
        isArmed = false
        lastError = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func startRecording() async throws {
        if recorder?.isRecording == true {
            isListening = true
            return
        }
        if !sessionPrimed {
            try activateSession()
            sessionPrimed = true
            isArmed = true
        }
        try beginRecorder()
        isListening = true
        lastError = nil
    }

    func stopRecording() async throws -> String {
        recorder?.stop()
        let url = fileURL
        recorder = nil
        fileURL = nil
        isListening = false
        defer { releaseMicKeepSession() }
        guard let url else { return "" }
        try? await Task.sleep(nanoseconds: 120_000_000)
        let text = (try? await transcribeOffMain(url: url)) ?? ""
        try? FileManager.default.removeItem(at: url)
        if !text.isEmpty {
            UIPasteboard.general.string = ClipboardDictation.encode(text)
        }
        return text
    }

    private func releaseMicKeepSession() {
        recorder?.stop()
        recorder = nil
        isListening = false
    }

    private func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
        try session.setActive(true)
    }

    private func beginRecorder() throws {
        recorder?.stop()
        recorder = nil
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
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        guard recorder.prepareToRecord(), recorder.record() else {
            throw SpeechCaptureError.engineStartFailed("Microphone did not start. Open Local Dictation and tap Start session.")
        }
        self.recorder = recorder
        fileURL = url
    }

    private func transcribeOffMain(url: URL) async throws -> String {
        try await Task.detached {
            try await transcribeWAV(url)
        }.value
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
                return json(["ok": true, "listening": isListening, "armed": isArmed])
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
            case "/off":
                shutdownAudio()
                return json(["ok": true])
            default:
                return json(["ok": false, "error": "unknown"])
            }
        } catch {
            releaseMicKeepSession()
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

    private func retainInBackground() {
        if retainTask != .invalid { return }
        retainTask = UIApplication.shared.beginBackgroundTask(withName: "local-dictation-retain") { [weak self] in
            guard let self else { return }
            if self.retainTask != .invalid {
                UIApplication.shared.endBackgroundTask(self.retainTask)
                self.retainTask = .invalid
            }
        }
    }
}

private func transcribeWAV(_ url: URL) async throws -> String {
    try await withThrowingTaskGroup(of: String.self) { group in
        group.addTask {
            let recognizer = SFSpeechRecognizer(locale: Locale.autoupdatingCurrent)
                ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
            guard let recognizer else { return "" }
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.requiresOnDeviceRecognition = false
            return try await withCheckedThrowingContinuation { continuation in
                let box = ResumeBox()
                recognizer.recognitionTask(with: request) { result, error in
                    if let result, result.isFinal {
                        guard box.finish() else { return }
                        continuation.resume(returning: result.bestTranscription.formattedString)
                    } else if error != nil {
                        guard box.finish() else { return }
                        continuation.resume(returning: result?.bestTranscription.formattedString ?? "")
                    }
                }
            }
        }
        group.addTask {
            try await Task.sleep(nanoseconds: 10_000_000_000)
            return ""
        }
        let first = try await group.next() ?? ""
        group.cancelAll()
        return first
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
