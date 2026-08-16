#if canImport(LocalDictationCore)
import LocalDictationCore
#endif

enum CleanupSuite {
    static func fillers() async throws {
        let cleaned = DeterministicCleanup().clean("um hello uh world", options: CleanupOptions(style: .raw, removeFillers: true))
        try expectEqual(cleaned, "hello world")
    }

    static func repeats() async throws {
        let cleaned = DeterministicCleanup().clean("hello hello there", options: CleanupOptions(style: .raw))
        try expectEqual(cleaned, "hello there")
    }

    static func polishedPunctuation() async throws {
        let unpunctuated = DeterministicCleanup().clean("um this is ready")
        try expectEqual(unpunctuated, "This is ready")
        let automaticPeriods = DeterministicCleanup().clean("first thought. second thought.")
        try expectEqual(automaticPeriods, "First thought. second thought")
        let dictatedQuestion = DeterministicCleanup().clean("is this ready?")
        try expectEqual(dictatedQuestion, "Is this ready?")
    }

    static func emailStyle() async throws {
        let cleaned = DeterministicCleanup().clean("can we meet tomorrow", options: CleanupOptions(style: .email))
        try expectEqual(cleaned, "Hi,\n\nCan we meet tomorrow.\n\nThanks")
    }

    static func vocabulary() async throws {
        let cleaned = DeterministicCleanup().clean(
            "open stay dos please",
            vocabulary: ["stay dos": "StaydOS"],
            options: CleanupOptions(style: .raw)
        )
        try expectEqual(cleaned, "open StaydOS please")
    }

    static func rawKeepsFillers() async throws {
        let cleaned = DeterministicCleanup().clean("um hello", options: CleanupOptions(style: .raw, removeFillers: false))
        try expectEqual(cleaned, "um hello")
    }

    static func emptyStaysEmpty() async throws {
        try expectEqual(DeterministicCleanup().clean("   "), "")
        try expectFalse(TranscriptPipeline().shouldInsert(DeterministicCleanup().clean("um uh")))
    }

    static func longestVocabWins() async throws {
        let cleaned = DeterministicCleanup().clean(
            "stay dos app",
            vocabulary: ["stay": "Stay", "stay dos": "StaydOS"],
            options: CleanupOptions(style: .raw)
        )
        try expectEqual(cleaned, "StaydOS app")
    }
}
