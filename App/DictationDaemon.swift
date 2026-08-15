import AVFoundation
import Foundation
import Network
import Speech
import UIKit

/// Wispr-style session: the host starts the mic in the foreground and keeps it.
/// Keyboard taps only open/close a clip on that live stream.
@MainActor
final class DictationDaemon: ObservableObject {
    static let shared = DictationDaemon()
    static let port: UInt16 = 18_765

    @Published private(set) var isArmed = false
    @Published private(set) var isListening = false

    private var listener: NWListener?
    private var engine: AVAudioEngine?
    private var tapInstalled = false
    private var clipURL: URL?
    private let clipBox = AudioFileWriterBox()
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
            try armCapture()
        } catch {
            NSLog("DictationDaemon arm failed: \(error)")
        }
    }

    func shutdownAudio() {
        clipBox.clear()
        clipURL = nil
        isListening = false
        removeTap()
        engine?.stop()
        engine?.reset()
        engine = nil
        isArmed = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func startRecording() async throws {
        if engine?.isRunning != true {
            throw SpeechCaptureError.engineStartFailed("Open Local Dictation to start a session, then tap again.")
        }
        if !tapInstalled {
            try installPersistentTap()
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-dictation-\(UUID().uuidString).caf")
        clipURL = url
        clipBox.setWriter(AudioFileWriter(url: url))
        isListening = true
    }

    func stopRecording() async throws -> String {
        let url = clipURL
        clipBox.clear()
        clipURL = nil
        isListening = false
        guard let url else {
            throw SpeechCaptureError.engineStartFailed("No audio captured")
        }
        try? await Task.sleep(nanoseconds: 80_000_000)
        let text = try await transcribe(url: url)
        try? FileManager.default.removeItem(at: url)
        if !text.isEmpty {
            UIPasteboard.general.string = ClipboardDictation.encode(text)
        }
        return text
    }

    private func armCapture() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
        try session.setActive(true)

        if let engine, engine.isRunning, tapInstalled {
            isArmed = true
            return
        }

        removeTap()
        engine?.stop()
        engine = nil

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let hardware = input.outputFormat(forBus: 0)
        if hardware.channelCount > 0, hardware.sampleRate > 0 {
            engine.connect(input, to: engine.mainMixerNode, format: hardware)
        }
        engine.mainMixerNode.outputVolume = 0
        engine.prepare()
        try engine.start()
        self.engine = engine
        try installPersistentTap()
        isArmed = true
    }

    private func installPersistentTap() throws {
        guard let engine else {
            throw SpeechCaptureError.engineStartFailed("Audio engine is not running")
        }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [clipBox] buffer, _ in
            clipBox.write(buffer)
        }
        tapInstalled = true
    }

    private func removeTap() {
        if tapInstalled, let engine {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
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
            default:
                return json(["ok": false, "error": "unknown"])
            }
        } catch {
            clipBox.clear()
            isListening = false
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

private final class AudioFileWriterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var writer: AudioFileWriter?

    func setWriter(_ writer: AudioFileWriter?) {
        lock.lock()
        self.writer = writer
        lock.unlock()
    }

    func clear() {
        setWriter(nil)
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let writer = writer
        lock.unlock()
        writer?.write(buffer)
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
