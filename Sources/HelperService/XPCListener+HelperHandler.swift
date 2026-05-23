#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import Foundation
import HelperCommunication
@preconcurrency public import SwiftyXPC

extension SwiftyXPC.XPCListener: @retroactive @unchecked Sendable {}

extension SwiftyXPC.XPCListener: HelperHandler {
    public func setMessageHandler<Request: HelperCommunication.Request & Sendable>(handler: @Sendable @escaping (Request) async throws -> Request.Response) {
        setMessageHandler { connection, request in
            try await handler(request)
        }
    }
}
#endif
