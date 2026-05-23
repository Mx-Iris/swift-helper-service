#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import Foundation
import HelperCommunication
@preconcurrency package import SwiftyXPC

/// Opaque, lib-internal adapter that exposes a `SwiftyXPC.XPCListener` through the
/// public `HelperHandler` protocol. The wrapper is `public` so the
/// `HelperHandler` conformance is reachable by external `HelperService`
/// implementations, but its storage and initializer are `package` so callers
/// cannot construct or unwrap it — keeping the `SwiftyXPC.XPCListener` type
/// from leaking through the lib's public surface.
public struct XPCHelperHandler: HelperHandler, @unchecked Sendable {
    package let listener: SwiftyXPC.XPCListener

    package init(listener: SwiftyXPC.XPCListener) {
        self.listener = listener
    }

    public func setMessageHandler<Request: HelperCommunication.Request & Sendable>(handler: @Sendable @escaping (Request) async throws -> Request.Response) {
        listener.setMessageHandler(requestType: Request.self) { _, request in
            try await handler(request)
        }
    }

    public func activate() async {
        listener.activate()
    }
}
#endif
