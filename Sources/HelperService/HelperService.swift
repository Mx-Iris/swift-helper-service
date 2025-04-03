import AppKit
import SwiftyXPC
import HelperCommunication
import ServiceLifecycle

public protocol HelperService: Service {
    init(proxy: HelperServiceProxy)
}

public protocol HelperServiceProxy: Sendable {
    func setMessageHandler<Request: HelperCommunication.Request>(handler: @escaping (Request) async throws -> Request.Response)
}

public actor HelperServiceController: HelperServiceProxy {
    private var listener: SwiftyXPC.XPCListener
    private var group: ServiceGroup?

    public init(machServiceName: String, services: [HelperService.Type]) async throws {
        self.listener = try .init(type: .machService(name: machServiceName), codeSigningRequirement: nil)
        self.listener.activate()
        self.group = .init(services: services.map { $0.init(proxy: self) }, logger: .init(label: ""))
    }

    func run() async throws {
        try await group?.run()
    }

    public nonisolated func setMessageHandler<Request>(handler: @escaping (Request) async throws -> Request.Response) where Request: HelperCommunication.Request {
        Task {
            await listener.setMessageHandler {
                try await handler($1)
            }
        }
    }
}

public actor MainService: HelperService {
    private var endpointByIdentifier: [String: XPCEndpoint] = [:]

    enum Error: LocalizedError {
        case selfDidDealloc
    }

    private func ping(request: PingRequest) async throws -> PingRequest.Response {
        return .empty
    }

    private func fetchEndpoint(request: FetchEndpointRequest) async throws -> FetchEndpointRequest.Response {
        guard let endpoint = endpointByIdentifier[request.identifier] else {
            throw XPCError.unknown("No endpoint available")
        }
        return .init(endpoint: endpoint)
    }

    private func registerEndpoint(request: RegisterEndpointRequest) async throws -> RegisterEndpointRequest.Response {
        endpointByIdentifier[request.identifier] = request.endpoint
        return .empty
    }

//    private func launchCatalystHelper(_ connection: XPCConnection, request: LaunchCatalystHelperRequest) async throws -> LaunchCatalystHelperRequest.Response {
//        let configuration = NSWorkspace.OpenConfiguration()
//        configuration.createsNewApplicationInstance = false
//        configuration.addsToRecentItems = false
//        configuration.activates = false
//        catalystHelperApplication = try await NSWorkspace.shared.openApplication(at: request.helperURL, configuration: configuration)
//        return .empty
//    }

    private func fileOperation(request: FileOperationRequest) async throws -> FileOperationRequest.Response {
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

//    private func injectApplication(_ connection: XPCConnection, request: InjectApplicationRequest) async throws -> InjectApplicationRequest.Response {
//        try await MainActor.run {
//            try MachInjector.inject(pid: request.pid, dylibPath: request.dylibURL.path)
//        }
//        return .empty
//    }

    public init(proxy: any HelperServiceProxy) {
        proxy.setMessageHandler { [weak self] (request: FetchEndpointRequest) -> FetchEndpointRequest.Response in
            guard let self else { throw Error.selfDidDealloc }
            return try await fetchEndpoint(request: request)
        }
        proxy.setMessageHandler { [weak self] (request: RegisterEndpointRequest) -> RegisterEndpointRequest.Response in
            guard let self else { throw Error.selfDidDealloc }
            return try await registerEndpoint(request: request)
        }
        proxy.setMessageHandler { [weak self] (request: PingRequest) -> PingRequest.Response in
            guard let self else { throw Error.selfDidDealloc }
            return try await ping(request: request)
        }
        proxy.setMessageHandler { [weak self] (request: FileOperationRequest) -> FileOperationRequest.Response in
            guard let self else { throw Error.selfDidDealloc }
            return try await fileOperation(request: request)
        }
    }

    public func run() async throws {}
}
