import Foundation

public struct SharedDictationPayload: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case idle
        case recording
        case ready
        case failed
    }

    public var status: Status
    public var transcript: String?
    public var errorMessage: String?
    public var generation: UInt64
    public var updatedAt: Date

    public init(
        status: Status = .idle,
        transcript: String? = nil,
        errorMessage: String? = nil,
        generation: UInt64 = 0,
        updatedAt: Date = Date(timeIntervalSince1970: 0)
    ) {
        self.status = status
        self.transcript = transcript
        self.errorMessage = errorMessage
        self.generation = generation
        self.updatedAt = updatedAt
    }
}

public protocol SharedDictationStoring: Sendable {
    func load() throws -> SharedDictationPayload
    func save(_ payload: SharedDictationPayload) throws
}

public struct FileSharedDictationStore: SharedDictationStoring, Sendable {
    public var fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> SharedDictationPayload {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return SharedDictationPayload()
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(SharedDictationPayload.self, from: data)
    }

    public func save(_ payload: SharedDictationPayload) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(payload)
        try data.write(to: fileURL, options: .atomic)
    }
}

public enum ClipboardDictation {
    public static let prefix = "localdictation-transcript:"

    public static func encode(_ text: String) -> String {
        prefix + text
    }

    public static func decode(_ raw: String) -> String? {
        guard raw.hasPrefix(prefix) else { return nil }
        let text = String(raw.dropFirst(prefix.count))
        return text.isEmpty ? nil : text
    }
}

public enum AppGroupPaths {
    public static let identifier = "group.com.jackzoppa.LocalDictation"
    public static let payloadFileName = "shared-dictation.json"
    public static let vocabularyFileName = "vocabulary.json"
    public static let settingsFileName = "settings.json"

    public static func containerURL(fileManager: FileManager = .default) -> URL? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    public static func payloadURL(fileManager: FileManager = .default) -> URL? {
        containerURL(fileManager: fileManager)?.appendingPathComponent(payloadFileName)
    }
}

public struct KeyboardSettings: Codable, Equatable, Sendable {
    public var style: WritingStyle
    public var holdToTalk: Bool

    public init(style: WritingStyle = .polished, holdToTalk: Bool = false) {
        self.style = style
        self.holdToTalk = holdToTalk
    }
}

public protocol SettingsPersisting: Sendable {
    func load() throws -> KeyboardSettings
    func save(_ settings: KeyboardSettings) throws
}

public struct FileSettingsPersister: SettingsPersisting, Sendable {
    public var fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> KeyboardSettings {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return KeyboardSettings() }
        return try JSONDecoder().decode(KeyboardSettings.self, from: Data(contentsOf: fileURL))
    }

    public func save(_ settings: KeyboardSettings) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(settings).write(to: fileURL, options: .atomic)
    }
}
