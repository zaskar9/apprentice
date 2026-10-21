import Foundation
import SSeq

/// The parameters of a track (Cakewalk's Track/Measure view columns).
public struct TrackParameters: Equatable {
    /// 0-based slot in the file; the UI shows `number + 1`.
    public var number: Int
    /// Forced output channel 0...15, nil = none (events play on their own channel).
    public var channel: UInt8?
    public var keyPlus: Int
    public var velPlus: Int
    /// 0-based output port.
    public var port: Int
    public var selected: Bool
    public var muted: Bool
    public var patch: Int?
    /// Loop count 1...9999 (9999 = while the other tracks play), nil = none.
    public var reps: Int?
    public var timePlus: Tick?
    public var volume: Int?
    public var pan: Int?

    public init(number: Int = 0, channel: UInt8? = nil, keyPlus: Int = 0, velPlus: Int = 0, port: Int = 0,
                selected: Bool = false, muted: Bool = false, patch: Int? = nil, reps: Int? = nil,
                timePlus: Tick? = nil, volume: Int? = nil, pan: Int? = nil) {
        self.number = number
        self.channel = channel
        self.keyPlus = keyPlus
        self.velPlus = velPlus
        self.port = port
        self.selected = selected
        self.muted = muted
        self.patch = patch
        self.reps = reps
        self.timePlus = timePlus
        self.volume = volume
        self.pan = pan
    }

    init(_ c: sseq_stream_params) {
        self.init(number: Int(c.number),
                  channel: c.channel >= 0 ? UInt8(c.channel) : nil,
                  keyPlus: Int(c.key_plus), velPlus: Int(c.vel_plus), port: Int(c.port),
                  selected: c.selected != 0, muted: c.muted != 0,
                  patch: c.patch >= 0 ? Int(c.patch) : nil,
                  reps: c.reps > 0 ? Int(c.reps) : nil,
                  timePlus: c.has_time_plus != 0 ? c.time_plus : nil,
                  volume: c.volume >= 0 ? Int(c.volume) : nil,
                  pan: c.pan >= 0 ? Int(c.pan) : nil)
    }

    var c: sseq_stream_params {
        sseq_stream_params(number: Int32(number),
                           channel: channel.map { Int32($0) } ?? -1,
                           key_plus: Int32(keyPlus), vel_plus: Int32(velPlus), port: Int32(port),
                           selected: selected ? 1 : 0, muted: muted ? 1 : 0,
                           patch: patch.map { Int32($0) } ?? -1,
                           reps: reps.map { Int32($0) } ?? 0,
                           has_time_plus: timePlus != nil ? 1 : 0, time_plus: timePlus ?? 0,
                           volume: volume.map { Int32($0) } ?? -1,
                           pan: pan.map { Int32($0) } ?? -1)
    }

    /// Whether the track loops (reps > 1).
    public var loops: Bool { (reps ?? 1) > 1 }
}

/// A snapshot of one track's name and parameters. Events are read with `Work.events(inTrack:)`.
public struct Track: Equatable, Identifiable {
    /// Index in file order; stable until tracks are added or removed.
    public let index: Int
    public var name: String
    public var parameters: TrackParameters

    public var id: Int { index }
    public var number: Int { parameters.number }
    /// The number the UI shows.
    public var displayNumber: Int { parameters.number + 1 }

    public init(index: Int, name: String, parameters: TrackParameters) {
        self.index = index
        self.name = name
        self.parameters = parameters
    }
}
