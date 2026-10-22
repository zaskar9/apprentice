import Foundation

/// Console logging of MIDI messages at every hop, for diagnosis. Off by default.
public enum MIDILog {
    public static var enabled = false

    public static func log(_ where_: String, _ message: MIDIMessage) {
        guard enabled else { return }
        let bytes = message.bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        print(String(format: "[midi] %@ t=%.3f port=%d %@", where_, message.time, message.port, bytes))
    }

    public static func log(_ where_: String, _ text: String) {
        guard enabled else { return }
        print("[midi] \(where_) \(text)")
    }
}
