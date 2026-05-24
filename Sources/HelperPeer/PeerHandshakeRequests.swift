#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
import HelperCommunication

/// Sent by `HelperPeerServer` to `HelperPeerClient` after the server fetches the
/// client's endpoint from the broker and opens a direct reverse connection. Lets the
/// client store the server's listener endpoint for later RPC.
package struct ServerLaunchedNotification: Codable, HelperCommunication.Request {
    package static let identifier: String = "com.JH.HelperPeer.ServerLaunched"
    package typealias Response = HelperCommunication.VoidResponse

    package let endpoint: HelperPeerEndpoint

    package init(endpoint: HelperPeerEndpoint) {
        self.endpoint = endpoint
    }
}

/// Sent by a reconnecting `HelperPeerClient` (constructed with a known
/// `serverEndpoint`) to inform the existing `HelperPeerServer` to replace its peer
/// connection with one backed by the new client's listener endpoint.
package struct ClientReconnectedNotification: Codable, HelperCommunication.Request {
    package static let identifier: String = "com.JH.HelperPeer.ClientReconnected"
    package typealias Response = HelperCommunication.VoidResponse

    package let endpoint: HelperPeerEndpoint

    package init(endpoint: HelperPeerEndpoint) {
        self.endpoint = endpoint
    }
}
#endif
