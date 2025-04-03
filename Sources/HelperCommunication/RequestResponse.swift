import Foundation
import OSLog

public protocol Request: Codable {
    associatedtype Response: HelperCommunication.Response

    static var identifier: String { get }
}

public protocol Response: Codable {}

public struct VoidResponse: Response, Codable {
    public init() {}

    public static let empty: VoidResponse = .init()
}
