#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import Foundation
import HelperCommunication
import HelperService
@preconcurrency public import SwiftyXPC
import OSLog

/// Peer that participates in a brokered XPC topology as the *server* (the one that
/// fetches the peer's endpoint from the broker, opens a direct reverse connection,
/// and registers its own endpoint for later host-side reconnects).
public actor BrokeredPeerServer: PeerConnection {
    public enum Error: LocalizedError {
        case peerNotConnected
        case cancelled

        public var errorDescription: String? {
            switch self {
            case .peerNotConnected: return "Peer connection not established"
            case .cancelled: return "Peer was cancelled"
            }
        }
    }

    public nonisolated let stateStream: AsyncStream<PeerConnectionState>

    private nonisolated let stateContinuation: AsyncStream<PeerConnectionState>.Continuation

    private nonisolated let listener: SwiftyXPC.XPCListener

    private nonisolated let serviceConnection: SwiftyXPC.XPCConnection

    private nonisolated let logger = Logger(subsystem: "com.JH.HelperPeer", category: "BrokeredPeerServer")

    private var peerConnection: SwiftyXPC.XPCConnection?

    private var isCancelled: Bool = false

    public nonisolated var listenerEndpoint: SwiftyXPC.XPCEndpoint {
        get async { listener.endpoint }
    }

    public init(
        machServiceName: String,
        isPrivilegedHelperTool: Bool,
        identifier: String,
        services: [HelperService] = []
    ) async throws {
        var capturedContinuation: AsyncStream<PeerConnectionState>.Continuation!
        self.stateStream = AsyncStream<PeerConnectionState> { continuation in
            capturedContinuation = continuation
        }
        self.stateContinuation = capturedContinuation
        capturedContinuation.yield(.connecting)

        let listener = try SwiftyXPC.XPCListener(type: .anonymous, codeSigningRequirement: nil)
        self.listener = listener

        let serviceConnection = try SwiftyXPC.XPCConnection(
            type: .remoteMachService(serviceName: machServiceName, isPrivilegedHelperTool: isPrivilegedHelperTool)
        )
        serviceConnection.activate()
        self.serviceConnection = serviceConnection

        self.peerConnection = nil

        await wireListenerHandlers()
        for service in services {
            await service.setupHandler(listener)
        }

        let peerConnection: SwiftyXPC.XPCConnection
        do {
            try await serviceConnection.pingHelperTool()
            let clientEndpoint = try await serviceConnection.fetchEndpoint(machServiceName: machServiceName, identifier: identifier)
            peerConnection = try SwiftyXPC.XPCConnection(type: .remoteServiceFromEndpoint(clientEndpoint))
            peerConnection.activate()
            try await peerConnection.pingHelperTool()
            try await peerConnection.sendMessage(request: ServerLaunchedNotification(endpoint: listener.endpoint))
            // Re-register own listener endpoint so the host can directly reconnect later.
            try await serviceConnection.registerEndpoint(listener.endpoint, machServiceName: machServiceName, identifier: identifier)
        } catch {
            capturedContinuation.yield(.disconnected(error))
            throw error
        }

        self.peerConnection = peerConnection
        configureErrorHandlers()
        listener.activate()
        capturedContinuation.yield(.connected)
    }

    // MARK: - PeerConnection

    @discardableResult
    public func send<Request: HelperCommunication.Request>(_ request: Request) async throws -> Request.Response {
        if isCancelled { throw Error.cancelled }
        guard let peerConnection else { throw Error.peerNotConnected }
        return try await peerConnection.sendMessage(request: request)
    }

    public func setMessageHandler<Request: HelperCommunication.Request>(
        _ requestType: Request.Type,
        handler: @escaping @Sendable (Request) async throws -> Request.Response
    ) async {
        listener.setMessageHandler(requestType: requestType) { _, request in
            try await handler(request)
        }
    }

    public func cancel() async {
        guard !isCancelled else { return }
        isCancelled = true
        peerConnection?.cancel()
        peerConnection = nil
        serviceConnection.cancel()
        listener.cancel()
        stateContinuation.yield(.cancelled)
        stateContinuation.finish()
    }

    // MARK: - Internals

    private func wireListenerHandlers() async {
        listener.setMessageHandler(requestType: PingRequest.self) { _, _ in
            .empty
        }
        listener.setMessageHandler(requestType: ClientReconnectedNotification.self) { [weak self] _, notification in
            guard let self else { return .empty }
            await self.handleClientReconnected(endpoint: notification.endpoint)
            return .empty
        }
    }

    private func handleClientReconnected(endpoint: SwiftyXPC.XPCEndpoint) async {
        guard !isCancelled else { return }
        do {
            let newPeerConnection = try SwiftyXPC.XPCConnection(type: .remoteServiceFromEndpoint(endpoint))
            newPeerConnection.activate()
            try await newPeerConnection.pingHelperTool()
            peerConnection?.cancel()
            peerConnection = newPeerConnection
            installPeerErrorHandler(on: newPeerConnection)
            stateContinuation.yield(.connected)
        } catch {
            stateContinuation.yield(.disconnected(error))
        }
    }

    private func configureErrorHandlers() {
        listener.errorHandler = { [weak self] _, error in
            guard let self else { return }
            self.logger.error("Listener error: \(String(describing: error), privacy: .public)")
            self.stateContinuation.yield(.disconnected(error))
        }
        serviceConnection.errorHandler = { [weak self] _, error in
            guard let self else { return }
            self.logger.error("Service connection error: \(String(describing: error), privacy: .public)")
        }
        if let peerConnection {
            installPeerErrorHandler(on: peerConnection)
        }
    }

    private nonisolated func installPeerErrorHandler(on connection: SwiftyXPC.XPCConnection) {
        connection.errorHandler = { [weak self] _, error in
            guard let self else { return }
            self.logger.error("Peer connection error: \(String(describing: error), privacy: .public)")
            self.stateContinuation.yield(.disconnected(error))
        }
    }
}
#endif
