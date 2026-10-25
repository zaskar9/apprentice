import SequencerKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct ApprenticeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = PlayerModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup {
            PlayerView(model: model)
                .onAppear { delegate.attach(model) }
                .fileImporter(isPresented: $model.showingOpenPanel, allowedContentTypes: PlayerModel.openableTypes) { result in
                    if case .success(let url) = result { model.open(url) }
                }
                .fileImporter(isPresented: $model.showingSoundFontPanel, allowedContentTypes: PlayerModel.soundFontTypes) { result in
                    if case .success(let url) = result { model.loadSoundFont(url) }
                }
                .sheet(isPresented: $model.showingDevicesDialog) {
                    MIDIDevicesView(model: model)
                }
                .alert("Apprentice", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                    Button("OK") { model.errorMessage = nil }
                } message: {
                    Text(model.errorMessage ?? "")
                }
        }
        .windowResizability(.contentSize)
        .commands {
            // Cakewalk's Window > New > Event list, one window per track, in the system Window menu.
            CommandGroup(before: .windowList) {
                Menu("Event list") {
                    if let work = model.work {
                        ForEach(work.tracks) { track in
                            Button("Track \(track.displayNumber): \(track.name)") {
                                openWindow(id: "event-list", value: track.index)
                            }
                        }
                    } else {
                        Text("No work open")
                    }
                }
                Divider()
            }
            CommandGroup(replacing: .newItem) {
                Button("Open…") { model.showingOpenPanel = true }
                    .keyboardShortcut("o")
                Button("Close") { model.close() }
                    .keyboardShortcut("w")
                    .disabled(model.work == nil)
            }
            CommandMenu("Settings") { // Cakewalk's Settings menu; the entries that exist so far
                Button("MIDI Devices…") { model.showingDevicesDialog = true }
                Menu("Synthesizer") {
                    Toggle("Built-in General MIDI bank", isOn: Binding(
                        get: { model.soundFontURL == nil },
                        set: { _ in model.loadSoundFont(nil) }
                    ))
                    if let url = model.soundFontURL {
                        Toggle(url.lastPathComponent, isOn: .constant(true))
                    }
                    Divider()
                    Button("Load SoundFont…") { model.showingSoundFontPanel = true }
                }
                .disabled(!model.hasBuiltInSynth)
                Divider()
                Toggle("Log MIDI to Console", isOn: $model.midiLogging)
            }
            CommandMenu("Scale") {
                Picker("Scale", selection: $model.scale) {
                    Text("Time").tag(PlayerModel.Scale.time).keyboardShortcut("1")
                    Text("Measures").tag(PlayerModel.Scale.measures).keyboardShortcut("2")
                }
                .pickerStyle(.inline)
            }
            CommandMenu("Realtime") {
                Button(model.isPlaying ? "Pause" : "Play") { model.togglePlay() }
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(model.work == nil)
                Button("Stop") { model.stop() }
                    .keyboardShortcut("s", modifiers: [])
                    .disabled(model.work == nil)
                Button("Rewind") { model.rewind() }
                    .keyboardShortcut("w", modifiers: [])
                    .disabled(model.work == nil)
                Divider()
                Button("Panic") { model.panic() }
                    .keyboardShortcut(".", modifiers: [.command])
            }
        }
        WindowGroup("Event list", id: "event-list", for: Int.self) { $trackIndex in
            if let trackIndex = trackIndex {
                EventListView(model: model, trackIndex: trackIndex)
            }
        }
    }
}

/// Receives files opened from the Finder (double-click, drag onto the icon) and hands them to the model.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private weak var model: PlayerModel?
    private var pending: [URL] = []

    func attach(_ model: PlayerModel) {
        self.model = model
        for url in pending { model.open(url) }
        pending.removeAll()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if let model = model {
            model.open(url)
        } else {
            pending.append(url)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
