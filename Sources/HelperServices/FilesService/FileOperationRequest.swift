#if os(macOS)
import Foundation
import HelperCommunication

public enum FileOperation: Codable, Sendable {
    case createDirectory(url: URL, isIntermediateDirectories: Bool)
    case remove(url: URL)
    case move(from: URL, to: URL)
    case copy(from: URL, to: URL)
    case write(url: URL, data: Data)
}

public struct FileOperationRequest: Codable, Request {
    public typealias Response = VoidResponse

    public static let identifier = "com.JH.HelperService.FilesService.FileOperationRequest"

    public let operation: FileOperation

    public init(operation: FileOperation) {
        self.operation = operation
    }
}

#endif
