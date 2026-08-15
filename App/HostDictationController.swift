import AVFoundation
import Foundation
import Speech

@MainActor
final class HostDictationController: ObservableObject {
    @Published var isActive = false
    @Published var isRecording = false
    @Published var partialText = ""
    @Published var statusTitle = "Listening in Local Dictation"

    private let capture = SpeechCaptureEngine()
    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?
    private var store: FileSharedDictationStore {
        let url = AppGroupPaths.payloadURL() ?? FileManager.default.temporaryDirectory.appendingPathComponent(AppGroupPaths.payloadFileName)
        return FileSharedDictationStore(fileURL: url)
    }

    func startFromURL() {
        isActive = true
        Task { await start() }
    }

    func start() async {
        stopEngine()
        isRecording = true
        partialText = ""
        statusTitle = "Listening…"
        do {
            try await capture.start()
            try store.save(SharedDictationPayload(status: .recording, generation: UInt64(Date().timeIntervalSince1970), updatedAt: Date()))
        } catch {
            fail(nsErrorText(error))
        }
    }

    func stop() {
        isRecording = false
        transcribe(url: capture.stop())
    }

    func reset() {
        stopEngine()
        isActive = false
        isRecording = false
        partialText = ""
    }

    private func transcribe(url: URL?) {
        guard let url else {
            fail("No audio captured")
            return
        }
        let recognizer = SFSpeechRecognizer(locale: Locale.autoupdatingCurrent) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        self.recognizer = recognizer
        guard let recognizer else {
            fail("Speech recognizer unavailable")
            try? FileManager.default.removeItem(at: url)
            return
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = false
        statusTitle = "Transcribing…"
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                defer { try? FileManager.default.removeItem(at: url) }
                guard let self else { return }
                if let result, result.isFinal {
                    self.finish(result.bestTranscription.formattedString)
                } else if let error {
                    self.fail(nsErrorText(error))
                }
            }
        }
    }

    private func finish(_ raw: String) {
        let directory = AppGroupPaths.containerURL() ?? FileManager.default.temporaryDirectory
        let settings = (try? FileSettingsPersister(fileURL: directory.appendingPathComponent(AppGroupPaths.settingsFileName)).load()) ?? KeyboardSettings()
        let vocabulary = VocabularyStore(
            persister: FileVocabularyPersister(fileURL: directory.appendingPathComponent(AppGroupPaths.vocabularyFileName))
        ).replacements()
        let cleaned = TranscriptPipeline(options: CleanupOptions(style: settings.style)).process(raw, vocabulary: vocabulary)
        try? store.save(SharedDictationPayload(status: .ready, transcript: cleaned, generation: UInt64(Date().timeIntervalSince1970), updatedAt: Date()))
        statusTitle = "Saved. Switch back to the previous app."
        isRecording = false
        partialText = cleaned
        stopEngine()
    }

    private func fail(_ message: String) {
        try? store.save(SharedDictationPayload(status: .failed, errorMessage: message, generation: UInt64(Date().timeIntervalSince1970), updatedAt: Date()))
        statusTitle = message
        isRecording = false
        stopEngine()
    }

    private func stopEngine() {
        task?.cancel()
        capture.stopAndDelete()
        task = nil
    }
}
