#if os(macOS) || targetEnvironment(macCatalyst)
import HelperCommunication

public protocol HelperService: Sendable {
    func setupHandler(_ handler: some HelperHandler) async
}

public protocol HelperHandler: Sendable {
    func setMessageHandler<Request: HelperCommunication.Request & Sendable>(handler: @Sendable @escaping (Request) async throws -> Request.Response)
    func activate() async
}

public enum HelperServerType: Sendable {
    /// A non-privileged server listening on an anonymous endpoint, published to the tool's
    /// registry under `identifier`.
    ///
    /// The registry key's `name` half comes from the `machServiceName` passed to
    /// `HelperServer.connectToTool(machServiceName:isPrivilegedHelperTool:)`, not from here —
    /// which is why this case carries only the identifier.
    case plain(identifier: String)

    case machService(name: String)
}

extension HelperServerType {
    /// - Warning: Deprecated. `name` was never read: `HelperServer` destructured this case as
    ///   `case .plain(_, let identifier)`, and the registry key's `name` has always come from
    ///   `connectToTool(machServiceName:)`. Passing one here changed nothing.
    @available(*, deprecated, message: "The name was never read; use .plain(identifier:) instead")
    public static func plain(name: String, identifier: String) -> HelperServerType {
        .plain(identifier: identifier)
    }
}
#endif
