#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
import HelperCommunication
public import HelperService

/// Lets a `HelperService` mount itself on a socket link, the same way `XPCHelperHandler` lets
/// it mount on an XPC listener.
///
/// Without this, a service written once would work on unsandboxed targets and quietly do
/// nothing on sandboxed ones — the sort of difference that only shows up on the one machine
/// where the target happens to be sandboxed.
struct PeerSocketHelperHandler: HelperHandler {
    let channel: PeerSocketChannel

    func setMessageHandler<Request: HelperCommunication.Request & Sendable>(
        handler: @Sendable @escaping (Request) async throws -> Request.Response
    ) {
        channel.setMessageHandler(Request.self, handler: handler)
    }

    /// No-op by design. `PeerSocketChannel` has its own two-phase lifecycle and the link's owner
    /// activates it once, after every service has mounted; a service activating the channel
    /// out from under the others would start the wire mid-installation.
    func activate() async {}
}

extension PeerSocketChannel {
    /// Mounts each service's handlers on this channel. Call before ``activate()``.
    func install(_ services: [HelperService]) async {
        guard !services.isEmpty else { return }
        let handler = PeerSocketHelperHandler(channel: self)
        for service in services {
            await service.setupHandler(handler)
        }
    }
}
#endif
