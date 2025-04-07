import AppKit
import HelperService
import HelperCommunication
@preconcurrency private import SwiftyXPC
import OSLog
internal import MainService

extension SwiftyXPC.XPCListener: @retroactive @unchecked Sendable {}
extension SwiftyXPC.XPCListener: HelperHandler {
    func setMessageHandler<Request>(handler: @escaping (Request) async throws -> Request.Response) where Request: HelperCommunication.Request {
        setMessageHandler { connection, request in
            try await handler(request)
        }
    }
}

public final class HelperServer {
    private let serverType: HelperServerType

    private let listener: SwiftyXPC.XPCListener

    private let services: [HelperService]

    private var toolConnection: SwiftyXPC.XPCConnection?

    private static let logger = Logger(subsystem: Bundle(for: HelperServer.self).bundleIdentifier ?? "com.JH.HelperServer", category: "\(HelperServer.self)")

    public init(serverType: HelperServerType, services: [HelperService]) async throws {
        self.serverType = serverType
        switch serverType {
        case .plain:
            self.listener = try SwiftyXPC.XPCListener(type: .anonymous, codeSigningRequirement: nil)
        case let .machService(name):
            self.listener = try SwiftyXPC.XPCListener(type: .machService(name: name), codeSigningRequirement: nil)
        }
        let services = [MainService()] + services
        self.services = services
        
        for service in services {
            await service.setupHandler(listener)
        }

        listener.errorHandler = { connection, error in
            Self.logger.error("Listener error: \(error)")
        }
    }

    public func connectToTool(machServiceName: String, isPrivilegedHelperTool: Bool) async throws {
        guard case let .plain(_, identifier) = serverType else {
            return
        }
        let connection = try SwiftyXPC.XPCConnection(type: .remoteMachService(serviceName: machServiceName, isPrivilegedHelperTool: isPrivilegedHelperTool))
        connection.activate()
        try await connection.sendMessage(request: PingRequest())
        connection.errorHandler = { connection, error in
            Self.logger.error("\(error)")
        }
        toolConnection = connection
        try await connection.sendMessage(request: PingRequest())
        try await connection.sendMessage(request: RegisterEndpointRequest(info: .init(name: machServiceName, identifier: identifier), endpoint: listener.endpoint))
    }

    public func activate() async {
        listener.activate()
    }
}
