import Foundation
import SSeq

public struct RecordOptions: Equatable {
    public var notes: Bool
    public var controllers: Bool
    public var patches: Bool
    public var pitchWheel: Bool
    public var aftertouch: Bool
    /// Keep only events in this range (punch-in / punch-out).
    public var punch: Range<Tick>?

    public init() {
        var c = sseq_record_options()
        sseq_record_options_default(&c)
        self.init(c)
    }

    init(_ c: sseq_record_options) {
        notes = c.notes != 0
        controllers = c.controllers != 0
        patches = c.patches != 0
        pitchWheel = c.pitch_wheel != 0
        aftertouch = c.aftertouch != 0
        punch = c.has_punch != 0 && c.punch_out > c.punch_in ? c.punch_in..<c.punch_out : nil
    }

    var c: sseq_record_options {
        var o = sseq_record_options()
        o.notes = notes ? 1 : 0
        o.controllers = controllers ? 1 : 0
        o.patches = patches ? 1 : 0
        o.pitch_wheel = pitchWheel ? 1 : 0
        o.aftertouch = aftertouch ? 1 : 0
        o.has_punch = punch != nil ? 1 : 0
        o.punch_in = punch?.lowerBound ?? 0
        o.punch_out = punch?.upperBound ?? 0
        return o
    }
}

/// Turns timestamped MIDI input into track events while a transport plays, and merges the take
/// into a track ("Keep take?").
public final class Recorder {
    let handle: OpaquePointer
    public let transport: Transport

    /// The transport must outlive the recorder.
    public init(transport: Transport, options: RecordOptions = RecordOptions()) throws {
        self.transport = transport
        var c = options.c
        guard let handle = sseq_recorder_new(transport.handle, &c) else { throw SequencerError.last() }
        self.handle = handle
    }

    deinit {
        sseq_recorder_free(handle)
    }

    public var options: RecordOptions {
        get {
            var c = sseq_record_options()
            sseq_recorder_options(handle, &c)
            return RecordOptions(c)
        }
        set {
            var c = newValue.c
            sseq_recorder_set_options(handle, &c)
        }
    }

    /// Input with its arrival time on the transport's clock.
    public func receive(_ message: MIDIMessage) {
        var c = message.c
        sseq_recorder_receive(handle, &c)
    }

    /// Ends the take: notes still held are closed at `time`.
    public func finish(at time: Double) {
        sseq_recorder_finish(handle, time)
    }

    public var count: Int { sseq_recorder_count(handle) }
    public var isEmpty: Bool { count == 0 }

    public var events: [Event] {
        (0..<count).compactMap { i in
            var c = sseq_event()
            guard sseq_recorder_event(handle, i, &c) != 0 else { return nil }
            return Event(c)
        }
    }

    public func clear() {
        sseq_recorder_clear(handle)
    }

    /// Merges the take into a track of the work (sound on sound) and clears it. With `replacing`,
    /// the track's events starting in that range are removed first.
    @discardableResult
    public func commit(toTrack index: Int, of work: Work, replacing range: Range<Tick>? = nil) -> Bool {
        sseq_recorder_commit(handle, work.handle, Int32(index), range != nil ? 1 : 0,
                             range?.lowerBound ?? 0, range?.upperBound ?? 0) != 0
    }
}
