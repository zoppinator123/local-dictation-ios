#if canImport(LocalDictationCore)
import LocalDictationCore
#endif

enum CaptureSuite {
    static func errorCopy() async throws {
        try expectEqual(SpeechCaptureError.invalidInputFormat.errorDescription, "Microphone is not ready yet.")
        try expect(SpeechCaptureError.engineStartFailed("boom").errorDescription?.contains("boom") == true)
    }
}
