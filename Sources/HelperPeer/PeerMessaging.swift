#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
public import HelperCommunication

/// What a host and its injected payload can do to each other, whichever transport carries it.
///
/// ## Why this is separate from ``PeerConnection``
///
/// There are two transports and they are not interchangeable at every level.
/// ``PeerConnection`` describes the brokered XPC topology: it has a listener endpoint worth
/// publishing, and it carries the untyped name-keyed RPC that SwiftyXPC provides for free. A
/// loopback socket has neither — an `XPCEndpoint` means nothing to it, and forcing it to
/// conform would produce a set of methods whose only behaviour is to throw.
///
/// What both really do is the same four things, and that is what lives here. Code that only
/// sends typed requests, answers typed requests, watches the state and tears the link down can
/// hold `any PeerMessaging` and never learn which transport it got — which is the point, since
/// the choice is made by ``PeerTransportSelection`` from a sandbox probe the caller did not ask
/// about.
///
/// ## Two-phase lifecycle, both transports
///
/// Construction wires nothing up on the wire. Install every handler, then call ``activate()``.
/// Folding the two together races the far side against handler registration: over XPC the peer
/// is told to connect before the handlers exist, and over a socket the payload's first frame can
/// arrive before the registry has anything in it. Both lose the message the same way — the far
/// side gets "no handler is registered", which reads like a programming error rather than a
/// race.
public protocol PeerMessaging: Actor, Sendable {
    /// State stream — `.connecting → .connected` once the link is usable; `.disconnected(_)` on
    /// transport failure, `.cancelled` after ``cancel()``. Finishes after `.cancelled`.
    nonisolated var stateStream: AsyncStream<PeerConnectionState> { get }

    /// Completes the handshake. Call exactly once, after the handlers are installed.
    func activate() async throws

    /// Sends a typed request and waits for the response.
    @discardableResult
    func send<Request: HelperCommunication.Request>(_ request: Request) async throws -> Request.Response

    /// Registers a handler for a typed request. May be called at any point in the link's life,
    /// but see the lifecycle note above for why "before ``activate()``" is the only safe time
    /// for handlers the far side may call immediately.
    nonisolated func setMessageHandler<Request: HelperCommunication.Request>(
        _ requestType: Request.Type,
        handler: @escaping @Sendable (Request) async throws -> Request.Response
    )

    /// Tears the link down and wakes everyone waiting on it. Idempotent.
    func cancel() async
}
#endif
