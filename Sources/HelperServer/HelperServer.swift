#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
import HelperService
import HelperCommunication
@preconcurrency private import SwiftyXPC
import FoundationToolbox
internal import MainService

@Loggable
public actor HelperServer {
    private let serverType: HelperServerType

    private let listener: SwiftyXPC.XPCListener

    private let services: [HelperService]

    private var toolConnection: SwiftyXPC.XPCConnection?

    public init(serverType: HelperServerType, version: String, services: [HelperService]) async throws {
        self.serverType = serverType
        switch serverType {
        case .plain:
            self.listener = try SwiftyXPC.XPCListener(type: .anonymous, codeSigningRequirement: nil)
        case .machService(let name):
            self.listener = try SwiftyXPC.XPCListener(type: .machService(name: name), codeSigningRequirement: nil)
        }
        let services = [MainService(version: version)] + services
        self.services = services

        let handlerAdapter = XPCHelperHandler(listener: listener)
        for service in services {
            await service.setupHandler(handlerAdapter)
        }

        listener.errorHandler = { connection, error in
            #log(.error, "Listener error: \(String(describing: error), privacy: .public)")
        }
    }

    public func connectToTool(machServiceName: String, isPrivilegedHelperTool: Bool) async throws {
        guard case .plain(_, let identifier) = serverType else {
            return
        }
        let connection = try SwiftyXPC.XPCConnection(type: .remoteMachService(serviceName: machServiceName, isPrivilegedHelperTool: isPrivilegedHelperTool))
        connection.activate()
        try await connection.pingHelperTool()
        connection.errorHandler = { connection, error in
            #log(.error, "Tool connection error: \(String(describing: error), privacy: .public)")
        }
        toolConnection = connection
        try await connection.registerEndpoint(listener.endpoint, machServiceName: machServiceName, identifier: identifier)
    }

    public func activate() async {
        listener.activate()
    }

    /// Suspends the current Task forever, keeping the process alive for the
    /// daemon's lifetime. `RunLoop.main.run()` is unsafe inside a Swift
    /// Concurrency context, so the daemon's "block main" step is expressed
    /// here as an awaited continuation that is never resumed — teardown
    /// happens via an explicit `SMAppService.unregister()` from the host
    /// (or a kill signal), never by returning from this call.
    ///
    /// Call `activate()` (or use `activateAndRun()`) before this; `run()`
    /// alone does not activate the listener.
    public func run() async {
        await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in
            // Intentionally never resumed.
        }
    }

    /// Convenience for the common daemon entry point: `activate()` followed by
    /// `run()`. Use this when the surrounding code has no other lifecycle to
    /// drive — e.g. the privileged tool's `main.swift`.
    public func activateAndRun() async {
        await activate()
        await run()
    }
}
#endif
