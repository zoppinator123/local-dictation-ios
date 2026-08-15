#if canImport(LocalDictationCore)
import LocalDictationCore
#endif
import Foundation

enum HostCaptureSuite {
    static func idleStartClipFailsWithoutHardware() async throws {
        var session = HostCaptureSession()
        let result = session.startClip(foreground: false)
        try expectEqual(result, .failure(.needsForegroundSession))
        try expectEqual(session.lastCommand, .none)
        try expectFalse(session.state.micEngaged)
        try expectEqual(session.state.phase, .idle)
    }

    static func backgroundStartSessionIsIllegal() async throws {
        var session = HostCaptureSession()
        let result = session.startSession(foreground: false)
        try expectEqual(result, .failure(.hardwareStartFromBackground))
        try expectEqual(session.lastCommand, .none)
        try expectFalse(session.state.micEngaged)
    }

    static func foregroundStartSessionArmsHardware() async throws {
        var session = HostCaptureSession()
        let result = session.startSession(foreground: true)
        try expectEqual(result, .success(.startHardware))
        try expect(session.state.micEngaged)
        try expectEqual(session.state.phase, .live)
        try expectFalse(session.state.clipOpen)
    }

    static func startClipOnLiveOpensClipNotHardware() async throws {
        var session = HostCaptureSession()
        _ = session.startSession(foreground: true)
        let result = session.startClip(foreground: false)
        try expectEqual(result, .success(.openClip))
        try expectEqual(session.lastCommand, .openClip)
        try expectEqual(session.state.phase, .clipping)
        try expect(session.state.clipOpen)
        try expect(session.state.micEngaged)
    }

    static func doubleStartClipRejected() async throws {
        var session = HostCaptureSession()
        _ = session.startSession(foreground: true)
        _ = session.startClip(foreground: false)
        let result = session.startClip(foreground: false)
        try expectEqual(result, .failure(.alreadyClipping))
        try expectEqual(session.lastCommand, .none)
        try expectEqual(session.state.phase, .clipping)
    }

    static func stopBeforeStartIsNotClipping() async throws {
        var session = HostCaptureSession()
        _ = session.startSession(foreground: true)
        let result = session.stopClip()
        try expectEqual(result, .failure(.notClipping))
        try expectEqual(session.state.phase, .live)
        try expect(session.state.micEngaged)
    }

    static func stopClipKeepsHardwareForNextTake() async throws {
        var session = HostCaptureSession()
        _ = session.startSession(foreground: true)
        _ = session.startClip(foreground: false)
        let result = session.stopClip()
        try expectEqual(result, .success(.closeClip))
        try expectEqual(session.state.phase, .transcribing)
        try expectFalse(session.state.clipOpen)
        try expect(session.state.micEngaged)
        session.finishTranscription("hello")
        try expectEqual(session.state.phase, .live)
        try expect(session.state.micEngaged)
        try expectNil(session.state.lastError)
        let again = session.startClip(foreground: false)
        try expectEqual(again, .success(.openClip))
    }

    static func emptyTranscriptStaysLive() async throws {
        var session = HostCaptureSession()
        _ = session.startSession(foreground: true)
        _ = session.startClip(foreground: false)
        _ = session.stopClip()
        session.finishTranscription("   ")
        try expectEqual(session.state.phase, .live)
        try expect(session.state.micEngaged)
        try expect(session.state.lastError?.contains("Didn't catch") == true)
    }

    static func failedTranscriptDoesNotKillSession() async throws {
        var session = HostCaptureSession()
        _ = session.startSession(foreground: true)
        _ = session.startClip(foreground: false)
        _ = session.stopClip()
        session.failTranscription("timeout")
        try expectEqual(session.state.phase, .live)
        try expect(session.state.micEngaged)
        try expectEqual(session.state.lastError, "timeout")
        try expectEqual(session.startClip(foreground: false), .success(.openClip))
    }

    static func micOffStopsHardwareFromAnyPhase() async throws {
        var session = HostCaptureSession()
        _ = session.startSession(foreground: true)
        _ = session.startClip(foreground: false)
        try expectEqual(session.micOff(), .stopHardware)
        try expectEqual(session.state, .idle)
        try expectEqual(session.startClip(foreground: false), .failure(.needsForegroundSession))
    }

    static func secondForegroundStartDoesNotRestartHardware() async throws {
        var session = HostCaptureSession()
        _ = session.startSession(foreground: true)
        let again = session.startSession(foreground: true)
        try expectEqual(again, .success(.none))
        try expectEqual(session.lastCommand, .none)
        try expect(session.state.micEngaged)
    }

    static func startClipDuringTranscribingIsRejected() async throws {
        var session = HostCaptureSession()
        _ = session.startSession(foreground: true)
        _ = session.startClip(foreground: false)
        _ = session.stopClip()
        try expectEqual(session.state.phase, .transcribing)
        let result = session.startClip(foreground: false)
        try expectEqual(result, .failure(.alreadyClipping))
        try expectEqual(session.state.phase, .transcribing)
        try expectFalse(session.state.clipOpen)
    }

    static func micOffDuringTranscribing() async throws {
        var session = HostCaptureSession()
        _ = session.startSession(foreground: true)
        _ = session.startClip(foreground: false)
        _ = session.stopClip()
        _ = session.micOff()
        try expectEqual(session.state, .idle)
        session.finishTranscription("hello")
        try expectEqual(session.state.phase, .idle)
        try expectFalse(session.state.micEngaged)
    }

    static func httpRoutes() async throws {
        try expectEqual(HostCaptureRoute.parseHTTP("GET /start HTTP/1.1\r\nHost: 127.0.0.1"), .start)
        try expectEqual(HostCaptureRoute.parseHTTP("GET /stop HTTP/1.1"), .stop)
        try expectEqual(HostCaptureRoute.parseHTTP("GET /health HTTP/1.1"), .health)
        try expectEqual(HostCaptureRoute.parseHTTP("GET /off HTTP/1.1"), .off)
        try expectEqual(HostCaptureRoute.parseHTTP("GET /nope HTTP/1.1"), .unknown)
        try expectEqual(HostCaptureRoute.parseHTTP("GET /start?x=1 HTTP/1.1"), .start)
        try expectEqual(HostCaptureRoute.parseHTTP(""), .unknown)
        try expectEqual(HostCaptureRoute.parseHTTP("GET / HTTP/1.1"), .unknown)
        try expectEqual(HostCaptureRoute.parseHTTP("POST /start HTTP/1.1"), .start)
        try expectEqual(HostCaptureRoute.parseHTTP("GET /off"), .off)
        try expectEqual(HostCaptureRoute.parseHTTP("GET /health\n"), .health)
    }

    static func lastErrorClearsOnNextClip() async throws {
        var session = HostCaptureSession()
        _ = session.startSession(foreground: true)
        _ = session.startClip(foreground: false)
        _ = session.stopClip()
        session.finishTranscription("  ")
        try expect(session.state.lastError != nil)
        _ = session.startClip(foreground: false)
        try expectNil(session.state.lastError)
        try expectEqual(session.state.phase, .clipping)
    }

    static func finishAfterMicOffStaysIdle() async throws {
        var session = HostCaptureSession()
        _ = session.startSession(foreground: true)
        _ = session.micOff()
        session.finishTranscription("hello")
        try expectEqual(session.state.phase, .idle)
        try expectFalse(session.state.micEngaged)
        try expectEqual(session.startClip(foreground: false), .failure(.needsForegroundSession))
    }

    static func fullTapCycleTwice() async throws {
        var session = HostCaptureSession()
        _ = session.startSession(foreground: true)
        for word in ["hello", "world"] {
            try expectEqual(session.startClip(foreground: false), .success(.openClip))
            try expectEqual(session.stopClip(), .success(.closeClip))
            session.finishTranscription(word)
            try expectEqual(session.state.phase, .live)
            try expectNil(session.state.lastError)
        }
        try expectEqual(session.micOff(), .stopHardware)
        try expectEqual(session.startClip(foreground: false), .failure(.needsForegroundSession))
    }

    static func stopDuringTranscribeStaysTranscribing() async throws {
        var session = HostCaptureSession()
        _ = session.startSession(foreground: true)
        _ = session.startClip(foreground: false)
        _ = session.stopClip()
        try expectEqual(session.state.phase, .transcribing)
        try expectEqual(session.stopClip(), .failure(.notClipping))
        try expectEqual(session.state.phase, .transcribing)
        try expect(session.state.micEngaged)
    }

    static func backgroundStartAfterLiveLeavesHardware() async throws {
        var session = HostCaptureSession()
        _ = session.startSession(foreground: true)
        try expectEqual(session.startSession(foreground: false), .failure(.hardwareStartFromBackground))
        try expect(session.state.micEngaged)
        try expectEqual(session.state.phase, .live)
    }

    static func foregroundStartDuringClipIsNoop() async throws {
        var session = HostCaptureSession()
        _ = session.startSession(foreground: true)
        _ = session.startClip(foreground: false)
        try expectEqual(session.startSession(foreground: true), .success(.none))
        try expectEqual(session.state.phase, .clipping)
        try expect(session.state.clipOpen)
    }

    static func startClipForegroundIdleStillNeedsSession() async throws {
        var session = HostCaptureSession()
        try expectEqual(session.startClip(foreground: true), .failure(.needsForegroundSession))
        try expectNil(session.state.lastError)
        try expectFalse(session.state.micEngaged)
    }

    static func stopFromIdleDoesNotArm() async throws {
        var session = HostCaptureSession()
        try expectEqual(session.stopClip(), .failure(.notClipping))
        try expectFalse(session.state.micEngaged)
        try expectEqual(session.state.phase, .idle)
    }
}
