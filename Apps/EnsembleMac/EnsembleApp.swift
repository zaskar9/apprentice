import SequencerKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct EnsembleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = PlayerModel()

    var body: some Scene {
        WindowGroup {
            PlayerView(model: model)
                .onAppear { delegate.attach(model) }
                .fileImporter(isPresented: $model.showingOpenPanel, allowedContentTypes: PlayerModel.openableTypes) { result in
                    if case .success(let url) = result { model.open(url) }
                }
                .alert("Ensemble", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
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
                if model.destinations.isEmpty {
                    Text("No MIDI destinations")
                } else {
                    ForEach(model.ports, id: \.self) { port in
                        Menu("Port \(port + 1)") {
                            ForEach(model.destinations) { destination in
                                Button {
                                    model.map(port: port, to: destination.uniqueID)
                                } label: {
                                    if model.portMap[port] == destination.uniqueID {
                                        Label(destination.name, systemImage: "checkmark")
                                    } else {
                                        Text(destination.name)
                                    }
                                }
                            }
                        }
                    }
                }
                Divider()
                Button("Panic") { model.panic() }
                    .keyboardShortcut(".", modifiers: [.command])
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
