#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
import Network
public import HelperCommunication
import FoundationToolbox

/// A typed request/response channel over a loopback socket, for the pairs that cannot use XPC.
///
/// ## When this is the transport
///
/// Only when the payload's target is sandboxed — see ``PeerTransportSelection``. Everything else
/// uses the brokered XPC path, which is simpler and better tested.
///
/// ## Which side is which
///
/// **The host listens and the payload connects out**, which is the opposite of the business
/// relationship and the opposite of the XPC path. A sandboxed process can dial localhost but
/// nothing can discover a port it bound, so the side that can be found has to be the one
/// listening. Both sides derive the port from the same identifier
/// (``PeerPortDerivation``) rather than telling each other.
///
/// ## What it does not do
///
/// No authentication and no encryption. It is bound to `127.0.0.1`, so the exposure is to other
/// processes on this machine — the same ones that could already talk to the daemon. Adding TLS
/// here would protect against nothing that is not already lost.
@Loggable(subsystem: "com.JH.HelperPeer", category: "Socket")
public actor PeerSocketChannel {
    public enum Error: LocalizedError {
        case listenerFailed(any Swift.Error)
        case connectionFailed(any Swift.Error)
        case notConnected
        case timedOut(requestIdentifier: String, seconds: Double)
        case cancelled

        public var errorDescription: String? {
            switch self {
            case let .listenerFailed(underlying):
                "Could not listen on the loopback port: \(underlying.localizedDescription). Another process may already hold the derived port."
            case let .connectionFailed(underlying):
                """
                Could not connect to the host over loopback: \(underlying.localizedDescription). \
                If the target is sandboxed, check it carries com.apple.security.network.client — \
                without it the sandbox denies even a localhost connection.
                """
            case .notConnected:
                "The peer socket channel is not connected."
            case let .timedOut(requestIdentifier, seconds):
                "No response to \(requestIdentifier) within \(seconds)s over the peer socket."
            case .cancelled:
                "The peer socket channel was cancelled."
            }
        }
    }

    /// How long a request waits for its response.
    ///
    /// A socket gives no indication that the far side has stopped caring — unlike XPC, where an
    /// interrupted connection surfaces on its own. Without a deadline a caller waits forever on
    /// a payload that stalled.
    public static let defaultRequestTimeout: Double = 30

    private let listener: NWListener?
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.JH.HelperPeer.PeerSocketChannel")

    private var receiveBuffer = Data()
    private var nextCorrelationIdentifier: UInt64 = 1
    private var pendingResponses: [UInt64: CheckedContinuation<PeerSocketMessage, any Swift.Error>] = [:]

    private let handlerRegistry = HandlerRegistry()
    private let stateContinuation: AsyncStream<PeerConnectionState>.Continuation
    public nonisolated let stateStream: AsyncStream<PeerConnectionState>

    private var isCancelled = false

    // MARK: - Construction

    private init(listener: NWListener?, connection: NWConnection?) {
        self.listener = listener
        self.connection = connection

        var capturedContinuation: AsyncStream<PeerConnectionState>.Continuation!
        self.stateStream = AsyncStream<PeerConnectionState> { capturedContinuation = $0 }
        self.stateContinuation = capturedContinuation
        capturedContinuation.yield(.connecting)
    }

    /// Host side: binds `port` on loopback and waits for the payload to connect.
    ///
    /// Call this **before** injecting. The payload dials the moment it starts, and a listener
    /// that is not up yet means a connection refused — which the payload cannot retry forever
    /// without looking like a hang.
    public static func listen(onPort port: UInt16) async throws -> PeerSocketChannel {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .init(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw Error.listenerFailed(error)
        }

        let channel = PeerSocketChannel(listener: listener, connection: nil)
        await channel.startListening()
        return channel
    }

    /// Payload side: connects to the host on loopback.
    public static func connect(toPort port: UInt16) async throws -> PeerSocketChannel {
        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .init(rawValue: port)!)
        let connection = NWConnection(to: endpoint, using: .tcp)

        let channel = PeerSocketChannel(listener: nil, connection: connection)
        await channel.startConnecting(connection)
        return channel
    }

    // MARK: - Lifecycle

    private func startListening() {
        guard let listener else { return }
        listener.newConnectionHandler = { [weak self] newConnection in
            Task { await self?.adopt(newConnection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard case let .failed(error) = state else { return }
            Task { await self?.fail(with: Error.listenerFailed(error)) }
        }
        listener.start(queue: queue)
    }

    /// Takes the first connection and refuses the rest.
    ///
    /// One channel is one host-payload pair. A second connection on the same port means either
    /// a stale payload from a previous injection or something unrelated that happened to pick
    /// this port; serving it would interleave two conversations on one correlation space.
    private func adopt(_ newConnection: NWConnection) {
        guard connection == nil, !isCancelled else {
            #log(.error, "Refusing a second connection on the peer socket; one channel serves one pair")
            newConnection.cancel()
            return
        }
        connection = newConnection
        startConnectionLifecycle(newConnection)
    }

    private func startConnecting(_ connection: NWConnection) {
        startConnectionLifecycle(connection)
    }

    private func startConnectionLifecycle(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            Task { await self?.handle(state: state) }
        }
        connection.start(queue: queue)
        receiveNextChunk(on: connection)
    }

    private func handle(state: NWConnection.State) {
        switch state {
        case .ready:
            stateContinuation.yield(.connected)
        case let .failed(error):
            fail(with: Error.connectionFailed(error))
        case .cancelled:
            // Only reached through `cancel()`, which yields `.cancelled` itself.
            break
        default:
            break
        }
    }

    private func fail(with error: any Swift.Error) {
        guard !isCancelled else { return }
        failAllPendingResponses(with: error)
        stateContinuation.yield(.disconnected(error))
    }

    /// Closes everything and wakes every waiting caller.
    ///
    /// Resuming the pending continuations is not tidiness: a `CheckedContinuation` that is never
    /// resumed leaks its task forever, and the caller simply never returns.
    public func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        failAllPendingResponses(with: Error.cancelled)
        connection?.cancel()
        listener?.cancel()
        stateContinuation.yield(.cancelled)
        stateContinuation.finish()
    }

    private func failAllPendingResponses(with error: any Swift.Error) {
        let pending = pendingResponses
        pendingResponses.removeAll()
        for continuation in pending.values {
            continuation.resume(throwing: error)
        }
    }

    // MARK: - Receiving

    private func receiveNextChunk(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] content, _, isComplete, error in
            Task { [weak self] in
                guard let self else { return }
                await self.ingest(content: content, isComplete: isComplete, error: error, connection: connection)
            }
        }
    }

    private func ingest(content: Data?, isComplete: Bool, error: NWError?, connection: NWConnection) {
        if let error {
            fail(with: Error.connectionFailed(error))
            return
        }
        if let content, !content.isEmpty {
            receiveBuffer.append(content)
            do {
                while let frame = try PeerSocketFraming.takeFrame(from: &receiveBuffer) {
                    dispatch(frame: frame)
                }
            } catch {
                // The stream is out of sync; no amount of further reading recovers it.
                #log(.error, "Peer socket framing error: \(String(describing: error), privacy: .public)")
                fail(with: error)
                return
            }
        }
        guard !isComplete, !isCancelled else {
            if isComplete { fail(with: Error.notConnected) }
            return
        }
        receiveNextChunk(on: connection)
    }

    private func dispatch(frame: Data) {
        guard let message = try? JSONDecoder().decode(PeerSocketMessage.self, from: frame) else {
            #log(.error, "Discarding an undecodable peer socket frame of \(frame.count, privacy: .public) bytes")
            return
        }

        switch message.kind {
        case .response, .failure:
            guard let continuation = pendingResponses.removeValue(forKey: message.correlationIdentifier) else {
                // A reply to a request that already timed out, or a duplicate.
                #log(.error, "No caller waiting for correlation \(message.correlationIdentifier, privacy: .public)")
                return
            }
            continuation.resume(returning: message)

        case .request:
            Task { await self.serve(request: message) }
        }
    }

    private func serve(request: PeerSocketMessage) async {
        let reply: PeerSocketMessage
        do {
            guard let handler = await handlerRegistry.handler(for: request.identifier) else {
                throw PeerSocketFailure(description: "No handler is registered for \(request.identifier).")
            }
            let responseBody = try await handler(request.body)
            reply = PeerSocketMessage(
                kind: .response,
                correlationIdentifier: request.correlationIdentifier,
                identifier: "",
                body: responseBody
            )
        } catch {
            let failure = PeerSocketFailure(description: error.localizedDescription)
            reply = PeerSocketMessage(
                kind: .failure,
                correlationIdentifier: request.correlationIdentifier,
                identifier: "",
                body: (try? JSONEncoder().encode(failure)) ?? Data()
            )
        }
        try? await transmit(reply)
    }

    // MARK: - Sending

    /// Sends a typed request and waits for its response.
    @discardableResult
    public func send<Request: HelperCommunication.Request>(
        _ request: Request,
        timeout: Double = PeerSocketChannel.defaultRequestTimeout
    ) async throws -> Request.Response {
        guard !isCancelled else { throw Error.cancelled }

        let correlationIdentifier = nextCorrelationIdentifier
        nextCorrelationIdentifier += 1

        let message = PeerSocketMessage(
            kind: .request,
            correlationIdentifier: correlationIdentifier,
            identifier: Request.identifier,
            body: try JSONEncoder().encode(request)
        )

        let timeoutTask = Task { [weak self] in
            // `Task.sleep(for:)` is macOS 13; the package floor is 10.15 and raising it for a
            // sleep would be the wrong trade.
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.timeOut(correlationIdentifier: correlationIdentifier, requestIdentifier: Request.identifier, seconds: timeout)
        }
        defer { timeoutTask.cancel() }

        let reply: PeerSocketMessage = try await withCheckedThrowingContinuation { continuation in
            pendingResponses[correlationIdentifier] = continuation
            Task {
                do {
                    try await transmit(message)
                } catch {
                    // Resume through the registry so a reply that races the failure cannot
                    // resume the same continuation twice.
                    if let pending = pendingResponses.removeValue(forKey: correlationIdentifier) {
                        pending.resume(throwing: error)
                    }
                }
            }
        }

        if reply.kind == .failure {
            throw (try? JSONDecoder().decode(PeerSocketFailure.self, from: reply.body))
                ?? PeerSocketFailure(description: "The peer reported a failure with no description.")
        }
        return try JSONDecoder().decode(Request.Response.self, from: reply.body)
    }

    private func timeOut(correlationIdentifier: UInt64, requestIdentifier: String, seconds: Double) {
        guard let continuation = pendingResponses.removeValue(forKey: correlationIdentifier) else { return }
        continuation.resume(throwing: Error.timedOut(requestIdentifier: requestIdentifier, seconds: seconds))
    }

    private func transmit(_ message: PeerSocketMessage) async throws {
        guard let connection, !isCancelled else { throw Error.notConnected }
        let framed = try PeerSocketFraming.frame(JSONEncoder().encode(message))

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Swift.Error>) in
            connection.send(content: framed, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: Error.connectionFailed(error))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    // MARK: - Handlers

    /// Registers a handler for a typed request. May be called at any point in the channel's life.
    public nonisolated func setMessageHandler<Request: HelperCommunication.Request>(
        _ requestType: Request.Type,
        handler: @escaping @Sendable (Request) async throws -> Request.Response
    ) {
        Task {
            await handlerRegistry.register(identifier: Request.identifier) { body in
                let request = try JSONDecoder().decode(Request.self, from: body)
                return try JSONEncoder().encode(try await handler(request))
            }
        }
    }

    /// Serialises handler registration against lookup from the receive path.
    private actor HandlerRegistry {
        private var handlersByIdentifier: [String: @Sendable (Data) async throws -> Data] = [:]

        func register(identifier: String, handler: @escaping @Sendable (Data) async throws -> Data) {
            handlersByIdentifier[identifier] = handler
        }

        func handler(for identifier: String) -> (@Sendable (Data) async throws -> Data)? {
            handlersByIdentifier[identifier]
        }
    }
}
#endif
