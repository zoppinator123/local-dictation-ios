#if canImport(LocalDictationCore)
import LocalDictationCore
#endif
import Foundation
import CryptoKit

private enum WhisperTestError: Error {
    case inference
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    func increment() {
        lock.lock()
        storedValue += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
}

enum WhisperIntegrationSuite {
    static func logicalCaptureWithoutHardware() async throws {
        let buffer = PCMClipBuffer(maximumFrames: 20, maximumChannels: 2)
        buffer.append(CapturedPCMChunk(sampleRate: 48_000, channels: [[1, 2]]))
        try expectFalse(buffer.isClipping)
        try expectEqual(buffer.takeClip().frameCount, 0)

        buffer.beginClip()
        try expect(buffer.isClipping)
        buffer.append(CapturedPCMChunk(sampleRate: 48_000, channels: [[1, 2], [3, 4]]))
        let take = buffer.takeClip()
        try expectFalse(buffer.isClipping)
        try expectEqual(take.frameCount, 2)
        try expectEqual(take.channelCount, 2)

        buffer.beginClip()
        buffer.append(CapturedPCMChunk(sampleRate: 48_000, channels: [[5]]))
        buffer.cancelClip()
        try expectEqual(buffer.takeClip().frameCount, 0)
    }

    static func stereo48kToMono16k() async throws {
        let left = [Float](repeating: 0.25, count: 480)
        let right = [Float](repeating: 0.9, count: 480)
        let output = try PCMResampler.convertToWhisperPCM(
            PCMClipSnapshot(chunks: [CapturedPCMChunk(sampleRate: 48_000, channels: [left, right])])
        )
        try expectEqual(output.sampleRate, 16_000)
        try expectEqual(output.samples.count, 160)
        try expectEqual(output.sourceChannelCount, 2)
        try expect(output.samples.allSatisfy { $0.isFinite && abs($0 - 0.25) < 0.001 })
    }

    static func mono48kToMono16kSanity() async throws {
        let input = (0..<4_800).map { index in
            Float(sin(2 * Double.pi * 1_000 * Double(index) / 48_000))
        }
        let output = try PCMResampler.convertToWhisperPCM(
            PCMClipSnapshot(chunks: [CapturedPCMChunk(sampleRate: 48_000, channels: [input])])
        )
        try expectEqual(output.samples.count, 1_600)
        try expect(output.samples.allSatisfy { $0.isFinite && abs($0) <= 1.05 })
        let rms = sqrt(output.samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(output.samples.count))
        try expect(rms > 0.65 && rms < 0.75, "unexpected sine RMS \(rms)")
    }

    static func fifteenSecondResampleLatency() async throws {
        let frameCount = 48_000 * 15
        let input = (0..<frameCount).map { Float(($0 % 101) - 50) / 50 }
        let started = ContinuousClock.now
        let output = PCMResampler.resample(input, from: 48_000, to: 16_000)
        let elapsed = started.duration(to: .now)
        try expectEqual(output.count, 16_000 * 15)
        try expect(elapsed < .milliseconds(750), "15-second resample took \(elapsed)")
    }

    static func emptyAndShortClip() async throws {
        do {
            _ = try PCMResampler.convertToWhisperPCM(PCMClipSnapshot(chunks: []))
            throw TestFailure("empty PCM should fail conversion")
        } catch PCMConversionError.empty {
            // Expected.
        }

        let calls = LockedCounter()
        let outcome = try await FallbackTranscriptionCoordinator(minimumSamples: 800).transcribe(
            samples: [Float](repeating: 0, count: 799),
            primaryAvailable: true,
            primary: { _ in calls.increment(); return "primary" },
            fallback: { _ in calls.increment(); return "fallback" }
        )
        try expectEqual(outcome.engine, .none)
        try expectEqual(outcome.text, "")
        try expectEqual(calls.value, 0)
    }

    static func primarySuccess() async throws {
        let fallbackCalls = LockedCounter()
        let outcome = try await FallbackTranscriptionCoordinator().transcribe(
            samples: [Float](repeating: 0, count: 800),
            primaryAvailable: true,
            primary: { _ in "Whisper result" },
            fallback: { _ in fallbackCalls.increment(); return "Apple result" }
        )
        try expectEqual(outcome, TranscriptionOutcome(text: "Whisper result", engine: .whisperKit))
        try expectEqual(fallbackCalls.value, 0)
    }

    static func modelLoadFailureFallsBack() async throws {
        let primaryCalls = LockedCounter()
        let outcome = try await FallbackTranscriptionCoordinator().transcribe(
            samples: [Float](repeating: 0, count: 800),
            primaryAvailable: false,
            primaryUnavailableReason: "model load failed",
            primary: { _ in primaryCalls.increment(); return "wrong" },
            fallback: { _ in "Apple result" }
        )
        try expectEqual(outcome.engine, .appleSpeech)
        try expectEqual(outcome.text, "Apple result")
        try expectEqual(outcome.fallbackReason, "model load failed")
        try expectEqual(primaryCalls.value, 0)
    }

    static func inferenceErrorFallsBack() async throws {
        let outcome = try await FallbackTranscriptionCoordinator().transcribe(
            samples: [Float](repeating: 0, count: 800),
            primaryAvailable: true,
            primary: { _ in throw WhisperTestError.inference },
            fallback: { _ in "Apple result" }
        )
        try expectEqual(outcome.engine, .appleSpeech)
        try expectEqual(outcome.text, "Apple result")
        try expect(outcome.fallbackReason?.isEmpty == false)
    }

    static func timeoutFallsBack() async throws {
        let outcome = try await FallbackTranscriptionCoordinator(timeoutNanoseconds: 5_000_000).transcribe(
            samples: [Float](repeating: 0, count: 800),
            primaryAvailable: true,
            primary: { _ in
                try await Task.sleep(nanoseconds: 1_000_000_000)
                return "late"
            },
            fallback: { _ in "Apple result" }
        )
        try expectEqual(outcome.engine, .appleSpeech)
        try expectEqual(outcome.text, "Apple result")
        try expect(outcome.fallbackReason?.contains("5-second") == true)
    }

    static func offDuringDecodeDiscardsStaleResult() async throws {
        let guardBox = TakeGenerationGuard()
        let takeGeneration = guardBox.advance()
        let operation = Task {
            try await FallbackTranscriptionCoordinator(timeoutNanoseconds: 1_000_000_000).transcribe(
                samples: [Float](repeating: 0, count: 800),
                primaryAvailable: true,
                primary: { _ in
                    try await Task.sleep(nanoseconds: 20_000_000)
                    return "stale"
                },
                fallback: { _ in "fallback" }
            )
        }
        try await Task.sleep(nanoseconds: 5_000_000)
        guardBox.advance()
        let result = try await operation.value
        try expectEqual(result.text, "stale")
        try expectFalse(guardBox.isCurrent(takeGeneration))
    }

    static func listenerReplacementInvalidatesStaleCallbacks() async throws {
        var lifecycle = ListenerLifecycleGuard()
        let staleListener = lifecycle.beginReplacement()
        let replacement = lifecycle.beginReplacement()
        try expectFalse(lifecycle.isCurrent(staleListener))
        try expect(lifecycle.isCurrent(replacement))
        try expect(ListenerLifecycleGuard.isTerminal(.failed))
        try expect(ListenerLifecycleGuard.isTerminal(.cancelled))
        try expectFalse(ListenerLifecycleGuard.isTerminal(.ready))
    }

    static func cancellationNeverFallsBack() async throws {
        let fallbackCalls = LockedCounter()
        let operation = Task {
            try await FallbackTranscriptionCoordinator(timeoutNanoseconds: 1_000_000_000).transcribe(
                samples: [Float](repeating: 0, count: 800),
                primaryAvailable: true,
                primary: { _ in
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    return "late"
                },
                fallback: { _ in
                    fallbackCalls.increment()
                    return "must-not-run"
                }
            )
        }
        try await Task.sleep(nanoseconds: 5_000_000)
        operation.cancel()
        do {
            _ = try await operation.value
            throw TestFailure("cancelled primary must not start fallback")
        } catch is CancellationError {
            // Expected.
        }
        try expectEqual(fallbackCalls.value, 0)
    }

    static func realtimeBufferCopiesRawPCM() async throws {
        let buffer = PCMClipBuffer(maximumFrames: 8, maximumChannels: 2)
        let left: [Float] = [1, 2, 3, 4]
        let right: [Float] = [5, 6, 7, 8]
        buffer.beginClip()
        left.withUnsafeBufferPointer { leftPointer in
            right.withUnsafeBufferPointer { rightPointer in
                let channelPointers = [
                    UnsafeMutablePointer(mutating: leftPointer.baseAddress!),
                    UnsafeMutablePointer(mutating: rightPointer.baseAddress!),
                ]
                channelPointers.withUnsafeBufferPointer { pointers in
                    buffer.appendFloat32(
                        channelData: pointers.baseAddress!,
                        frameCount: 4,
                        channelCount: 2,
                        sampleRate: 48_000,
                        interleaved: false
                    )
                }
            }
        }
        let snapshot = buffer.takeClip()
        try expectEqual(snapshot.frameCount, 4)
        try expectEqual(snapshot.chunks.first?.channels[0], left)
        try expectEqual(snapshot.chunks.first?.channels[1], right)
    }

    static func localhostAuthentication() async throws {
        let expected = Data((0..<32).map(UInt8.init)).base64EncodedString()
        let missing = "GET /start HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        let wrong = missing.replacingOccurrences(of: "\r\n\r\n", with: "\r\nX-Local-Dictation-Token: wrong\r\n\r\n")
        let correct = missing.replacingOccurrences(
            of: "\r\n\r\n",
            with: "\r\nx-local-dictation-token: \(expected)\r\n\r\n"
        )
        try expectFalse(LocalhostAuthentication.isAuthorized(request: missing, expectedToken: expected))
        try expectFalse(LocalhostAuthentication.isAuthorized(request: wrong, expectedToken: expected))
        try expect(LocalhostAuthentication.isAuthorized(request: correct, expectedToken: expected))
        try expectFalse(LocalhostAuthentication.isAuthorized(request: correct, expectedToken: nil))
        try expect(LocalhostAuthentication.constantTimeEqual(Data("same".utf8), Data("same".utf8)))
        try expectFalse(LocalhostAuthentication.constantTimeEqual(Data("short".utf8), Data("longer".utf8)))
    }

    static func localhostMethodPolicy() async throws {
        try expect(LocalhostRequestPolicy.isAllowed(request: "GET /health HTTP/1.1\r\n\r\n", route: .health))
        try expect(LocalhostRequestPolicy.isAllowed(request: "POST /start HTTP/1.1\r\n\r\n", route: .start))
        try expect(LocalhostRequestPolicy.isAllowed(request: "POST /stop HTTP/1.1\r\n\r\n", route: .stop))
        try expect(LocalhostRequestPolicy.isAllowed(request: "POST /off HTTP/1.1\r\n\r\n", route: .off))
        try expectFalse(LocalhostRequestPolicy.isAllowed(request: "GET /start HTTP/1.1\r\n\r\n", route: .start))
        try expectFalse(LocalhostRequestPolicy.isAllowed(request: "POST /health HTTP/1.1\r\n\r\n", route: .health))
        try expectFalse(LocalhostRequestPolicy.isAllowed(request: "POST /unknown HTTP/1.1\r\n\r\n", route: .unknown))
    }

    static func stopFailureMessage() async throws {
        try expectEqual(
            KeyboardTransportPolicy.sessionExpiredMessage,
            "Session expired. Reopen Local Dictation."
        )
    }

    static func bundledModelProvenance() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let folder = root
            .appendingPathComponent("Resources/Models", isDirectory: true)
            .appendingPathComponent(BundledWhisperModel.folderName, isDirectory: true)
        let required = [
            "AudioEncoder.mlmodelc/coremldata.bin",
            "MelSpectrogram.mlmodelc/coremldata.bin",
            "TextDecoder.mlmodelc/coremldata.bin",
            "tokenizer.json",
            "SOURCE.json",
        ]
        for relativePath in required {
            try expect(
                FileManager.default.fileExists(atPath: folder.appendingPathComponent(relativePath).path),
                "missing bundled model file \(relativePath)"
            )
        }
        let source = try Data(contentsOf: folder.appendingPathComponent("SOURCE.json"))
        let object = try JSONSerialization.jsonObject(with: source) as? [String: Any]
        try expectEqual(object?["repository"] as? String, BundledWhisperModel.repository)
        try expectEqual(object?["revision"] as? String, BundledWhisperModel.revision)
        let tokenizer = object?["tokenizer"] as? [String: Any]
        try expectEqual(tokenizer?["repository"] as? String, BundledWhisperModel.tokenizerRepository)
        try expectEqual(tokenizer?["revision"] as? String, BundledWhisperModel.tokenizerRevision)
        try expectEqual(BundledWhisperModel.tokenizerSHA256.count, 7)
        try expectEqual(
            Set(BundledWhisperModel.tokenizerSHA256.keys),
            Set(tokenizer?["files"] as? [String] ?? [])
        )
        for (relativePath, expectedHash) in BundledWhisperModel.tokenizerSHA256 {
            let data = try Data(contentsOf: folder.appendingPathComponent(relativePath))
            let actualHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            try expectEqual(actualHash, expectedHash)
        }
    }

    static func vocabularyPromptIncludesAllWords() async throws {
        for word in ["Hostaway", "Breezeway", "Sevierville", "Tendwell", "ADR", "GBV", "StaydOS"] {
            try expect(WhisperVocabularyPrompt.text.contains(word), "prompt omitted \(word)")
        }
        try expectEqual(WhisperVocabularyPrompt.words.count, 7)
    }
}
