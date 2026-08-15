import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        DictationDaemon.shared.start()
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        DictationDaemon.shared.start()
    }
}

@main
struct LocalDictationApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear { DictationDaemon.shared.primeSession() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active || phase == .background {
                        DictationDaemon.shared.start()
                    }
                }
        }
    }
}
