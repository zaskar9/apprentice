import CoreMIDI
import Foundation

/// A CoreMIDI destination (an output endpoint).
public struct MIDIDestination: Identifiable, Hashable {
    public let endpoint: MIDIEndpointRef
    /// CoreMIDI's persistent identifier for the endpoint; what an application should remember.
    public let uniqueID: MIDIUniqueID
    public let name: String

    public var id: MIDIUniqueID { uniqueID }
}

/// The CoreMIDI client and output port shared by the application, and the list of destinations.
public final class MIDISystem {
    private(set) var client = MIDIClientRef()
    private(set) var outputPort = MIDIPortRef()
    /// Called on the main queue when the MIDI setup changes (devices plugged or unplugged).
    public var setupChanged: (() -> Void)?

    public init(name: String = "Apprentice") throws {
        var status = MIDIClientCreateWithBlock(name as CFString, &client) { [weak self] notification in
            if notification.pointee.messageID == .msgSetupChanged {
                DispatchQueue.main.async { self?.setupChanged?() }
            }
        }
        guard status == noErr else { throw MIDISystemError.client(status) }
        status = MIDIOutputPortCreate(client, "\(name) Out" as CFString, &outputPort)
        guard status == noErr else { throw MIDISystemError.port(status) }
    }

    deinit {
        MIDIPortDispose(outputPort)
        MIDIClientDispose(client)
    }

    /// All destinations currently present, in CoreMIDI's order.
    public var destinations: [MIDIDestination] {
        (0..<MIDIGetNumberOfDestinations()).compactMap { i in
            let endpoint = MIDIGetDestination(i)
            guard endpoint != 0 else { return nil }
            var uniqueID: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &uniqueID)
            return MIDIDestination(endpoint: endpoint, uniqueID: uniqueID, name: MIDISystem.displayName(of: endpoint))
        }
    }

    /// The destination with this unique ID, if it is present.
    public func destination(uniqueID: MIDIUniqueID) -> MIDIDestination? {
        destinations.first { $0.uniqueID == uniqueID }
    }

    static func displayName(of endpoint: MIDIEndpointRef) -> String {
        var name: Unmanaged<CFString>?
        if MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name) == noErr, let name = name {
            return name.takeRetainedValue() as String
        }
        return "Destination \(endpoint)"
    }
}

public enum MIDISystemError: Error, CustomStringConvertible {
    case client(OSStatus)
    case port(OSStatus)

    public var description: String {
        switch self {
        case .client(let status): return "MIDIClientCreate failed (\(status))"
        case .port(let status): return "MIDIOutputPortCreate failed (\(status))"
        }
    }
}
