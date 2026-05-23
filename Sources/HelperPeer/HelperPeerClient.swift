#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import Foundation
public import HelperCommunication
import HelperService
@preconcurrency internal import SwiftyXPC
import FoundationToolbox

/// Peer that participates in a brokered XPC topology as the *client* (the one whose
/// listener endpoint is registered with the broker and whose peer reverse-connects).
///
/// Two construction modes:
/// - Initial handshake: connect to tool, register own endpoint, wait for peer's
///   `ServerLaunchedNotification` to populate the peer connection.
/// - Reconnect with known `serverEndpoint`: open listener, direct-connect to the
///   peer's endpoint, notify peer to swap its peer connection.
@Loggable
public actor HelperPeerClient: PeerConnection {
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

    private var peerConnection: SwiftyXPC.XPCConnection?

    private var isCancelled: Bool = false

    public nonisolated var listenerEndpoint: HelperPeerEndpoint {
        get async { HelperPeerEndpoint(listener.endpoint) }
    }

    /// Initial-handshake init. Connects to the tool, registers the listener endpoint
    /// under `(machServiceName, identifier)`, and waits for the peer's
    /// `ServerLaunchedNotification` (delivered asynchronously after activation).
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

        await wireListenerHandlers(initialHandshake: true)
        let handlerAdapter = XPCHelperHandler(listener: listener)
        for service in services {
            await service.setupHandler(handlerAdapter)
        }

        do {
            try await serviceConnection.pingHelperTool()
            try await serviceConnection.registerEndpoint(listener.endpoint, machServiceName: machServiceName, identifier: identifier)
        } catch {
            stateContinuation.yield(.disconnected(error))
            throw error
        }

        configureErrorHandlers()
        listener.activate()
    }

    /// Reconnect init. Opens a fresh listener, direct-connects to the peer's known
    /// `serverEndpoint`, notifies peer via `ClientReconnectedNotification`. Used when
    /// the host app reconnects to an already-running peer process (e.g. an injected
    /// app's existing `HelperPeerServer`).
    public init(
        machServiceName: String,
        isPrivilegedHelperTool: Bool,
        identifier: String,
        serverEndpoint: HelperPeerEndpoint,
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

        let peerConnection = try SwiftyXPC.XPCConnection(type: .remoteServiceFromEndpoint(serverEndpoint.underlying))
        peerConnection.activate()
        self.peerConnection = peerConnection

        await wireListenerHandlers(initialHandshake: false)
        let handlerAdapter = XPCHelperHandler(listener: listener)
        for service in services {
            await service.setupHandler(handlerAdapter)
        }

        do {
            try await peerConnection.pingHelperTool()
            try await peerConnection.sendMessage(request: ClientReconnectedNotification(endpoint: HelperPeerEndpoint(listener.endpoint)))
        } catch {
            stateContinuation.yield(.disconnected(error))
            throw error
        }

        configureErrorHandlers()
        listener.activate()
        stateContinuation.yield(.connected)
    }

    // MARK: - PeerConnection

    @discardableResult
    public func send<Request: HelperCommunication.Request>(_ request: Request) async throws -> Request.Response {
        if isCancelled { throw Error.cancelled }
        guard let peerConnection else { throw Error.peerNotConnected }
        return try await peerConnection.sendMessage(request: request)
    }

    public nonisolated func setMessageHandler<Request: HelperCommunication.Request>(
        _ requestType: Request.Type,
        handler: @escaping @Sendable (Request) async throws -> Request.Response
    ) {
        listener.setMessageHandler(requestType: requestType) { _, request in
            try await handler(request)
        }
    }

    // MARK: - Untyped (name-based) RPC

    public nonisolated func sendMessage(name: String) async throws {
        let peer = try await currentPeerOrThrow()
        try await peer.sendMessage(name: name)
    }

    public nonisolated func sendMessage<Request: Codable>(name: String, request: Request) async throws {
        let peer = try await currentPeerOrThrow()
        try await peer.sendMessage(name: name, request: request)
    }

    public nonisolated func sendMessage<Response: Codable & Sendable>(name: String) async throws -> Response {
        let peer = try await currentPeerOrThrow()
        return try await peer.sendMessage(name: name)
    }

    public nonisolated func sendMessage<Response: Codable & Sendable>(name: String, request: some Codable) async throws -> Response {
        let peer = try await currentPeerOrThrow()
        return try await peer.sendMessage(name: name, request: request)
    }

    private func currentPeerOrThrow() throws -> SwiftyXPC.XPCConnection {
        if isCancelled { throw Error.cancelled }
        guard let peerConnection else { throw Error.peerNotConnected }
        return peerConnection
    }

    public nonisolated func setMessageHandler(name: String, handler: @escaping @Sendable () async throws -> Void) {
        listener.setMessageHandler(name: name) { (_: SwiftyXPC.XPCConnection) in
            try await handler()
        }
    }

    public nonisolated func setMessageHandler<Request: Codable>(name: String, handler: @escaping @Sendable (Request) async throws -> Void) {
        listener.setMessageHandler(name: name) { (_: SwiftyXPC.XPCConnection, request: Request) in
            try await handler(request)
        }
    }

    public nonisolated func setMessageHandler<Response: Codable>(name: String, handler: @escaping @Sendable () async throws -> Response) {
        listener.setMessageHandler(name: name) { (_: SwiftyXPC.XPCConnection) -> Response in
            try await handler()
        }
    }

    public nonisolated func setMessageHandler<Request: Codable, Response: Codable>(name: String, handler: @escaping @Sendable (Request) async throws -> Response) {
        listener.setMessageHandler(name: name) { (_: SwiftyXPC.XPCConnection, request: Request) -> Response in
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

    private func wireListenerHandlers(initialHandshake: Bool) async {
        listener.setMessageHandler(requestType: PingRequest.self) { _, _ in
            .empty
        }
        if initialHandshake {
            listener.setMessageHandler(requestType: ServerLaunchedNotification.self) { [weak self] _, notification in
                guard let self else { return .empty }
                await self.handleServerLaunched(endpoint: notification.endpoint)
                return .empty
            }
        }
    }

    private func handleServerLaunched(endpoint: HelperPeerEndpoint) async {
        guard !isCancelled else { return }
        do {
            let peerConnection = try SwiftyXPC.XPCConnection(type: .remoteServiceFromEndpoint(endpoint.underlying))
            peerConnection.activate()
            try await peerConnection.pingHelperTool()
            self.peerConnection = peerConnection
            installPeerErrorHandler(on: peerConnection)
            stateContinuation.yield(.connected)
        } catch {
            stateContinuation.yield(.disconnected(error))
        }
    }

    private func configureErrorHandlers() {
        listener.errorHandler = { [weak self] _, error in
            #log(.error, "Listener error: \(String(describing: error), privacy: .public)")
            self?.stateContinuation.yield(.disconnected(error))
        }
        serviceConnection.errorHandler = { _, error in
            #log(.error, "Service connection error: \(String(describing: error), privacy: .public)")
        }
        if let peerConnection {
            installPeerErrorHandler(on: peerConnection)
        }
    }

    private nonisolated func installPeerErrorHandler(on connection: SwiftyXPC.XPCConnection) {
        connection.errorHandler = { [weak self] _, error in
            #log(.error, "Peer connection error: \(String(describing: error), privacy: .public)")
            self?.stateContinuation.yield(.disconnected(error))
        }
    }
}
#endif
