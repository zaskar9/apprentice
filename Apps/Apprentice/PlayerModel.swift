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

    /// An output device as the MIDI Devices dialog lists it: the built-in synthesizer or a CoreMIDI
    /// destination. The checked devices become Cakewalk ports 1, 2, 3 in list order, as in
    /// Cakewalk's Settings > MIDI Devices.
    enum DeviceID: Hashable {
        case builtInSynth
        case destination(MIDIUniqueID)

        static let builtInSynthKey: Int = -1
        var stored: Int {
            switch self {
            case .builtInSynth: return DeviceID.builtInSynthKey
            case .destination(let id): return Int(id)
            }
        }
        init(stored: Int) {
            self = stored == DeviceID.builtInSynthKey ? .builtInSynth : .destination(MIDIUniqueID(stored))
        }
    }

    struct OutputDevice: Identifiable, Equatable {
        let id: DeviceID
        let name: String
        var checked: Bool
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
    @Published private(set) var sources: [MIDIDestination] = []
    /// The output devices in the user's order, present ones only; checked ones are the ports.
    @Published private(set) var outputDevices: [OutputDevice] = []
    @Published var showingDevicesDialog = false
    @Published private(set) var soundFontURL: URL?
    @Published var showingOpenPanel = false
    @Published var showingSoundFontPanel = false
    @Published var midiLogging = false {
        didSet { MIDILog.enabled = midiLogging }
    }
    @Published var errorMessage: String?
    /// True while the user drags the position slider; the timer then leaves `position` alone.
    @Published var isScrubbing = false

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
        if let order = UserDefaults.standard.array(forKey: "deviceOrder") as? [Int] {
            rememberedOrder = order.map { DeviceID(stored: $0) }
        }
        if let checked = UserDefaults.standard.array(forKey: "checkedDevices") as? [Int] {
            rememberedChecked = Set(checked.map { DeviceID(stored: $0) })
        } else {
            rememberedChecked = [.builtInSynth] // a fresh install plays through the built-in synthesizer
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
            applyRouting()
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

    /// Stops and silences everything that can make a sound: the transport's panic goes through the
    /// current routes; the two outputs are told directly as well, so a device that is no longer
    /// routed (or never was) is reached too.
    func panic() {
        if let confined = confined {
            stopTimer()
            position = queue.sync {
                confined.transport.panic()
                return confined.transport.now
            }
            isPlaying = false
        }
        coreMIDI?.allNotesOff(allDestinations: true)
        synth?.allNotesOff(now: true)
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

    /// Every device the user has ever ordered or checked, present or not, so that an unplugged
    /// interface keeps its place and its port when it comes back.
    private var rememberedOrder: [DeviceID] = []
    private var rememberedChecked: Set<DeviceID> = []

    /// The device each port of the open work goes to, for comparing routings.
    private func routing(of devices: [OutputDevice]) -> [DeviceID?] {
        let checked = devices.filter { $0.checked }
        return ports.map { port in checked.isEmpty ? nil : checked[min(port, checked.count - 1)].id }
    }

    /// Routes must not change under a running transport: the note-offs of notes sounding on the
    /// old device would go to the new one and the old one would hang. Pausing first silences
    /// through the old routes (and discards what is scheduled); Space continues afterwards.
    private func pauseIfRoutingChanges(to devices: [OutputDevice]) {
        if isPlaying, routing(of: devices) != routing(of: outputDevices) {
            pause()
        }
    }

    /// Rebuilds the device list from what is present now, in the remembered order, with new
    /// devices appended unchecked.
    func refreshDestinations() {
        destinations = system?.destinations ?? []
        sources = system?.sources ?? []
        var present: [DeviceID: String] = [:]
        if synth != nil { present[.builtInSynth] = "Built-in Synthesizer" }
        for d in destinations { present[.destination(d.uniqueID)] = d.name }
        var list: [OutputDevice] = []
        for id in rememberedOrder {
            if let name = present[id] {
                list.append(OutputDevice(id: id, name: name, checked: rememberedChecked.contains(id)))
            }
        }
        let known = Set(list.map { $0.id })
        if synth != nil, !known.contains(.builtInSynth) {
            list.append(OutputDevice(id: .builtInSynth, name: "Built-in Synthesizer",
                                     checked: rememberedChecked.contains(.builtInSynth)))
        }
        for d in destinations where !known.contains(.destination(d.uniqueID)) {
            let id = DeviceID.destination(d.uniqueID)
            list.append(OutputDevice(id: id, name: d.name, checked: rememberedChecked.contains(id)))
        }
        pauseIfRoutingChanges(to: list) // a device that vanished or appeared may move a port
        outputDevices = list
        applyRouting()
    }

    /// The devices behind ports 1, 2, 3, ...: the checked devices in list order.
    var portDevices: [OutputDevice] { outputDevices.filter { $0.checked } }

    /// The device a 0-based port goes to; ports beyond the last checked device use the last one,
    /// nil when no device is checked.
    func device(forPort port: Int) -> OutputDevice? {
        let ports = portDevices
        guard !ports.isEmpty else { return nil }
        return ports[min(max(port, 0), ports.count - 1)]
    }

    /// Takes the dialog's result: the full list in its new order with its check marks.
    func applyDeviceSettings(_ devices: [OutputDevice]) {
        pauseIfRoutingChanges(to: devices)
        outputDevices = devices
        // Keep absent devices in the remembered order, after the present ones.
        let presentIDs = devices.map { $0.id }
        rememberedOrder = presentIDs + rememberedOrder.filter { !presentIDs.contains($0) }
        for d in devices {
            if d.checked { rememberedChecked.insert(d.id) } else { rememberedChecked.remove(d.id) }
        }
        UserDefaults.standard.set(rememberedOrder.map { $0.stored }, forKey: "deviceOrder")
        UserDefaults.standard.set(rememberedChecked.map { $0.stored }, forKey: "checkedDevices")
        applyRouting()
    }

    /// Points the router's ports at the checked devices.
    private func applyRouting() {
        let used = Set(ports).union(0..<max(1, portDevices.count))
        var coreMIDIMap: [Int: MIDIDestination] = [:]
        for port in used {
            switch device(forPort: port)?.id {
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

    /// "Port 1: Built-in Synthesizer" for each port the open work uses, for the player window.
    var portSummary: [String] {
        ports.map { port in
            let name = device(forPort: port)?.name ?? "no device"
            return "Port \(port + 1): \(name)"
        }
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

    var positionText: String { positionText(at: position) }

    /// The counter text for a position, in the current scale.
    func positionText(at tick: Tick) -> String {
        guard let work = work else { return "" }
        switch scale {
        case .time:
            let total = work.seconds(at: tick)
            let seconds = Int(total.rounded(.down))
            let hundredths = Int((total - Double(seconds)) * 100)
            return String(format: "%d:%02d.%02d", seconds / 60, seconds % 60, hundredths)
        case .measures:
            return work.mbt(at: tick).description
        }
    }

    /// Evenly spaced ruler marks over the work, as (tick, label) pairs.
    /// Regular marks from the start, plus one at the end of the work. When the end mark would crowd
    /// the last regular mark (closer than about two thirds of a step), the regular one gives way.
    func rulerMarks(count: Int) -> [(tick: Tick, label: String)] {
        guard let work = work, endTick > 0, count > 1 else { return [] }
        var marks: [(tick: Tick, label: String)]
        let endLabel: String
        let crowded: Bool
        switch scale {
        case .time:
            let total = work.seconds(at: endTick)
            let step = PlayerModel.niceStep(total / Double(count - 1), candidates: [1, 2, 5, 10, 15, 30, 60, 120, 300, 600])
            let regular = Array(stride(from: 0.0, to: total, by: step))
            marks = regular.map { s -> (tick: Tick, label: String) in
                let tick = work.tick(atSeconds: s)
                return (tick: tick, label: label(for: tick))
            }
            endLabel = label(for: endTick)
            crowded = total - (regular.last ?? 0) < step * 0.65
        case .measures:
            let measures = work.measure(at: max(0, endTick - 1))
            let step = max(1, Int(PlayerModel.niceStep(Double(measures) / Double(count - 1), candidates: [1, 2, 5, 10, 15, 20, 25, 50, 100])))
            // Measure 1, then the multiples of the step (10, 20, 30, ...); small steps count on from 1.
            let regular = [1] + Array(stride(from: step < 5 ? 1 + step : step, to: measures, by: step))
            marks = regular.map { m -> (tick: Tick, label: String) in
                (tick: work.startOfMeasure(m), label: String(m))
            }
            endLabel = String(measures)
            crowded = Double(measures - (regular.last ?? 1)) < Double(step) * 0.65
        }
        if crowded, marks.count > 1 {
            marks.removeLast()
        }
        if marks.last?.label != endLabel {
            marks.append((tick: endTick, label: endLabel))
        }
        return marks
    }

    private static func niceStep(_ raw: Double, candidates: [Double]) -> Double {
        candidates.first { $0 >= raw } ?? candidates.last ?? raw
    }
}
