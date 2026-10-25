import Foundation
import SSeq

/// Text forms as Cakewalk's views show them (libsseq's display helpers).
public enum DisplayText {
    /// "C 5" = 60, "G#4" = 56, "G 10" = 127.
    public static func keyName(_ key: Int) -> String {
        var buffer = [CChar](repeating: 0, count: 16)
        sseq_key_name(Int32(key), &buffer, buffer.count)
        return String(cString: buffer)
    }

    /// Parses "C 5", "C5", "G#4" or "Bb3"; nil when the text is not a key name.
    public static func key(parsing text: String) -> Int? {
        var key: Int32 = 0
        return sseq_parse_key_name(text, &key) != 0 ? Int(key) : nil
    }

    /// Plain ticks below one quarter note ("50"), otherwise quarters and ticks ("1:080").
    public static func durationText(_ ticks: Tick, ppq: Int) -> String {
        var buffer = [CChar](repeating: 0, count: 32)
        sseq_duration_text(ticks, Int32(ppq), &buffer, buffer.count)
        return String(cString: buffer)
    }

    public static func duration(parsing text: String, ppq: Int) -> Tick? {
        var ticks: Tick = 0
        return sseq_parse_duration_text(text, Int32(ppq), &ticks) != 0 ? ticks : nil
    }

    /// General MIDI level 1 program name (0-based); nil outside 0...127.
    public static func generalMIDIProgramName(_ program: Int) -> String? {
        let name = String(cString: sseq_gm_program_name(Int32(program)))
        return name.isEmpty ? nil : name
    }

    /// General MIDI percussion key name (channel 10, keys 35...81); nil otherwise.
    public static func generalMIDIPercussionName(_ key: Int) -> String? {
        let name = String(cString: sseq_gm_percussion_name(Int32(key)))
        return name.isEmpty ? nil : name
    }
}

public extension EventKind {
    /// The Event list's kind name: "Note", "KeyAft", "ChanAft", "Contrl", "Patch", "Wheel", "Sysx",
    /// "Text", "MCICmd", "Wave".
    var displayName: String {
        String(cString: sseq_event_kind_name(c))
    }
}

public extension Event {
    /// The Event list's Chn column: 1-based channel, "n/a" for sysex and string events.
    var channelText: String {
        var c = self.c
        var buffer = [CChar](repeating: 0, count: 8)
        sseq_event_channel_text(&c, &buffer, buffer.count)
        return String(cString: buffer)
    }

    /// The Event list's Values column ("C 5  100  1:080", "7  100", "Reed Organ", ...).
    func valuesText(ppq: Int) -> String {
        var c = self.c
        let payload = self.payload ?? Data()
        var buffer = [CChar](repeating: 0, count: 512)
        payload.withUnsafeBytes { bytes in
            sseq_event_values_text(&c, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, Int32(ppq),
                                   &buffer, buffer.count)
        }
        return String(cString: buffer)
    }
}
