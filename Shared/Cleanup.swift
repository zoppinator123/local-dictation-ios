import Foundation

public enum WritingStyle: String, Codable, CaseIterable, Sendable {
    case raw
    case polished
    case email

    public var displayName: String {
        switch self {
        case .raw: return "Raw"
        case .polished: return "Polished"
        case .email: return "Email"
        }
    }

    public var detail: String {
        switch self {
        case .raw: return "Keep what you said, including filler words."
        case .polished: return "Remove fillers, fix casing, and add light punctuation."
        case .email: return "Clean the transcript and format it as a short message."
        }
    }
}

public struct CleanupOptions: Equatable, Sendable {
    public var style: WritingStyle
    public var removeFillers: Bool
    public var collapseRepeats: Bool

    public init(style: WritingStyle = .polished, removeFillers: Bool? = nil, collapseRepeats: Bool = true) {
        self.style = style
        self.removeFillers = removeFillers ?? (style != .raw)
        self.collapseRepeats = collapseRepeats
    }
}

public struct DeterministicCleanup: Sendable {
    public static let defaultFillers: Set<String> = [
        "um", "uh", "uhh", "erm", "ah", "like", "you know", "i mean",
    ]

    public var fillers: Set<String>

    public init(fillers: Set<String> = DeterministicCleanup.defaultFillers) {
        self.fillers = fillers
    }

    public func clean(_ text: String, vocabulary: [String: String] = [:], options: CleanupOptions = CleanupOptions()) -> String {
        var output = text.replacingOccurrences(of: "\u{00a0}", with: " ")
        output = collapseWhitespace(output)
        if options.removeFillers {
            output = removeFillers(output)
        }
        if options.collapseRepeats {
            output = collapseRepeats(output)
        }
        output = applyVocabulary(output, replacements: vocabulary)
        output = collapseWhitespace(output)
        switch options.style {
        case .raw:
            return output
        case .polished:
            return sentenceCase(removeAutomaticTerminalPeriod(output))
        case .email:
            return formatEmail(output)
        }
    }

    public func removeFillers(_ text: String) -> String {
        let tokens = tokenize(text)
        var kept: [String] = []
        var index = 0
        while index < tokens.count {
            let lower = normalize(tokens[index])
            if fillers.contains(lower) {
                index += 1
                continue
            }
            if index + 1 < tokens.count {
                let pair = "\(lower) \(normalize(tokens[index + 1]))"
                if fillers.contains(pair) {
                    index += 2
                    continue
                }
            }
            kept.append(tokens[index])
            index += 1
        }
        return kept.joined(separator: " ")
    }

    public func collapseRepeats(_ text: String) -> String {
        let tokens = tokenize(text)
        var result: [String] = []
        var last: String?
        for token in tokens {
            let normalized = normalize(token)
            if let last, last == normalized { continue }
            result.append(token)
            last = normalized
        }
        return result.joined(separator: " ")
    }

    public func applyVocabulary(_ text: String, replacements: [String: String]) -> String {
        guard !replacements.isEmpty else { return text }
        let ordered = replacements.sorted { lhs, rhs in
            tokenize(lhs.key).count > tokenize(rhs.key).count
        }
        var output = " \(collapseWhitespace(text)) "
        for (phrase, replacement) in ordered {
            let needle = " \(collapseWhitespace(phrase)) "
            var searchStart = output.startIndex
            while let range = output.range(of: needle, options: [.caseInsensitive], range: searchStart..<output.endIndex) {
                let shaped = preserveShape(of: String(output[range]).trimmingCharacters(in: .whitespaces), using: replacement)
                output.replaceSubrange(range, with: " \(shaped) ")
                searchStart = output.index(range.lowerBound, offsetBy: shaped.count + 2, limitedBy: output.endIndex) ?? output.endIndex
            }
        }
        return collapseWhitespace(output)
    }

    public func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    public func sentenceCase(_ text: String) -> String {
        guard let first = text.first else { return text }
        return String(first).uppercased() + text.dropFirst()
    }

    public func ensureTerminalPunctuation(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if let last = trimmed.last, ".!?".contains(last) { return trimmed }
        return trimmed + "."
    }

    public func removeAutomaticTerminalPeriod(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix("."), !trimmed.hasSuffix("...") else { return trimmed }
        return String(trimmed.dropLast())
    }

    public func formatEmail(_ text: String) -> String {
        let body = sentenceCase(ensureTerminalPunctuation(collapseWhitespace(text)))
        guard !body.isEmpty else { return body }
        return "Hi,\n\n\(body)\n\nThanks"
    }

    public func tokenize(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
    }

    public func normalize(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
    }

    private func preserveShape(of original: String, using replacement: String) -> String {
        if original == original.uppercased(), original.count > 1 {
            return replacement.uppercased()
        }
        if original.first?.isUppercase == true {
            return sentenceCase(replacement)
        }
        return replacement
    }
}
