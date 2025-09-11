import Foundation
import HelperService
import HelperCommunication
@preconcurrency private import SwiftyXPC

package actor MainService: HelperService {
    private var endpointByInfo: [HelperServerInfo: SwiftyXPC.XPCEndpoint] = [:]

    public enum Error: LocalizedError {
        case selfDidDealloc
        case notFound
    }

    private func ping(request: PingRequest) async throws -> PingRequest.Response {
        return .empty
    }


    private func fetchEndpoint(request: FetchEndpointRequest) async throws -> FetchEndpointRequest.Response {
        guard let endpoint = endpointByInfo[request.info] else {
            throw Error.notFound
        }
        return .init(endpoint: endpoint)
    }

    private func listEndpoints(request: ListServerInfosRequest) async throws -> ListServerInfosRequest.Response {
        return .init(infos: endpointByInfo.map { $0.key })
    }

    private func registerEndpoint(request: RegisterEndpointRequest) async throws -> RegisterEndpointRequest.Response {
        endpointByInfo[request.info] = request.endpoint
        return .empty
    }

    public init() {}

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
    }

    public func run() async throws {}
}
