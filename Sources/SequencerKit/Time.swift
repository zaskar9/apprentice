import Foundation
import SSeq

/// A position in ticks (pulses per quarter note, see `Work.ppq`).
public typealias Tick = Int64

/// Measure:Beat:Tick, as shown in Cakewalk (measure and beat are 1-based).
public struct MBT: Equatable, Hashable, CustomStringConvertible {
    public var measure: Int
    public var beat: Int
    public var tick: Int

    public init(measure: Int = 1, beat: Int = 1, tick: Int = 0) {
        self.measure = measure
        self.beat = beat
        self.tick = tick
    }

    init(_ c: sseq_mbt) {
        self.init(measure: Int(c.measure), beat: Int(c.beat), tick: Int(c.tick))
    }

    var c: sseq_mbt { sseq_mbt(measure: Int32(measure), beat: Int32(beat), tick: Int32(tick)) }

    /// "12:3:045", Cakewalk's text form.
    public var description: String {
        var buffer = [CChar](repeating: 0, count: 32)
        var value = c
        sseq_format_mbt(&value, &buffer, buffer.count)
        return String(cString: buffer)
    }

    /// Parses Cakewalk's text form; nil when the text is not valid.
    public init?(parsing text: String) {
        var out = sseq_mbt()
        guard sseq_parse_mbt(text, &out) != 0 else { return nil }
        self.init(out)
    }
}

/// SMPTE time: hours, minutes, seconds, frames.
public struct HMSF: Equatable, Hashable, CustomStringConvertible {
    public var hours: Int
    public var minutes: Int
    public var seconds: Int
    public var frames: Int

    public init(hours: Int = 0, minutes: Int = 0, seconds: Int = 0, frames: Int = 0) {
        self.hours = hours
        self.minutes = minutes
        self.seconds = seconds
        self.frames = frames
    }

    init(_ c: sseq_hmsf) {
        self.init(hours: Int(c.hours), minutes: Int(c.minutes), seconds: Int(c.seconds), frames: Int(c.frames))
    }

    var c: sseq_hmsf {
        sseq_hmsf(hours: Int32(hours), minutes: Int32(minutes), seconds: Int32(seconds), frames: Int32(frames))
    }

    /// "00:01:05:10"
    public var description: String {
        var buffer = [CChar](repeating: 0, count: 32)
        var value = c
        sseq_format_hmsf(&value, &buffer, buffer.count)
        return String(cString: buffer)
    }

    public init?(parsing text: String) {
        var out = sseq_hmsf()
        guard sseq_parse_hmsf(text, &out) != 0 else { return nil }
        self.init(out)
    }
}

/// SMPTE frame rates (the TIMEFMT chunk).
public enum FrameRate: Int, CaseIterable {
    case fps24 = 24
    case fps25 = 25
    case fps30Drop = 29
    case fps30 = 30

    public var label: String {
        switch self {
        case .fps24: return "24 fps"
        case .fps25: return "25 fps"
        case .fps30Drop: return "30 fps drop"
        case .fps30: return "30 fps"
        }
    }
}

public struct Timecode: Equatable {
    public var rate: FrameRate
    public var offsetFrames: Int64

    public init(rate: FrameRate = .fps30, offsetFrames: Int64 = 0) {
        self.rate = rate
        self.offsetFrames = offsetFrames
    }
}

public struct TempoEntry: Equatable {
    public var time: Tick
    /// Beats per minute times 100 (120.00 bpm = 12000), as stored in the file.
    public var bpm100: Int

    public init(time: Tick, bpm100: Int) {
        self.time = time
        self.bpm100 = bpm100
    }

    public var bpm: Double { Double(bpm100) / 100 }
}

public struct MeterEntry: Equatable {
    public var measure: Int
    public var numerator: Int
    public var denominatorLog2: Int

    public init(measure: Int, numerator: Int = 4, denominatorLog2: Int = 2) {
        self.measure = measure
        self.numerator = numerator
        self.denominatorLog2 = denominatorLog2
    }

    public var denominator: Int { 1 << denominatorLog2 }
}

public struct KeyEntry: Equatable {
    public var measure: Int
    /// -7..7, negative = flats.
    public var alterations: Int

    public init(measure: Int, alterations: Int = 0) {
        self.measure = measure
        self.alterations = alterations
    }
}

public struct Marker: Equatable {
    public var time: Tick
    public var smpteLocked: Bool
    public var name: String

    public init(time: Tick, smpteLocked: Bool = false, name: String) {
        self.time = time
        self.smpteLocked = smpteLocked
        self.name = name
    }
}
