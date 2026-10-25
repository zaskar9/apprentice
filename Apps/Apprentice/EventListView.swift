import SequencerKit
import SwiftUI

/// One row of the Event list: an event of one track, in Cakewalk's six columns.
struct EventRow: Identifiable, Equatable {
    let id: Int // index in the track
    let time: Tick
    let trk: String
    let hmsf: String
    let mbt: String
    let chn: String
    let kind: String
    let values: String
}

/// Cakewalk's Event list for one track, read-only: Trk, Hr:Mn:Sc:Fr, Meas:Beat:Tick, Chn, Kind,
/// Values. The row at the playback position is selected and follows the Now time; selecting a row
/// moves the Now time to that event.
struct EventListView: View {
    @ObservedObject var model: PlayerModel
    @ObservedObject var playhead: Playhead
    let trackIndex: Int
    @State private var selection: Int?
    @State private var rows: [EventRow] = []

    init(model: PlayerModel, trackIndex: Int) {
        self.model = model
        self.playhead = model.playhead
        self.trackIndex = trackIndex
    }

    /// The rows are built once per work (the events are read through the C API), not per redraw.
    private func makeRows() -> [EventRow] {
        guard let work = model.work, let track = work.track(at: trackIndex) else { return [] }
        let ppq = work.ppq
        return work.events(inTrack: trackIndex).enumerated().map { index, event in
            EventRow(id: index, time: event.time,
                     trk: String(track.displayNumber),
                     hmsf: work.hmsf(at: event.time).description,
                     mbt: work.mbt(at: event.time).description,
                     chn: event.channelText,
                     kind: event.kind.displayName,
                     values: event.valuesText(ppq: ppq))
        }
    }

    private var title: String {
        guard let track = model.work?.track(at: trackIndex) else { return "Event list" }
        return "Event list - Track \(track.displayNumber): \(track.name)"
    }

    var body: some View {
        ScrollViewReader { proxy in
            table(proxy)
        }
    }

    private func table(_ proxy: ScrollViewProxy) -> some View {
        Table(rows, selection: $selection) {
            TableColumn("Trk", value: \.trk).width(min: 30, ideal: 36, max: 50)
            TableColumn("Hr:Mn:Sc:Fr") { row in Text(row.hmsf).monospacedDigit() }.width(min: 90, ideal: 96)
            TableColumn("Meas:Beat:Tick") { row in Text(row.mbt).monospacedDigit() }.width(min: 100, ideal: 110)
            TableColumn("Chn", value: \.chn).width(min: 30, ideal: 36, max: 50)
            TableColumn("Kind", value: \.kind).width(min: 50, ideal: 60, max: 80)
            TableColumn("Values") { row in Text(row.values).monospacedDigit() }
        }
        .font(.system(.body, design: .monospaced))
        .navigationTitle(title)
        .frame(minWidth: 520, minHeight: 240)
        .onAppear {
            rows = makeRows()
            let rows = self.rows
            // The table lays its rows out after this turn of the run loop; scroll then.
            DispatchQueue.main.async { follow(rows, position: playhead.position, proxy: proxy) }
        }
        .onChange(of: model.fileURL) { _ in
            rows = makeRows()
            follow(rows, position: playhead.position, proxy: proxy)
        }
        .onChange(of: playhead.position) { position in follow(rows, position: position, proxy: proxy) }
        .onChange(of: selection) { newValue in
            // A row chosen by the user moves the Now time there; a row set by follow() is already there.
            guard let id = newValue, let row = rows.first(where: { $0.id == id }), row.time != playhead.position,
                  !model.isPlaying else { return }
            model.seek(to: row.time)
        }
    }

    /// Selects the cursor row for a position (the first event at or after it, or the last event)
    /// and scrolls it into view, so the list follows playback.
    private func follow(_ rows: [EventRow], position: Tick, proxy: ScrollViewProxy) {
        guard !rows.isEmpty else { return }
        let row = rows.first { $0.time >= position } ?? rows[rows.count - 1]
        if selection != row.id {
            selection = row.id
            proxy.scrollTo(row.id, anchor: .center)
        }
    }
}
