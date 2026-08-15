import AVFoundation
import Speech
import SwiftUI

struct ContentView: View {
    @StateObject private var store = HostSettingsController()
    @StateObject private var hostDictation = HostDictationController()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    readinessCard
                    if hostDictation.isActive {
                        hostRecordingCard
                    }
                    styleCard
                    vocabularyCard
                    howToCard
                }
                .padding()
            }
            .navigationTitle("Local Dictation")
            .background(Color(.systemGroupedBackground))
        }
        .onAppear {
            store.refresh()
            DictationDaemon.shared.start()
            DictationDaemon.shared.shutdownAudio()
            Task { await store.requestPermissions() }
        }
        .onOpenURL { url in
            store.refresh()
            if url.absoluteString.hasPrefix(AppRoute.dictate.rawValue) || url.absoluteString.hasPrefix(AppRoute.root.rawValue) {
                DictationDaemon.shared.start()
            }
        }
        .alert("Microphone and Speech", isPresented: $store.showingPermissionAlert) {
            Button("Open Settings") { store.openSettings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Local Dictation needs Microphone and Speech Recognition to turn speech into text on this iPhone.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Speak in any app.")
                .font(.largeTitle.bold())
            Text("Add the Local Dictation keyboard, allow Full Access, then tap the microphone while Messages, Mail, Slack, or any other text field is open.")
                .foregroundStyle(.secondary)
        }
    }

    private var readinessCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Setup")
                .font(.headline)
            ForEach(store.readiness.steps) { step in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: step.complete ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(step.complete ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title).fontWeight(.semibold)
                        Text(step.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Button("Refresh") { store.refresh() }
                Button("Request Permissions") { Task { await store.requestPermissions() } }
                Button("Open Keyboard Settings") { store.openKeyboardSettings() }
            }
            .buttonStyle(.bordered)
            Button("Turn microphone off") {
                DictationDaemon.shared.shutdownAudio()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
    }

    private var hostRecordingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(hostDictation.statusTitle).font(.headline)
            Text(hostDictation.partialText.isEmpty ? "Speak now. Return to the previous app when the transcript appears in the keyboard." : hostDictation.partialText)
                .foregroundStyle(.secondary)
            Button(hostDictation.isRecording ? "Stop & Save" : "Close") {
                if hostDictation.isRecording {
                    hostDictation.stop()
                } else {
                    hostDictation.reset()
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }

    private var styleCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Writing style")
                .font(.headline)
            Picker("Style", selection: $store.settings.style) {
                ForEach(WritingStyle.allCases, id: \.self) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: store.settings.style) { _, _ in store.save() }
            Text(store.settings.style.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Tap the mic to start. Tap again to insert the transcript.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
    }

    private var vocabularyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Custom words")
                .font(.headline)
            Text("Add names and product terms the keyboard should keep exactly, such as Haven or StaydOS.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                TextField("Heard", text: $store.draftPhrase)
                TextField("Write", text: $store.draftReplacement)
                Button("Add") { store.addVocabulary() }
                    .disabled(store.draftPhrase.count < 2 || store.draftReplacement.isEmpty)
            }
            ForEach(store.vocabulary) { entry in
                HStack {
                    Text("\(entry.phrase) → \(entry.replacement)")
                    Spacer()
                    Button("Remove", role: .destructive) { store.removeVocabulary(entry) }
                }
            }
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
    }

    private var howToCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Use it like Wispr Flow")
                .font(.headline)
            labeled("1", "Open Messages, Mail, Slack, Notes, or any app with a text field.")
            labeled("2", "Hold the globe key and switch to Local Dictation.")
            labeled("3", "Tap the microphone, speak, then tap again to insert.")
            labeled("4", "Cleaned text is inserted at the cursor. Use the letter keys if you need to edit.")
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
    }

    private func labeled(_ index: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(index).fontWeight(.bold).frame(width: 18)
            Text(text)
        }
    }
}
