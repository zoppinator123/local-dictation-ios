import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        DictationDaemon.shared.shutdownAudio()
        DictationDaemon.shared.start()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--smoke-prime") {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 750_000_000)
                DictationDaemon.shared.primeSession()
            }
        }
        #endif
        return true
    }
}

@main
struct LocalDictationApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
