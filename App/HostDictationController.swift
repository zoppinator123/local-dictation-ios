import AVFoundation
import Foundation
import Speech

extension SFSpeechAudioBufferRecognitionRequest: SFSpeechBufferAppending {}

@MainActor
final class HostDictationController: ObservableObject {
    @Published var isActive = false
    @Published var isRecording = false
    @Published var partialText = ""
    @Published var statusTitle = "Listening in Local Dictation"

    private let capture = SpeechCaptureEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var store: FileSharedDictationStore {
        let url = AppGroupPaths.payloadURL() ?? FileManager.default.temporaryDirectory.appendingPathComponent(AppGroupPaths.payloadFileName)
        return FileSharedDictationStore(fileURL: url)
    }

    func startFromURL() {
        isActive = true
        start()
    }

    func start() {
        stopEngine()
        isRecording = true
        partialText = ""
        statusTitle = "Listening…"

        let recognizer = SFSpeechRecognizer(locale: Locale.autoupdatingCurrent) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        self.recognizer = recognizer
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer?.supportsOnDeviceRecognition == true {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        do {
            try capture.start(appending: request)
            try store.save(SharedDictationPayload(status: .recording, generation: UInt64(Date().timeIntervalSince1970), updatedAt: Date()))
        } catch {
            fail(error.localizedDescription)
            return
        }

        task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.partialText = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.finish(result.bestTranscription.formattedString)
                    }
                } else if let error {
                    self.fail(error.localizedDescription)
                }
            }
        }
    }

    func stop() {
        capture.endAudio()
        isRecording = false
        if !partialText.isEmpty {
            finish(partialText)
        }
    }

    func reset() {
        stopEngine()
        isActive = false
        isRecording = false
        partialText = ""
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
        capture.stop()
        request = nil
        task = nil
    }
}
