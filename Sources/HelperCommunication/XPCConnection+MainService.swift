#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import Foundation
@preconcurrency public import SwiftyXPC

extension SwiftyXPC.XPCConnection {
    /// Sends a `PingRequest` to verify that the tool is reachable.
    public func pingHelperTool() async throws {
        try await sendMessage(request: PingRequest())
    }

    /// Registers an `XPCEndpoint` with the tool's `MainService` endpoint registry, keyed by `(machServiceName, identifier)`.
    public func registerEndpoint(_ endpoint: SwiftyXPC.XPCEndpoint, machServiceName: String, identifier: String) async throws {
        let info = HelperServerInfo(name: machServiceName, identifier: identifier)
        try await sendMessage(request: RegisterEndpointRequest(info: info, endpoint: endpoint))
    }

    /// Fetches a previously registered `XPCEndpoint` from the tool's `MainService` endpoint registry.
    public func fetchEndpoint(machServiceName: String, identifier: String) async throws -> SwiftyXPC.XPCEndpoint {
        let info = HelperServerInfo(name: machServiceName, identifier: identifier)
        return try await sendMessage(request: FetchEndpointRequest(info: info)).endpoint
    }

    /// Lists all `HelperServerInfo` entries currently registered with the tool.
    public func listHelperServerInfos() async throws -> [HelperServerInfo] {
        try await sendMessage(request: ListServerInfosRequest()).infos
    }
}

#endif
