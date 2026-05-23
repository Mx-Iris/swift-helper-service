#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import Foundation
public import HelperCommunication

/// Abstraction over a brokered XPC peer connection (host ↔ peer process via a privileged tool).
///
/// `PeerConnection` is the unified surface exposed by `HelperPeerClient` and
/// `HelperPeerServer`. Both sides may send typed `HelperCommunication.Request`s,
/// register typed handlers, observe connection state, and surface their own listener
/// endpoint (useful when the endpoint needs to be embedded in a business `Request`
/// payload — e.g. an injected-app registry).
public protocol PeerConnection: Actor, Sendable {
    /// State stream — `.connecting → .connected` on initial handshake; transitions to
    /// `.disconnected(_)` on transport failure or `.cancelled` after an explicit
    /// `cancel()`. Finishes after `.cancelled` is yielded.
    nonisolated var stateStream: AsyncStream<PeerConnectionState> { get }

    /// Own anonymous listener endpoint, suitable for embedding in `Request` payloads so
    /// peers can directly reconnect later.
    var listenerEndpoint: HelperPeerEndpoint { get async }

    /// Send a typed `Request` to the peer. Throws if no peer connection is established
    /// yet, or the underlying XPC connection fails.
    @discardableResult
    func send<Request: HelperCommunication.Request>(_ request: Request) async throws -> Request.Response

    /// Register a handler for a typed `Request`. Handlers run on the listener side and
    /// can be added at any point during the peer's lifetime.
    nonisolated func setMessageHandler<Request: HelperCommunication.Request>(
        _ requestType: Request.Type,
        handler: @escaping @Sendable (Request) async throws -> Request.Response
    )

    // MARK: - Untyped (name-based) RPC

    /// Send an untyped, name-keyed message with no payload and no response.
    nonisolated func sendMessage(name: String) async throws

    /// Send an untyped, name-keyed message with a payload but no response.
    nonisolated func sendMessage<Request: Codable>(name: String, request: Request) async throws

    /// Send an untyped, name-keyed message with no payload and decode a response.
    nonisolated func sendMessage<Response: Codable & Sendable>(name: String) async throws -> Response

    /// Send an untyped, name-keyed message with a payload and decode a response.
    nonisolated func sendMessage<Response: Codable & Sendable>(name: String, request: some Codable) async throws -> Response

    /// Register a handler for a name-keyed message with no payload and no response.
    nonisolated func setMessageHandler(name: String, handler: @escaping @Sendable () async throws -> Void)

    /// Register a handler for a name-keyed message with a payload but no response.
    nonisolated func setMessageHandler<Request: Codable>(name: String, handler: @escaping @Sendable (Request) async throws -> Void)

    /// Register a handler for a name-keyed message with no payload but returning a response.
    nonisolated func setMessageHandler<Response: Codable>(name: String, handler: @escaping @Sendable () async throws -> Response)

    /// Register a handler for a name-keyed message with both payload and response.
    nonisolated func setMessageHandler<Request: Codable, Response: Codable>(name: String, handler: @escaping @Sendable (Request) async throws -> Response)

    /// Tear down the peer: closes the listener and both XPC connections, transitions
    /// state to `.cancelled`, finishes the state stream. Idempotent.
    func cancel() async
}
#endif
