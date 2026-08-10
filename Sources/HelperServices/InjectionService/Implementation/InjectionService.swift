#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
import HelperService
import MachInjector
import InjectionServiceInterface

public actor InjectionService: HelperService {
    private static let errorDomain = "com.JH.HelperService.InjectionService"

    private enum ErrorCode {
        /// The target needs the remap path, which predates the deployment target.
        static let remapUnavailableOnThisSystem = -1
        /// The target needs the remap path, but the payload exports no entry symbol.
        static let remapEntrySymbolMissing = -2
        /// Injection reported success, but the target is no longer running.
        static let targetNoLongerRunning = -3
    }

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

    /// Loads `request.dylibURL` into `request.pid`, attempting the simpler
    /// `dlopen` path first and falling back to `mach_vm_remap` only once the
    /// target has actually refused it — see ``InjectionStrategy``.
    @MainActor
    private static func inject(request: InjectApplicationRequest) throws {
        let payloadPath = request.dylibURL.path
        let strategy = request.preferredStrategy
            ?? InjectionStrategy.initialAttempt(forTarget: request.pid, payloadPath: payloadPath)

        // Falling back is only for a path this side chose. A caller that pinned
        // one explicitly gets that path or an error — quietly rerouting would
        // defeat the point of `preferredStrategy` being an escape hatch.
        let mayFallBackToRemap = request.preferredStrategy == nil

        switch strategy {
        case .dlopen:
            do {
                try MachInjector.inject(pid: request.pid, dylibPath: payloadPath)
            } catch {
                guard mayFallBackToRemap else { throw error }
                try injectViaRemap(request: request, payloadPath: payloadPath, dlopenFailure: error)
                return
            }

        case .machVirtualMemoryRemap:
            try injectViaRemap(request: request, payloadPath: payloadPath, dlopenFailure: nil)
            return
        }

        try requireTargetIsStillRunning(pid: request.pid, strategy: .dlopen)
    }

    /// Projects the payload into the target with `mach_vm_remap`.
    ///
    /// `dlopenFailure` carries the refusal that sent us here, when a `dlopen`
    /// was tried first. It is folded into the "no entry symbol" error, because
    /// a caller told only that remap needs a symbol has no way to see *why*
    /// remap became necessary.
    @MainActor
    private static func injectViaRemap(
        request: InjectApplicationRequest,
        payloadPath: String,
        dlopenFailure: (any Error)?
    ) throws {
        guard #available(macOS 11.0, *) else {
            throw makeError(
                code: ErrorCode.remapUnavailableOnThisSystem,
                description: "This target can only be injected via mach_vm_remap, which requires macOS 11.0 or later."
            )
        }

        guard let remapEntrySymbol = request.remapEntrySymbol else {
            let refusal = dlopenFailure.map { "The target refused a dlopen: \($0.localizedDescription) " } ?? ""
            let validationNote = InjectionStrategy.isLibraryValidationEnforced(pid: request.pid)
                ? " The target carries CS_REQUIRE_LV, so AMFI library validation is the likely reason."
                : ""
            throw makeError(
                code: ErrorCode.remapEntrySymbolMissing,
                description: """
                \(refusal)It can only be injected via mach_vm_remap, which needs the payload's entry \
                symbol. Pass `remapEntrySymbol` when the payload exports one.\(validationNote)
                """
            )
        }

        try MachInjectorRemap.inject(
            pid: request.pid,
            payloadPath: payloadPath,
            entrySymbol: remapEntrySymbol
        )

        try requireTargetIsStillRunning(pid: request.pid, strategy: .machVirtualMemoryRemap)
    }

    /// Fails when the target did not survive the injection.
    ///
    /// Neither injector can see this on its own. MachInjector's report block is
    /// written by a pthread *inside* the target, so a target that is gone
    /// leaves the report permanently `Pending` — indistinguishable from a slow
    /// `dlopen`, and treated as success after the poll budget. A payload whose
    /// page hashes do not match is SIGKILLed by the kernel on page-in, before
    /// `dlopen` ever returns, so there is no `dlerror` to relay either. Without
    /// this check that lands as "injected successfully" on a process that no
    /// longer exists.
    ///
    /// The check keys off `ESRCH` rather than `kill`'s return value: the daemon
    /// runs as root and will not see `EPERM` for a live process, but reading
    /// the errno is correct at any privilege level.
    ///
    /// A target that exits on its own between the injection and this check is
    /// reported as a failure. That window is small, and the conclusion still
    /// holds from the caller's side — nothing was durably injected — so the
    /// message describes what was observed rather than asserting a cause.
    private static func requireTargetIsStillRunning(pid: pid_t, strategy: InjectionStrategy) throws {
        guard kill(pid, 0) == -1, errno == ESRCH else { return }
        throw makeError(
            code: ErrorCode.targetNoLongerRunning,
            description: """
            Injection via \(strategy.rawValue) reported success, but process \(pid) is no longer \
            running. The payload most likely killed it — a dylib whose page hashes do not match its \
            signature is terminated by the kernel on page-in, without the injector ever seeing an \
            error.
            """
        )
    }

    private static func makeError(code: Int, description: String) -> NSError {
        NSError(domain: errorDomain, code: code, userInfo: [NSLocalizedDescriptionKey: description])
    }
}
#endif
