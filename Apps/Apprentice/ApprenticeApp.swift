import SequencerKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct ApprenticeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = PlayerModel()

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
                .alert("Apprentice", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                    Button("OK") { model.errorMessage = nil }
                } message: {
                    Text(model.errorMessage ?? "")
                }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { model.showingOpenPanel = true }
                    .keyboardShortcut("o")
                Button("Close") { model.close() }
                    .keyboardShortcut("w")
                    .disabled(model.work == nil)
            }
            CommandMenu("Device") {
                ForEach(model.ports, id: \.self) { port in
                    Menu("Port \(port + 1)") {
                        if model.hasBuiltInSynth {
                            targetButton("Built-in Synthesizer", port: port, target: .builtInSynth)
                            Divider()
                        }
                        if model.destinations.isEmpty {
                            Text("No MIDI destinations")
                        }
                        ForEach(model.destinations) { destination in
                            targetButton(destination.name, port: port, target: .destination(destination.uniqueID))
                        }
                    }
                }
                Divider()
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
                Button("Panic") { model.panic() }
                    .keyboardShortcut(".", modifiers: [.command])
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
            }
        }
    }
}

extension ApprenticeApp {
    /// A menu item with a checkmark when the port goes to this target.
    private func targetButton(_ name: String, port: Int, target: PlayerModel.PortTarget) -> some View {
        Toggle(name, isOn: Binding(
            get: { model.portMap[port] == target },
            set: { _ in model.map(port: port, to: target) }
        ))
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
