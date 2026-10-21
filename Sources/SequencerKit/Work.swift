import Foundation
import SSeq

/// A Cakewalk work: the tracks, maps and settings of one `.WRK` (or `.MID`) file.
///
/// `Work` owns a libsseq sequence. It is a reference type; copy it with `copy()`. A `Work` may be
/// used from one thread at a time, and it must not be modified while a `Transport` built on it is
/// playing (a transport snapshots the events when it is created).
public final class Work {
    /// The libsseq handle. Exposed for the other kits; do not free it.
    public let handle: OpaquePointer

    /// An empty work with Cakewalk's defaults (120 ppq, 120 bpm, 4/4).
    public init() {
        handle = sseq_sequence_new()
    }

    init(taking handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        sseq_sequence_free(handle)
    }

    // MARK: Files

    /// Reads a `.WRK` or `.MID` file, chosen by the file's extension.
    public convenience init(contentsOf url: URL) throws {
        let isMIDI = ["mid", "midi", "smf"].contains(url.pathExtension.lowercased())
        let handle = url.withUnsafeFileSystemRepresentation { path -> OpaquePointer? in
            isMIDI ? sseq_sequence_read_mid(path) : sseq_sequence_read_wrk(path)
        }
        guard let handle = handle else { throw SequencerError.last() }
        self.init(taking: handle)
    }

    public convenience init(wrkData data: Data) throws {
        let handle = data.withUnsafeBytes { buffer -> OpaquePointer? in
            sseq_sequence_read_wrk_data(buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count)
        }
        guard let handle = handle else { throw SequencerError.last() }
        self.init(taking: handle)
    }

    public convenience init(midData data: Data) throws {
        let handle = data.withUnsafeBytes { buffer -> OpaquePointer? in
            sseq_sequence_read_mid_data(buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count)
        }
        guard let handle = handle else { throw SequencerError.last() }
        self.init(taking: handle)
    }

    /// Writes a `.WRK` file. `normalize` writes the chunk order Cakewalk uses and drops legacy
    /// chunks; otherwise the layout of the file that was read is reproduced.
    public func writeWRK(to url: URL, normalize: Bool = false) throws {
        let ok = url.withUnsafeFileSystemRepresentation { path in
            sseq_sequence_write_wrk(handle, path, normalize ? 1 : 0)
        }
        if ok == 0 { throw SequencerError.last() }
    }

    /// Writes a Standard MIDI File (format 1). `portMeta` writes Cakewalk's "MIDI Port" meta event.
    public func writeMID(to url: URL, portMeta: Bool = true) throws {
        let ok = url.withUnsafeFileSystemRepresentation { path in
            sseq_sequence_write_mid(handle, path, portMeta ? 1 : 0)
        }
        if ok == 0 { throw SequencerError.last() }
    }

    public func wrkData(normalize: Bool = false) throws -> Data {
        var out = sseq_data()
        guard sseq_sequence_write_wrk_data(handle, normalize ? 1 : 0, &out) != 0 else {
            throw SequencerError.last()
        }
        defer { sseq_data_free(&out) }
        return Data(bytes: out.bytes, count: out.size)
    }

    public func midData(portMeta: Bool = true) throws -> Data {
        var out = sseq_data()
        guard sseq_sequence_write_mid_data(handle, portMeta ? 1 : 0, &out) != 0 else {
            throw SequencerError.last()
        }
        defer { sseq_data_free(&out) }
        return Data(bytes: out.bytes, count: out.size)
    }

    public func copy() -> Work {
        Work(taking: sseq_sequence_copy(handle))
    }

    // MARK: Global settings

    /// Ticks per quarter note. Changing it does not rescale the events.
    public var ppq: Int {
        get { Int(sseq_sequence_ppq(handle)) }
        set { sseq_sequence_set_ppq(handle, Int32(newValue)) }
    }

    /// End of the last event over all tracks.
    public var endTick: Tick { sseq_sequence_end_tick(handle) }

    public var comments: String {
        get { String(cString: sseq_sequence_comments(handle)) }
        set { sseq_sequence_set_comments(handle, newValue) }
    }

    /// The global variables Cakewalk keeps in the VARS chunk.
    public enum Variable {
        case now, from, thru
        case metronomePlayback, metronomeRecording, metronomeAccent, countIn
        case patchSearchBack, zeroControllers, thruOn, autoRestart, transmitMIDISync

        var c: sseq_var {
            switch self {
            case .now: return SSEQ_VAR_NOW
            case .from: return SSEQ_VAR_FROM
            case .thru: return SSEQ_VAR_THRU
            case .metronomePlayback: return SSEQ_VAR_METRONOME_PLAYBACK
            case .metronomeRecording: return SSEQ_VAR_METRONOME_RECORDING
            case .metronomeAccent: return SSEQ_VAR_METRONOME_ACCENT
            case .countIn: return SSEQ_VAR_COUNT_IN
            case .patchSearchBack: return SSEQ_VAR_PATCH_SEARCH_BACK
            case .zeroControllers: return SSEQ_VAR_ZERO_CONTROLLERS
            case .thruOn: return SSEQ_VAR_THRU_ON
            case .autoRestart: return SSEQ_VAR_AUTO_RESTART
            case .transmitMIDISync: return SSEQ_VAR_TRANSMIT_MIDI_SYNC
            }
        }
    }

    public func value(of variable: Variable) -> Int64 {
        sseq_sequence_var(handle, variable.c)
    }

    public func flag(_ variable: Variable) -> Bool {
        value(of: variable) != 0
    }

    /// Returns false for a read-only variable.
    @discardableResult
    public func set(_ variable: Variable, to value: Int64) -> Bool {
        sseq_sequence_set_var(handle, variable.c, value) != 0
    }

    @discardableResult
    public func set(_ variable: Variable, to flag: Bool) -> Bool {
        set(variable, to: flag ? 1 : 0)
    }

    public struct Metronome: Equatable {
        public var port: Int
        public var channel: Int
        public var key: Int
        /// 0 disables the metronome note.
        public var velocity: Int
        /// Ticks; 0 disables the metronome note.
        public var duration: Int

        public init(port: Int = 0, channel: Int = 9, key: Int = 42, velocity: Int = 110, duration: Int = 1) {
            self.port = port
            self.channel = channel
            self.key = key
            self.velocity = velocity
            self.duration = duration
        }
    }

    public var metronome: Metronome {
        get {
            var c = sseq_metronome()
            sseq_sequence_metronome(handle, &c)
            return Metronome(port: Int(c.port), channel: Int(c.channel), key: Int(c.key),
                             velocity: Int(c.velocity), duration: Int(c.duration))
        }
        set {
            var c = sseq_metronome(port: Int32(newValue.port), channel: Int32(newValue.channel),
                                   key: Int32(newValue.key), velocity: Int32(newValue.velocity),
                                   duration: Int32(newValue.duration))
            sseq_sequence_set_metronome(handle, &c)
        }
    }

    public var timecode: Timecode {
        get {
            var c = sseq_timecode()
            sseq_sequence_timecode(handle, &c)
            return Timecode(rate: FrameRate(rawValue: Int(c.rate.rawValue)) ?? .fps30, offsetFrames: c.offset_frames)
        }
        set {
            var c = sseq_timecode(rate: sseq_frame_rate(rawValue: UInt32(newValue.rate.rawValue)),
                                  offset_frames: newValue.offsetFrames)
            sseq_sequence_set_timecode(handle, &c)
        }
    }

    // MARK: Tracks

    public var trackCount: Int { Int(sseq_sequence_stream_count(handle)) }

    /// Snapshots of all tracks, in file order.
    public var tracks: [Track] {
        (0..<trackCount).compactMap { track(at: $0) }
    }

    public func track(at index: Int) -> Track? {
        var c = sseq_stream_params()
        guard sseq_stream_get_params(handle, Int32(index), &c) != 0,
              let name = sseq_stream_name(handle, Int32(index)) else { return nil }
        return Track(index: index, name: String(cString: name), parameters: TrackParameters(c))
    }

    /// Index of the track with this number, or nil.
    public func indexOfTrack(number: Int) -> Int? {
        let index = sseq_sequence_find_stream(handle, Int32(number))
        return index >= 0 ? Int(index) : nil
    }

    /// Adds a track with this number (or finds the existing one) and returns its index.
    @discardableResult
    public func addTrack(number: Int) -> Int {
        Int(sseq_sequence_add_stream(handle, Int32(number)))
    }

    @discardableResult
    public func removeTrack(at index: Int) -> Bool {
        sseq_sequence_remove_stream(handle, Int32(index)) != 0
    }

    /// Writes a track's name and parameters back (the number is not changed).
    @discardableResult
    public func update(_ track: Track) -> Bool {
        var c = track.parameters.c
        return sseq_stream_set_name(handle, Int32(track.index), track.name) != 0
            && sseq_stream_set_params(handle, Int32(track.index), &c) != 0
    }

    public func endTick(ofTrack index: Int) -> Tick {
        sseq_stream_end_tick(handle, Int32(index))
    }

    // MARK: Events

    public func eventCount(inTrack index: Int) -> Int {
        Int(sseq_stream_event_count(handle, Int32(index)))
    }

    public func event(at eventIndex: Int, inTrack index: Int) -> Event? {
        var c = sseq_event()
        guard sseq_stream_event(handle, Int32(index), eventIndex, &c) != 0 else { return nil }
        var payload: Data?
        var size = 0
        if let bytes = sseq_stream_event_payload(handle, Int32(index), eventIndex, &size) {
            payload = Data(bytes: bytes, count: size)
        }
        return Event(c, payload: payload)
    }

    /// All events of a track, in time order.
    public func events(inTrack index: Int) -> [Event] {
        (0..<eventCount(inTrack: index)).compactMap { event(at: $0, inTrack: index) }
    }

    /// Inserts in time order and returns the new event's index.
    @discardableResult
    public func insert(_ event: Event, inTrack index: Int) -> Int? {
        let result: Int
        if event.kind.isString {
            let payload = event.payload ?? Data()
            result = payload.withUnsafeBytes { buffer in
                sseq_stream_insert_string_event(handle, Int32(index), event.time, event.kind.c,
                                                buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count)
            }
        } else {
            var c = event.c
            result = sseq_stream_insert_event(handle, Int32(index), &c)
        }
        return result < 0 ? nil : result // SIZE_MAX comes through as -1
    }

    /// Replaces an event (its payload is kept) and returns its new index.
    @discardableResult
    public func replaceEvent(at eventIndex: Int, inTrack index: Int, with event: Event) -> Int? {
        var c = event.c
        let result = sseq_stream_set_event(handle, Int32(index), eventIndex, &c)
        return result < 0 ? nil : result // SIZE_MAX comes through as -1
    }

    @discardableResult
    public func removeEvent(at eventIndex: Int, inTrack index: Int) -> Bool {
        sseq_stream_remove_event(handle, Int32(index), eventIndex) != 0
    }

    @discardableResult
    public func removeAllEvents(inTrack index: Int) -> Bool {
        sseq_stream_clear_events(handle, Int32(index)) != 0
    }

    // MARK: Maps

    public var tempoMap: [TempoEntry] {
        (0..<sseq_sequence_tempo_count(handle)).compactMap { i in
            var c = sseq_tempo()
            guard sseq_sequence_tempo(handle, i, &c) != 0 else { return nil }
            return TempoEntry(time: c.time, bpm100: Int(c.bpm100))
        }
    }

    public func tempo(at tick: Tick) -> TempoEntry {
        var c = sseq_tempo()
        sseq_sequence_tempo_at(handle, tick, &c)
        return TempoEntry(time: c.time, bpm100: Int(c.bpm100))
    }

    public func setTempo(at tick: Tick, bpm100: Int) {
        sseq_sequence_set_tempo(handle, tick, Int32(bpm100))
    }

    public func removeTempo(at tick: Tick) {
        sseq_sequence_remove_tempo(handle, tick)
    }

    public var meterMap: [MeterEntry] {
        (0..<sseq_sequence_meter_count(handle)).compactMap { i in
            var c = sseq_meter()
            guard sseq_sequence_meter(handle, i, &c) != 0 else { return nil }
            return MeterEntry(measure: Int(c.measure), numerator: Int(c.numerator), denominatorLog2: Int(c.denominator_log2))
        }
    }

    public func meter(atMeasure measure: Int) -> MeterEntry {
        var c = sseq_meter()
        sseq_sequence_meter_at(handle, Int32(measure), &c)
        return MeterEntry(measure: Int(c.measure), numerator: Int(c.numerator), denominatorLog2: Int(c.denominator_log2))
    }

    public func setMeter(_ entry: MeterEntry) {
        var c = sseq_meter(measure: Int32(entry.measure), numerator: Int32(entry.numerator),
                           denominator_log2: Int32(entry.denominatorLog2))
        sseq_sequence_set_meter(handle, &c)
    }

    public func removeMeter(atMeasure measure: Int) {
        sseq_sequence_remove_meter(handle, Int32(measure))
    }

    public var keyMap: [KeyEntry] {
        (0..<sseq_sequence_key_count(handle)).compactMap { i in
            var c = sseq_key()
            guard sseq_sequence_key(handle, i, &c) != 0 else { return nil }
            return KeyEntry(measure: Int(c.measure), alterations: Int(c.alterations))
        }
    }

    public func key(atMeasure measure: Int) -> KeyEntry {
        var c = sseq_key()
        sseq_sequence_key_at(handle, Int32(measure), &c)
        return KeyEntry(measure: Int(c.measure), alterations: Int(c.alterations))
    }

    public func setKey(_ entry: KeyEntry) {
        var c = sseq_key(measure: Int32(entry.measure), alterations: Int32(entry.alterations))
        sseq_sequence_set_key(handle, &c)
    }

    public var markers: [Marker] {
        (0..<sseq_sequence_marker_count(handle)).compactMap { i in
            var c = sseq_marker()
            guard sseq_sequence_marker(handle, i, &c) != 0, let name = sseq_sequence_marker_name(handle, i) else {
                return nil
            }
            return Marker(time: c.time, smpteLocked: c.smpte_locked != 0, name: String(cString: name))
        }
    }

    /// Adds a marker and returns its index (markers stay sorted by time).
    @discardableResult
    public func addMarker(_ marker: Marker) -> Int {
        var c = sseq_marker(time: marker.time, smpte_locked: marker.smpteLocked ? 1 : 0)
        return sseq_sequence_add_marker(handle, &c, marker.name)
    }

    @discardableResult
    public func removeMarker(at index: Int) -> Bool {
        sseq_sequence_remove_marker(handle, index) != 0
    }

    // MARK: Time conversions

    public func seconds(at tick: Tick) -> Double {
        sseq_sequence_tick_to_seconds(handle, tick)
    }

    public func tick(atSeconds seconds: Double) -> Tick {
        sseq_sequence_seconds_to_tick(handle, seconds)
    }

    public func mbt(at tick: Tick) -> MBT {
        var c = sseq_mbt()
        sseq_sequence_tick_to_mbt(handle, tick, &c)
        return MBT(c)
    }

    public func tick(at mbt: MBT) -> Tick {
        var c = mbt.c
        return sseq_sequence_mbt_to_tick(handle, &c)
    }

    public func hmsf(at tick: Tick) -> HMSF {
        var c = sseq_hmsf()
        sseq_sequence_tick_to_hmsf(handle, tick, &c)
        return HMSF(c)
    }

    public func tick(at hmsf: HMSF) -> Tick {
        var c = hmsf.c
        return sseq_sequence_hmsf_to_tick(handle, &c)
    }

    public func nextMeasure(after tick: Tick) -> Tick {
        sseq_sequence_next_measure(handle, tick)
    }

    public func previousMeasure(before tick: Tick) -> Tick {
        sseq_sequence_prev_measure(handle, tick)
    }

    public func startOfMeasure(_ measure: Int) -> Tick {
        sseq_sequence_measure_start(handle, Int32(measure))
    }

    /// Number of the measure that contains `tick`.
    public func measure(at tick: Tick) -> Int {
        mbt(at: tick).measure
    }

    /// The 0-based output ports the tracks with events use.
    public var portsInUse: [Int] {
        var ports = Set<Int>()
        for t in tracks where eventCount(inTrack: t.index) > 0 {
            ports.insert(t.parameters.port)
        }
        return ports.sorted()
    }
}

/// The libsseq version string.
public var libsseqVersion: String { String(cString: sseq_version()) }
