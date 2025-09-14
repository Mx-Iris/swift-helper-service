import Foundation
import HelperService
import HelperCommunication
import FilesServiceInterface

public actor FilesService: HelperService {
    public init() {}
    public func setupHandler(_ handler: some HelperHandler) async {
        handler.setMessageHandler { (request: FileOperationRequest) -> FileOperationRequest.Response in
            let fileManager = FileManager.default
            switch request.operation {
            case let .createDirectory(url, isIntermediateDirectories):
                try fileManager.createDirectory(at: url, withIntermediateDirectories: isIntermediateDirectories)
            case let .remove(url: url):
                try fileManager.removeItem(at: url)
            case let .move(from: from, to: to):
                try fileManager.moveItem(at: from, to: to)
            case let .copy(from: from, to: to):
                if fileManager.fileExists(atPath: to.path) {
                    try fileManager.removeItem(at: to)
                }
                try fileManager.copyItem(at: from, to: to)
            case let .write(url: url, data: data):
                try data.write(to: url)
            }
            return .empty
        }
    }

    public func run() async throws {}
}
