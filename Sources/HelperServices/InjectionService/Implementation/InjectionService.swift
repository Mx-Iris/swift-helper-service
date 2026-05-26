#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
import HelperService
import MachInjector
import InjectionServiceInterface

public actor InjectionService: HelperService {
    public init() {}
    public func setupHandler(_ handler: some HelperHandler) async {
        handler.setMessageHandler { (request: InjectApplicationRequest) -> InjectApplicationRequest.Response in
            // MachInjector calls `task_for_pid`, which requires a main-thread host port.
            try await MainActor.run {
                try MachInjector.inject(pid: request.pid, dylibPath: request.dylibURL.path)
            }
            return .empty
        }
    }

    public func run() async throws {}
}
#endif
