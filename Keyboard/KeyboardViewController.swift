import AVFoundation
import Speech
import UIKit

extension SFSpeechAudioBufferRecognitionRequest: SFSpeechBufferAppending {}

final class KeyboardViewController: UIInputViewController {
    private var session = KeyboardSession()
    private var keyboardView: KeyboardChromeView?
    private let capture = SpeechCaptureEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var pollTask: Task<Void, Never>?
    private var lastInsertedGeneration: UInt64 = 0
    private var lastCaptureError: String?
    private var captureToken = UUID()
    private var usingLiveCapture = false

    private var appGroupDirectory: URL {
        AppGroupPaths.containerURL() ?? FileManager.default.temporaryDirectory
    }

    private var payloadStore: FileSharedDictationStore {
        FileSharedDictationStore(fileURL: appGroupDirectory.appendingPathComponent(AppGroupPaths.payloadFileName))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let chrome = KeyboardChromeView(frame: .zero)
        chrome.translatesAutoresizingMaskIntoConstraints = false
        chrome.onMicDown = { [weak self] in self?.handleMicDown() }
        chrome.onMicUp = { [weak self] in self?.handleMicUp() }
        chrome.onMicTap = { [weak self] in self?.handleMicTap() }
        chrome.onKey = { [weak self] text in self?.insertTyped(text) }
        chrome.onDelete = { [weak self] in self?.textDocumentProxy.deleteBackward() }
        chrome.onSpace = { [weak self] in self?.textDocumentProxy.insertText(" ") }
        chrome.onReturn = { [weak self] in self?.textDocumentProxy.insertText("\n") }
        chrome.onNextKeyboard = { [weak self] in self?.advanceToNextInputMode() }
        chrome.onOpenApp = { [weak self] in self?.openHost(AppRoute.root.url) }
        chrome.onMicOff = { [weak self] in self?.turnMicOff() }
        view.addSubview(chrome)
        NSLayoutConstraint.activate([
            chrome.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            chrome.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            chrome.topAnchor.constraint(equalTo: view.topAnchor),
            chrome.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            chrome.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
        ])
        keyboardView = chrome
        persistFullAccessFlag()
        refreshSession()
        consumeSharedTranscriptIfNeeded()
        startPollingSharedStore()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        persistFullAccessFlag()
        refreshSession()
        consumeSharedTranscriptIfNeeded()
    }

    deinit {
        pollTask?.cancel()
        stopAudio()
    }

    private func refreshSession() {
        session.applyReadiness(
            KeyboardReadiness(
                keyboardEnabled: true,
                fullAccessGranted: openAccessGranted,
                microphoneGranted: AVAudioApplication.shared.recordPermission != .denied,
                speechAuthorized: SFSpeechRecognizer.authorizationStatus() != .denied
            )
        )
        keyboardView?.apply(session.snapshot, holdToTalk: false)
    }

    private var openAccessGranted: Bool {
        super.hasFullAccess
    }

    private func persistFullAccessFlag() {
        let url = appGroupDirectory.appendingPathComponent("full-access.json")
        try? FileManager.default.createDirectory(at: appGroupDirectory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(openAccessGranted).write(to: url, options: .atomic)
    }

    private func handleMicDown() {}

    private func handleMicUp() {}

    private var connecting = false

    private func handleMicTap() {
        refreshSession()
        if connecting { return }
        if session.phase == .recording {
            stopRecording()
        } else if session.phase == .transcribing {
            return
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        connecting = true
        lastCaptureError = nil
        usingLiveCapture = false
        let token = UUID()
        captureToken = token
        keyboardView?.setPartial("Starting…")
        Task { [weak self] in
            guard let self else { return }
            defer { self.connecting = false }
            do {
                try await DictationClient.start()
                guard self.captureToken == token else {
                    _ = try? await DictationClient.stop()
                    return
                }
                guard self.session.handle(.beginHold) else {
                    _ = try? await DictationClient.stop()
                    self.keyboardView?.apply(self.session.snapshot, holdToTalk: false)
                    return
                }
                self.keyboardView?.apply(self.session.snapshot, holdToTalk: false)
            } catch {
                guard self.captureToken == token else { return }
                self.session.fail(KeyboardFailure(code: "mic", message: self.friendlyMicError(error)))
                self.keyboardView?.apply(self.session.snapshot, holdToTalk: false)
            }
        }
    }

    private func beginCapture() async throws {
        let recognizer = SFSpeechRecognizer(locale: Locale.autoupdatingCurrent) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer else {
            throw SpeechCaptureError.engineStartFailed("Speech recognizer unavailable")
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false
        do {
            try await capture.startLive(appending: request)
            usingLiveCapture = true
            self.recognizer = recognizer
            self.request = request
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let result, result.isFinal {
                        self.completeTranscription(result.bestTranscription.formattedString)
                    } else if let result {
                        self.keyboardView?.setPartial(result.bestTranscription.formattedString)
                    } else if let error, self.session.phase == .transcribing {
                        self.session.fail(KeyboardFailure(code: "speech", message: nsErrorText(error)))
                        self.keyboardView?.apply(self.session.snapshot, holdToTalk: false)
                    }
                }
            }
            return
        } catch {
            lastCaptureError = "live \(captureErrorText(error))"
            throw error
        }
    }

    private func handOffToHost() {
        capture.stopAndDelete()
        usingLiveCapture = false
        _ = session.handle(.cancel)
        session.fail(KeyboardFailure(code: "handoff", message: "Open Local Dictation once, then tap the mic again."))
        keyboardView?.apply(session.snapshot, holdToTalk: false)
        openHost(AppRoute.root.url)
    }

    private func friendlyMicError(_ error: Error) -> String {
        let text = error.localizedDescription + " " + nsErrorText(error)
        if text.contains("560557684") || text.contains("!int") || text.contains("avfaudi") || text.contains("coreaudio") {
            return "Tap the mic again."
        }
        return error.localizedDescription
    }

    private func captureErrorText(_ error: Error) -> String {
        let access = openAccessGranted ? "fa=1" : "fa=0"
        return "\(access) \(error.localizedDescription)"
    }

    private func stopRecording() {
        captureToken = UUID()
        connecting = false
        _ = session.handle(.endHold)
        keyboardView?.apply(session.snapshot, holdToTalk: false)
        Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await DictationClient.stop()
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    self.session.fail(KeyboardFailure(code: "empty", message: "Didn't catch that. Tap Start session, then tap the mic and speak."))
                    self.keyboardView?.apply(self.session.snapshot, holdToTalk: false)
                    return
                }
                self.completeTranscription(trimmed)
            } catch {
                self.session.fail(KeyboardFailure(code: "speech", message: self.friendlyMicError(error)))
                self.keyboardView?.apply(self.session.snapshot, holdToTalk: false)
            }
        }
    }

    private func transcribeFile(_ url: URL?) {
        guard let url else {
            session.fail(KeyboardFailure(code: "mic", message: lastCaptureError ?? "No audio captured"))
            keyboardView?.apply(session.snapshot, holdToTalk: false)
            return
        }
        let recognizer = SFSpeechRecognizer(locale: Locale.autoupdatingCurrent) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer else {
            try? FileManager.default.removeItem(at: url)
            session.fail(KeyboardFailure(code: "speech", message: "Speech recognizer unavailable"))
            keyboardView?.apply(session.snapshot, holdToTalk: false)
            return
        }
        self.recognizer = recognizer
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = false
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                defer { try? FileManager.default.removeItem(at: url) }
                guard let self else { return }
                if let result, result.isFinal {
                    self.completeTranscription(result.bestTranscription.formattedString)
                } else if let error {
                    self.session.fail(KeyboardFailure(code: "speech", message: nsErrorText(error)))
                    self.keyboardView?.apply(self.session.snapshot, holdToTalk: false)
                }
            }
        }
    }

    private func completeTranscription(_ raw: String) {
        stopAudio()
        if session.phase == .recording {
            _ = session.handle(.endHold)
        }
        let cleaned = TranscriptPipeline(options: CleanupOptions(style: loadSettings().style))
            .process(raw, vocabulary: loadVocabulary())
        session.finishTranscription(cleaned)
        if session.phase == .inserting, let text = session.lastTranscript {
            insertDictation(text)
            session.finishInsertion()
        }
        keyboardView?.apply(session.snapshot, holdToTalk: false)
    }

    private func insertDictation(_ text: String) {
        let preceding = textDocumentProxy.documentContextBeforeInput
        let plan = InsertionPlanner.plan(cleaned: text, precedingText: preceding)
        textDocumentProxy.insertText(plan.insertedText)
    }

    private func insertTyped(_ text: String) {
        textDocumentProxy.insertText(text)
    }

    private func consumeSharedTranscriptIfNeeded() {
        guard let payload = try? payloadStore.load() else { return }
        guard payload.generation != lastInsertedGeneration else { return }
        if payload.status == .ready, let transcript = payload.transcript, !transcript.isEmpty {
            insertDictation(transcript)
            lastInsertedGeneration = payload.generation
            try? payloadStore.save(SharedDictationPayload(status: .idle, generation: payload.generation, updatedAt: Date()))
            session.finishInsertion()
        } else if payload.status == .failed {
            session.fail(KeyboardFailure(code: "host", message: payload.errorMessage ?? "Dictation failed"))
            lastInsertedGeneration = payload.generation
        }
        if let clip = UIPasteboard.general.string, let transcript = ClipboardDictation.decode(clip) {
            insertDictation(transcript)
            UIPasteboard.general.string = ""
            session.finishInsertion()
        }
        keyboardView?.apply(session.snapshot, holdToTalk: false)
    }

    private func startPollingSharedStore() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                await MainActor.run { self.consumeSharedTranscriptIfNeeded() }
            }
        }
    }

    private func turnMicOff() {
        captureToken = UUID()
        connecting = false
        if session.phase == .recording {
            _ = session.handle(.cancel)
        }
        keyboardView?.apply(session.snapshot, holdToTalk: false)
        Task { await DictationClient.turnOff() }
    }

    private func openHost(_ url: URL) {
        if let context = extensionContext {
            context.open(url) { [weak self] success in
                if !success {
                    self?.openViaResponder(url)
                }
            }
            return
        }
        openViaResponder(url)
    }

    private func openViaResponder(_ url: URL) {
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(url)
                return
            }
            responder = current.next
        }
    }

    private func loadSettings() -> KeyboardSettings {
        (try? FileSettingsPersister(fileURL: appGroupDirectory.appendingPathComponent(AppGroupPaths.settingsFileName)).load()) ?? KeyboardSettings()
    }

    private func loadVocabulary() -> [String: String] {
        VocabularyStore(persister: FileVocabularyPersister(fileURL: appGroupDirectory.appendingPathComponent(AppGroupPaths.vocabularyFileName))).replacements()
    }

    private func stopAudio() {
        task?.cancel()
        capture.stopAndDelete()
        task = nil
    }
}
