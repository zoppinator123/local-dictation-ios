import AVFoundation
import Foundation
import Network
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
    private var listenerLifecycle = ListenerLifecycleGuard()
    private var engine: AVAudioEngine?
    private var tapInstalled = false
    private let pcmBox = PCMClipBuffer()
    private let transcriptionService = TranscriptionService()
    private let takeGeneration = TakeGenerationGuard()
    private let authTokenStore = SharedAuthTokenStore()
    private var authToken: String?
    private var retainTask: UIBackgroundTaskIdentifier = .invalid
    private var commandBusy = false
    private var activationTask: Task<Void, Never>?
    private var activationGeneration: UInt64 = 0
    private let networkQueue = DispatchQueue(label: "com.jackzoppa.LocalDictation.listener", qos: .userInitiated)
    private var notificationTokens: [NSObjectProtocol] = []

    private init() {
        transcriptionService.onDiagnostic = { [weak self] message in
            self?.event(message)
        }
        observeSafetyNotifications()
    }

    func start() {
        event("daemon start")
        restartAuthenticatedListener()
        retainInBackground()
    }

    func primeSession() {
        takeGeneration.advance()
        event("Start session tapped")
        startAuthenticatedListener()
        retainInBackground()
        if engine?.isRunning != true || !tapInstalled {
            _ = session.micOff()
        }
        apply(session.startSession(foreground: true))
        transcriptionService.prepareForSession()
    }

    func schedulePrimeSession() {
        activationGeneration &+= 1
        let generation = activationGeneration
        activationTask?.cancel()
        activationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                return
            }
            guard let self, self.activationGeneration == generation else { return }
            self.activationTask = nil
            self.primeSession()
        }
    }

    func shutdownAudio() {
        event("OFF requested")
        activationGeneration &+= 1
        activationTask?.cancel()
        activationTask = nil
        let offGeneration = takeGeneration.advance()
        commandBusy = false
        _ = session.micOff()
        pcmBox.cancelClip()
        transcriptionService.cancelAndUnload()
        removeTap()
        engine?.stop()
        engine?.reset()
        engine = nil
        endRetain()
        publish()
        deactivateAudioSession(attempt: 1, targetGeneration: offGeneration)
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
        pcmBox.beginClip()
        publish()
    }

    func stopRecording() async throws -> String {
        event("/stop received")
        let stopGeneration = takeGeneration.snapshot()
        switch session.stopClip() {
        case .failure:
            publish()
            return ""
        case .success:
            break
        }
        publish()
        let clip = pcmBox.takeClip()
        event(
            "take captured source_samples=\(clip.frameCount) source_rate=\(Int(clip.sampleRate ?? 0)) channels=\(clip.channelCount) overflow=\(clip.overflowed)"
        )
        do {
            let resampleStarted = Date()
            let converted = try PCMResampler.convertToWhisperPCM(clip)
            let resampleMS = Int(Date().timeIntervalSince(resampleStarted) * 1_000)
            event(
                "take resample_ms=\(resampleMS) source_samples=\(converted.sourceFrameCount) source_rate=\(Int(converted.sourceSampleRate)) source_channels=\(converted.sourceChannelCount) output_samples=\(converted.samples.count) output_rate=\(converted.sampleRate)"
            )
            let outcome = try await transcriptionService.transcribe(samples: converted.samples)
            guard takeGeneration.isCurrent(stopGeneration) else {
                event("discarded stale /stop after OFF")
                return ""
            }
            let text = outcome.text.trimmingCharacters(in: .whitespacesAndNewlines)
            session.finishTranscription(text)
            publish()
            return text
        } catch {
            guard takeGeneration.isCurrent(stopGeneration) else {
                event("discarded failed stale /stop after OFF")
                return ""
            }
            session.failTranscription(error.localizedDescription)
            publish()
            event("take failed primary=WhisperKit fallback=AppleSpeech reason=\(error.localizedDescription)")
            throw error
        }
    }

    private func apply(_ result: Result<HostCaptureCommand, HostCaptureError>) {
        switch result {
        case .success(.startHardware):
            do {
                try armCapture()
                publish()
                lastError = nil
                event("armCapture succeeded engine=\(engine?.isRunning == true) tap=\(tapInstalled)")
            } catch {
                _ = session.micOff()
                publish()
                lastError = error.localizedDescription
                event("armCapture failed: \(error.localizedDescription)")
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
        let hardware = input.inputFormat(forBus: 0)
        guard hardware.channelCount > 0, hardware.sampleRate > 0 else {
            try? audio.setActive(false, options: .notifyOthersOnDeactivation)
            throw SpeechCaptureError.engineStartFailed("Microphone input is not ready.")
        }
        self.engine = engine
        do {
            try installPersistentTap()
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

    private func installPersistentTap() throws {
        guard let engine else {
            throw SpeechCaptureError.engineStartFailed("Audio engine is not running")
        }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        let handler = Self.makeAudioTapHandler(pcmBox)
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil, block: handler)
        tapInstalled = true
    }

    nonisolated private static func makeAudioTapHandler(_ pcmBox: PCMClipBuffer) -> AVAudioNodeTapBlock {
        { buffer, _ in
            guard buffer.format.commonFormat == .pcmFormatFloat32,
                  let data = buffer.floatChannelData else { return }
            pcmBox.appendFloat32(
                channelData: data,
                frameCount: Int(buffer.frameLength),
                channelCount: Int(buffer.format.channelCount),
                sampleRate: buffer.format.sampleRate,
                interleaved: buffer.format.isInterleaved
            )
        }
    }

    private func removeTap() {
        if tapInstalled, let engine {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
    }

    private func startAuthenticatedListener() {
        if authToken == nil {
            do {
                authToken = try authTokenStore.loadOrCreate()
                event("localhost authentication ready access_group=\(SharedAuthTokenStore.accessGroup)")
            } catch {
                listenerLifecycle.invalidate()
                listener?.cancel()
                listener = nil
                lastError = error.localizedDescription
                event("localhost authentication failed closed: \(error.localizedDescription)")
                return
            }
        }
        startListener()
    }

    private func restartAuthenticatedListener() {
        listenerLifecycle.invalidate()
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        startAuthenticatedListener()
    }

    private func startListener() {
        guard listener == nil else { return }
        do {
            let port = NWEndpoint.Port(rawValue: Self.port)!
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
            let listener = try NWListener(using: parameters)
            let generation = listenerLifecycle.beginReplacement()
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.listenerLifecycle.isCurrent(generation) else { return }
                    self.event("listener \(String(describing: state))")
                    let lifecycleState: ListenerLifecycleState?
                    switch state {
                    case .failed: lifecycleState = .failed
                    case .cancelled: lifecycleState = .cancelled
                    case .ready: lifecycleState = .ready
                    default: lifecycleState = nil
                    }
                    if let lifecycleState, ListenerLifecycleGuard.isTerminal(lifecycleState) {
                        self.listener = nil
                    }
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
                guard LocalhostAuthentication.isAuthorized(request: request, expectedToken: self.authToken) else {
                    self.event("localhost authentication rejected")
                    let body = self.json(["ok": false, "error": "unauthorized"])
                    self.sendHTTP(status: "401 Unauthorized", body: body, on: connection)
                    return
                }
                let route = HostCaptureRoute.parseHTTP(request)
                guard route != .unknown else {
                    let body = self.json(["ok": false, "error": "unknown"])
                    self.sendHTTP(status: "404 Not Found", body: body, on: connection)
                    return
                }
                guard LocalhostRequestPolicy.isAllowed(request: request, route: route) else {
                    let body = self.json(["ok": false, "error": "method not allowed"])
                    self.sendHTTP(status: "405 Method Not Allowed", body: body, on: connection)
                    return
                }
                self.event("request \(route.rawValue)")
                let body = await self.handle(request)
                self.sendHTTP(status: "200 OK", body: body, on: connection)
            }
        }
    }

    private func sendHTTP(status: String, body: String, on connection: NWConnection) {
        let response = Data(
            "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8
        )
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
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
        appendDiagnosticLine(line)
        NSLog("LocalDictation: \(line)")
    }

    private func appendDiagnosticLine(_ line: String) {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = directory.appendingPathComponent("local-dictation-diagnostics.log")
        let data = Data((line + "\n").utf8)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: data)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // In-app diagnostics remain available even if durable logging fails.
        }
    }

    private func deactivateAudioSession(attempt: Int, targetGeneration: UInt64) {
        guard takeGeneration.isCurrent(targetGeneration) else { return }
        let audio = AVAudioSession.sharedInstance()
        do {
            try audio.setActive(false, options: .notifyOthersOnDeactivation)
            try? audio.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            isArmed = false
            if lastError?.contains("could not be turned off") == true { lastError = nil }
            event("OFF confirmed")
        } catch {
            isArmed = true
            lastError = "Microphone could not be turned off (attempt \(attempt)): \(error.localizedDescription)"
            event("OFF failed attempt \(attempt): \(error.localizedDescription)")
            guard attempt < 3 else { return }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 250_000_000)
                self?.deactivateAudioSession(attempt: attempt + 1, targetGeneration: targetGeneration)
            }
        }
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

    private func observeSafetyNotifications() {
        let center = NotificationCenter.default
        notificationTokens.append(
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
                guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else { return }
                Task { @MainActor in
                    guard let self,
                          let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                    self.event("audio interruption type=\(type == .began ? "began" : "ended")")
                    if type == .began { self.shutdownAudio() }
                }
            }
        )
        notificationTokens.append(
            center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor in
                    self?.event("thermal state changed raw=\(ProcessInfo.processInfo.thermalState.rawValue)")
                }
            }
        )
        notificationTokens.append(
            center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor in
                    self?.event("memory warning armed=\(self?.isArmed == true)")
                }
            }
        )
    }
}
