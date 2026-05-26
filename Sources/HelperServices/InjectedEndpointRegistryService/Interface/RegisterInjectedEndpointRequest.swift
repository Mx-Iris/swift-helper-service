#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
import HelperCommunication

/// Registers an injected app's XPC endpoint with the helper tool.
///
/// Sent by the injected app after its initial XPC connection succeeds.
/// The registry starts monitoring the PID and auto-removes the endpoint on process exit.
public struct RegisterInjectedEndpointRequest: Codable, Request {
    public typealias Response = VoidResponse

    public static let identifier: String = "com.JH.HelperService.InjectedEndpointRegistryService.RegisterInjectedEndpoint"

    public let pid: pid_t
    public let appName: String
    public let bundleIdentifier: String
    public let endpoint: HelperPeerEndpoint

    public init(pid: pid_t, appName: String, bundleIdentifier: String, endpoint: HelperPeerEndpoint) {
        self.pid = pid
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.endpoint = endpoint
    }
}

#endif
