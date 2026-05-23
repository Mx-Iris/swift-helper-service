import AppKit
import HelperService
import HelperCommunication
@preconcurrency private import SwiftyXPC
import OSLog
internal import MainService

public actor HelperServer {
    private let serverType: HelperServerType

    private let listener: SwiftyXPC.XPCListener

    private let services: [HelperService]

    private var toolConnection: SwiftyXPC.XPCConnection?

    private static let logger = Logger(subsystem: Bundle(for: HelperServer.self).bundleIdentifier ?? "com.JH.HelperServer", category: "\(HelperServer.self)")

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

        for service in services {
            await service.setupHandler(listener)
        }

        listener.errorHandler = { connection, error in
            Self.logger.error("Listener error: \(error)")
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
            Self.logger.error("\(error)")
        }
        toolConnection = connection
        try await connection.registerEndpoint(listener.endpoint, machServiceName: machServiceName, identifier: identifier)
    }

    public func activate() async {
        listener.activate()
    }
}
