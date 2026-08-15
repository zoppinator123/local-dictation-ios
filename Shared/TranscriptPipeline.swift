import Foundation

public struct TranscriptPipeline: Sendable {
    public var cleanup: DeterministicCleanup
    public var options: CleanupOptions

    public init(cleanup: DeterministicCleanup = DeterministicCleanup(), options: CleanupOptions = CleanupOptions()) {
        self.cleanup = cleanup
        self.options = options
    }

    public func process(_ raw: String, vocabulary: [String: String]) -> String {
        cleanup.clean(raw, vocabulary: vocabulary, options: options)
    }

    public func shouldInsert(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public struct InsertionPlan: Equatable, Sendable {
    public var text: String
    public var prependSpace: Bool

    public var insertedText: String {
        prependSpace ? " " + text : text
    }
}

public enum InsertionPlanner {
    public static func plan(cleaned: String, precedingText: String?) -> InsertionPlan {
        let needsSpace: Bool
        if let precedingText, let last = precedingText.last {
            needsSpace = !last.isWhitespace && !".!?,;:(".contains(last)
        } else {
            needsSpace = false
        }
        return InsertionPlan(text: cleaned, prependSpace: needsSpace)
    }
}
