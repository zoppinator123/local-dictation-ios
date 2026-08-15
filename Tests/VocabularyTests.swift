#if canImport(LocalDictationCore)
import LocalDictationCore
#endif
import Foundation

enum VocabularySuite {
    static func persist() async throws {
        let persister = MemoryVocabularyPersister()
        let store = VocabularyStore(persister: persister)
        _ = try store.add(phrase: "haven", replacement: "Haven")
        try expectEqual(store.replacements()["haven"], "Haven")
        let reloaded = VocabularyStore(persister: persister)
        try expectEqual(reloaded.all().map(\.phrase), ["haven"])
    }

    static func shortWordsRejected() async throws {
        let store = VocabularyStore(persister: MemoryVocabularyPersister())
        do {
            _ = try store.add(phrase: "a", replacement: "A")
            throw TestFailure("expected short phrase to fail")
        } catch VocabularyError.tooShort {
            return
        }
    }

    static func remove() async throws {
        let store = VocabularyStore(persister: MemoryVocabularyPersister())
        let entry = try store.add(phrase: "jack", replacement: "Jack")
        try store.remove(id: entry.id)
        try expect(store.all().isEmpty)
    }
}
