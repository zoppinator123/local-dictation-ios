import Foundation
#if canImport(LocalDictationCore)
import LocalDictationCore
#endif

struct TestFailure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

func expect(_ condition: Bool, _ message: String = "expected condition to be true") throws {
    if !condition { throw TestFailure(message) }
}

func expectFalse(_ condition: Bool, _ message: String = "expected condition to be false") throws {
    if condition { throw TestFailure(message) }
}

func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String? = nil) throws {
    if lhs != rhs {
        throw TestFailure(message ?? "expected \(lhs) == \(rhs)")
    }
}

func expectNil<T>(_ value: T?, _ message: String = "expected nil") throws {
    if value != nil { throw TestFailure(message) }
}

public struct RegisteredTest: Sendable {
    public var name: String
    public var body: @Sendable () async throws -> Void
}
