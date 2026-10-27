#if os(macOS)
import Foundation
import Testing
import HelperCommunication
import HelperService
@testable import HelperPeer

/// The socket transport seen through ``PeerMessaging`` — the surface that lets a caller hold a
/// link without knowing which transport it got.
///
/// These matter because the alternative is a caller that works on unsandboxed targets and
/// silently does nothing on sandboxed ones. Everything here goes through `any PeerMessaging`
/// deliberately: calling the concrete type would not prove the existential is usable, and a
/// generic method that cannot be called on an existential is a compile error nobody hits until
/// they try.
@Suite("Peer messaging over a socket", .serialized)
struct PeerMessagingTests {
    @Test("A link held as an existential sends and answers")
    func existentialRoundTrip() async throws {
        let pair = try await PreparedPair.make()
        defer { pair.tearDown() }

        let payload: any PeerMessaging = pair.payload
        payload.setMessageHandler(MessagingEchoRequest.self) { MessagingEchoRequest.Response(text: $0.text.uppercased()) }
        try await pair.activateBoth()

        let host: any PeerMessaging = pair.host
        let response = try await host.send(MessagingEchoRequest(text: "through the protocol"))
        #expect(response.text == "THROUGH THE PROTOCOL")
    }

    /// The reason the lifecycle has two phases. The payload dials and sends immediately; a
    /// handler registered after the socket is up is a handler the first message misses.
    @Test("A handler installed before activate catches the first message")
    func handlerInstalledBeforeActivateCatchesFirstMessage() async throws {
        let pair = try await PreparedPair.make()
        defer { pair.tearDown() }

        pair.host.setMessageHandler(MessagingEchoRequest.self) { MessagingEchoRequest.Response(text: "host saw \($0.text)") }
        try await pair.activateBoth()

        let response = try await pair.payload.send(MessagingEchoRequest(text: "first"))
        #expect(response.text == "host saw first")
    }

    @Test("Activating twice is harmless")
    func activateIsIdempotent() async throws {
        let pair = try await PreparedPair.make()
        defer { pair.tearDown() }

        pair.payload.setMessageHandler(MessagingEchoRequest.self) { MessagingEchoRequest.Response(text: $0.text) }
        try await pair.host.activate()
        try await pair.host.activate()
        try await pair.activateBoth()

        #expect(try await pair.host.send(MessagingEchoRequest(text: "still fine")).text == "still fine")
    }

    @Test("Activating a cancelled channel fails instead of reopening the socket")
    func activateAfterCancelFails() async throws {
        let channel = PeerSocketChannel.preparedDialer(toPort: PeerPortDerivation.port(for: "com.JH.HelperPeerTests.\(UUID().uuidString)"))
        await channel.cancel()

        await #expect(throws: (any Error).self) { try await channel.activate() }
    }

    /// Sending before the far side has arrived is a failure, not a wait — the same answer the
    /// XPC path gives. A host that has only just activated has a listener and no peer; callers
    /// watch ``PeerMessaging/stateStream`` for `.connected` rather than sending hopefully.
    @Test("Sending before the far side arrives fails rather than blocking")
    func sendBeforeConnectionFails() async throws {
        let pair = try await PreparedPair.make()
        defer { pair.tearDown() }

        try await pair.host.activate()

        await #expect(throws: (any Error).self) {
            _ = try await pair.host.send(MessagingEchoRequest(text: "nobody has dialled in yet"))
        }
    }

    /// A `HelperService` written once has to work on both transports. Mounted on a socket it
    /// used to do nothing at all — the service protocol only knew how to install itself on an
    /// XPC listener.
    @Test("A HelperService mounted on a socket link answers")
    func helperServiceMountsOnSocket() async throws {
        let pair = try await PreparedPair.make()
        defer { pair.tearDown() }

        await pair.payload.install([GreetingService()])
        try await pair.activateBoth()

        let response = try await pair.host.send(GreetingRequest(name: "payload"))
        #expect(response.greeting == "hello, payload")
    }
}

// MARK: - Fixtures

private struct MessagingEchoRequest: Codable, Request {
    static let identifier = "com.JH.HelperPeerTests.MessagingEcho"
    struct Response: Codable, Sendable { let text: String }
    let text: String
}

private struct GreetingRequest: Codable, Request {
    static let identifier = "com.JH.HelperPeerTests.Greeting"
    struct Response: Codable, Sendable { let greeting: String }
    let name: String
}

private struct GreetingService: HelperService {
    func setupHandler(_ handler: some HelperHandler) async {
        handler.setMessageHandler { (request: GreetingRequest) in
            GreetingRequest.Response(greeting: "hello, \(request.name)")
        }
        await handler.activate()
    }
}

/// Two channels aimed at each other but **not yet activated**, so a test can install handlers
/// in between — which is the whole point of the two-phase lifecycle.
private struct PreparedPair {
    let host: PeerSocketChannel
    let payload: PeerSocketChannel

    static func make() async throws -> PreparedPair {
        // Retry: the derived port is in the range every ephemeral socket on the machine draws
        // from, so an unrelated process can be holding it.
        var lastError: (any Error)?
        for attempt in 0 ..< 8 {
            let port = PeerPortDerivation.port(for: "com.JH.HelperPeerTests.\(UUID().uuidString).\(attempt)")
            do {
                return PreparedPair(
                    host: try PeerSocketChannel.preparedListener(onPort: port),
                    payload: PeerSocketChannel.preparedDialer(toPort: port)
                )
            } catch {
                lastError = error
            }
        }
        throw lastError ?? PeerSocketChannel.Error.notConnected
    }

    /// Brings both ends up, **host first**, and waits until each reports `.connected`.
    ///
    /// The order is not a style choice and this helper exists so no test gets it wrong: the
    /// dialer needs something to dial. In production the same constraint reads as "open the
    /// host link before injecting" — a payload that starts against a listener that is not up
    /// gets connection refused, and nothing retries it.
    func activateBoth() async throws {
        try await host.activate()
        try await payload.activate()
        try await PreparedPair.waitUntilConnected(host)
        try await PreparedPair.waitUntilConnected(payload)
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
