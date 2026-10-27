#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
import HelperService
import HelperCommunication
@preconcurrency private import SwiftyXPC

package actor MainService: HelperService {
    private var endpointByInfo: [HelperServerInfo: SwiftyXPC.XPCEndpoint] = [:]

    /// Which registrations belong to which process, so they can all be dropped when it exits.
    /// A registrant that did not report a pid is absent here and keeps the original
    /// grows-only behaviour.
    private var registeredInfosByProcessIdentifier: [pid_t: Set<HelperServerInfo>] = [:]

    private var processMonitorSources: [pid_t: any DispatchSourceProcess] = [:]

    /// Exit events land here rather than on `.main`. The handler only kicks off a `Task` into
    /// this actor, so it needs no particular queue — and depending on the main queue would make
    /// the registry's cleanup unobservable anywhere that queue is not being serviced, which
    /// includes a test process.
    private let processMonitorQueue = DispatchQueue(label: "com.JH.HelperCommunication.MainService.ProcessMonitor")

    private let version: String

    public enum Error: LocalizedError {
        case selfDidDealloc
        case notFound
    }

    private func ping(request: PingRequest) async throws -> PingRequest.Response {
        return .empty
    }

    package func fetchEndpoint(request: FetchEndpointRequest) async throws -> FetchEndpointRequest.Response {
        guard let endpoint = endpointByInfo[request.info] else {
            throw Error.notFound
        }
        return .init(endpoint: endpoint)
    }

    package func listEndpoints(request: ListServerInfosRequest) async throws -> ListServerInfosRequest.Response {
        return .init(infos: endpointByInfo.map { $0.key })
    }

    package func registerEndpoint(request: RegisterEndpointRequest) async throws -> RegisterEndpointRequest.Response {
        endpointByInfo[request.info] = request.endpoint
        bindRegistration(info: request.info, to: request.registrantProcessIdentifier)
        return .empty
    }

    /// Puts `info` under `processIdentifier`'s exit monitor, first detaching it from whichever
    /// process had registered it before.
    ///
    /// The detach matters when a sub-server crashes and comes back: it re-registers the same
    /// identifier from a new pid, and without this the dead process's exit handler would later
    /// evict the live registration that replaced it.
    private func bindRegistration(info: HelperServerInfo, to processIdentifier: pid_t?) {
        let previousOwners = registeredInfosByProcessIdentifier
            .filter { $0.value.contains(info) }
            .map(\.key)
        for previousOwner in previousOwners where previousOwner != processIdentifier {
            registeredInfosByProcessIdentifier[previousOwner]?.remove(info)
            if registeredInfosByProcessIdentifier[previousOwner]?.isEmpty ?? false {
                registeredInfosByProcessIdentifier.removeValue(forKey: previousOwner)
                stopMonitoring(processIdentifier: previousOwner)
            }
        }

        guard let processIdentifier else { return }
        registeredInfosByProcessIdentifier[processIdentifier, default: []].insert(info)
        startMonitoring(processIdentifier: processIdentifier)
    }

    private func startMonitoring(processIdentifier: pid_t) {
        guard processMonitorSources[processIdentifier] == nil else { return }
        let source = DispatchSource.makeProcessSource(identifier: processIdentifier, eventMask: .exit, queue: processMonitorQueue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.handleRegistrantExit(processIdentifier: processIdentifier) }
        }
        processMonitorSources[processIdentifier] = source
        source.resume()
    }

    private func stopMonitoring(processIdentifier: pid_t) {
        processMonitorSources[processIdentifier]?.cancel()
        processMonitorSources.removeValue(forKey: processIdentifier)
    }

    private func handleRegistrantExit(processIdentifier: pid_t) {
        for info in registeredInfosByProcessIdentifier.removeValue(forKey: processIdentifier) ?? [] {
            endpointByInfo.removeValue(forKey: info)
        }
        stopMonitoring(processIdentifier: processIdentifier)
    }

    private func fetchVersion(request: FetchVersionRequest) async throws -> FetchVersionRequest.Response {
        return .init(version: version)
    }

    package init(version: String) {
        self.version = version
    }

    public func setupHandler(_ handler: some HelperHandler) async {
        handler.setMessageHandler { [weak self] (request: ListServerInfosRequest) -> ListServerInfosRequest.Response in
            guard let self else { throw Error.selfDidDealloc }
            return try await listEndpoints(request: request)
        }
        handler.setMessageHandler { [weak self] (request: RegisterEndpointRequest) -> RegisterEndpointRequest.Response in
            guard let self else { throw Error.selfDidDealloc }
            return try await registerEndpoint(request: request)
        }
        handler.setMessageHandler { [weak self] (request: PingRequest) -> PingRequest.Response in
            guard let self else { throw Error.selfDidDealloc }
            return try await ping(request: request)
        }
        handler.setMessageHandler { [weak self] (request: FetchEndpointRequest) -> FetchEndpointRequest.Response in
            guard let self else { throw Error.selfDidDealloc }
            return try await fetchEndpoint(request: request)
        }
        handler.setMessageHandler { [weak self] (request: FetchVersionRequest) -> FetchVersionRequest.Response in
            guard let self else { throw Error.selfDidDealloc }
            return try await fetchVersion(request: request)
        }
    }

}
#endif
