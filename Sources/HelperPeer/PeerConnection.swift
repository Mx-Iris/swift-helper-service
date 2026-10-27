#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
public import HelperCommunication

/// A ``PeerMessaging`` link carried by brokered XPC — host ↔ peer process via a privileged tool.
///
/// `PeerConnection` is the surface shared by `HelperPeerClient` and `HelperPeerServer`. On top
/// of the four things every transport can do (see ``PeerMessaging``) it adds the two that are
/// specific to XPC: an anonymous listener endpoint worth publishing, and the untyped name-keyed
/// RPC SwiftyXPC provides.
///
/// Code that does not need those two should hold `any PeerMessaging` instead, so it keeps
/// working when the sandbox forces the pair onto a loopback socket.
public protocol PeerConnection: PeerMessaging {
    /// Own anonymous listener endpoint, suitable for embedding in `Request` payloads so
    /// peers can directly reconnect later.
    ///
    /// This is the member that does not generalise. A socket link has nothing to put here: the
    /// two sides agree on a port by deriving it (``PeerPortDerivation``) precisely because they
    /// have no channel on which to exchange an address.
    var listenerEndpoint: HelperPeerEndpoint { get async }

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
}
#endif
