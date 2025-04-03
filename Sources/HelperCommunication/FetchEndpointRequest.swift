#if os(macOS)
import Foundation
import SwiftyXPC

public struct FetchEndpointRequest: Codable, Request {
    public typealias Response = FetchEndpointResponse

    public static let identifier: String = "com.JH.HelperCommunication.FetchEndpoint"

    public let identifier: String

    public init(identifier: String) {
        self.identifier = identifier
    }
}

public struct FetchEndpointResponse: Response, Codable {
    public let endpoint: XPCEndpoint

    public init(endpoint: XPCEndpoint) {
        self.endpoint = endpoint
    }
}
#endif
