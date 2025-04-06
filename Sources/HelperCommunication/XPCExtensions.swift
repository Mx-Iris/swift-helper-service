#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import Foundation
@preconcurrency package import SwiftyXPC

extension SwiftyXPC.XPCConnection {
    @discardableResult
    package func sendMessage<Request: HelperCommunication.Request>(request: Request) async throws -> Request.Response {
        try await sendMessage(name: type(of: request).identifier, request: request)
    }
}

extension SwiftyXPC.XPCListener {
    package func setMessageHandler<Request: HelperCommunication.Request>(requestType: Request.Type = Request.self, handler: @escaping (XPCConnection, Request) async throws -> Request.Response) {
        setMessageHandler(name: requestType.identifier) { (connection: XPCConnection, request: Request) -> Request.Response in
            try await handler(connection, request)
        }
    }
}

#endif
