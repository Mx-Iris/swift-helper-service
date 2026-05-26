#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
import HelperCommunication

/// Fetches all currently registered injected app endpoints from the helper tool.
///
/// Sent by the host app on startup to discover already-injected processes for reconnection.
public struct FetchAllInjectedEndpointsRequest: Codable, Request {
    public static let identifier: String = "com.JH.HelperService.InjectedEndpointRegistryService.FetchAllInjectedEndpoints"

    public struct Response: Codable, Sendable {
        public let endpoints: [InjectedEndpointInfo]

        public init(endpoints: [InjectedEndpointInfo]) {
            self.endpoints = endpoints
        }
    }

    public init() {}
}

#endif
