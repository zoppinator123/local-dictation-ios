import AVFoundation
import Foundation
import Speech

@MainActor
final class HostDictationController: ObservableObject {
    @Published var isActive = false
    @Published var isRecording = false
    @Published var partialText = ""
    @Published var statusTitle = "Listening in Local Dictation"

    private var audioEngine: AVAudioEngine?
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
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        self.recognizer = recognizer
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        self.request = request

        let engine = AVAudioEngine()
        audioEngine = engine
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            try engine.start()
            try store.save(SharedDictationPayload(status: .recording, generation: UInt64(Date().timeIntervalSince1970), updatedAt: Date()))
        } catch {
            fail(error.localizedDescription)
            return
        }

        task = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                if let result {
                    self?.partialText = result.bestTranscription.formattedString
                    if result.isFinal {
                        self?.finish(result.bestTranscription.formattedString)
                    }
                } else if let error {
                    self?.fail(error.localizedDescription)
                }
            }
        }
    }

    func stop() {
        request?.endAudio()
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
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
        let settings = (try? FileSettingsPersister(fileURL: (AppGroupPaths.containerURL() ?? FileManager.default.temporaryDirectory).appendingPathComponent(AppGroupPaths.settingsFileName)).load()) ?? KeyboardSettings()
        let vocabulary = VocabularyStore(
            persister: FileVocabularyPersister(
                fileURL: (AppGroupPaths.containerURL() ?? FileManager.default.temporaryDirectory).appendingPathComponent(AppGroupPaths.vocabularyFileName)
            )
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
        request?.endAudio()
        task?.cancel()
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        request = nil
        task = nil
    }
}
