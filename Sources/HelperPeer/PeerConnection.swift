#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import Foundation
import HelperCommunication
@preconcurrency public import SwiftyXPC

/// Abstraction over a brokered XPC peer connection (host ↔ peer process via a privileged tool).
///
/// `PeerConnection` is the unified surface exposed by `BrokeredPeerClient` and
/// `BrokeredPeerServer`. Both sides may send typed `HelperCommunication.Request`s,
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
    var listenerEndpoint: SwiftyXPC.XPCEndpoint { get async }

    /// Send a typed `Request` to the peer. Throws if no peer connection is established
    /// yet, or the underlying XPC connection fails.
    @discardableResult
    func send<Request: HelperCommunication.Request>(_ request: Request) async throws -> Request.Response

    /// Register a handler for a typed `Request`. Handlers run on the listener side and
    /// can be added at any point during the peer's lifetime.
    func setMessageHandler<Request: HelperCommunication.Request>(
        _ requestType: Request.Type,
        handler: @escaping @Sendable (Request) async throws -> Request.Response
    ) async

    /// Tear down the peer: closes the listener and both XPC connections, transitions
    /// state to `.cancelled`, finishes the state stream. Idempotent.
    func cancel() async
}
#endif
