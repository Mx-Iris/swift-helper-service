import Foundation
import OSLog

public protocol Request<Response>: Codable {
    associatedtype Response: Codable

    static var identifier: String { get }
}

public struct VoidResponse: Codable {
    public init() {}

    public static let empty: VoidResponse = .init()
}
