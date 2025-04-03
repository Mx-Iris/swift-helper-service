#if os(macOS)
import Foundation
import SwiftyXPC

public struct RegisterEndpointRequest: Codable, Request {
    public static let identifier: String = "com.JH.HelperCommunication.RegisterEndpoint"

    public typealias Response = VoidResponse

    public let identifier: String

    public let endpoint: XPCEndpoint

    public init(identifier: String, endpoint: XPCEndpoint) {
        self.identifier = identifier
        self.endpoint = endpoint
    }
}
#endif
