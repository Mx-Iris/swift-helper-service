#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
// `public` because the `InjectionPeer` SPI members below extend `XPCConnection` and mention
// `XPCEndpoint`; SPI declarations are public ones and cannot carry package types.
@preconcurrency public import SwiftyXPC

extension SwiftyXPC.XPCConnection {
    /// Sends a `PingRequest` to verify that the tool is reachable.
    @_spi(InjectionPeer) public func pingHelperTool() async throws {
        try await sendMessage(request: PingRequest())
    }

    /// Registers an `XPCEndpoint` with the tool's `MainService` endpoint registry, keyed by `(machServiceName, identifier)`.
    ///
    /// The caller's pid rides along so the registry can evict the entry when this process exits;
    /// callers do not supply it, because a registrant reporting anything other than its own pid
    /// would only ever be wrong.
    @_spi(InjectionPeer) public func registerEndpoint(_ endpoint: SwiftyXPC.XPCEndpoint, machServiceName: String, identifier: String) async throws {
        let info = HelperServerInfo(name: machServiceName, identifier: identifier)
        try await sendMessage(
            request: RegisterEndpointRequest(
                info: info,
                endpoint: endpoint,
                registrantProcessIdentifier: getpid()
            )
        )
    }

    /// Fetches a previously registered `XPCEndpoint` from the tool's `MainService` endpoint registry.
    @_spi(InjectionPeer) public func fetchEndpoint(machServiceName: String, identifier: String) async throws -> SwiftyXPC.XPCEndpoint {
        let info = HelperServerInfo(name: machServiceName, identifier: identifier)
        return try await sendMessage(request: FetchEndpointRequest(info: info)).endpoint
    }

    /// Lists all `HelperServerInfo` entries currently registered with the tool.
    package func listHelperServerInfos() async throws -> [HelperServerInfo] {
        try await sendMessage(request: ListServerInfosRequest()).infos
    }
}

#endif
