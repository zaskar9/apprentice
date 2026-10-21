import Foundation
import SSeq

/// A short MIDI message (1 to 3 bytes) with an absolute time on the application's clock.
public struct MIDIMessage: Equatable {
    public var time: Double
    /// 0-based output port, as in the work.
    public var port: Int
    public var bytes: [UInt8]

    public init(time: Double, port: Int, bytes: [UInt8]) {
        self.time = time
        self.port = port
        self.bytes = Array(bytes.prefix(3))
    }

    init(_ c: sseq_midi_message) {
        let all = [c.data.0, c.data.1, c.data.2]
        self.init(time: c.time, port: Int(c.port), bytes: Array(all.prefix(Int(c.size))))
    }

    var c: sseq_midi_message {
        var m = sseq_midi_message()
        m.time = time
        m.port = Int32(port)
        m.size = UInt8(bytes.count)
        if bytes.count > 0 { m.data.0 = bytes[0] }
        if bytes.count > 1 { m.data.1 = bytes[1] }
        if bytes.count > 2 { m.data.2 = bytes[2] }
        return m
    }

    public var status: UInt8 { bytes.first ?? 0 }
    public var channel: UInt8 { status & 0x0f }
    public var isNoteOn: Bool { (status & 0xf0) == 0x90 && bytes.count > 2 && bytes[2] != 0 }
    public var isNoteOff: Bool {
        (status & 0xf0) == 0x80 || ((status & 0xf0) == 0x90 && bytes.count > 2 && bytes[2] == 0)
    }
}

/// Monotonic time in seconds. The transport schedules against this clock, and MIDI input must be
/// stamped with it for recording.
public protocol SequencerClock: AnyObject {
    var now: Double { get }
}

/// MIDI output. Messages arrive with timestamps up to the look-ahead in the future and must be
/// delivered at those times (CoreMIDI does this natively). All calls come from the thread that
/// pumps the transport.
public protocol MIDIOutput: AnyObject {
    func send(_ message: MIDIMessage)
    func sendSysex(at time: Double, port: Int, bytes: [UInt8])
    /// Called at the end of every pump; batching outputs hand their packets over here.
    func flush()
}

public extension MIDIOutput {
    func flush() {}
}

/// Playback settings (see libsseq's PlaybackOptions).
public struct PlaybackOptions: Equatable {
    public var lookAhead: Double
    public var tempoRatio: Double
    public var sendTrackParameters: Bool
    public var chase: Bool
    public var zeroControllersOnStop: Bool
    public var sendSysexBanks: Bool
    public var loop: ClosedRange<Tick>?
    public var metronome: Bool
    public var metronomeAccent: Bool
    public var countInMeasures: Int
    public var stopAtEnd: Bool

    /// libsseq's defaults.
    public init() {
        var c = sseq_playback_options()
        sseq_playback_options_default(&c)
        self.init(c)
    }

    /// Options from the work's own settings; `recording` picks the recording metronome, the
    /// count-in and running past the end.
    public init(from work: Work, recording: Bool = false) {
        var c = sseq_playback_options()
        sseq_playback_options_from_sequence(work.handle, recording ? 1 : 0, &c)
        self.init(c)
    }

    init(_ c: sseq_playback_options) {
        lookAhead = c.look_ahead
        tempoRatio = c.tempo_ratio
        sendTrackParameters = c.send_stream_parameters != 0
        chase = c.chase != 0
        zeroControllersOnStop = c.zero_controllers_on_stop != 0
        sendSysexBanks = c.send_sysex_banks != 0
        loop = c.has_loop != 0 && c.loop_thru > c.loop_from ? c.loop_from...c.loop_thru : nil
        metronome = c.metronome != 0
        metronomeAccent = c.metronome_accent != 0
        countInMeasures = Int(c.count_in_measures)
        stopAtEnd = c.stop_at_end != 0
    }

    var c: sseq_playback_options {
        var o = sseq_playback_options()
        o.look_ahead = lookAhead
        o.tempo_ratio = tempoRatio
        o.send_stream_parameters = sendTrackParameters ? 1 : 0
        o.chase = chase ? 1 : 0
        o.zero_controllers_on_stop = zeroControllersOnStop ? 1 : 0
        o.send_sysex_banks = sendSysexBanks ? 1 : 0
        o.has_loop = loop != nil ? 1 : 0
        o.loop_from = loop?.lowerBound ?? 0
        o.loop_thru = loop?.upperBound ?? 0
        o.metronome = metronome ? 1 : 0
        o.metronome_accent = metronomeAccent ? 1 : 0
        o.count_in_measures = Int32(countInMeasures)
        o.stop_at_end = stopAtEnd ? 1 : 0
        return o
    }
}

/// Playback of a work: play/stop/seek, a position that follows the clock, mute and solo, and
/// look-ahead scheduling of timestamped messages into a `MIDIOutput`.
///
/// Call `pump()` every 10 to 20 ms while playing. The transport is not thread-safe: use it from one
/// queue, including `pump()`.
public final class Transport {
    /// Receives Text, MCI command and Wave events when their time comes (on the pumping thread).
    public typealias StringEventHandler = (_ trackNumber: Int, _ event: Event, _ time: Double) -> Void

    final class Context {
        let clock: SequencerClock
        let output: MIDIOutput
        var stringEventHandler: StringEventHandler?

        init(clock: SequencerClock, output: MIDIOutput) {
            self.clock = clock
            self.output = output
        }
    }

    let handle: OpaquePointer
    private let context: Context
    public let work: Work

    /// The work must outlive the transport and must not be modified while it plays; after an
    /// edit, make a new transport.
    public init(work: Work, clock: SequencerClock, output: MIDIOutput, options: PlaybackOptions = PlaybackOptions()) throws {
        self.work = work
        context = Context(clock: clock, output: output)
        var callbacks = sseq_transport_callbacks()
        callbacks.context = Unmanaged.passUnretained(context).toOpaque()
        callbacks.now = { ctx in
            Unmanaged<Context>.fromOpaque(ctx!).takeUnretainedValue().clock.now
        }
        callbacks.send = { ctx, message in
            Unmanaged<Context>.fromOpaque(ctx!).takeUnretainedValue().output.send(MIDIMessage(message!.pointee))
        }
        callbacks.send_sysex = { ctx, time, port, bytes, size in
            let array = bytes.map { Array(UnsafeBufferPointer(start: $0, count: size)) } ?? []
            Unmanaged<Context>.fromOpaque(ctx!).takeUnretainedValue().output.sendSysex(at: time, port: Int(port), bytes: array)
        }
        callbacks.flush = { ctx in
            Unmanaged<Context>.fromOpaque(ctx!).takeUnretainedValue().output.flush()
        }
        callbacks.string_event = { ctx, track, event, payload, size, time in
            let context = Unmanaged<Context>.fromOpaque(ctx!).takeUnretainedValue()
            guard let handler = context.stringEventHandler, let event = event else { return }
            let data = payload.map { Data(bytes: $0, count: size) }
            handler(Int(track), Event(event.pointee, payload: data), time)
        }
        var c = options.c
        guard let handle = sseq_transport_new(work.handle, &callbacks, &c) else { throw SequencerError.last() }
        self.handle = handle
    }

    deinit {
        sseq_transport_free(handle)
    }

    public var stringEventHandler: StringEventHandler? {
        get { context.stringEventHandler }
        set { context.stringEventHandler = newValue }
    }

    public var options: PlaybackOptions {
        get {
            var c = sseq_playback_options()
            sseq_transport_options(handle, &c)
            return PlaybackOptions(c)
        }
        set {
            var c = newValue.c
            sseq_transport_set_options(handle, &c)
        }
    }

    /// Playback speed (Cakewalk's 0.50 / 1.00 / 2.00 buttons); takes effect immediately.
    public var tempoRatio: Double {
        get { options.tempoRatio }
        set { sseq_transport_set_tempo_ratio(handle, newValue) }
    }

    public func play() { sseq_transport_play(handle) }
    public func stop() { sseq_transport_stop(handle) }
    /// Stop, then all-notes-off and a controller reset on every channel of every port.
    public func panic() { sseq_transport_panic(handle) }
    public func rewind() { sseq_transport_rewind(handle) }
    public func seek(to tick: Tick) { sseq_transport_seek(handle, tick) }

    public var isPlaying: Bool { sseq_transport_playing(handle) != 0 }
    public var isCountingIn: Bool { sseq_transport_counting_in(handle) != 0 }
    /// The current position; advances with the clock while playing.
    public var now: Tick { sseq_transport_now(handle) }
    public var endTick: Tick { sseq_transport_end_tick(handle) }

    /// The position a clock time corresponds to while playing (for recording); nil otherwise.
    public func tick(at time: Double) -> Tick? {
        var valid: Int32 = 0
        let tick = sseq_transport_tick_at(handle, time, &valid)
        return valid != 0 ? tick : nil
    }

    public func setMuted(_ muted: Bool, trackNumber: Int) {
        sseq_transport_set_muted(handle, Int32(trackNumber), muted ? 1 : 0)
    }

    public func setSolo(_ solo: Bool, trackNumber: Int) {
        sseq_transport_set_solo(handle, Int32(trackNumber), solo ? 1 : 0)
    }

    public func isAudible(trackNumber: Int) -> Bool {
        sseq_transport_audible(handle, Int32(trackNumber)) != 0
    }

    /// Schedules everything up to now + lookAhead. Returns false once playback has stopped by itself.
    @discardableResult
    public func pump() -> Bool {
        sseq_transport_pump(handle) != 0
    }
}

/// Offline rendering: every message of `work` between `from` and `thru` (default: the end), with
/// times in seconds from `from`.
public func render(_ work: Work, options: PlaybackOptions = PlaybackOptions(), from: Tick = 0, thru: Tick? = nil) throws -> [MIDIMessage] {
    var c = options.c
    var out: UnsafeMutablePointer<sseq_midi_message>?
    var count = 0
    guard sseq_render(work.handle, &c, from, thru ?? -1, &out, &count) != 0, let messages = out else {
        throw SequencerError.last()
    }
    defer { sseq_render_free(messages) }
    return (0..<count).map { MIDIMessage(messages[$0]) }
}
