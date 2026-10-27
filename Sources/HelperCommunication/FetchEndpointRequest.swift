#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
@preconcurrency package import SwiftyXPC

public struct HelperServerInfo: Hashable, Codable, Sendable {
    public let name: String

    public let identifier: String

    package init(name: String, identifier: String) {
        self.name = name
        self.identifier = identifier
    }
}

package struct FetchEndpointRequest: Codable, Request {
    package static let identifier: String = "com.JH.HelperCommunication.FetchEndpoint"

    package struct Response: Codable {
        package let endpoint: SwiftyXPC.XPCEndpoint

        package init(endpoint: SwiftyXPC.XPCEndpoint) {
            self.endpoint = endpoint
        }
    }

    package let info: HelperServerInfo

    package init(info: HelperServerInfo) {
        self.info = info
    }
}

package struct ListServerInfosRequest: Codable, Request {
    package struct Response: Codable {
        package let infos: [HelperServerInfo]

        package init(infos: [HelperServerInfo]) {
            self.infos = infos
        }
    }

    package static let identifier: String = "com.JH.HelperCommunication.ListEndpoints"

    package init() {}
}

package struct RegisterEndpointRequest: Codable, Request {
    package static let identifier: String = "com.JH.HelperCommunication.RegisterEndpoint"

    package typealias Response = VoidResponse

    package let info: HelperServerInfo

    package let endpoint: SwiftyXPC.XPCEndpoint

    /// The registrant's own pid, so the registry can drop the entry when that process exits.
    ///
    /// Optional because it is additive: a peer built before this field existed sends a message
    /// without it, which decodes to `nil` and leaves the registry with its original
    /// grows-only behaviour for that entry rather than failing the registration outright.
    package let registrantProcessIdentifier: pid_t?

    package init(info: HelperServerInfo, endpoint: SwiftyXPC.XPCEndpoint, registrantProcessIdentifier: pid_t?) {
        self.info = info
        self.endpoint = endpoint
        self.registrantProcessIdentifier = registrantProcessIdentifier
    }
}

#endif
