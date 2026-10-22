import CoreMIDI
import Foundation
import SequencerKit

/// The sequencer clock on the host's monotonic time (`mach_absolute_time`), in seconds since the
/// clock was created, with conversion to the `MIDITimeStamp` CoreMIDI schedules against.
public final class HostClock: SequencerClock {
    private let origin: UInt64
    /// Seconds per `mach_absolute_time` unit.
    public let secondsPerHostTick: Double

    public init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        secondsPerHostTick = Double(info.numer) / Double(info.denom) / 1e9
        origin = mach_absolute_time()
    }

    public var now: Double {
        Double(mach_absolute_time() - origin) * secondsPerHostTick
    }

    /// The host time stamp for a clock time; times in the past map to "now" (0 means immediately).
    public func hostTime(for seconds: Double) -> MIDITimeStamp {
        guard seconds > 0 else { return 0 }
        return origin + UInt64(seconds / secondsPerHostTick)
    }
}
