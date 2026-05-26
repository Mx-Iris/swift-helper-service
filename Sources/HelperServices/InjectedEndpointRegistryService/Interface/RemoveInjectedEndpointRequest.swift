#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
import HelperCommunication

/// Removes an injected app's endpoint from the helper tool.
///
/// Sent by the host app when a reconnection attempt fails, indicating
/// the injected process has likely exited (backup for PID monitoring).
public struct RemoveInjectedEndpointRequest: Codable, Request {
    public typealias Response = VoidResponse

    public static let identifier: String = "com.JH.HelperService.InjectedEndpointRegistryService.RemoveInjectedEndpoint"

    public let pid: pid_t

    public init(pid: pid_t) {
        self.pid = pid
    }
}

#endif
