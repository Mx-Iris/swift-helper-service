import AppKit
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
}
