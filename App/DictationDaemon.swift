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
    @Published private(set) var events: [String] = []

    private var session = HostCaptureSession()
    private var listener: NWListener?
    private var engine: AVAudioEngine?
    private var tapInstalled = false
    private let speechBox = SpeechBox()
    private var retainTask: UIBackgroundTaskIdentifier = .invalid
    private var commandBusy = false
    private let networkQueue = DispatchQueue(label: "com.jackzoppa.LocalDictation.listener", qos: .userInitiated)

    private init() {}

    func start() {
        event("daemon start")
        startListener()
        retainInBackground()
    }

    func primeSession() {
        event("Start session tapped")
        startListener()
        retainInBackground()
        if engine?.isRunning != true || !tapInstalled {
            _ = session.micOff()
        }
        apply(session.startSession(foreground: true))
    }

    func shutdownAudio() {
        event("OFF requested")
        commandBusy = false
        _ = session.micOff()
        speechBox.cancel()
        removeTap()
        engine?.stop()
        engine?.reset()
        engine = nil
        endRetain()
        let audio = AVAudioSession.sharedInstance()
        try? audio.setActive(false, options: .notifyOthersOnDeactivation)
        try? audio.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        publish()
    }

    func startRecording() async throws {
        event("/start received engine=\(engine?.isRunning == true) tap=\(tapInstalled)")
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
        guard speechBox.begin() else {
            session.failTranscription("Speech recognition is unavailable. Check your connection and Speech permission.")
            publish()
            throw SpeechCaptureError.engineStartFailed("Speech recognition is unavailable")
        }
        publish()
    }

    func stopRecording() async throws -> String {
        event("/stop received")
        switch session.stopClip() {
        case .failure:
            publish()
            return ""
        case .success:
            break
        }
        publish()
        let text = await speechBox.finish(timeout: 3.5)
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
        isArmed = session.state.micEngaged || engine?.isRunning == true
        isListening = session.isListening
        lastError = session.state.lastError
    }

    private func armCapture() throws {
#if targetEnvironment(simulator)
        throw SpeechCaptureError.engineStartFailed("Simulator cannot start the mic. Plug in the iPhone to test dictation.")
#else
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.record, mode: .measurement, options: [])
        try audio.setActive(true)

        if let engine, engine.isRunning, tapInstalled { return }

        removeTap()
        engine?.stop()
        engine?.reset()
        engine = nil

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let hardware = input.outputFormat(forBus: 0)
        guard hardware.channelCount > 0, hardware.sampleRate > 0 else {
            try? audio.setActive(false, options: .notifyOthersOnDeactivation)
            throw SpeechCaptureError.engineStartFailed("Microphone input is not ready.")
        }
        self.engine = engine
        do {
            try installPersistentTap(format: hardware)
            engine.prepare()
            try engine.start()
        } catch {
            removeTap()
            engine.stop()
            engine.reset()
            self.engine = nil
            try? audio.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
#endif
    }

    private func installPersistentTap(format: AVAudioFormat) throws {
        guard let engine else {
            throw SpeechCaptureError.engineStartFailed("Audio engine is not running")
        }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [speechBox] buffer, _ in
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

    private func startListener() {
        guard listener == nil else { return }
        do {
            let port = NWEndpoint.Port(rawValue: Self.port)!
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    self?.event("listener \(String(describing: state))")
                    if case .failed = state { self?.listener = nil }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: self?.networkQueue ?? .global(qos: .userInitiated))
                Task { @MainActor in
                    self?.event("connection accepted")
                    self?.serve(connection)
                }
            }
            listener.start(queue: networkQueue)
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
                let route = HostCaptureRoute.parseHTTP(request)
                self.event("request \(route.rawValue)")
                let body = await self.handle(request)
                let response = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8)
                connection.send(content: response, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    private func handle(_ request: String) async -> String {
        let route = HostCaptureRoute.parseHTTP(request)
        if route == .health {
            return json(["ok": true, "listening": isListening, "armed": isArmed])
        }
        if route == .off {
            shutdownAudio()
            return json(["ok": true])
        }
        if commandBusy {
            return json(["ok": false, "error": "Busy. Tap again."])
        }
        commandBusy = true
        defer { commandBusy = false }
        do {
            switch route {
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

    private func event(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let line = "\(formatter.string(from: Date()))  \(message)"
        events.append(line)
        if events.count > 30 { events.removeFirst(events.count - 30) }
        NSLog("LocalDictation: \(line)")
    }

    private func endRetain() {
        if retainTask != .invalid {
            UIApplication.shared.endBackgroundTask(retainTask)
            retainTask = .invalid
        }
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

private final class SpeechBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var latest = ""
    private var isFinal = false

    func begin() -> Bool {
        cancel()
        let recognizer = SFSpeechRecognizer(locale: Locale.autoupdatingCurrent)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer, recognizer.isAvailable else { return false }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false
        lock.lock()
        self.request = request
        latest = ""
        isFinal = false
        lock.unlock()
        let recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            self.lock.lock()
            if let result {
                self.latest = result.bestTranscription.formattedString
                if result.isFinal { self.isFinal = true }
            }
            if error != nil { self.isFinal = true }
            self.lock.unlock()
        }
        lock.lock()
        task = recognitionTask
        lock.unlock()
        return true
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
        let request = request
        let task = task
        self.request = nil
        self.task = nil
        isFinal = false
        lock.unlock()
        request?.endAudio()
        task?.cancel()
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
