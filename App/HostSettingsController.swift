import AVFoundation
import Speech
import SwiftUI
import UIKit

@MainActor
final class HostSettingsController: ObservableObject {
    @Published var readiness = KeyboardReadiness()
    @Published var settings = KeyboardSettings()
    @Published var vocabulary: [VocabularyEntry] = []
    @Published var draftPhrase = ""
    @Published var draftReplacement = ""
    @Published var showingPermissionAlert = false

    private var vocabularyStore: VocabularyStore
    private var settingsPersister: FileSettingsPersister

    init() {
        let directory = AppGroupPaths.containerURL() ?? FileManager.default.temporaryDirectory
        vocabularyStore = VocabularyStore(persister: FileVocabularyPersister(fileURL: directory.appendingPathComponent(AppGroupPaths.vocabularyFileName)))
        settingsPersister = FileSettingsPersister(fileURL: directory.appendingPathComponent(AppGroupPaths.settingsFileName))
        vocabulary = vocabularyStore.all()
        settings = (try? settingsPersister.load()) ?? KeyboardSettings()
        refresh()
    }

    func refresh() {
        readiness = KeyboardReadiness(
            keyboardEnabled: Self.isKeyboardEnabled(),
            fullAccessGranted: Self.hasFullAccess(),
            microphoneGranted: AVAudioApplication.shared.recordPermission == .granted,
            speechAuthorized: SFSpeechRecognizer.authorizationStatus() == .authorized
        )
        vocabulary = vocabularyStore.all()
        settings = (try? settingsPersister.load()) ?? settings
    }

    func save() {
        try? settingsPersister.save(settings)
    }

    func addVocabulary() {
        _ = try? vocabularyStore.add(phrase: draftPhrase, replacement: draftReplacement)
        draftPhrase = ""
        draftReplacement = ""
        vocabulary = vocabularyStore.all()
    }

    func removeVocabulary(_ entry: VocabularyEntry) {
        try? vocabularyStore.remove(id: entry.id)
        vocabulary = vocabularyStore.all()
    }

    func requestPermissions() async {
        let mic = await AVAudioApplication.requestRecordPermission()
        let speech: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        refresh()
        if !mic || speech != .authorized {
            showingPermissionAlert = true
        }
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    func openKeyboardSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private static func isKeyboardEnabled() -> Bool {
        let keyboards = UserDefaults.standard.object(forKey: "AppleKeyboards") as? [String] ?? []
        return keyboards.contains { $0.contains("LocalDictationKeyboard") || $0.contains("com.jackzoppa.LocalDictation") }
    }

    private static func hasFullAccess() -> Bool {
        // The host app cannot read the extension's full-access switch directly.
        // The keyboard writes this flag into the App Group after it launches.
        let url = AppGroupPaths.containerURL()?.appendingPathComponent("full-access.json")
        guard let url, let data = try? Data(contentsOf: url),
              let flag = try? JSONDecoder().decode(Bool.self, from: data) else {
            return false
        }
        return flag
    }
}
