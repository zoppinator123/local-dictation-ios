import Foundation
#if canImport(Security)
import Security
#endif

public enum SharedAuthTokenStoreError: Error, LocalizedError, Sendable {
    case securityFrameworkUnavailable
    case randomGenerationFailed(Int32)
    case keychainReadFailed(Int32)
    case keychainWriteFailed(Int32)
    case invalidStoredToken

    public var errorDescription: String? {
        switch self {
        case .securityFrameworkUnavailable:
            return "The Security framework is unavailable."
        case .randomGenerationFailed(let status):
            return "Could not generate the localhost authentication token (OSStatus \(status))."
        case .keychainReadFailed(let status):
            return "Could not read the shared localhost authentication token (OSStatus \(status))."
        case .keychainWriteFailed(let status):
            return "Could not save the shared localhost authentication token (OSStatus \(status))."
        case .invalidStoredToken:
            return "The shared localhost authentication token is invalid."
        }
    }
}

public struct SharedAuthTokenStore: Sendable {
    public static let accessGroup = "Q4MSNRURZ4.com.jackzoppa.LocalDictation.shared"
    public static let service = "com.jackzoppa.LocalDictation.localhost-auth"
    public static let account = "keyboard-host-token-v1"

    public init() {}

    public func load() throws -> String? {
        #if canImport(Security)
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw SharedAuthTokenStoreError.keychainReadFailed(status)
        }
        guard let data = item as? Data,
              let token = String(data: data, encoding: .utf8),
              Data(base64Encoded: token)?.count == 32 else {
            throw SharedAuthTokenStoreError.invalidStoredToken
        }
        return token
        #else
        throw SharedAuthTokenStoreError.securityFrameworkUnavailable
        #endif
    }

    /// Host-only operation. The keyboard extension calls `load()` and always fails closed.
    public func loadOrCreate() throws -> String {
        if let existing = try load() { return existing }
        #if canImport(Security)
        var random = [UInt8](repeating: 0, count: 32)
        let randomStatus = SecRandomCopyBytes(kSecRandomDefault, random.count, &random)
        guard randomStatus == errSecSuccess else {
            throw SharedAuthTokenStoreError.randomGenerationFailed(randomStatus)
        }
        let token = Data(random).base64EncodedString()
        var attributes = baseQuery
        attributes[kSecValueData as String] = Data(token.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem, let winner = try load() {
            return winner
        }
        guard status == errSecSuccess else {
            throw SharedAuthTokenStoreError.keychainWriteFailed(status)
        }
        return token
        #else
        throw SharedAuthTokenStoreError.securityFrameworkUnavailable
        #endif
    }

    #if canImport(Security)
    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrAccessGroup as String: Self.accessGroup,
            kSecAttrSynchronizable as String: false,
        ]
    }
    #endif
}
