import AVFoundation
import Foundation
import Network
import Speech
import UIKit

/// Flow session: hardware starts in the foreground and stays up.
/// Keyboard taps only open/close a clip. They never call record() / engine.start().
@MainActor
final class DictationDaemon: ObservableObject {
    static let shared = DictationDaemon()
    static let port: UInt16 = 18_765

    @Published private(set) var isArmed = false
    @Published private(set) var isListening = false
    @Published private(set) var lastError: String?

    private var session = HostCaptureSession()
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
        if engine?.isRunning != true || !tapInstalled {
            _ = session.micOff()
        }
        apply(session.startSession(foreground: true))
    }

    func shutdownAudio() {
        _ = session.micOff()
        speechBox.cancel()
        clipBox.clear()
        clipURL = nil
        removeTap()
        engine?.stop()
        engine?.reset()
        engine = nil
        publish()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func startRecording() async throws {
        guard engine?.isRunning == true, tapInstalled else {
            if session.state.micEngaged {
                _ = session.micOff()
            }
            publish()
            throw HostCaptureError.needsForegroundSession
        }
        switch session.startClip(foreground: false) {
        case .failure(let error):
            publish()
            throw error
        case .success:
            break
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-dictation-\(UUID().uuidString).caf")
        let writer = AudioFileWriter(url: url)
        clipURL = url
        clipBox.setWriter(writer)
        speechBox.begin()
        publish()
    }

    func stopRecording() async throws -> String {
        switch session.stopClip() {
        case .failure:
            publish()
            return ""
        case .success:
            break
        }
        let url = clipURL
        clipBox.clear()
        clipURL = nil
        publish()
        let live = await speechBox.finish(timeout: 3.5)
        let fileText: String
        if live.isEmpty, let url {
            try? await Task.sleep(nanoseconds: 80_000_000)
            fileText = (try? await transcribeOffMain(url: url)) ?? ""
        } else {
            fileText = ""
        }
        if let url { try? FileManager.default.removeItem(at: url) }
        let text = live.isEmpty ? fileText : live
        session.finishTranscription(text)
        publish()
        if !text.isEmpty {
            UIPasteboard.general.string = ClipboardDictation.encode(text)
        }
        return text
    }

    private func apply(_ result: Result<HostCaptureCommand, HostCaptureError>) {
        switch result {
        case .success(.startHardware):
            do {
                try armCapture()
                publish()
                lastError = nil
            } catch {
                _ = session.micOff()
                publish()
                lastError = error.localizedDescription
            }
        case .success:
            publish()
        case .failure(let error):
            publish()
            lastError = error.localizedDescription
        }
    }

    private func publish() {
        isArmed = session.state.micEngaged && engine?.isRunning == true
        isListening = session.isListening
        lastError = session.state.lastError
    }

    private func armCapture() throws {
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
        try audio.setActive(true)

        if let engine, engine.isRunning, tapInstalled { return }

        removeTap()
        engine?.stop()
        engine = nil

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let hardware = input.outputFormat(forBus: 0)
        guard hardware.channelCount > 0, hardware.sampleRate > 0 else {
            throw SpeechCaptureError.engineStartFailed("Microphone input is not ready.")
        }
        engine.connect(input, to: engine.mainMixerNode, format: hardware)
        engine.mainMixerNode.outputVolume = 0
        engine.prepare()
        try engine.start()
        self.engine = engine
        try installPersistentTap(format: hardware)
    }

    private func installPersistentTap(format: AVAudioFormat) throws {
        guard let engine else {
            throw SpeechCaptureError.engineStartFailed("Audio engine is not running")
        }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [clipBox, speechBox] buffer, _ in
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
        do {
            switch HostCaptureRoute.parseHTTP(request) {
            case .health:
                return json(["ok": true, "listening": isListening, "armed": isArmed])
            case .start:
                try await startRecording()
                return json(["ok": true])
            case .stop:
                let raw = try await stopRecording()
                return json(["ok": true, "text": raw])
            case .off:
                shutdownAudio()
                return json(["ok": true])
            case .unknown:
                return json(["ok": false, "error": "unknown"])
            }
        } catch {
            publish()
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

    func clear() { setWriter(nil) }

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
    private(set) var hasData = false

    init(url: URL) { self.url = url }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        if file == nil {
            file = try? AVAudioFile(forWriting: url, settings: buffer.format.settings)
        }
        try? file?.write(from: buffer)
        if buffer.frameLength > 0 { hasData = true }
    }
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
            let snap = snapshot()
            if snap.done {
                cancel()
                return snap.text
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let text = snapshot().text
        cancel()
        return text
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
                    } else if error != nil {
                        guard box.finish() else { return }
                        continuation.resume(returning: result?.bestTranscription.formattedString ?? "")
                    }
                }
            }
        }
        group.addTask {
            try await Task.sleep(nanoseconds: 8_000_000_000)
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
