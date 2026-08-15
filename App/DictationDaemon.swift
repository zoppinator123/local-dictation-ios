import AVFoundation
import Foundation
import Network
import Speech
import UIKit

/// Wispr-style Flow Session: the host process owns the mic.
/// The keyboard only sends start/stop over localhost (Full Access allows network).
@MainActor
final class DictationDaemon: ObservableObject {
    static let shared = DictationDaemon()
    static let port: UInt16 = 18_765

    @Published private(set) var isListening = false

    private var listener: NWListener?
    private let capture = SpeechCaptureEngine()
    private var keepAliveEngine: AVAudioEngine?
    private var keepAlivePlayer: AVAudioPlayerNode?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private init() {}

    func start() {
        startKeepAlive()
        startListener()
    }

    func startRecording() async throws {
        endBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "local-dictation") { [weak self] in
            self?.endBackgroundTask()
        }
        stopKeepAliveAudio()
        try await Task.sleep(nanoseconds: 150_000_000)
        try await capture.startFile()
        isListening = true
    }

    func stopRecording() async throws -> String {
        defer {
            isListening = false
            startKeepAlive()
        }
        guard let url = capture.stop(deactivateSession: false) else {
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
            recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    continuation.resume(returning: result.bestTranscription.formattedString)
                } else if let error {
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
                return #"{"ok":true,"listening":\#(isListening)}"#
            case "/start":
                try await startRecording()
                return #"{"ok":true}"#
            case "/stop":
                let raw = try await stopRecording()
                let directory = AppGroupPaths.containerURL() ?? FileManager.default.temporaryDirectory
                let settings = (try? FileSettingsPersister(fileURL: directory.appendingPathComponent(AppGroupPaths.settingsFileName)).load()) ?? KeyboardSettings()
                let vocabulary = VocabularyStore(
                    persister: FileVocabularyPersister(fileURL: directory.appendingPathComponent(AppGroupPaths.vocabularyFileName))
                ).replacements()
                let cleaned = TranscriptPipeline(options: CleanupOptions(style: settings.style)).process(raw, vocabulary: vocabulary)
                let encoded = cleaned.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                return "{\"ok\":true,\"text\":\"\(encoded)\"}"
            default:
                return #"{"ok":false,"error":"unknown"}"#
            }
        } catch {
            let message = error.localizedDescription.replacingOccurrences(of: "\"", with: "'")
            return "{\"ok\":false,\"error\":\"\(message)\"}"
        }
    }

    private func startKeepAlive() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
        try? session.setActive(true)

        if keepAliveEngine != nil { return }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000)!
        buffer.frameLength = 8_000
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0
        do {
            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
            keepAliveEngine = engine
            keepAlivePlayer = player
        } catch {
            NSLog("DictationDaemon keep-alive failed: \(error)")
        }
    }

    private func stopKeepAliveAudio() {
        keepAlivePlayer?.stop()
        keepAliveEngine?.stop()
        keepAlivePlayer = nil
        keepAliveEngine = nil
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
}
