#if canImport(LocalDictationTestSupport)
import LocalDictationTestSupport
#endif
import Foundation

@main
struct TestRunnerMain {
    static func main() async {
        var failed = 0
        let tests = allTests()
        for test in tests {
            do {
                try await test.body()
                print("PASS \(test.name)")
            } catch {
                failed += 1
                print("FAIL \(test.name): \(error)")
            }
        }
        print("\(tests.count - failed)/\(tests.count) passed")
        if failed > 0 {
            exit(1)
        }
    }
}
