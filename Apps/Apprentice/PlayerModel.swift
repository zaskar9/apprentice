import Combine
import CoreMIDI
import CoreMIDIKit
import Foundation
import SequencerKit
import SynthKit
import UniformTypeIdentifiers

/// The playback position, published separately from the rest of the player's state: it changes
/// many times a second, and anything that observes it (the window) is re-rendered that often.
/// The menus observe only `PlayerModel`, so they stay open while playing.
@MainActor
final class Playhead: ObservableObject {
    @Published var position: Tick = 0
}

/// A transport confined to `PlayerModel.queue`: every call goes through that serial queue, which is
/// what makes it safe to capture in the queue's `@Sendable` closures. `Transport` itself is not
/// thread-safe and stays non-Sendable in SequencerKit.
final class ConfinedTransport: @unchecked Sendable {
    let transport: Transport

    init(_ transport: Transport) {
        self.transport = transport
    }
}

/// The player's state: the open work, the transport and its output, and the position shown in the
/// window. The transport runs on its own serial queue; everything published here is on the main
/// thread.
@MainActor
final class PlayerModel: ObservableObject {
    enum Scale: String, CaseIterable {
        case time
        case measures
    }

    /// Where a Cakewalk port goes: the built-in synthesizer or a CoreMIDI destination.
    enum PortTarget: Equatable {
        case builtInSynth
        case destination(MIDIUniqueID)

        static let builtInSynthKey: Int = -1
        var stored: Int {
            switch self {
            case .builtInSynth: return PortTarget.builtInSynthKey
            case .destination(let id): return Int(id)
            }
        }
        init(stored: Int) {
            self = stored == PortTarget.builtInSynthKey ? .builtInSynth : .destination(MIDIUniqueID(stored))
        }
    }

    static let workType = UTType(importedAs: "io.github.zaskar9.apprentice.cakewalk-work", conformingTo: .data)
    static let openableTypes: [UTType] = [workType, .midi]
    static let soundFontTypes: [UTType] = [
        UTType(importedAs: "io.github.zaskar9.apprentice.soundfont", conformingTo: .data),
        UTType(importedAs: "io.github.zaskar9.apprentice.dls", conformingTo: .data),
    ]

    @Published private(set) var work: Work?
    @Published private(set) var fileURL: URL?
    @Published private(set) var isPlaying = false
    let playhead = Playhead()
    private(set) var position: Tick {
        get { playhead.position }
        set { playhead.position = newValue }
    }
    @Published private(set) var endTick: Tick = 0
    @Published var scale: Scale = .time {
        didSet { UserDefaults.standard.set(scale.rawValue, forKey: "scale") }
    }
    @Published private(set) var destinations: [MIDIDestination] = []
    @Published private(set) var portMap: [Int: PortTarget] = [:]
    @Published private(set) var soundFontURL: URL?
    @Published var showingOpenPanel = false
    @Published var showingSoundFontPanel = false
    @Published var midiLogging = false {
        didSet { MIDILog.enabled = midiLogging }
    }
    @Published var errorMessage: String?
    /// True while the user drags the position slider; the timer then leaves `position` alone.
    var isScrubbing = false

    private let clock = HostClock()
    private var system: MIDISystem?
    private var coreMIDI: CoreMIDIOutput?
    private var synth: BuiltInSynth?
    private let router = PortRouter()
    private var confined: ConfinedTransport?
    private let queue = DispatchQueue(label: "io.github.zaskar9.apprentice.transport", qos: .userInteractive)
    private var timer: DispatchSourceTimer?

    init() {
        if let saved = UserDefaults.standard.string(forKey: "scale"), let s = Scale(rawValue: saved) {
            scale = s
        }
        if let saved = UserDefaults.standard.dictionary(forKey: "portMap") as? [String: Int] {
            for (key, value) in saved {
                if let port = Int(key) { portMap[port] = PortTarget(stored: value) }
            }
        }
        do {
            synth = try BuiltInSynth(clock: clock)
        } catch {
            errorMessage = "The built-in synthesizer is not available: \(error)"
        }
        do {
            let system = try MIDISystem()
            self.system = system
            coreMIDI = CoreMIDIOutput(system: system, clock: clock)
            system.setupChanged = { [weak self] in
                Task { @MainActor in self?.refreshDestinations() }
            }
        } catch {
            errorMessage = "CoreMIDI is not available: \(error)"
        }
        restoreSoundFont()
        refreshDestinations()
    }

    // MARK: Files

    var title: String {
        guard let url = fileURL else { return "Apprentice" }
        let state = isPlaying ? "playing" : (position > 0 ? "paused" : "stopped")
        return "Apprentice - \(url.lastPathComponent) (\(state))"
    }

    func open(_ url: URL) {
        close()
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let work = try Work(contentsOf: url)
            self.work = work
            fileURL = url
            endTick = work.endTick
            position = 0
            ensurePortMap(for: work)
            synth?.preload(for: work)
            try makeTransport()
        } catch {
            errorMessage = "\(url.lastPathComponent): \(error)"
            self.work = nil
            fileURL = nil
        }
    }

    func close() {
        stopTimer()
        let old = confined
        queue.sync {
            old?.transport.stop()
        }
        confined = nil
        work = nil
        fileURL = nil
        isPlaying = false
        position = 0
        endTick = 0
    }

    private func makeTransport() throws {
        guard let work = work else { return }
        var options = PlaybackOptions(from: work)
        options.lookAhead = 0.1
        let transport = try Transport(work: work, clock: clock, output: router, options: options)
        confined = ConfinedTransport(transport)
    }

    // MARK: Transport

    /// The ports the open work uses (at least port 1, so the Device menu is never empty).
    var ports: [Int] {
        let used = work?.portsInUse ?? []
        return used.isEmpty ? [0] : used
    }

    func togglePlay() {
        if isPlaying { pause() } else { play() }
    }

    func play() {
        guard let confined = confined else { return }
        if position >= endTick, endTick > 0 {
            queue.sync { confined.transport.rewind() }
        }
        isPlaying = true
        queue.async { confined.transport.play() }
        startTimer()
    }

    func pause() {
        guard let confined = confined else { return }
        stopTimer()
        position = queue.sync {
            confined.transport.stop()
            return confined.transport.now
        }
        isPlaying = false
    }

    func stop() {
        guard let confined = confined else { return }
        stopTimer()
        queue.sync { confined.transport.rewind() }
        isPlaying = false
        position = 0
    }

    func rewind() {
        guard let confined = confined else { return }
        let wasPlaying = isPlaying
        queue.sync {
            if wasPlaying { confined.transport.seek(to: 0) } else { confined.transport.rewind() }
        }
        position = 0
    }

    func seek(to tick: Tick) {
        guard let confined = confined else { return }
        let target = max(0, min(tick, endTick))
        queue.sync { confined.transport.seek(to: target) }
        position = target
    }

    func panic() {
        guard let confined = confined else {
            coreMIDI?.allNotesOff()
            synth?.allNotesOff(now: true)
            return
        }
        stopTimer()
        position = queue.sync {
            confined.transport.panic()
            return confined.transport.now
        }
        isPlaying = false
    }

    private func startTimer() {
        stopTimer()
        guard let confined = confined else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        var ticks = 0
        timer.setEventHandler { [weak self] in
            let running = confined.transport.pump()
            ticks += 1
            if !running || ticks % 4 == 0 {
                let now = confined.transport.now
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    if !self.isScrubbing { self.position = now }
                    if !running {
                        self.isPlaying = false
                        self.stopTimer()
                    }
                }
            }
        }
        timer.resume()
        self.timer = timer
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    // MARK: Devices

    var hasBuiltInSynth: Bool { synth != nil }

    func refreshDestinations() {
        destinations = system?.destinations ?? []
        if let work = work {
            ensurePortMap(for: work) // a destination may have appeared after the file was opened
        } else {
            applyPortMap()
        }
    }

    func map(port: Int, to target: PortTarget) {
        portMap[port] = target
        savePortMap()
        applyPortMap()
    }

    private func isPresent(_ target: PortTarget) -> Bool {
        switch target {
        case .builtInSynth: return synth != nil
        case .destination(let id): return destinations.contains { $0.uniqueID == id }
        }
    }

    /// Maps every port the work uses that has no present target: to the built-in synthesizer,
    /// or else to the first CoreMIDI destination.
    private func ensurePortMap(for work: Work) {
        let fallback: PortTarget? = synth != nil
            ? PortTarget.builtInSynth
            : destinations.first.map { PortTarget.destination($0.uniqueID) }
        var changed = false
        for port in ports {
            if let target = portMap[port], isPresent(target) { continue }
            if let fallback = fallback {
                portMap[port] = fallback
                changed = true
            }
        }
        if changed { savePortMap() }
        applyPortMap()
    }

    private func applyPortMap() {
        var coreMIDIMap: [Int: MIDIDestination] = [:]
        for port in Set(portMap.keys).union(ports) {
            switch portMap[port] {
            case .builtInSynth?:
                if let synth = synth {
                    router.setRoute(PortRouter.Route(output: synth, port: 0), forPort: port)
                } else {
                    router.setRoute(nil, forPort: port)
                }
            case .destination(let id)?:
                if let destination = destinations.first(where: { $0.uniqueID == id }), let coreMIDI = coreMIDI {
                    coreMIDIMap[port] = destination
                    router.setRoute(PortRouter.Route(output: coreMIDI, port: port), forPort: port)
                } else {
                    router.setRoute(nil, forPort: port)
                }
            case nil:
                router.setRoute(nil, forPort: port)
            }
        }
        coreMIDI?.portMap = coreMIDIMap
    }

    private func savePortMap() {
        var saved: [String: Int] = [:]
        for (port, target) in portMap { saved[String(port)] = target.stored }
        UserDefaults.standard.set(saved, forKey: "portMap")
    }

    // MARK: Synthesizer

    private var soundFontAccess: URL?

    /// Loads a soundfont into the built-in synthesizer (nil: the system's General MIDI bank) and
    /// remembers it across launches.
    func loadSoundFont(_ url: URL?) {
        guard let synth = synth else { return }
        if let old = soundFontAccess {
            old.stopAccessingSecurityScopedResource()
            soundFontAccess = nil
        }
        if let url = url, url.startAccessingSecurityScopedResource() {
            soundFontAccess = url
        }
        do {
            try synth.loadSoundFont(url)
            if let work = work { synth.preload(for: work) }
            soundFontURL = url
            if let url = url, let bookmark = try? url.bookmarkData(options: .withSecurityScope) {
                UserDefaults.standard.set(bookmark, forKey: "soundFont")
            } else {
                UserDefaults.standard.removeObject(forKey: "soundFont")
            }
        } catch {
            errorMessage = "\(error)"
            soundFontURL = synth.soundFontURL
        }
    }

    private func restoreSoundFont() {
        guard let bookmark = UserDefaults.standard.data(forKey: "soundFont") else { return }
        var stale = false
        if let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, bookmarkDataIsStale: &stale) {
            loadSoundFont(url)
        }
    }

    // MARK: Display

    func label(for tick: Tick) -> String {
        guard let work = work else { return scale == .time ? "0:00" : "1" }
        switch scale {
        case .time:
            let seconds = Int(work.seconds(at: tick).rounded(.down))
            return String(format: "%d:%02d", seconds / 60, seconds % 60)
        case .measures:
            return String(work.measure(at: tick))
        }
    }

    var positionText: String {
        guard let work = work else { return "" }
        switch scale {
        case .time:
            let total = work.seconds(at: position)
            let seconds = Int(total.rounded(.down))
            let hundredths = Int((total - Double(seconds)) * 100)
            return String(format: "%d:%02d.%02d", seconds / 60, seconds % 60, hundredths)
        case .measures:
            return work.mbt(at: position).description
        }
    }

    /// Evenly spaced ruler marks over the work, as (tick, label) pairs.
    func rulerMarks(count: Int) -> [(tick: Tick, label: String)] {
        guard let work = work, endTick > 0, count > 1 else { return [] }
        switch scale {
        case .time:
            let total = work.seconds(at: endTick)
            let step = PlayerModel.niceStep(total / Double(count - 1), candidates: [1, 2, 5, 10, 15, 30, 60, 120, 300, 600])
            return stride(from: 0.0, through: total, by: step).map { s -> (tick: Tick, label: String) in
                let tick = work.tick(atSeconds: s)
                return (tick: tick, label: label(for: tick))
            }
        case .measures:
            let measures = work.measure(at: max(0, endTick - 1))
            let step = Int(PlayerModel.niceStep(Double(measures) / Double(count - 1), candidates: [1, 2, 4, 8, 16, 32, 64]))
            return stride(from: 1, through: measures, by: max(1, step)).map { m -> (tick: Tick, label: String) in
                (tick: work.startOfMeasure(m), label: String(m))
            }
        }
    }

    private static func niceStep(_ raw: Double, candidates: [Double]) -> Double {
        candidates.first { $0 >= raw } ?? candidates.last ?? raw
    }
}
