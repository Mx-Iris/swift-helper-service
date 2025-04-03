#if os(macOS)
import Foundation

public struct PingRequest: Codable, Request {
    public typealias Response = VoidResponse

    public static let identifier: String = "com.JH.HelperCommunication.Ping"

    public init() {}
}
#endif
