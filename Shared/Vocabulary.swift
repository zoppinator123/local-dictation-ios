import Foundation

public struct VocabularyEntry: Codable, Equatable, Identifiable, Sendable {
    public var phrase: String
    public var replacement: String

    public var id: String { VocabularyStore.normalize(phrase) }

    public init(phrase: String, replacement: String) {
        self.phrase = phrase
        self.replacement = replacement
    }
}

public protocol VocabularyPersisting: Sendable {
    func load() throws -> [VocabularyEntry]
    func save(_ entries: [VocabularyEntry]) throws
}

public struct MemoryVocabularyPersister: VocabularyPersisting, Sendable {
    private let box: LockedBox<[VocabularyEntry]>

    public init(entries: [VocabularyEntry] = []) {
        box = LockedBox(entries)
    }

    public func load() throws -> [VocabularyEntry] { box.value }
    public func save(_ entries: [VocabularyEntry]) throws { box.value = entries }
}

public struct FileVocabularyPersister: VocabularyPersisting, Sendable {
    public var fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> [VocabularyEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([VocabularyEntry].self, from: data)
    }

    public func save(_ entries: [VocabularyEntry]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(entries)
        try data.write(to: fileURL, options: .atomic)
    }
}

public final class VocabularyStore: @unchecked Sendable {
    private var entries: [VocabularyEntry]
    private let persister: any VocabularyPersisting

    public init(persister: any VocabularyPersisting) {
        self.persister = persister
        self.entries = (try? persister.load()) ?? []
    }

    public func all() -> [VocabularyEntry] { entries }

    public func replacements() -> [String: String] {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.phrase, $0.replacement) })
    }

    @discardableResult
    public func add(phrase: String, replacement: String) throws -> VocabularyEntry {
        let cleanedPhrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanedPhrase.count >= 2 else {
            throw VocabularyError.tooShort
        }
        guard !cleanedReplacement.isEmpty else {
            throw VocabularyError.emptyReplacement
        }
        let entry = VocabularyEntry(phrase: cleanedPhrase, replacement: cleanedReplacement)
        entries.removeAll { $0.id == entry.id }
        entries.append(entry)
        try persister.save(entries)
        return entry
    }

    public func remove(id: String) throws {
        entries.removeAll { $0.id == id }
        try persister.save(entries)
    }

    public static func normalize(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
    }
}

public enum VocabularyError: Error, Equatable, LocalizedError {
    case tooShort
    case emptyReplacement

    public var errorDescription: String? {
        switch self {
        case .tooShort: return "Vocabulary phrases need at least two characters."
        case .emptyReplacement: return "Replacement text cannot be empty."
        }
    }
}

final class LockedBox<Value>: @unchecked Sendable {
    private var storage: Value
    private let lock = NSLock()

    init(_ value: Value) { storage = value }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}
