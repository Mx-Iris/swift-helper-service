#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
public import HelperCommunication
public import HelperService

/// Opens the link between a host and the payload injected into it, over whichever transport
/// that particular target allows.
///
/// ## Why a factory and not just two initialisers
///
/// The two sides must agree on the transport, and they cannot ask each other — in the case
/// where the socket is needed, the hop they would negotiate over is the one that is blocked.
/// Agreement therefore comes from both sides computing the same answer from the same inputs:
/// the target's pid and the tool's Mach service name. Putting that computation in one place is
/// the only thing keeping the two sides from drifting apart; a host that picks XPC while its
/// payload picks a socket does not fail, it hangs.
///
/// ## Two phases, as everywhere else in this module
///
/// These return an **unactivated** link. Install the handlers, then call
/// ``PeerMessaging/activate()``. See ``PeerMessaging`` for what goes wrong otherwise.
///
/// ## Which side listens
///
/// It depends on the transport, and the caller should not have to care — that is the point of
/// ``PeerMessaging``. For the record: over XPC the payload listens and the host connects to it;
/// over a socket the host listens and the payload dials out. The inversion is forced by the
/// sandbox, not chosen. See ``PeerTransport``.
public struct PeerLink: Sendable {
    /// The link, ready for handlers and then `activate()`.
    public let channel: any PeerMessaging

    /// Which transport was chosen. Worth logging: it is the first thing to know when a link
    /// fails to come up, and nothing else on the wire reveals it.
    public let transport: PeerTransport

    private init(channel: any PeerMessaging, transport: PeerTransport) {
        self.channel = channel
        self.transport = transport
    }

    // MARK: - Host side

    /// The host's end of a link to a payload it is **about to inject**.
    ///
    /// Must be opened and activated *before* the injection. On the XPC path the payload looks
    /// the host's endpoint up as it starts; on the socket path it dials immediately and a
    /// listener that is not up yet refuses the connection. Either way, late means no link.
    ///
    /// - Parameters:
    ///   - machServiceName: The privileged tool's Mach service name. Also the name whose
    ///     lookup is probed to decide the transport.
    ///   - targetProcessIdentifier: The process about to be injected.
    public static func host(
        machServiceName: String,
        isPrivilegedHelperTool: Bool,
        targetProcessIdentifier: pid_t,
        services: [HelperService] = []
    ) async throws -> PeerLink {
        let transport = PeerTransportSelection.transport(
            forProcess: targetProcessIdentifier,
            machServiceName: machServiceName,
            channelIdentifier: PeerPortDerivation.channelIdentifier(
                serviceName: machServiceName,
                targetProcessIdentifier: targetProcessIdentifier
            )
        )

        switch transport {
        case .brokeredXPC:
            let client = try await HelperPeerClient(
                machServiceName: machServiceName,
                isPrivilegedHelperTool: isPrivilegedHelperTool,
                identifier: String(targetProcessIdentifier),
                services: services
            )
            return PeerLink(channel: client, transport: transport)

        case let .loopbackSocket(port):
            let channel = try PeerSocketChannel.preparedListener(onPort: port)
            await channel.install(services)
            return PeerLink(channel: channel, transport: transport)
        }
    }

    /// The host's end of a link to a payload that is **already resident**, using the endpoint
    /// that payload published.
    ///
    /// XPC only, and that is a real limitation rather than an omission: reconnecting works
    /// because the payload's listener outlives the host app, and on the socket path the payload
    /// is not the one listening. A host that restarts leaves its socket payload with a dead
    /// connection and no way to be told about the new one. Sandboxed targets therefore survive
    /// a host restart only by being injected again — and since a mapped image cannot be loaded
    /// twice, in practice that means the target has to be restarted too.
    ///
    /// Callers that reach here for a sandboxed target get ``Failure/reconnectionNeedsXPC``
    /// rather than a link that silently never connects.
    public static func hostReconnecting(
        machServiceName: String,
        isPrivilegedHelperTool: Bool,
        targetProcessIdentifier: pid_t,
        payloadEndpoint: HelperPeerEndpoint,
        services: [HelperService] = []
    ) async throws -> PeerLink {
        let transport = PeerTransportSelection.transport(
            forProcess: targetProcessIdentifier,
            machServiceName: machServiceName,
            channelIdentifier: PeerPortDerivation.channelIdentifier(
                serviceName: machServiceName,
                targetProcessIdentifier: targetProcessIdentifier
            )
        )
        guard case .brokeredXPC = transport else {
            throw Failure.reconnectionNeedsXPC(targetProcessIdentifier: targetProcessIdentifier)
        }

        let client = try await HelperPeerClient(
            machServiceName: machServiceName,
            isPrivilegedHelperTool: isPrivilegedHelperTool,
            identifier: String(targetProcessIdentifier),
            serverEndpoint: payloadEndpoint,
            services: services
        )
        return PeerLink(channel: client, transport: transport)
    }

    // MARK: - Payload side

    /// The payload's end, from inside the target.
    ///
    /// Takes no pid: the payload is the target, so it asks about `getpid()`. Passing one in
    /// would create a way for the two sides to disagree, which is the one failure this design
    /// is built to rule out.
    public static func payload(
        machServiceName: String,
        isPrivilegedHelperTool: Bool,
        services: [HelperService] = []
    ) async throws -> PeerLink {
        let ownProcessIdentifier = getpid()
        let transport = PeerTransportSelection.transport(
            forProcess: ownProcessIdentifier,
            machServiceName: machServiceName,
            channelIdentifier: PeerPortDerivation.channelIdentifier(
                serviceName: machServiceName,
                targetProcessIdentifier: ownProcessIdentifier
            )
        )

        switch transport {
        case .brokeredXPC:
            let server = try await HelperPeerServer(
                machServiceName: machServiceName,
                isPrivilegedHelperTool: isPrivilegedHelperTool,
                identifier: String(ownProcessIdentifier),
                services: services
            )
            return PeerLink(channel: server, transport: transport)

        case let .loopbackSocket(port):
            let channel = PeerSocketChannel.preparedDialer(toPort: port)
            await channel.install(services)
            return PeerLink(channel: channel, transport: transport)
        }
    }

    public enum Failure: LocalizedError {
        case reconnectionNeedsXPC(targetProcessIdentifier: pid_t)

        public var errorDescription: String? {
            switch self {
            case let .reconnectionNeedsXPC(targetProcessIdentifier):
                """
                Cannot reconnect to the payload in \(targetProcessIdentifier): it is sandboxed, so \
                its link is a loopback socket on which the host is the listener. There is no \
                listener on the payload's side to reconnect to. Inject again — which, because a \
                mapped image cannot be loaded twice, generally means restarting the target first.
                """
            }
        }
    }
}
#endif
