import CoreMIDI
import Foundation
import SequencerKit

/// A `MIDIOutput` that sends the transport's timestamped messages to CoreMIDI destinations.
///
/// Cakewalk port numbers (0-based, as in the work) are mapped to destinations with `portMap`.
/// Messages for an unmapped port are dropped. Messages are sent as MIDI 1.0 event lists with the
/// host time stamp of their scheduled time, so CoreMIDI delivers them on time regardless of when
/// the transport was pumped.
public final class CoreMIDIOutput: MIDIOutput {
    public let system: MIDISystem
    public let clock: HostClock
    private let lock = NSLock()
    private var endpoints: [Int: MIDIEndpointRef] = [:]

    public init(system: MIDISystem, clock: HostClock) {
        self.system = system
        self.clock = clock
    }

    /// Cakewalk port index to destination. May be changed at any time, from any thread.
    public var portMap: [Int: MIDIDestination] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return endpoints.compactMapValues { endpoint in system.destinations.first { $0.endpoint == endpoint } }
        }
        set {
            lock.lock()
            endpoints = newValue.mapValues { $0.endpoint }
            lock.unlock()
        }
    }

    private func endpoint(forPort port: Int) -> MIDIEndpointRef? {
        lock.lock()
        defer { lock.unlock() }
        return endpoints[port]
    }

    public func send(_ message: MIDIMessage) {
        guard let endpoint = endpoint(forPort: message.port), let status = message.bytes.first else {
            MIDILog.log("coremidi: no endpoint for port", message)
            return
        }
        MIDILog.log("coremidi -> endpoint \(endpoint)", message)
        let d1 = message.bytes.count > 1 ? message.bytes[1] : 0
        let d2 = message.bytes.count > 2 ? message.bytes[2] : 0
        // UMP MIDI 1.0 channel voice message, group 0.
        let word = UInt32(0x20) << 24 | UInt32(status) << 16 | UInt32(d1) << 8 | UInt32(d2)
        sendWords([word], at: clock.hostTime(for: message.time), to: endpoint)
    }

    public func sendSysex(at time: Double, port: Int, bytes: [UInt8]) {
        guard let endpoint = endpoint(forPort: port) else { return }
        let timestamp = clock.hostTime(for: time)
        // A bank may hold several F0 ... F7 messages; UMP SysEx7 carries the bytes between them.
        for message in CoreMIDIOutput.splitSysex(bytes) {
            var words: [UInt32] = []
            let chunks = stride(from: 0, to: max(message.count, 1), by: 6).map { Array(message[$0..<min($0 + 6, message.count)]) }
            for (i, chunk) in chunks.enumerated() {
                let statusNibble: UInt32
                if chunks.count == 1 {
                    statusNibble = 0 // complete in one packet
                } else if i == 0 {
                    statusNibble = 1 // start
                } else if i == chunks.count - 1 {
                    statusNibble = 3 // end
                } else {
                    statusNibble = 2 // continue
                }
                var padded = chunk
                while padded.count < 6 { padded.append(0) }
                let word0 = UInt32(0x30) << 24 | statusNibble << 20 | UInt32(chunk.count) << 16
                    | UInt32(padded[0]) << 8 | UInt32(padded[1])
                let word1 = UInt32(padded[2]) << 24 | UInt32(padded[3]) << 16 | UInt32(padded[4]) << 8 | UInt32(padded[5])
                words.append(word0)
                words.append(word1)
                if words.count >= 64 { // one event packet holds 64 words
                    sendWords(words, at: timestamp, to: endpoint)
                    words.removeAll()
                }
            }
            if !words.isEmpty {
                sendWords(words, at: timestamp, to: endpoint)
            }
        }
    }

    public func flush() {}

    /// Drops the packets CoreMIDI still holds for the mapped destinations (MIDIFlushOutput).
    public func discardScheduled() {
        lock.lock()
        let targets = Array(Set(endpoints.values))
        lock.unlock()
        for endpoint in targets {
            MIDIFlushOutput(endpoint)
        }
    }

    /// All notes off and reset all controllers on every channel, immediately, after dropping
    /// what is still scheduled: to the mapped destinations, or with `allDestinations` to every
    /// destination CoreMIDI knows (a panic must reach a device that is no longer routed).
    public func allNotesOff(allDestinations: Bool = false) {
        lock.lock()
        var targets = Set(endpoints.values)
        lock.unlock()
        if allDestinations {
            for d in system.destinations { targets.insert(d.endpoint) }
        }
        for endpoint in targets {
            MIDIFlushOutput(endpoint)
            for channel in 0..<16 {
                let status = UInt8(0xb0 | channel)
                sendWords([UInt32(0x20) << 24 | UInt32(status) << 16 | UInt32(123) << 8], at: 0, to: endpoint)
                sendWords([UInt32(0x20) << 24 | UInt32(status) << 16 | UInt32(121) << 8], at: 0, to: endpoint)
            }
        }
    }

    private func sendWords(_ words: [UInt32], at timestamp: MIDITimeStamp, to endpoint: MIDIEndpointRef) {
        var list = MIDIEventList()
        let packet = MIDIEventListInit(&list, ._1_0)
        words.withUnsafeBufferPointer { buffer in
            _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, packet, timestamp, buffer.count, buffer.baseAddress!)
        }
        let status = MIDISendEventList(system.outputPort, endpoint, &list)
        if status != noErr {
            MIDILog.log("coremidi", "MIDISendEventList failed: \(status)")
        }
    }

    /// Splits a sysex bank into the payloads of its messages (without the F0 and F7 delimiters).
    static func splitSysex(_ bytes: [UInt8]) -> [[UInt8]] {
        var messages: [[UInt8]] = []
        var current: [UInt8]? = nil
        for byte in bytes {
            if byte == 0xf0 {
                if let open = current, !open.isEmpty { messages.append(open) }
                current = []
            } else if byte == 0xf7 {
                if let open = current { messages.append(open) }
                current = nil
            } else if current != nil {
                current!.append(byte)
            } else {
                current = [byte] // data without a leading F0: take it as is
            }
        }
        if let open = current, !open.isEmpty { messages.append(open) }
        return messages
    }
}
