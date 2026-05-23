#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import Foundation
import HelperCommunication
@preconcurrency import SwiftyXPC

/// Sent by `BrokeredPeerServer` to `BrokeredPeerClient` after the server fetches the
/// client's endpoint from the broker and opens a direct reverse connection. Lets the
/// client store the server's listener endpoint for later RPC.
package struct ServerLaunchedNotification: Codable, HelperCommunication.Request {
    package static let identifier: String = "com.JH.HelperPeer.ServerLaunched"
    package typealias Response = HelperCommunication.VoidResponse

    package let endpoint: SwiftyXPC.XPCEndpoint

    package init(endpoint: SwiftyXPC.XPCEndpoint) {
        self.endpoint = endpoint
    }
}

/// Sent by a reconnecting `BrokeredPeerClient` (constructed with a known
/// `serverEndpoint`) to inform the existing `BrokeredPeerServer` to replace its peer
/// connection with one backed by the new client's listener endpoint.
package struct ClientReconnectedNotification: Codable, HelperCommunication.Request {
    package static let identifier: String = "com.JH.HelperPeer.ClientReconnected"
    package typealias Response = HelperCommunication.VoidResponse

    package let endpoint: SwiftyXPC.XPCEndpoint

    package init(endpoint: SwiftyXPC.XPCEndpoint) {
        self.endpoint = endpoint
    }
}
#endif
