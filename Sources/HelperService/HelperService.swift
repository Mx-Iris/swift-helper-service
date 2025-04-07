import HelperCommunication

public protocol HelperService: Sendable {
    func setupHandler(_ handler: HelperHandler) async
    func run() async throws
}

public protocol HelperHandler: Sendable {
    func setMessageHandler<Request: HelperCommunication.Request>(handler: @escaping (Request) async throws -> Request.Response)
    func activate() async
}

public enum HelperServerType {
    case plain(name: String, identifier: String)
    case machService(name: String)
}
