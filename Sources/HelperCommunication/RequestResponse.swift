import Foundation
import OSLog

public protocol Request<Response>: Codable, Sendable {
    associatedtype Response: Codable & Sendable

    static var identifier: String { get }
}

public struct VoidResponse: Codable, Sendable {
    public init() {}

    public static let empty: VoidResponse = .init()
}
