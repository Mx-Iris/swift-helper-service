#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
// `public` because the `InjectionPeer` SPI members below extend SwiftyXPC's types; SPI
// declarations are public ones and cannot carry package types.
@preconcurrency public import SwiftyXPC

extension SwiftyXPC.XPCConnection {
    @discardableResult
    @_spi(InjectionPeer) public func sendMessage<Request: HelperCommunication.Request & Sendable>(request: Request) async throws -> Request.Response {
        try await sendMessage(name: type(of: request).identifier, request: request)
    }
}

extension SwiftyXPC.XPCListener {
    /// The one baseline every typed handler goes through — `XPCHelperHandler` in this library, and
    /// swift-injection-peer's `HelperPeer*` typed `setMessageHandler` plus its peer handshake
    /// handlers. That is why failures only have to be wrapped for transport in this one place to
    /// cover every `HelperService`, including ones written outside this package.
    ///
    /// Exposed through the `InjectionPeer` SPI because the peer channel now lives in another
    /// package and must keep landing here — if it stopped, its failures would silently lose the
    /// transport wrapping and arrive as bare `BoxedError`s.
    @_spi(InjectionPeer) public func setMessageHandler<Request: HelperCommunication.Request & Sendable>(requestType: Request.Type = Request.self, handler: @escaping (XPCConnection, Request) async throws -> Request.Response) {
        setMessageHandler(name: requestType.identifier) { (connection: XPCConnection, request: Request) -> Request.Response in
            try await ServiceFailureTransport.wrappingFailures(requestIdentifier: requestType.identifier) {
                try await handler(connection, request)
            }
        }
    }
}

#endif
