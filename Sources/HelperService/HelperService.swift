import HelperCommunication

public protocol HelperService: Sendable {
    func setupHandler(_ handler: HelperHandler)
    func run() async throws
}

public protocol HelperHandler: Sendable {
    func setMessageHandler<Request: HelperCommunication.Request>(handler: @escaping (Request) async throws -> Request.Response)
    func activate()
}

public enum HelperServerType {
    case plain(name: String, identifier: String)
    case machService(name: String)
}
