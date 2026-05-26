#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
import HelperCommunication

/// Metadata for an injected app's registered XPC endpoint.
///
/// Stored by the registry service inside the privileged helper tool and returned to
/// the host app for reconnecting to already-injected processes after restart.
public struct InjectedEndpointInfo: Codable, Sendable {
    /// The process identifier of the injected app.
    public let pid: pid_t

    /// The display name of the injected app.
    public let appName: String

    /// The bundle identifier of the injected app.
    public let bundleIdentifier: String

    /// The XPC listener endpoint of the injected app's runtime engine server.
    public let endpoint: HelperPeerEndpoint

    public init(pid: pid_t, appName: String, bundleIdentifier: String, endpoint: HelperPeerEndpoint) {
        self.pid = pid
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.endpoint = endpoint
    }
}

#endif
