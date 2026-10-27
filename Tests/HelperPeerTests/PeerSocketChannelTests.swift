#if os(macOS)
import Foundation
import Testing
import HelperCommunication
@testable import HelperPeer

/// Two channels wired to each other over real loopback sockets. Nothing here is mocked: the
/// framing, the correlation, the handler dispatch and the Network.framework plumbing all run,
/// which is the only way to catch the failures this transport actually has — a reply going to
/// the wrong caller, a continuation nobody resumes, a half-read frame.
///
/// Nothing in this repository performs a real injection, so a sandboxed target is still
/// untested. What these cover is everything up to that boundary.
@Suite("Peer socket channel", .serialized)
struct PeerSocketChannelTests {
    @Test("A request reaches the other side and its response comes back")
    func requestAndResponse() async throws {
        let pair = try await ConnectedPair.make()
        defer { pair.tearDown() }

        await pair.payload.setMessageHandler(EchoRequest.self) { request in
            EchoRequest.Response(text: request.text.uppercased())
        }

        let response = try await pair.host.send(EchoRequest(text: "hello"))
        #expect(response.text == "HELLO")
    }

    @Test("Both directions work on one channel")
    func bothDirections() async throws {
        let pair = try await ConnectedPair.make()
        defer { pair.tearDown() }

        await pair.payload.setMessageHandler(EchoRequest.self) { EchoRequest.Response(text: "from payload: \($0.text)") }
        await pair.host.setMessageHandler(EchoRequest.self) { EchoRequest.Response(text: "from host: \($0.text)") }

        #expect(try await pair.host.send(EchoRequest(text: "a")).text == "from payload: a")
        #expect(try await pair.payload.send(EchoRequest(text: "b")).text == "from host: b")
    }

    /// The reason correlation identifiers exist. With several requests in flight on one stream,
    /// a reader that just takes the next reply hands the first answer to the second caller —
    /// and the mix-up only appears under concurrency.
    @Test("Overlapping requests each get their own response")
    func overlappingRequestsDoNotCrossWires() async throws {
        let pair = try await ConnectedPair.make()
        defer { pair.tearDown() }

        await pair.payload.setMessageHandler(SlowEchoRequest.self) { request in
            // Deliberately out of order: the later request finishes first.
            try? await Task.sleep(nanoseconds: UInt64(request.delayMilliseconds) * 1_000_000)
            return SlowEchoRequest.Response(text: request.text)
        }

        async let slow = pair.host.send(SlowEchoRequest(text: "slow", delayMilliseconds: 300))
        async let quick = pair.host.send(SlowEchoRequest(text: "quick", delayMilliseconds: 10))

        let (slowResult, quickResult) = try await (slow, quick)
        #expect(slowResult.text == "slow")
        #expect(quickResult.text == "quick")
    }

    @Test("A throwing handler surfaces as an error with its description intact")
    func handlerFailurePropagates() async throws {
        let pair = try await ConnectedPair.make()
        defer { pair.tearDown() }

        await pair.payload.setMessageHandler(EchoRequest.self) { _ in
            throw HandlerTestError.refused
        }

        await #expect(throws: (any Error).self) {
            _ = try await pair.host.send(EchoRequest(text: "anything"))
        }

        do {
            _ = try await pair.host.send(EchoRequest(text: "anything"))
            Issue.record("expected the handler's failure to propagate")
        } catch {
            #expect(
                error.localizedDescription.contains("refused"),
                "the description has to survive the hop; got \(error.localizedDescription)"
            )
        }
    }

    @Test("A request with no handler on the far side fails rather than hanging")
    func unhandledRequestFails() async throws {
        let pair = try await ConnectedPair.make()
        defer { pair.tearDown() }

        do {
            _ = try await pair.host.send(EchoRequest(text: "nobody is listening"))
            Issue.record("expected an unhandled request to fail")
        } catch {
            #expect(error.localizedDescription.contains("No handler"))
        }
    }

    /// An unresumed `CheckedContinuation` does not just lose a reply — the awaiting task never
    /// returns, forever. Cancelling has to wake everyone still waiting.
    @Test("Cancelling wakes a caller that is still waiting")
    func cancelWakesPendingCallers() async throws {
        let pair = try await ConnectedPair.make()
        defer { pair.tearDown() }

        await pair.payload.setMessageHandler(SlowEchoRequest.self) { request in
            try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            return SlowEchoRequest.Response(text: request.text)
        }

        let pending = Task {
            try await pair.host.send(SlowEchoRequest(text: "never answered", delayMilliseconds: 0))
        }
        try await Task.sleep(nanoseconds: 200 * 1_000_000)
        await pair.host.cancel()

        await #expect(throws: (any Error).self) { _ = try await pending.value }
    }

    @Test("A request times out rather than waiting indefinitely")
    func requestTimesOut() async throws {
        let pair = try await ConnectedPair.make()
        defer { pair.tearDown() }

        await pair.payload.setMessageHandler(SlowEchoRequest.self) { request in
            try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            return SlowEchoRequest.Response(text: request.text)
        }

        do {
            _ = try await pair.host.send(SlowEchoRequest(text: "stalled", delayMilliseconds: 0), timeout: 0.5)
            Issue.record("expected a timeout")
        } catch {
            #expect(error.localizedDescription.contains("within"), "got \(error.localizedDescription)")
        }
    }

    @Test("A body larger than one read still arrives whole")
    func largePayloadSurvivesChunking() async throws {
        let pair = try await ConnectedPair.make()
        defer { pair.tearDown() }

        await pair.payload.setMessageHandler(EchoRequest.self) { EchoRequest.Response(text: $0.text) }

        // Comfortably past the 64 KiB receive chunk, so the frame spans several reads.
        let large = String(repeating: "abcdefghij", count: 30_000)
        let response = try await pair.host.send(EchoRequest(text: large))
        #expect(response.text == large)
        #expect(response.text.count == large.count)
    }
}

// MARK: - Fixtures

private enum HandlerTestError: LocalizedError {
    case refused
    var errorDescription: String? { "the handler refused this one" }
}

private struct EchoRequest: Codable, Request {
    static let identifier = "com.JH.HelperPeerTests.Echo"
    struct Response: Codable, Sendable { let text: String }
    let text: String
}

private struct SlowEchoRequest: Codable, Request {
    static let identifier = "com.JH.HelperPeerTests.SlowEcho"
    struct Response: Codable, Sendable { let text: String }
    let text: String
    let delayMilliseconds: Int
}

/// A host and a payload channel connected over loopback, in this one process.
private struct ConnectedPair {
    let host: PeerSocketChannel
    let payload: PeerSocketChannel

    static func make() async throws -> ConnectedPair {
        // Derive from a unique identifier so concurrent runs do not collide, and retry on the
        // chance that the derived port is already taken by something unrelated — which is a
        // real possibility in a range shared with every ephemeral socket on the machine.
        var lastError: (any Error)?
        for attempt in 0 ..< 8 {
            let port = PeerPortDerivation.port(for: "com.JH.HelperPeerTests.\(UUID().uuidString).\(attempt)")
            do {
                let host = try await PeerSocketChannel.listen(onPort: port)
                let payload = try await PeerSocketChannel.connect(toPort: port)
                try await waitUntilConnected(host)
                try await waitUntilConnected(payload)
                return ConnectedPair(host: host, payload: payload)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? PeerSocketChannel.Error.notConnected
    }

    func tearDown() {
        Task {
            await host.cancel()
            await payload.cancel()
        }
    }

    private static func waitUntilConnected(_ channel: PeerSocketChannel) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await state in channel.stateStream {
                    if case .connected = state { return }
                    if case let .disconnected(error) = state { throw error }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 5 * 1_000_000_000)
                throw PeerSocketChannel.Error.timedOut(requestIdentifier: "handshake", seconds: 5)
            }
            try await group.next()
            group.cancelAll()
        }
    }
}
#endif
