#if canImport(LocalDictationCore)
import LocalDictationCore
#endif
import Foundation

enum SharedStoreSuite {
    static func roundTrip() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("payload-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FileSharedDictationStore(fileURL: url)
        let payload = SharedDictationPayload(status: .ready, transcript: "Hello", generation: 3, updatedAt: Date(timeIntervalSince1970: 10))
        try store.save(payload)
        try expectEqual(try store.load(), payload)
    }

    static func missingFileIsIdle() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).json")
        let store = FileSharedDictationStore(fileURL: url)
        try expectEqual(try store.load().status, .idle)
    }
}

enum PipelineSuite {
    static func insertsCleanedText() async throws {
        let pipeline = TranscriptPipeline()
        let text = pipeline.process("um book the haven cabin", vocabulary: ["haven": "Haven"])
        try expectEqual(text, "Book the Haven cabin.")
        try expect(pipeline.shouldInsert(text))
    }

    static func rejectsBlank() async throws {
        try expectFalse(TranscriptPipeline().shouldInsert("   "))
    }

    static func prependsSpaceWhenNeeded() async throws {
        let plan = InsertionPlanner.plan(cleaned: "next.", precedingText: "Hello")
        try expect(plan.prependSpace)
        try expectEqual(plan.insertedText, " next.")
    }

    static func noSpaceAfterPunctuation() async throws {
        let plan = InsertionPlanner.plan(cleaned: "Thanks.", precedingText: "Hello.")
        try expectFalse(plan.prependSpace)
    }
}

enum ReadinessSuite {
    static func blockingOrder() async throws {
        var readiness = KeyboardReadiness()
        try expectEqual(readiness.blockingMessage, "Add Local Dictation in Settings › General › Keyboard.")
        readiness.keyboardEnabled = true
        try expectEqual(readiness.blockingMessage, "Turn on Allow Full Access for Local Dictation.")
        readiness.fullAccessGranted = true
        try expectEqual(readiness.blockingMessage, "Allow Microphone access in Settings.")
        readiness.microphoneGranted = true
        try expectEqual(readiness.blockingMessage, "Allow Speech Recognition in Settings.")
        readiness.speechAuthorized = true
        try expect(readiness.isReady)
        try expect(readiness.canAttemptRecording)
        try expectNil(readiness.blockingMessage)
        readiness.fullAccessGranted = false
        try expectFalse(readiness.isReady)
        try expect(readiness.canAttemptRecording)
    }
}
