import Foundation
@preconcurrency internal import SwiftyXPC

package final class HelperTool {
    private var connection: SwiftyXPC.XPCConnection?

    private let machServiceName: String
    
    private let isPrivilegedHelperTool: Bool

    package init(machServiceName: String, isPrivilegedHelperTool: Bool) async throws {
        self.machServiceName = machServiceName
        self.isPrivilegedHelperTool = isPrivilegedHelperTool
    }

    package func connect() async throws {
        let connection = try SwiftyXPC.XPCConnection(type: .remoteMachService(serviceName: machServiceName, isPrivilegedHelperTool: isPrivilegedHelperTool))
        connection.activate()
        try await connection.sendMessage(request: PingRequest())
        connection.errorHandler = { connection, error in
            print(error)
        }
        self.connection = connection
    }
}
