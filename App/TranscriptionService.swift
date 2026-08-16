import AVFoundation
import CryptoKit
import Darwin
import Foundation
import Speech
import WhisperKit

@MainActor
final class TranscriptionService {
    enum ModelStatus: Equatable {
        case idle
        case loading(path: String)
        case ready(path: String, loadMilliseconds: Int, residentMemoryMB: Int)
        case failed(path: String?, reason: String)

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }

        var failureReason: String? {
            if case .failed(_, let reason) = self { return reason }
            return nil
        }
    }

    var onDiagnostic: ((String) -> Void)?
    private(set) var status: ModelStatus = .idle

    private var whisperKit: WhisperKit?
    private var preparationTask: Task<Void, Never>?
    private var preparationGeneration: UInt64?
    private var inferenceTask: Task<Void, Never>?
    private var inferenceGeneration: UInt64?
    private var timeoutTask: Task<Void, Never>?
    private var timeoutGeneration: UInt64?
    private var inferenceContinuation: OneShotContinuation<String>?
    private var modelGeneration: UInt64 = 0
    private var takeGeneration: UInt64 = 0
    private let appleSpeech = AppleSpeechFallback()
    private let timeoutNanoseconds: UInt64 = 5_000_000_000
    private let minimumSamples = 800

    func prepareForSession() {
        guard preparationTask == nil, !status.isReady else { return }
        guard let modelFolder = Self.bundledModelFolder() else {
            let reason = "Bundled WhisperKit model folder is missing."
            status = .failed(path: nil, reason: reason)
            diagnostic("model failure reason=\(reason)")
            return
        }

        modelGeneration &+= 1
        let generation = modelGeneration
        let path = modelFolder.path
        status = .loading(path: path)
        diagnostic("model loading path=\(path) thermal=\(Self.thermalStateText)")
        preparationGeneration = generation
        preparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let started = ContinuousClock.now
            do {
                try Self.validateProvenance(in: modelFolder)
                try Self.validateTokenizerFiles(in: modelFolder)
                try Task.checkCancellation()
                let config = WhisperKitConfig(
                    modelFolder: path,
                    tokenizerFolder: modelFolder,
                    verbose: false,
                    logLevel: .error,
                    prewarm: true,
                    load: true,
                    download: false,
                    useBackgroundDownloadSession: false
                )
                let loaded = try await WhisperKit(config)
                try Task.checkCancellation()
                guard self.modelGeneration == generation else {
                    throw CancellationError()
                }
                self.whisperKit = loaded
                let loadMS = Int(started.duration(to: .now).seconds * 1_000)
                let memoryMB = Self.residentMemoryMB
                self.status = .ready(path: path, loadMilliseconds: loadMS, residentMemoryMB: memoryMB)
                self.diagnostic(
                    "model ready load_ms=\(loadMS) path=\(path) resident_mb=\(memoryMB) primary=WhisperKit fallback=AppleSpeech thermal=\(Self.thermalStateText)"
                )
            } catch is CancellationError {
                if self.modelGeneration == generation {
                    self.status = .idle
                    self.diagnostic("model loading cancelled")
                }
            } catch {
                if self.modelGeneration == generation {
                    let reason = error.localizedDescription
                    self.whisperKit = nil
                    self.status = .failed(path: path, reason: reason)
                    self.diagnostic(
                        "model failure path=\(path) reason=\(reason) resident_mb=\(Self.residentMemoryMB) fallback=AppleSpeech thermal=\(Self.thermalStateText)"
                    )
                }
            }
            if self.preparationGeneration == generation {
                self.preparationTask = nil
                self.preparationGeneration = nil
            }
        }
    }

    func transcribe(samples: [Float]) async throws -> TranscriptionOutcome {
        guard samples.count >= minimumSamples else {
            diagnostic("take skipped reason=clip-too-short samples=\(samples.count) rate=16000")
            return TranscriptionOutcome(text: "", engine: .none, fallbackReason: "clip-too-short")
        }

        let generation = beginTake()
        try Task.checkCancellation()
        if status == .idle { prepareForSession() }
        let awaitedModelGeneration = preparationGeneration
        if let preparationTask { await preparationTask.value }
        try ensureCurrentTake(generation)
        if let awaitedModelGeneration, modelGeneration != awaitedModelGeneration {
            throw CancellationError()
        }

        guard status.isReady, whisperKit != nil else {
            let reason = status.failureReason ?? "WhisperKit model is unavailable."
            return try await runAppleFallback(samples: samples, reason: reason, generation: generation)
        }

        let started = ContinuousClock.now
        do {
            let text = try await transcribeWithWhisperTimeout(samples: samples, generation: generation)
            try ensureCurrentTake(generation)
            let inferenceMS = Int(started.duration(to: .now).seconds * 1_000)
            diagnostic(
                "take inference_ms=\(inferenceMS) engine=WhisperKit fallback=none samples=\(samples.count) rate=16000 resident_mb=\(Self.residentMemoryMB) thermal=\(Self.thermalStateText)"
            )
            return TranscriptionOutcome(text: text, engine: .whisperKit)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try ensureCurrentTake(generation)
            return try await runAppleFallback(
                samples: samples,
                reason: error.localizedDescription,
                generation: generation
            )
        }
    }

    func cancelAndUnload() {
        modelGeneration &+= 1
        preparationTask?.cancel()
        preparationTask = nil
        preparationGeneration = nil
        cancelActiveTake()
        whisperKit = nil
        status = .idle
        diagnostic("transcription service cancelled and model released")
    }

    func cancelCurrentTake() {
        cancelActiveTake()
    }

    private func transcribeWithWhisperTimeout(samples: [Float], generation: UInt64) async throws -> String {
        try ensureCurrentTake(generation)
        guard let whisperKit else {
            throw PrimaryTranscriptionError.unavailable("WhisperKit model is unavailable.")
        }
        guard let tokenizer = whisperKit.tokenizer else {
            throw PrimaryTranscriptionError.unavailable("WhisperKit tokenizer is unavailable.")
        }
        let promptTokens = tokenizer.encode(text: WhisperVocabularyPrompt.text)
        let options = DecodingOptions(
            language: "en",
            usePrefillPrompt: true,
            withoutTimestamps: true,
            promptTokens: promptTokens
        )

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let race = OneShotContinuation(continuation)
                inferenceContinuation = race
                inferenceGeneration = generation

                let inference = Task { @MainActor [weak self] in
                    guard let self else {
                        race.resume(throwing: CancellationError())
                        return
                    }
                    do {
                        let results = try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
                        try Task.checkCancellation()
                        try self.ensureCurrentTake(generation)
                        let text = results.map(\.text).joined(separator: " ")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        self.finishInference(race, generation: generation, result: .success(text))
                    } catch is CancellationError {
                        self.finishInference(
                            race,
                            generation: generation,
                            result: .failure(CancellationError())
                        )
                    } catch {
                        self.finishInference(race, generation: generation, result: .failure(error))
                    }
                }
                inferenceTask = inference

                let timeout = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: self?.timeoutNanoseconds ?? 0)
                    } catch {
                        return
                    }
                    guard let self else {
                        race.resume(throwing: CancellationError())
                        return
                    }
                    self.finishTimeout(race, generation: generation)
                }
                timeoutTask = timeout
                timeoutGeneration = generation
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.cancelTake(generation: generation)
            }
        }
    }

    private func runAppleFallback(
        samples: [Float],
        reason: String,
        generation: UInt64
    ) async throws -> TranscriptionOutcome {
        try ensureCurrentTake(generation)
        let started = ContinuousClock.now
        diagnostic("fallback start engine=AppleSpeech reason=\(reason)")
        let text = try await appleSpeech.transcribe(samples: samples, timeout: 3.5)
        try ensureCurrentTake(generation)
        let inferenceMS = Int(started.duration(to: .now).seconds * 1_000)
        diagnostic(
            "take inference_ms=\(inferenceMS) engine=AppleSpeech fallback_reason=\(reason) samples=\(samples.count) rate=16000 resident_mb=\(Self.residentMemoryMB) thermal=\(Self.thermalStateText)"
        )
        return TranscriptionOutcome(text: text, engine: .appleSpeech, fallbackReason: reason)
    }

    private func beginTake() -> UInt64 {
        cancelActiveTake()
        return takeGeneration
    }

    private func cancelActiveTake() {
        takeGeneration &+= 1
        let inference = inferenceTask
        let timeout = timeoutTask
        let continuation = inferenceContinuation
        inferenceTask = nil
        inferenceGeneration = nil
        timeoutTask = nil
        timeoutGeneration = nil
        inferenceContinuation = nil
        inference?.cancel()
        timeout?.cancel()
        appleSpeech.cancel()
        continuation?.resume(throwing: CancellationError())
    }

    private func cancelTake(generation: UInt64) {
        guard takeGeneration == generation else { return }
        cancelActiveTake()
    }

    private func ensureCurrentTake(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard takeGeneration == generation else {
            throw CancellationError()
        }
    }

    private func finishInference(
        _ continuation: OneShotContinuation<String>,
        generation: UInt64,
        result: Result<String, Error>
    ) {
        guard takeGeneration == generation else {
            continuation.resume(throwing: CancellationError())
            return
        }
        if inferenceGeneration == generation {
            inferenceTask = nil
            inferenceGeneration = nil
        }
        if timeoutGeneration == generation {
            timeoutTask?.cancel()
            timeoutTask = nil
            timeoutGeneration = nil
        }
        if inferenceContinuation === continuation {
            inferenceContinuation = nil
        }
        switch result {
        case .success(let text): continuation.resume(returning: text)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }

    private func finishTimeout(_ continuation: OneShotContinuation<String>, generation: UInt64) {
        guard takeGeneration == generation, timeoutGeneration == generation else {
            continuation.resume(throwing: CancellationError())
            return
        }
        if inferenceGeneration == generation {
            inferenceTask?.cancel()
            inferenceTask = nil
            inferenceGeneration = nil
        }
        timeoutTask = nil
        timeoutGeneration = nil
        if inferenceContinuation === continuation {
            inferenceContinuation = nil
        }
        continuation.resume(throwing: PrimaryTranscriptionError.timedOut)
    }

    private func diagnostic(_ message: String) {
        onDiagnostic?(message)
    }

    private static func bundledModelFolder(bundle: Bundle = .main) -> URL? {
        bundle.url(
            forResource: BundledWhisperModel.folderName,
            withExtension: nil,
            subdirectory: "Models"
        )
    }

    private static func validateProvenance(in folder: URL) throws {
        let sourceURL = folder.appendingPathComponent("SOURCE.json")
        let data = try Data(contentsOf: sourceURL)
        guard let source = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              source["repository"] as? String == BundledWhisperModel.repository,
              source["revision"] as? String == BundledWhisperModel.revision else {
            throw PrimaryTranscriptionError.unavailable("Bundled model provenance does not match the pinned revision.")
        }
    }

    private static func validateTokenizerFiles(in folder: URL) throws {
        for (fileName, expectedHash) in BundledWhisperModel.tokenizerSHA256.sorted(by: { $0.key < $1.key }) {
            let fileURL = folder.appendingPathComponent(fileName, isDirectory: false)
            let data: Data
            do {
                data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            } catch {
                throw PrimaryTranscriptionError.unavailable(
                    "Bundled tokenizer file is missing or unreadable: \(fileName)."
                )
            }
            let actualHash = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
            guard actualHash == expectedHash.lowercased() else {
                throw PrimaryTranscriptionError.unavailable(
                    "Bundled tokenizer file failed SHA-256 validation: \(fileName)."
                )
            }
        }
    }

    private static var thermalStateText: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static var residentMemoryMB: Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        guard status == KERN_SUCCESS else { return -1 }
        return Int(info.resident_size / (1_024 * 1_024))
    }
}

private final class OneShotContinuation<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return continuation == nil
    }

    func resume(returning value: Value) {
        take()?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<Value, Error>? {
        lock.lock()
        let value = continuation
        continuation = nil
        lock.unlock()
        return value
    }
}

private final class AppleSpeechFallback: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var timeoutTask: Task<Void, Never>?
    private var continuation: OneShotContinuation<String>?
    private var latest = ""

    func transcribe(samples: [Float], timeout: TimeInterval) async throws -> String {
        cancel()
        let recognizer = SFSpeechRecognizer(locale: Locale.autoupdatingCurrent)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer, recognizer.isAvailable else {
            throw PrimaryTranscriptionError.unavailable("Apple Speech recognition is unavailable.")
        }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
           let destination = buffer.floatChannelData?[0] else {
            throw PrimaryTranscriptionError.unavailable("Could not create the Apple Speech fallback buffer.")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let baseAddress = source.baseAddress {
                destination.update(from: baseAddress, count: samples.count)
            }
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        let generation = begin(request: request)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { checkedContinuation in
                let continuation = OneShotContinuation(checkedContinuation)
                guard install(continuation: continuation, generation: generation) else {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                let recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                    guard let self else { return }
                    if let result {
                        self.update(
                            text: result.bestTranscription.formattedString,
                            generation: generation
                        )
                        if result.isFinal {
                            self.finish(generation: generation)
                        }
                    }
                    if error != nil {
                        self.finish(generation: generation)
                    }
                }
                guard install(task: recognitionTask, generation: generation) else {
                    recognitionTask.cancel()
                    return
                }
                request.append(buffer)
                request.endAudio()

                let nanoseconds = UInt64(max(0, timeout) * 1_000_000_000)
                let timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: nanoseconds)
                    } catch {
                        return
                    }
                    self?.finish(generation: generation)
                }
                guard install(timeoutTask: timeoutTask, generation: generation) else {
                    timeoutTask.cancel()
                    return
                }
            }
        } onCancel: { [weak self] in
            self?.cancel(generation: generation)
        }
    }

    func cancel() {
        cancel(generation: nil)
    }

    private func cancel(generation expectedGeneration: UInt64?) {
        lock.lock()
        if let expectedGeneration, generation != expectedGeneration {
            lock.unlock()
            return
        }
        generation &+= 1
        let request = self.request
        let task = self.task
        let timeoutTask = self.timeoutTask
        let continuation = self.continuation
        self.request = nil
        self.task = nil
        self.timeoutTask = nil
        self.continuation = nil
        latest = ""
        lock.unlock()
        request?.endAudio()
        task?.cancel()
        timeoutTask?.cancel()
        continuation?.resume(throwing: CancellationError())
    }

    private func begin(request: SFSpeechAudioBufferRecognitionRequest) -> UInt64 {
        lock.lock()
        generation &+= 1
        let currentGeneration = generation
        self.request = request
        latest = ""
        lock.unlock()
        return currentGeneration
    }

    private func install(
        continuation: OneShotContinuation<String>,
        generation: UInt64
    ) -> Bool {
        lock.lock()
        guard self.generation == generation else {
            lock.unlock()
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    private func install(task: SFSpeechRecognitionTask, generation: UInt64) -> Bool {
        lock.lock()
        guard self.generation == generation else {
            lock.unlock()
            return false
        }
        self.task = task
        lock.unlock()
        return true
    }

    private func install(timeoutTask: Task<Void, Never>, generation: UInt64) -> Bool {
        lock.lock()
        guard self.generation == generation else {
            lock.unlock()
            return false
        }
        self.timeoutTask = timeoutTask
        lock.unlock()
        return true
    }

    private func update(text: String, generation: UInt64) {
        lock.lock()
        if self.generation == generation {
            latest = text
        }
        lock.unlock()
    }

    private func finish(generation: UInt64) {
        lock.lock()
        guard self.generation == generation else {
            lock.unlock()
            return
        }
        self.generation &+= 1
        let text = latest
        let request = self.request
        let task = self.task
        let timeoutTask = self.timeoutTask
        let continuation = self.continuation
        self.request = nil
        self.task = nil
        self.timeoutTask = nil
        self.continuation = nil
        latest = ""
        lock.unlock()
        request?.endAudio()
        task?.cancel()
        timeoutTask?.cancel()
        continuation?.resume(returning: text)
    }
}

private extension Duration {
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1_000_000_000_000_000_000
    }
}
