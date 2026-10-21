import Foundation
import SSeq

/// An error reported by libsseq, with the message of the failed call.
public struct SequencerError: Error, CustomStringConvertible, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    /// The last error libsseq recorded on this thread.
    static func last() -> SequencerError {
        SequencerError(String(cString: sseq_last_error()))
    }

    public var description: String { message }
}
