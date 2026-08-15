#if canImport(LocalDictationCore)
import LocalDictationCore
#endif
import Foundation

enum CaptureSuite {
    static func errorCopy() async throws {
        try expectEqual(SpeechCaptureError.invalidInputFormat.errorDescription, "Microphone is not ready yet.")
        try expect(SpeechCaptureError.engineStartFailed("boom").errorDescription?.contains("boom") == true)
        let ns = NSError(domain: "com.apple.coreaudio.avfaudio", code: 561_015_905, userInfo: [NSLocalizedDescriptionKey: "failed"])
        try expect(nsErrorText(ns).contains("561015905"))
    }
}
