#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
// SPI-qualified because `XPCListener.setMessageHandler(requestType:handler:)` moved from
// `package` to the `InjectionPeer` SPI. These members were freely visible across this package's
// modules while they were `package`; an SPI member is not, even to its own package.
@_spi(InjectionPeer) import HelperCommunication
// `public` because the initializer below is exposed through the `InjectionPeer` SPI, and an SPI
// declaration is a public one — it cannot take a package type.
@preconcurrency public import SwiftyXPC

/// Opaque, lib-internal adapter that exposes a `SwiftyXPC.XPCListener` through the
/// public `HelperHandler` protocol. The wrapper is `public` so the
/// `HelperHandler` conformance is reachable by external `HelperService`
/// implementations, while its storage stays `package` and its initializer is reachable only
/// through the `InjectionPeer` SPI — so ordinary callers still cannot construct or unwrap it, and
/// the `SwiftyXPC.XPCListener` type does not leak through the lib's public surface.
///
/// The initializer opened up when the peer channel moved to swift-injection-peer: a peer server
/// owns its own anonymous listener and has to wrap it to mount services on it.
public struct XPCHelperHandler: HelperHandler, @unchecked Sendable {
    package let listener: SwiftyXPC.XPCListener

    @_spi(InjectionPeer) public init(listener: SwiftyXPC.XPCListener) {
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
