import Foundation
import SSeq

/// The event kinds of a Cakewalk work.
public enum EventKind: UInt32, CaseIterable {
    case note = 0
    case keyAftertouch
    case controller
    case patch
    case channelAftertouch
    case pitchWheel
    case sysex
    case mciCommand
    case wave
    case text

    public var isMIDI: Bool { rawValue <= EventKind.sysex.rawValue }
    public var isString: Bool { rawValue >= EventKind.mciCommand.rawValue }

    var c: sseq_event_kind { sseq_event_kind(rawValue: rawValue) }
}

/// One event of a track. Notes are single events with a duration, as in Cakewalk.
///
/// Field use by kind: note (key, velocity, duration), key aftertouch (key, pressure),
/// controller (number, value), patch (program), channel aftertouch (pressure), pitch wheel
/// (data1 is -8192...8191), sysex (data1 is the bank index); string events carry `payload`.
public struct Event: Equatable {
    public var time: Tick
    public var kind: EventKind
    public var channel: UInt8
    public var data1: Int
    public var data2: Int
    public var duration: Tick
    public var payload: Data?

    public init(time: Tick, kind: EventKind, channel: UInt8 = 0, data1: Int = 0, data2: Int = 0,
                duration: Tick = 0, payload: Data? = nil) {
        self.time = time
        self.kind = kind
        self.channel = channel
        self.data1 = data1
        self.data2 = data2
        self.duration = duration
        self.payload = payload
    }

    init(_ c: sseq_event, payload: Data? = nil) {
        self.init(time: c.time, kind: EventKind(rawValue: c.kind.rawValue) ?? .note, channel: c.channel,
                  data1: Int(c.data1), data2: Int(c.data2), duration: c.duration, payload: payload)
    }

    var c: sseq_event {
        sseq_event(time: time, kind: kind.c, channel: channel, data1: Int32(data1), data2: Int32(data2),
                   duration: duration)
    }

    /// End of the event: start plus duration for notes, the start itself otherwise.
    public var end: Tick { kind == .note ? time + duration : time }

    /// The payload of a Text or MCI command event as text.
    public var text: String? {
        guard let payload = payload else { return nil }
        return String(data: payload, encoding: .windowsCP1252) ?? String(decoding: payload, as: UTF8.self)
    }

    public static func note(_ time: Tick, channel: UInt8, key: Int, velocity: Int, duration: Tick) -> Event {
        Event(time: time, kind: .note, channel: channel, data1: key, data2: velocity, duration: duration)
    }

    public static func controller(_ time: Tick, channel: UInt8, number: Int, value: Int) -> Event {
        Event(time: time, kind: .controller, channel: channel, data1: number, data2: value)
    }

    public static func patch(_ time: Tick, channel: UInt8, program: Int) -> Event {
        Event(time: time, kind: .patch, channel: channel, data1: program)
    }

    public static func pitchWheel(_ time: Tick, channel: UInt8, value: Int) -> Event {
        Event(time: time, kind: .pitchWheel, channel: channel, data1: value)
    }

    public static func text(_ time: Tick, _ text: String) -> Event {
        Event(time: time, kind: .text, payload: text.data(using: .windowsCP1252) ?? Data(text.utf8))
    }

    public static func mciCommand(_ time: Tick, _ command: String) -> Event {
        Event(time: time, kind: .mciCommand, payload: command.data(using: .windowsCP1252) ?? Data(command.utf8))
    }
}
