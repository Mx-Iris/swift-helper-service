#if os(macOS)
import Foundation
import HelperCommunication

public struct InjectApplicationRequest: Codable, Request {
    public typealias Response = VoidResponse

    public static let identifier: String = "com.JH.HelperCommunication.InjectApplication"

    public let pid: pid_t

    public let dylibURL: URL

    public init(pid: pid_t, dylibURL: URL) {
        self.pid = pid
        self.dylibURL = dylibURL
    }
}

#endif
