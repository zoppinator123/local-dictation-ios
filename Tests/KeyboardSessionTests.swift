#if canImport(LocalDictationCore)
import LocalDictationCore
#endif

enum KeyboardSessionSuite {
    static func readyHoldCycle() async throws {
        var session = KeyboardSession(readiness: ready)
        try expect(session.handle(.beginHold))
        try expectEqual(session.phase, .recording)
        try expect(session.handle(.endHold))
        try expectEqual(session.phase, .transcribing)
        session.finishTranscription("Hello there.")
        try expectEqual(session.phase, .inserting)
        session.finishInsertion()
        try expectEqual(session.phase, .idle)
    }

    static func setupBlocksRecording() async throws {
        var session = KeyboardSession(readiness: KeyboardReadiness())
        try expectFalse(session.handle(.beginHold))
        try expectEqual(session.phase, .needsSetup)
        try expect(session.status.contains("Add Local Dictation"))
    }

    static func emptyAudioFails() async throws {
        var session = KeyboardSession(readiness: ready)
        _ = session.handle(.beginHold)
        _ = session.handle(.endHold)
        session.finishTranscription("   ")
        try expectEqual(session.phase, .error)
        try expectEqual(session.lastError?.code, "empty")
    }

    static func cancelReturnsIdle() async throws {
        var session = KeyboardSession(readiness: ready)
        _ = session.handle(.beginHold)
        try expect(session.handle(.cancel))
        try expectEqual(session.phase, .idle)
    }

    static func toggleStartsAndStops() async throws {
        var session = KeyboardSession(readiness: ready)
        try expect(session.handle(.toggle))
        try expectEqual(session.phase, .recording)
        try expect(session.handle(.toggle))
        try expectEqual(session.phase, .transcribing)
    }

    static func readinessRecovery() async throws {
        var session = KeyboardSession(readiness: KeyboardReadiness())
        try expectEqual(session.phase, .needsSetup)
        session.applyReadiness(ready)
        try expectEqual(session.phase, .idle)
    }

    static func missingFullAccessStillRecords() async throws {
        var session = KeyboardSession(
            readiness: KeyboardReadiness(
                keyboardEnabled: true,
                fullAccessGranted: false,
                microphoneGranted: true,
                speechAuthorized: true
            )
        )
        try expectEqual(session.phase, .idle)
        try expect(session.handle(.beginHold))
        try expectEqual(session.phase, .recording)
    }

    private static var ready: KeyboardReadiness {
        KeyboardReadiness(
            keyboardEnabled: true,
            fullAccessGranted: true,
            microphoneGranted: true,
            speechAuthorized: true
        )
    }
}
