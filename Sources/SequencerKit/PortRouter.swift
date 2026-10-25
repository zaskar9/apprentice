import Foundation

/// A `MIDIOutput` that sends each Cakewalk port to another output, with the port number
/// translated. Lets a work's ports go to different kinds of devices (CoreMIDI destinations, a
/// built-in synthesizer) at the same time. Routes may be changed from any thread.
public final class PortRouter: MIDIOutput {
    public struct Route {
        public let output: MIDIOutput
        /// The port number the target output sees.
        public let port: Int

        public init(output: MIDIOutput, port: Int = 0) {
            self.output = output
            self.port = port
        }
    }

    private let lock = NSLock()
    private var routes: [Int: Route] = [:]

    public init() {}

    public func setRoute(_ route: Route?, forPort port: Int) {
        lock.lock()
        routes[port] = route
        lock.unlock()
    }

    public func route(forPort port: Int) -> Route? {
        lock.lock()
        defer { lock.unlock() }
        return routes[port]
    }

    /// Every output that has at least one route.
    public var outputs: [MIDIOutput] {
        lock.lock()
        defer { lock.unlock() }
        var seen: [ObjectIdentifier: MIDIOutput] = [:]
        for route in routes.values { seen[ObjectIdentifier(route.output)] = route.output }
        return Array(seen.values)
    }

    public func send(_ message: MIDIMessage) {
        guard let route = route(forPort: message.port) else {
            MIDILog.log("router: no route", message)
            return
        }
        MIDILog.log("router -> \(type(of: route.output)) port \(route.port)", message)
        var forwarded = message
        forwarded.port = route.port
        route.output.send(forwarded)
    }

    public func sendSysex(at time: Double, port: Int, bytes: [UInt8]) {
        guard let route = route(forPort: port) else { return }
        route.output.sendSysex(at: time, port: route.port, bytes: bytes)
    }

    public func flush() {
        for output in outputs { output.flush() }
    }

    public func discardScheduled() {
        for output in outputs { output.discardScheduled() }
    }
}
