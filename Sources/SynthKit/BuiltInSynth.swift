import AVFoundation
import AudioToolbox
import CoreMIDIKit
import Foundation
import SequencerKit

/// A General MIDI synthesizer inside the application, built on Apple's AUSampler.
///
/// One sampler per MIDI channel; each loads the instrument for its current program from the bank
/// (`loadSoundBankInstrument`), channel 10 from the percussion bank. The default bank is the
/// system's General MIDI DLS file (macOS); `loadSoundFont` switches to an `.sf2` or `.dls`. As a
/// `MIDIOutput` it accepts the transport's timestamped messages; a scheduler thread hands each one
/// to the samplers when its time comes, so the look-ahead scheduling works the same way as with
/// CoreMIDI. All channels of one port.
public final class BuiltInSynth: MIDIOutput {
    public let clock: HostClock
    private let engine = AVAudioEngine()
    private let samplers: [AVAudioUnitSampler]
    private let scheduler: MIDIScheduler
    private let state = ChannelState()
    public private(set) var soundFontURL: URL?

    /// The system's General MIDI bank on macOS.
    public static let systemBankURL = URL(fileURLWithPath:
        "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")

    /// Current program per channel and the bank in use; read and written on the scheduler thread.
    final class ChannelState {
        var bankURL: URL = BuiltInSynth.systemBankURL
        var program = [Int](repeating: 0, count: 16)
        var loaded = [Int](repeating: -1, count: 16) // program loaded into each sampler, -1 none
    }

    public init(clock: HostClock) throws {
        self.clock = clock
        samplers = (0..<16).map { _ in AVAudioUnitSampler() }
        for sampler in samplers {
            engine.attach(sampler)
            engine.connect(sampler, to: engine.mainMixerNode, format: nil)
        }
        let samplers = self.samplers
        let state = self.state
        scheduler = MIDIScheduler(clock: clock) { bytes in
            BuiltInSynth.deliver(bytes, to: samplers, state: state)
        }
        try engine.start()
    }

    deinit {
        scheduler.stop()
        engine.stop()
    }

    /// Loads a soundfont (`.sf2` or `.dls`); nil returns to the system bank. Sounding notes stop.
    public func loadSoundFont(_ url: URL?) throws {
        let bank = url ?? BuiltInSynth.systemBankURL
        // Try the bank on one sampler first so a bad file is reported here, not on the scheduler thread.
        try samplers[0].loadSoundBankInstrument(at: bank, program: 0,
                                                bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB),
                                                bankLSB: UInt8(kAUSampler_DefaultBankLSB))
        scheduler.clear()
        state.bankURL = bank
        scheduler.schedule([0xff], at: 0) // reset marker: the samplers reload their programs from the new bank
        soundFontURL = url
        allNotesOff()
    }

    /// Delivers one message on the scheduler thread.
    private static func deliver(_ bytes: [UInt8], to samplers: [AVAudioUnitSampler], state: ChannelState) {
        guard let status = bytes.first else { return }
        MIDILog.log("synth deliver", bytes.map { String(format: "%02x", $0) }.joined(separator: " "))
        if status == 0xff { // bank changed: forget what is loaded
            for i in 0..<16 { state.loaded[i] = -1 }
            return
        }
        if status == 0xf0 { return } // sysex: not supported by the sampler
        let channel = Int(status & 0x0f)
        let kind = status & 0xf0
        let d1 = bytes.count > 1 ? bytes[1] : 0
        let d2 = bytes.count > 2 ? bytes[2] : 0
        let sampler = samplers[channel]
        switch kind {
        case 0xc0:
            state.program[channel] = Int(d1)
            load(channel: channel, sampler: sampler, state: state)
        case 0x90, 0x80, 0xa0:
            if state.loaded[channel] != state.program[channel] {
                load(channel: channel, sampler: sampler, state: state)
            }
            if kind == 0x90 {
                sampler.startNote(d1, withVelocity: d2, onChannel: UInt8(channel))
            } else if kind == 0x80 {
                sampler.stopNote(d1, onChannel: UInt8(channel))
            } else {
                sampler.sendPressure(forKey: d1, withValue: d2, onChannel: UInt8(channel))
            }
        case 0xb0:
            sampler.sendController(d1, withValue: d2, onChannel: UInt8(channel))
        case 0xd0:
            sampler.sendPressure(d1, onChannel: UInt8(channel))
        case 0xe0:
            sampler.sendPitchBend(UInt16(d1) | (UInt16(d2) << 7), onChannel: UInt8(channel))
        default:
            break
        }
    }

    private static func load(channel: Int, sampler: AVAudioUnitSampler, state: ChannelState) {
        let program = state.program[channel]
        let msb = channel == 9 ? kAUSampler_DefaultPercussionBankMSB : kAUSampler_DefaultMelodicBankMSB
        do {
            try sampler.loadSoundBankInstrument(at: state.bankURL, program: UInt8(program), bankMSB: UInt8(msb),
                                                bankLSB: UInt8(kAUSampler_DefaultBankLSB))
            state.loaded[channel] = program
        } catch {
            MIDILog.log("synth", "loadSoundBankInstrument program \(program) channel \(channel): \(error)")
            state.loaded[channel] = program // do not retry on every note
        }
    }

    // MARK: MIDIOutput

    public func send(_ message: MIDIMessage) {
        scheduler.schedule(message.bytes, at: clock.hostTime(for: message.time))
    }

    public func sendSysex(at time: Double, port: Int, bytes: [UInt8]) {
        scheduler.schedule(bytes, at: clock.hostTime(for: time))
    }

    public func flush() {}

    /// All notes off and controller reset on every channel; with `now` the pending queue is dropped too.
    public func allNotesOff(now: Bool = false) {
        if now { scheduler.clear() }
        for channel in 0..<16 {
            let status = UInt8(0xb0 | channel)
            scheduler.schedule([status, 123, 0], at: 0)
            scheduler.schedule([status, 121, 0], at: 0)
        }
    }
}

public enum SynthError: Error, CustomStringConvertible {
    case soundFont(URL, OSStatus)

    public var description: String {
        switch self {
        case .soundFont(let url, let status): return "Cannot load \(url.lastPathComponent) (\(status))"
        }
    }
}

/// Delivers MIDI bytes at host times from a dedicated thread (the audio unit only takes
/// immediate events). Events are kept in a min-heap by time; the thread sleeps until the earliest
/// is due and wakes early when an earlier one arrives.
final class MIDIScheduler {
    private struct Entry {
        let time: UInt64
        let sequence: UInt64 // keeps events with equal times in arrival order
        let bytes: [UInt8]
    }

    private let clock: HostClock
    private let deliver: ([UInt8]) -> Void
    private let condition = NSCondition()
    private var heap: [Entry] = []
    private var sequence: UInt64 = 0
    private var running = true
    private var thread: Thread?

    init(clock: HostClock, deliver: @escaping ([UInt8]) -> Void) {
        self.clock = clock
        self.deliver = deliver
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "SynthKit.MIDIScheduler"
        thread.qualityOfService = .userInteractive
        thread.threadPriority = 1.0
        self.thread = thread
        thread.start()
    }

    func schedule(_ bytes: [UInt8], at hostTime: UInt64) {
        condition.lock()
        sequence += 1
        push(Entry(time: hostTime, sequence: sequence, bytes: bytes))
        condition.signal()
        condition.unlock()
    }

    func clear() {
        condition.lock()
        heap.removeAll()
        condition.unlock()
    }

    func stop() {
        condition.lock()
        running = false
        condition.signal()
        condition.unlock()
    }

    private func run() {
        condition.lock()
        while running {
            guard let next = heap.first else {
                condition.wait()
                continue
            }
            let now = mach_absolute_time()
            if next.time > now {
                let seconds = Double(next.time - now) * clock.secondsPerHostTick
                condition.wait(until: Date(timeIntervalSinceNow: seconds))
                continue
            }
            let entry = pop()
            condition.unlock()
            deliver(entry.bytes)
            condition.lock()
        }
        condition.unlock()
    }

    // Binary min-heap on (time, sequence).
    private func less(_ a: Entry, _ b: Entry) -> Bool {
        a.time != b.time ? a.time < b.time : a.sequence < b.sequence
    }

    private func push(_ entry: Entry) {
        heap.append(entry)
        var i = heap.count - 1
        while i > 0 {
            let parent = (i - 1) / 2
            if less(heap[i], heap[parent]) {
                heap.swapAt(i, parent)
                i = parent
            } else {
                break
            }
        }
    }

    private func pop() -> Entry {
        let top = heap[0]
        let last = heap.removeLast()
        if !heap.isEmpty {
            heap[0] = last
            var i = 0
            while true {
                let left = 2 * i + 1
                let right = left + 1
                var smallest = i
                if left < heap.count, less(heap[left], heap[smallest]) { smallest = left }
                if right < heap.count, less(heap[right], heap[smallest]) { smallest = right }
                if smallest == i { break }
                heap.swapAt(i, smallest)
                i = smallest
            }
        }
        return top
    }
}
