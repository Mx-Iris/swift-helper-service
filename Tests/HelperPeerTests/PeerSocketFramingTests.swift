#if os(macOS)
import Foundation
import Testing
@testable import HelperPeer

/// Framing is where a socket transport goes wrong quietly. A stream hands over whatever it
/// likes — half a frame, three frames, a frame split across two reads — and every one of those
/// has to produce the same messages. The cases below are the ones that break naive readers.
@Suite("Peer socket framing")
struct PeerSocketFramingTests {
    @Test("A framed body comes back out intact")
    func roundTripsOneFrame() throws {
        let body = Data("hello".utf8)
        var buffer = try PeerSocketFraming.frame(body)

        #expect(try PeerSocketFraming.takeFrame(from: &buffer) == body)
        #expect(buffer.isEmpty)
    }

    @Test("An empty body is a valid frame")
    func roundTripsAnEmptyBody() throws {
        var buffer = try PeerSocketFraming.frame(Data())
        #expect(try PeerSocketFraming.takeFrame(from: &buffer) == Data())
        #expect(buffer.isEmpty)
    }

    /// The case that catches `Data`'s slice indices. A slice keeps its parent's indices, so a
    /// reader that hands out `buffer[4..<n]` without rebasing produces a `Data` whose
    /// `startIndex` is not zero — and the next caller to subscript it from 0 traps.
    @Test("Several frames in one buffer come out in order, each usable from index zero")
    func readsSeveralFramesInOrder() throws {
        let bodies = [Data("first".utf8), Data("second".utf8), Data("third".utf8)]
        var buffer = Data()
        for body in bodies { buffer.append(try PeerSocketFraming.frame(body)) }

        for expected in bodies {
            let body = try #require(try PeerSocketFraming.takeFrame(from: &buffer))
            #expect(body == expected)
            #expect(body.startIndex == 0, "the slice must be rebased, or the caller traps indexing it")
            if !body.isEmpty { #expect(body[0] == expected.first) }
        }
        #expect(buffer.isEmpty)
    }

    @Test("A partial frame yields nothing and consumes nothing")
    func partialFrameIsNotConsumed() throws {
        let complete = try PeerSocketFraming.frame(Data("a reasonably long body".utf8))

        for prefixLength in 0 ..< complete.count {
            var buffer = complete.prefix(prefixLength)
            #expect(try PeerSocketFraming.takeFrame(from: &buffer) == nil, "at \(prefixLength) bytes")
            #expect(buffer.count == prefixLength, "a partial read must leave the buffer alone")
        }
    }

    @Test("A frame arriving one byte at a time reads correctly once complete")
    func frameSplitAcrossManyReads() throws {
        let body = Data((0 ..< 300).map { UInt8($0 % 251) })
        let complete = try PeerSocketFraming.frame(body)

        var buffer = Data()
        var received: Data?
        for byte in complete {
            buffer.append(byte)
            if let frame = try PeerSocketFraming.takeFrame(from: &buffer) {
                received = frame
            }
        }
        #expect(received == body)
        #expect(buffer.isEmpty)
    }

    @Test("Trailing bytes of the next frame are left in place")
    func trailingPartialFrameRemains() throws {
        var buffer = try PeerSocketFraming.frame(Data("complete".utf8))
        let nextFrame = try PeerSocketFraming.frame(Data("incomplete".utf8))
        buffer.append(nextFrame.prefix(6))

        #expect(try PeerSocketFraming.takeFrame(from: &buffer) == Data("complete".utf8))
        #expect(buffer.count == 6)
        #expect(try PeerSocketFraming.takeFrame(from: &buffer) == nil)
    }

    // MARK: - Refusing the impossible

    @Test("A declared length beyond the limit throws rather than waiting for it")
    func absurdLengthThrows() {
        var buffer = Data()
        withUnsafeBytes(of: UInt32(PeerSocketFraming.maximumBodyLength + 1).bigEndian) {
            buffer.append(contentsOf: $0)
        }

        #expect(throws: PeerSocketFraming.FramingError.bodyTooLarge(length: PeerSocketFraming.maximumBodyLength + 1)) {
            _ = try PeerSocketFraming.takeFrame(from: &buffer)
        }
    }

    /// A little-endian reader facing a big-endian writer sees a plausible-looking but enormous
    /// length and waits forever. Throwing on the absurd value turns that into a visible error.
    @Test("A length written in the wrong byte order is caught, not waited on")
    func wrongByteOrderIsCaught() {
        var buffer = Data()
        // 16 bytes, written little-endian: reads as 268435456 big-endian.
        withUnsafeBytes(of: UInt32(16).littleEndian) { buffer.append(contentsOf: $0) }
        buffer.append(Data(repeating: 0, count: 16))

        #expect(throws: (any Error).self) {
            _ = try PeerSocketFraming.takeFrame(from: &buffer)
        }
    }

    @Test("Framing a body over the limit throws at the sender")
    func oversizedBodyIsRefusedWhenFraming() {
        let body = Data(repeating: 0, count: PeerSocketFraming.maximumBodyLength + 1)
        #expect(throws: (any Error).self) {
            _ = try PeerSocketFraming.frame(body)
        }
    }

    // MARK: - Messages

    @Test("A message survives the encode/frame/take/decode round trip")
    func messageRoundTrip() throws {
        let message = PeerSocketMessage(
            kind: .request,
            correlationIdentifier: 42,
            identifier: "com.JH.Test.DoSomething",
            body: Data(#"{"value":1}"#.utf8)
        )

        var buffer = try PeerSocketFraming.frame(JSONEncoder().encode(message))
        let frame = try #require(try PeerSocketFraming.takeFrame(from: &buffer))
        let decoded = try JSONDecoder().decode(PeerSocketMessage.self, from: frame)

        #expect(decoded == message)
    }

    @Test("A failure carries its description across")
    func failureCarriesDescription() throws {
        let failure = PeerSocketFailure(description: "the handler did not like it")
        let decoded = try JSONDecoder().decode(
            PeerSocketFailure.self,
            from: JSONEncoder().encode(failure)
        )
        #expect(decoded.errorDescription == "the handler did not like it")
    }
}
#endif
