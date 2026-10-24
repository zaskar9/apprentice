import SequencerKit
import SwiftUI

/// The player window, after the Windows 3.1 Media Player: a scale with marks, a position slider,
/// play/pause, stop and eject, and the scale name.
struct PlayerView: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var playhead: Playhead
    @State private var sliderValue = 0.0

    init(model: PlayerModel) {
        self.model = model
        self.playhead = model.playhead
    }

    var body: some View {
        VStack(spacing: 8) {
            Ruler(model: model)
                .frame(height: 22)
            Slider(value: $sliderValue, in: 0...1) { editing in
                model.isScrubbing = editing
                if !editing {
                    model.seek(to: Tick((sliderValue * Double(model.endTick)).rounded()))
                }
            }
            .disabled(model.work == nil)
            HStack(spacing: 10) {
                controlButton(model.isPlaying ? "pause.fill" : "play.fill", help: model.isPlaying ? "Pause" : "Play") {
                    model.togglePlay()
                }
                .disabled(model.work == nil)
                controlButton("stop.fill", help: "Stop") { model.stop() }
                    .disabled(model.work == nil)
                controlButton("eject.fill", help: "Close") { model.close() }
                    .disabled(model.work == nil)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(model.positionText)
                        .font(.system(.body, design: .monospaced))
                    Text(model.scale == .time ? "Scale: Time (mm:ss)" : "Scale: Measures")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(width: 420)
        .navigationTitle(model.title)
        .onChange(of: playhead.position) { position in
            if !model.isScrubbing {
                sliderValue = model.endTick > 0 ? Double(position) / Double(model.endTick) : 0
            }
        }
        .onChange(of: model.endTick) { _ in sliderValue = 0 }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url = url {
                    Task { @MainActor in model.open(url) }
                }
            }
            return true
        }
    }

    private func controlButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 44, height: 24)
        }
        .help(help)
    }
}

/// Time or measure marks over the length of the work.
struct Ruler: View {
    @ObservedObject var model: PlayerModel

    var body: some View {
        GeometryReader { geometry in
            let marks = model.rulerMarks(count: max(2, Int(geometry.size.width / 60)))
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: geometry.size.height - 1))
                    path.addLine(to: CGPoint(x: width, y: geometry.size.height - 1))
                    for mark in marks {
                        let x = position(of: mark.tick, in: width)
                        path.move(to: CGPoint(x: x, y: geometry.size.height - 7))
                        path.addLine(to: CGPoint(x: x, y: geometry.size.height - 1))
                    }
                }
                .stroke(Color.secondary, lineWidth: 1)
                ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
                    let x = position(of: mark.tick, in: width)
                    Text(mark.label)
                        .font(.caption2)
                        .fixedSize()
                        .position(x: min(max(x, 12), width - 12), y: 6)
                }
            }
        }
    }

    private func position(of tick: Tick, in width: CGFloat) -> CGFloat {
        guard model.endTick > 0 else { return 0 }
        return CGFloat(Double(tick) / Double(model.endTick)) * width
    }
}
