#if os(macOS)
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

    package init(info: HelperServerInfo, endpoint: SwiftyXPC.XPCEndpoint) {
        self.info = info
        self.endpoint = endpoint
    }
}

#endif
