import AVFoundation
import Foundation
import Network
import Speech
import UIKit

/// Wispr-style Flow Session: the host process owns the mic.
/// Keyboard only sends start/stop over localhost.
@MainActor
final class DictationDaemon: ObservableObject {
    static let shared = DictationDaemon()
    static let port: UInt16 = 18_765

    @Published private(set) var isListening = false

    private var listener: NWListener?
    private var engine: AVAudioEngine?
    private var keepAlivePlayer: AVAudioPlayerNode?
    private var tapInstalled = false
    private var fileURL: URL?
    private var fileWriter: AudioFileWriter?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private init() {}

    func start() {
        startSessionAndEngine(forceRebuild: true)
        startListener()
    }

    func startRecording() async throws {
        startSessionAndEngine(forceRebuild: false)
        if nativeInputFormat() == nil {
            startSessionAndEngine(forceRebuild: true)
        }
        guard let engine else {
            throw SpeechCaptureError.engineStartFailed("Audio engine is not running. Open Local Dictation and leave it open.")
        }

        endBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "local-dictation") { [weak self] in
            self?.endBackgroundTask()
        }

        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-dictation-\(UUID().uuidString).caf")
        let writer = AudioFileWriter(url: url)
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            writer.write(buffer)
        }
        tapInstalled = true
        fileURL = url
        fileWriter = writer
        isListening = true
    }

    func stopRecording() async throws -> String {
        defer {
            isListening = false
            endBackgroundTask()
        }
        if tapInstalled, let engine {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        fileWriter = nil
        guard let url = fileURL else {
            throw SpeechCaptureError.engineStartFailed("No audio captured")
        }
        fileURL = nil
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
                return json(["ok": true, "listening": isListening, "engine": engine?.isRunning ?? false])
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

    private func nativeInputFormat() -> AVAudioFormat? {
        guard let engine else { return nil }
        let input = engine.inputNode
        let hardware = input.inputFormat(forBus: 0)
        if hardware.channelCount > 0, hardware.sampleRate > 0 { return hardware }
        let output = input.outputFormat(forBus: 0)
        if output.channelCount > 0, output.sampleRate > 0 { return output }
        return nil
    }

    private func startSessionAndEngine(forceRebuild: Bool) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
        try? session.setPreferredSampleRate(48_000)
        try? session.setActive(true)

        if !forceRebuild, let engine, engine.isRunning, nativeInputFormat() != nil { return }

        if tapInstalled, let engine {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        keepAlivePlayer?.stop()
        engine?.stop()
        keepAlivePlayer = nil
        engine = nil

        let engine = AVAudioEngine()
        engine.connect(engine.inputNode, to: engine.mainMixerNode, format: nil)
        engine.mainMixerNode.outputVolume = 0.001
        engine.prepare()
        do {
            try engine.start()
            let hw = engine.mainMixerNode.outputFormat(forBus: 0)
            if hw.sampleRate > 0, hw.channelCount > 0 {
                let player = AVAudioPlayerNode()
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: hw)
                let frames = AVAudioFrameCount(max(hw.sampleRate / 2, 512))
                if let buffer = AVAudioPCMBuffer(pcmFormat: hw, frameCapacity: frames) {
                    buffer.frameLength = frames
                    player.scheduleBuffer(buffer, at: nil, options: .loops)
                    player.play()
                    keepAlivePlayer = player
                }
            }
            self.engine = engine
        } catch {
            NSLog("DictationDaemon engine start failed: \(error)")
        }
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
}

private final class AudioFileWriter: @unchecked Sendable {
    private let url: URL
    private var file: AVAudioFile?
    private let lock = NSLock()

    init(url: URL) {
        self.url = url
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        if file == nil {
            file = try? AVAudioFile(forWriting: url, settings: buffer.format.settings)
        }
        try? file?.write(from: buffer)
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
