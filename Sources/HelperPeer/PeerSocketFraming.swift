#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation

/// One message on the socket transport.
///
/// The XPC transport gets framing and request/response correlation from XPC itself. A socket
/// gets a byte stream and nothing else, so both have to be built here — and they have to be
/// built the same way on each side, since the two ends are different binaries that cannot
/// negotiate anything.
struct PeerSocketMessage: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case request
        case response
        /// The handler threw. `body` carries the description; see ``PeerSocketFailure``.
        case failure
    }

    let kind: Kind

    /// Pairs a response with its request.
    ///
    /// Needed because both directions are in flight at once over one stream: without it, two
    /// overlapping requests cannot tell which reply is theirs, and the second caller gets the
    /// first one's answer. Unique per sender, and never reused within a connection.
    let correlationIdentifier: UInt64

    /// `Request.identifier` — the routing key, exactly as on the XPC side.
    ///
    /// Empty for responses and failures, which are routed by `correlationIdentifier`.
    let identifier: String

    /// The encoded `Request` or `Response`.
    let body: Data
}

/// Carried in a `.failure` message so the far side gets something readable rather than a bare
/// transport error.
///
/// Deliberately not an attempt to rebuild the thrown error's type: the two ends are separate
/// binaries and the type may not exist on the receiving side at all. The description survives,
/// which is the part a person needs — the same bargain `HelperServiceFailure` makes for XPC.
struct PeerSocketFailure: Codable, Sendable, Error, LocalizedError {
    let description: String

    var errorDescription: String? { description }
}

/// Length-prefixed framing over a byte stream.
///
/// `UInt32` big-endian length, then that many bytes. Big-endian because it is the convention for
/// anything on a wire, and because a mismatch here is otherwise invisible — a little-endian
/// reader sees a plausible but enormous length and waits forever rather than failing.
enum PeerSocketFraming {
    /// Refuses anything absurd before allocating for it.
    ///
    /// A corrupt or hostile length prefix would otherwise have the reader wait for — or reserve
    /// — gigabytes. 16 MiB is far beyond any plausible control message while staying well clear
    /// of exhausting a host process that did not ask to be injected into.
    static let maximumBodyLength = 16 * 1024 * 1024

    static let lengthPrefixSize = MemoryLayout<UInt32>.size

    enum FramingError: LocalizedError, Equatable {
        case bodyTooLarge(length: Int)

        var errorDescription: String? {
            switch self {
            case let .bodyTooLarge(length):
                "A peer socket frame declared \(length) bytes, over the \(maximumBodyLength)-byte limit. The stream is out of sync or the sender is not speaking this protocol."
            }
        }
    }

    /// Wraps `body` in a length prefix.
    static func frame(_ body: Data) throws -> Data {
        guard body.count <= maximumBodyLength else {
            throw FramingError.bodyTooLarge(length: body.count)
        }
        var framed = Data(capacity: lengthPrefixSize + body.count)
        withUnsafeBytes(of: UInt32(body.count).bigEndian) { framed.append(contentsOf: $0) }
        framed.append(body)
        return framed
    }

    /// Takes one complete frame off the front of `buffer`, if there is one.
    ///
    /// Returns `nil` when more bytes are needed, leaving `buffer` untouched — a stream delivers
    /// whatever it feels like, and a partial frame is the ordinary case, not an error.
    ///
    /// Throws only when the declared length is impossible, which means the stream is no longer
    /// synchronised and no amount of further reading will fix it.
    static func takeFrame(from buffer: inout Data) throws -> Data? {
        guard buffer.count >= lengthPrefixSize else { return nil }

        let declaredLength = Int(
            buffer.prefix(lengthPrefixSize).withUnsafeBytes { rawBuffer in
                rawBuffer.loadUnaligned(as: UInt32.self).bigEndian
            }
        )
        guard declaredLength <= maximumBodyLength else {
            throw FramingError.bodyTooLarge(length: declaredLength)
        }

        let totalLength = lengthPrefixSize + declaredLength
        guard buffer.count >= totalLength else { return nil }

        // `Data` slices keep the parent's indices, so rebase before handing anything out:
        // otherwise a caller's `body[0]` traps on the second frame onwards.
        let body = Data(buffer[buffer.startIndex + lengthPrefixSize ..< buffer.startIndex + totalLength])
        buffer.removeFirst(totalLength)
        return body
    }
}
#endif
