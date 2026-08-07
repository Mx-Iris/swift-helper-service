#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
import HelperService
import MachInjector
import InjectionServiceInterface

public actor InjectionService: HelperService {
    private static let errorDomain = "com.JH.HelperService.InjectionService"

    public init() {}

    public func setupHandler(_ handler: some HelperHandler) async {
        handler.setMessageHandler { (request: InjectApplicationRequest) -> InjectApplicationRequest.Response in
            // MachInjector calls `task_for_pid`, which requires a main-thread host port.
            try await MainActor.run {
                try Self.inject(request: request)
            }
            return .empty
        }
    }

    public func run() async throws {}

    /// Loads `request.dylibURL` into `request.pid` along whichever path the
    /// target will actually accept — see ``InjectionStrategy``.
    @MainActor
    private static func inject(request: InjectApplicationRequest) throws {
        let payloadPath = request.dylibURL.path

        switch InjectionStrategy.forTarget(pid: request.pid, payloadPath: payloadPath) {
        case .dlopen:
            try MachInjector.inject(pid: request.pid, dylibPath: payloadPath)

        case .machVirtualMemoryRemap:
            guard #available(macOS 11.0, *) else {
                throw makeError(
                    code: -1,
                    description: "This target can only be injected via mach_vm_remap, which requires macOS 11.0 or later."
                )
            }
            guard let remapEntrySymbol = request.remapEntrySymbol else {
                throw makeError(
                    code: -2,
                    description: """
                    This target refuses dlopen — its sandbox denies file-map-executable, or it enforces \
                    library validation — so it can only be injected via mach_vm_remap, which needs the \
                    payload's entry symbol. Pass `remapEntrySymbol` when the payload exports one.
                    """
                )
            }
            try MachInjectorRemap.inject(
                pid: request.pid,
                payloadPath: payloadPath,
                entrySymbol: remapEntrySymbol
            )
        }
    }

    private static func makeError(code: Int, description: String) -> NSError {
        NSError(domain: errorDomain, code: code, userInfo: [NSLocalizedDescriptionKey: description])
    }
}
#endif
