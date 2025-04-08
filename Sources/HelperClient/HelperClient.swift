import Foundation
import HelperCommunication
import ServiceManagement
@preconcurrency private import SwiftyXPC

public actor HelperClient {
    public enum Error: LocalizedError {
        case message(String)
        case invalidConnection
        public var errorDescription: String? {
            switch self {
            case let .message(message):
                return message
            case .invalidConnection:
                return "Invalid connection"
            }
        }
    }

    private var toolConnection: SwiftyXPC.XPCConnection?

    private var serverConnectionByInfo: [HelperServerInfo: SwiftyXPC.XPCConnection] = [:]

    public init() {}

    public var isConnectedToTool: Bool {
        get async {
            do {
                guard let toolConnection else { return false }
                try await toolConnection.sendMessage(request: PingRequest())
                return true
            } catch {
                print(error)
                return false
            }
        }
    }

    public func availableServerInfos() async throws -> [HelperServerInfo] {
        guard let toolConnection else { throw Error.invalidConnection }
        return try await toolConnection.sendMessage(request: ListServerInfosRequest()).infos
    }

    public func connectToServer(info: HelperServerInfo) async throws {
        guard let toolConnection else { throw Error.invalidConnection }
        let endpoint = try await toolConnection.sendMessage(request: FetchEndpointRequest(info: info)).endpoint
        let connection = try XPCConnection(type: .remoteServiceFromEndpoint(endpoint))
        connection.errorHandler = { connection, error in
            print(error)
        }
        connection.activate()
        serverConnectionByInfo[info] = connection
        try await connection.sendMessage(request: PingRequest())
    }

    public func connectToTool(machServiceName: String, isPrivilegedHelperTool: Bool) async throws {
        let connection = try SwiftyXPC.XPCConnection(type: .remoteMachService(serviceName: machServiceName, isPrivilegedHelperTool: isPrivilegedHelperTool))
        connection.activate()
        try await connection.sendMessage(request: PingRequest())
        connection.errorHandler = { connection, error in
            print(error)
        }

        toolConnection = connection
    }

    @discardableResult
    public func sendToTool<Request: HelperCommunication.Request>(request: Request) async throws -> Request.Response {
        guard let toolConnection else { throw Error.invalidConnection }
        return try await toolConnection.sendMessage(request: request)
    }

    @discardableResult
    public func sendToServer<Request: HelperCommunication.Request>(request: Request, for info: HelperServerInfo) async throws -> Request.Response {
        guard let serverConnection = serverConnectionByInfo[info] else { throw Error.invalidConnection }
        return try await serverConnection.sendMessage(request: request)
    }

    public func installTool(name: String) async throws {
//        guard await !isConnectedToTool else { throw Error.message("Helper already installed") }
        func executeAuthorizationFunction(_ authorizationFunction: () -> (OSStatus)) throws {
            let osStatus = authorizationFunction()
            guard osStatus == errAuthorizationSuccess else {
                throw Error.message(String(describing: SecCopyErrorMessageString(osStatus, nil)))
            }
        }

        func authorizationRef(
            _ rights: UnsafePointer<AuthorizationRights>?,
            _ environment: UnsafePointer<AuthorizationEnvironment>?,
            _ flags: AuthorizationFlags
        ) throws -> AuthorizationRef? {
            var authRef: AuthorizationRef?
            try executeAuthorizationFunction { AuthorizationCreate(rights, environment, flags, &authRef) }
            return authRef
        }
        var cfError: Unmanaged<CFError>?

        var authItem: AuthorizationItem = kSMRightBlessPrivilegedHelper.withCString {
            AuthorizationItem(name: $0, valueLength: 0, value: UnsafeMutableRawPointer(bitPattern: 0), flags: 0)
        }

        var authRights = AuthorizationRights(count: 1, items: withUnsafeMutablePointer(to: &authItem) { $0 })

        let authRef = try authorizationRef(&authRights, nil, [.interactionAllowed, .extendRights, .preAuthorize])
        SMJobBless(kSMDomainSystemLaunchd, name as CFString, authRef, &cfError)
        if let error = cfError?.takeRetainedValue() {
            throw error
        }
    }
}
