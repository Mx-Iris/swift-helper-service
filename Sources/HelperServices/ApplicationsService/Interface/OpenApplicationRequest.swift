#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
import HelperCommunication

public struct OpenApplicationRequest: Codable, Request {
    public typealias Response = VoidResponse

    public static let identifier: String = "com.JH.HelperService.ApplicationsService.OpenApplication"

    public let url: URL

    public let callerPID: Int32

    public init(url: URL, callerPID: Int32) {
        self.url = url
        self.callerPID = callerPID
    }
}

#endif
