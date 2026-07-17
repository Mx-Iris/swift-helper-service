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

        handler.setMessageHandler { (request: InjectApplicationViaRemapRequest) -> InjectApplicationViaRemapRequest.Response in
            guard #available(macOS 11.0, *) else {
                throw NSError(
                    domain: "com.JH.HelperService.InjectionService",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "MachInjectorRemap requires macOS 11.0 or later."]
                )
            }
            // Same main-thread task_for_pid constraint as the dlopen path.
            try await MainActor.run {
                try MachInjectorRemap.inject(
                    pid: request.pid,
                    payloadPath: request.payloadURL.path,
                    entrySymbol: request.entrySymbol
                )
            }
            return .empty
        }
    }

    public func run() async throws {}
}
#endif
