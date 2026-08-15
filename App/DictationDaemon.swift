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
    @Published private(set) var lastError: String?

    private var listener: NWListener?
    private var engine: AVAudioEngine?
    private var tapInstalled = false
    private var clipURL: URL?
    private let clipBox = AudioFileWriterBox()
    private let speechBox = SpeechBox()
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
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            isArmed = false
        }
    }

    func shutdownAudio() {
        clipBox.clear()
        speechBox.cancel()
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
            throw SpeechCaptureError.engineStartFailed("Tap Start session in Local Dictation first.")
        }
        if !tapInstalled {
            try installPersistentTap()
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-dictation-\(UUID().uuidString).caf")
        let writer = AudioFileWriter(url: url)
        clipURL = url
        clipBox.setWriter(writer)
        speechBox.begin()
        isListening = true
    }

    func stopRecording() async throws -> String {
        let url = clipURL
        clipBox.clear()
        clipURL = nil
        isListening = false
        let live = await speechBox.finish(timeout: 2.5)
        if !live.isEmpty {
            try? url.map { try? FileManager.default.removeItem(at: $0) }
            UIPasteboard.general.string = ClipboardDictation.encode(live)
            return live
        }
        guard let url else { return "" }
        try? await Task.sleep(nanoseconds: 100_000_000)
        let text = (try? await transcribeOffMain(url: url)) ?? ""
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
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [clipBox, speechBox] buffer, _ in
            clipBox.write(buffer)
            speechBox.append(buffer)
        }
        tapInstalled = true
    }

    private func removeTap() {
        if tapInstalled, let engine {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
    }

    private func transcribeOffMain(url: URL) async throws -> String {
        try await Task.detached {
            try await transcribeURL(url)
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
        if buffer.frameLength > 0 { hasData = true }
    }

    private(set) var hasData = false
}

private final class SpeechBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var latest = ""
    private var isFinal = false

    func begin() {
        cancel()
        let recognizer = SFSpeechRecognizer(locale: Locale.autoupdatingCurrent)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false
        lock.lock()
        self.request = request
        latest = ""
        isFinal = false
        lock.unlock()
        task = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let self, let result else { return }
            self.lock.lock()
            self.latest = result.bestTranscription.formattedString
            if result.isFinal { self.isFinal = true }
            self.lock.unlock()
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let request = request
        lock.unlock()
        request?.append(buffer)
    }

    func finish(timeout: TimeInterval) async -> String {
        endRequest()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if snapshot().done {
                let text = snapshot().text
                cancel()
                return text
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let text = snapshot().text
        cancel()
        return text
    }

    private func endRequest() {
        lock.lock()
        request?.endAudio()
        lock.unlock()
    }

    private func snapshot() -> (done: Bool, text: String) {
        lock.lock()
        defer { lock.unlock() }
        return (isFinal, latest)
    }

    func cancel() {
        lock.lock()
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isFinal = false
        lock.unlock()
    }
}

private func transcribeURL(_ url: URL) async throws -> String {
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
                    } else if let error {
                        guard box.finish() else { return }
                        continuation.resume(returning: "")
                        _ = error
                    }
                }
            }
        }
        group.addTask {
            try await Task.sleep(nanoseconds: 6_000_000_000)
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
