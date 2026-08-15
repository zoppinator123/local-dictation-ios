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
        keyboardView?.apply(session.snapshot, holdToTalk: loadSettings().holdToTalk)
    }

    private var openAccessGranted: Bool {
        super.hasFullAccess
    }

    private func persistFullAccessFlag() {
        let url = appGroupDirectory.appendingPathComponent("full-access.json")
        try? FileManager.default.createDirectory(at: appGroupDirectory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(openAccessGranted).write(to: url, options: .atomic)
    }

    private func handleMicDown() {
        refreshSession()
        guard loadSettings().holdToTalk else { return }
        startRecording()
    }

    private func handleMicUp() {
        guard loadSettings().holdToTalk, session.phase == .recording else { return }
        stopRecording()
    }

    private func handleMicTap() {
        refreshSession()
        if loadSettings().holdToTalk { return }
        if session.phase == .recording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard session.handle(.beginHold) else {
            keyboardView?.apply(session.snapshot, holdToTalk: loadSettings().holdToTalk)
            return
        }
        keyboardView?.apply(session.snapshot, holdToTalk: loadSettings().holdToTalk)
        if startInKeyboardRecognition() { return }
        session.fail(KeyboardFailure(
            code: "mic",
            message: "Mic blocked. In Settings, turn Full Access off and on for Local Dictation."
        ))
        keyboardView?.apply(session.snapshot, holdToTalk: loadSettings().holdToTalk)
    }

    private func stopRecording() {
        _ = session.handle(.endHold)
        keyboardView?.apply(session.snapshot, holdToTalk: loadSettings().holdToTalk)
        capture.endAudio()
    }

    private func startInKeyboardRecognition() -> Bool {
        stopAudio()
        let recognizer = SFSpeechRecognizer(locale: Locale.autoupdatingCurrent) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer, recognizer.isAvailable else { return false }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        do {
            try capture.start(appending: request)
        } catch {
            stopAudio()
            return false
        }
        self.recognizer = recognizer
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let result, result.isFinal {
                    self.completeTranscription(result.bestTranscription.formattedString)
                } else if error != nil, self.session.phase == .transcribing || self.session.phase == .recording {
                    if let text = result?.bestTranscription.formattedString, !text.isEmpty {
                        self.completeTranscription(text)
                    } else if self.session.phase == .transcribing {
                        self.session.fail(KeyboardFailure(code: "speech", message: error?.localizedDescription ?? "Transcription failed"))
                        self.keyboardView?.apply(self.session.snapshot, holdToTalk: self.loadSettings().holdToTalk)
                    }
                } else if let result {
                    self.keyboardView?.setPartial(result.bestTranscription.formattedString)
                }
            }
        }
        return true
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
        keyboardView?.apply(session.snapshot, holdToTalk: loadSettings().holdToTalk)
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
        keyboardView?.apply(session.snapshot, holdToTalk: loadSettings().holdToTalk)
    }

    private func startPollingSharedStore() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 700_000_000)
                await MainActor.run { self.consumeSharedTranscriptIfNeeded() }
            }
        }
    }

    private func openHost(_ url: URL) {
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(url)
                return
            }
            responder = current.next
        }
        extensionContext?.open(url)
    }

    private func loadSettings() -> KeyboardSettings {
        (try? FileSettingsPersister(fileURL: appGroupDirectory.appendingPathComponent(AppGroupPaths.settingsFileName)).load()) ?? KeyboardSettings()
    }

    private func loadVocabulary() -> [String: String] {
        VocabularyStore(persister: FileVocabularyPersister(fileURL: appGroupDirectory.appendingPathComponent(AppGroupPaths.vocabularyFileName))).replacements()
    }

    private func stopAudio() {
        task?.cancel()
        capture.stop()
        request = nil
        task = nil
    }
}
