#if os(macOS)
import Foundation
import HelperCommunication
import HelperService
import InjectedEndpointRegistryServiceInterface

/// Stores XPC endpoints of injected (non-sandboxed) apps keyed by PID, with PID-monitor
/// auto-cleanup so the host can reconnect to live processes after restart without
/// stale entries.
public actor InjectedEndpointRegistryService: HelperService {
    public enum Error: Swift.Error {
        case deallocated
    }

    private var injectedEndpointsByPID: [pid_t: InjectedEndpointInfo] = [:]

    private var processMonitorSources: [pid_t: any DispatchSourceProcess] = [:]

    public init() {}

    public func setupHandler(_ handler: some HelperHandler) async {
        handler.setMessageHandler { [weak self] (request: RegisterInjectedEndpointRequest) -> RegisterInjectedEndpointRequest.Response in
            guard let self else { throw Error.deallocated }
            return try await self.registerInjectedEndpoint(request: request)
        }
        handler.setMessageHandler { [weak self] (request: FetchAllInjectedEndpointsRequest) -> FetchAllInjectedEndpointsRequest.Response in
            guard let self else { throw Error.deallocated }
            return try await self.fetchAllInjectedEndpoints(request: request)
        }
        handler.setMessageHandler { [weak self] (request: RemoveInjectedEndpointRequest) -> RemoveInjectedEndpointRequest.Response in
            guard let self else { throw Error.deallocated }
            return try await self.removeInjectedEndpoint(request: request)
        }
    }

    public func run() async throws {}

    private func registerInjectedEndpoint(request: RegisterInjectedEndpointRequest) async throws -> RegisterInjectedEndpointRequest.Response {
        let info = InjectedEndpointInfo(
            pid: request.pid,
            appName: request.appName,
            bundleIdentifier: request.bundleIdentifier,
            endpoint: request.endpoint
        )
        injectedEndpointsByPID[request.pid] = info
        startMonitoringProcess(pid: request.pid)
        return .empty
    }

    private func fetchAllInjectedEndpoints(request: FetchAllInjectedEndpointsRequest) async throws -> FetchAllInjectedEndpointsRequest.Response {
        let endpoints = Array(injectedEndpointsByPID.values)
        return .init(endpoints: endpoints)
    }

    private func removeInjectedEndpoint(request: RemoveInjectedEndpointRequest) async throws -> RemoveInjectedEndpointRequest.Response {
        removeInjectedEndpointEntry(pid: request.pid)
        return .empty
    }

    private func startMonitoringProcess(pid: pid_t) {
        processMonitorSources[pid]?.cancel()
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.handleMonitoredProcessExit(pid: pid) }
        }
        processMonitorSources[pid] = source
        source.resume()
    }

    private func handleMonitoredProcessExit(pid: pid_t) {
        removeInjectedEndpointEntry(pid: pid)
    }

    private func removeInjectedEndpointEntry(pid: pid_t) {
        injectedEndpointsByPID.removeValue(forKey: pid)
        processMonitorSources[pid]?.cancel()
        processMonitorSources.removeValue(forKey: pid)
    }
}

#endif
