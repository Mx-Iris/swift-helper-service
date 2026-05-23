#if os(macOS)
import Foundation

public struct FetchVersionRequest: Codable, Request {
    public static let identifier: String = "com.JH.HelperCommunication.FetchVersion"

    public struct Response: Codable, Sendable {
        public let version: String

        public init(version: String) {
            self.version = version
        }
    }

    public init() {}
}
#endif
