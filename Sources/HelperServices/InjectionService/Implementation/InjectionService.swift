#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
import Security
import HelperService
import MachInjector
import InjectionServiceInterface
import FoundationToolbox

/// The subsystem is spelled out because a daemon has no bundle to infer one from:
/// `@Loggable`'s default would fall back to the bare type name.
@Loggable(subsystem: "com.JH.HelperService.InjectionService", category: "Injection")
public actor InjectionService: HelperService {
    private static let errorDomain = "com.JH.HelperService.InjectionService"

    private enum ErrorCode {
        /// The target needs the remap path, which predates the deployment target.
        static let remapUnavailableOnThisSystem = -1
        /// The target needs the remap path, but the payload exports no entry symbol.
        static let remapEntrySymbolMissing = -2
        /// Injection reported success, but the target is no longer running.
        static let targetNoLongerRunning = -3
        /// The payload is built for a different platform than the target.
        static let payloadPlatformMismatch = -4
        /// A cross-platform target refused a dlopen, and remap is not an option for it.
        static let crossPlatformTargetRefusedDlopen = -5
        /// The payload has no slice for the architecture the target executes.
        static let payloadArchitectureMismatch = -6
        /// The payload's code signature does not validate.
        static let payloadSignatureInvalid = -7
    }

    /// This daemon's own platform, read once.
    ///
    /// It is the reference for "is the target running on a different platform
    /// than we are" — read rather than assumed, because this same code builds
    /// for macOS and Mac Catalyst, which are different platform values.
    @MainActor
    private static let daemonPlatform: UInt32? = MachOPlatform.ofProcess(getpid())

    /// Why the remap fallback is or is not available for one injection.
    ///
    /// Three distinct answers that used to be one `Bool`. They read identically
    /// at the branch and completely differently in a log, which is where this
    /// matters: "did not fall back" with no reason attached is the kind of line
    /// that costs an hour later.
    private enum RemapFallback {
        case allowed
        case blockedByCallerPinnedStrategy
        case blockedByCrossPlatformTarget

        var isAllowed: Bool {
            if case .allowed = self { return true }
            return false
        }

        var logDescription: String {
            switch self {
            case .allowed: return "allowed"
            case .blockedByCallerPinnedStrategy: return "not allowed (caller pinned a strategy)"
            case .blockedByCrossPlatformTarget: return "not allowed (target runs on another platform)"
            }
        }
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


    /// Loads `request.dylibURL` into `request.pid`, attempting the simpler
    /// `dlopen` path first and falling back to `mach_vm_remap` only once the
    /// target has actually refused it — see ``InjectionStrategy``.
    @MainActor
    private static func inject(request: InjectApplicationRequest) throws {
        let payloadPath = request.dylibURL.path
        let targetPlatform = MachOPlatform.ofProcess(request.pid)

        try requirePayloadMatchesTargetPlatform(
            pid: request.pid,
            payloadPath: payloadPath,
            targetPlatform: targetPlatform
        )
        try requirePayloadCoversTargetArchitecture(pid: request.pid, payloadPath: payloadPath)
        try requirePayloadSignatureIsValid(payloadPath: payloadPath)

        let strategy = request.preferredStrategy
            ?? InjectionStrategy.initialAttempt(forTarget: request.pid, payloadPath: payloadPath)

        let fallback = remapFallback(for: request, targetPlatform: targetPlatform)

        #log(
            .info,
            """
            Injecting \(payloadPath, privacy: .public) into pid \(request.pid, privacy: .public) \
            via \(strategy.rawValue, privacy: .public) \
            (fallback to remap \(fallback.logDescription, privacy: .public))
            """
        )

        switch strategy {
        case .dlopen:
            do {
                try MachInjector.inject(pid: request.pid, dylibPath: payloadPath)
            } catch {
                // The refusal text is the single most useful thing in a failed
                // injection, and only this process ever sees it in full.
                #log(
                    .error,
                    """
                    pid \(request.pid, privacy: .public) refused a dlopen of \
                    \(payloadPath, privacy: .public): \(String(describing: error), privacy: .public) \
                    — \(error.localizedDescription, privacy: .public). \
                    Remap fallback: \(fallback.logDescription, privacy: .public).
                    """
                )
                switch fallback {
                case .allowed:
                    try injectViaRemap(request: request, payloadPath: payloadPath, dlopenFailure: error)
                case .blockedByCallerPinnedStrategy:
                    throw error
                case .blockedByCrossPlatformTarget:
                    throw crossPlatformDlopenRefusalError(pid: request.pid, dlopenFailure: error)
                }
                return
            }

        case .machVirtualMemoryRemap:
            // A caller can still pin remap for a cross-platform target. That is
            // what an escape hatch is for, and refusing here would leave no way
            // to exercise the path once it is fixed — but it is worth a line in
            // the log, because the likely outcome is a dead target.
            if case .blockedByCrossPlatformTarget = remapFallback(for: request, targetPlatform: targetPlatform) {
                #log(.error, "pid \(request.pid, privacy: .public) runs on another platform and remap was pinned explicitly; this will most likely kill it")
            }
            try injectViaRemap(request: request, payloadPath: payloadPath, dlopenFailure: nil)
            return
        }

        try requireTargetIsStillRunning(pid: request.pid, strategy: .dlopen)
    }

    /// Refuses a payload built for a different platform than its target.
    ///
    /// The host app already picks the payload slice per target platform, so
    /// reaching this means something upstream is wrong. It is still checked
    /// here, because getting it wrong is not a recoverable error: dyld refuses
    /// the mismatched slice, and the remap fallback then projects it in anyway,
    /// which the kernel kills the target for. A refusal costs one failed
    /// injection; not refusing costs the target process.
    ///
    /// An unreadable platform on either side is *not* treated as a mismatch. A
    /// guard that blocks whenever it cannot see clearly would turn every
    /// unparseable target into an injection failure, and this is a second line
    /// of defence rather than the decision itself.
    @MainActor
    private static func requirePayloadMatchesTargetPlatform(
        pid: pid_t,
        payloadPath: String,
        targetPlatform: UInt32?
    ) throws {
        guard let targetPlatform,
              let payloadPlatform = MachOPlatform.ofFile(atPath: payloadPath),
              targetPlatform != payloadPlatform
        else { return }

        throw makeError(
            code: ErrorCode.payloadPlatformMismatch,
            description: """
            The payload at \(payloadPath) is built for platform \(payloadPlatform), but process \(pid) \
            runs on platform \(targetPlatform). dyld would refuse it. These values are \
            LC_BUILD_VERSION platforms: 1 is macOS, 6 Mac Catalyst, 7 iOS Simulator, 8 tvOS \
            Simulator, 9 watchOS Simulator. Note that a mismatch is invisible in the architecture \
            — on Apple silicon both sides are arm64 — and that one fat binary cannot carry both, \
            which is why the payload ships as a separate bundle per platform.
            """
        )
    }

    /// Refuses a payload with no slice for the architecture the target is executing.
    ///
    /// This is the most common packaging mistake and the least legible one. An arm64e process
    /// does not accept an arm64-only library: the `dlopen` comes back with a message about the
    /// file not being loadable, which reads like a missing file or a bad path, and on the remap
    /// path the payload goes in and the target dies instead. Both are hours of looking in the
    /// wrong place. One sentence naming the missing slice ends it.
    ///
    /// Anything unreadable — on either side — passes. Same reasoning as the platform guard: a
    /// check that blocks whenever it cannot see clearly turns every unparseable target into a
    /// failed injection, and this is a second line of defence rather than the decision itself.
    /// Translated (Rosetta) targets also pass, because the inference behind
    /// ``MachOArchitectureReader/executingArchitectureOfProcess(_:)`` does not hold for them —
    /// neither injector supports such a target anyway, and it fails later with its own message.
    @MainActor
    private static func requirePayloadCoversTargetArchitecture(pid: pid_t, payloadPath: String) throws {
        guard let targetArchitecture = MachOArchitectureReader.executingArchitectureOfProcess(pid),
              let payloadArchitectures = MachOArchitectureReader.architecturesOfFile(atPath: payloadPath),
              !payloadArchitectures.contains(targetArchitecture)
        else { return }

        let present = payloadArchitectures
            .map(\.description)
            .sorted()
            .joined(separator: ", ")

        throw makeError(
            code: ErrorCode.payloadArchitectureMismatch,
            description: """
            Process \(pid) executes \(targetArchitecture), but the payload at \(payloadPath) only \
            has \(present). An arm64e process will not load an arm64-only library — dyld grades \
            arm64e strictly, so there is no fallback to the arm64 slice. Rebuild the payload for \
            \(targetArchitecture); for a fat build that is `-arch arm64 -arch arm64e`, and for an \
            Xcode target it is ENABLE_POINTER_AUTHENTICATION plus a generic/platform=macOS \
            destination (a `platform=macOS` destination silently drops the slice).
            """
        )
    }

    /// Refuses a payload whose signature does not validate.
    ///
    /// Worth checking before injecting rather than after, because of how it fails otherwise: the
    /// kernel SIGKILLs the *target* when a mapped page's hash does not match the signature, and
    /// it does so during page-in, before `dlopen` returns anything the injector could relay. From
    /// the outside that is "injection reported success and the app disappeared" — the payload is
    /// the last place anyone looks.
    ///
    /// An unsigned payload is allowed through. Ad hoc and unsigned binaries are ordinary during
    /// development, and refusing them would make this check a policy decision about who may
    /// inject what — which is the listener's requirement's job, not this one's. What is refused
    /// is a payload that *claims* a signature which does not hold: that one is either corrupt or
    /// tampered with, and it is the one that kills the target.
    @MainActor
    private static func requirePayloadSignatureIsValid(payloadPath: String) throws {
        var staticCode: SecStaticCode?
        let creationStatus = SecStaticCodeCreateWithPath(
            URL(fileURLWithPath: payloadPath) as CFURL,
            [],
            &staticCode
        )
        guard creationStatus == errSecSuccess, let staticCode else { return }

        let validityStatus = SecStaticCodeCheckValidity(staticCode, [], nil)
        switch validityStatus {
        case errSecSuccess, errSecCSUnsigned:
            // Unsigned is fine; see the note above.
            return
        default:
            let explanation = SecCopyErrorMessageString(validityStatus, nil) as String?
                ?? "OSStatus \(validityStatus)"
            throw makeError(
                code: ErrorCode.payloadSignatureInvalid,
                description: """
                The payload at \(payloadPath) carries a code signature that does not validate: \
                \(explanation). It was not injected, because this is the failure that kills the \
                target rather than reporting an error — the kernel terminates a process when a \
                mapped page's hash does not match, during page-in, before dlopen returns. \
                Re-sign the payload (`codesign -f -s -` for an ad hoc signature) and try again.
                """
            )
        }
    }

    /// Whether this injection may fall back to remap, and why not when it may not.
    @MainActor
    private static func remapFallback(
        for request: InjectApplicationRequest,
        targetPlatform: UInt32?
    ) -> RemapFallback {
        // Falling back is only for a path this side chose. A caller that pinned
        // one explicitly gets that path or an error — quietly rerouting would
        // defeat the point of `preferredStrategy` being an escape hatch.
        guard request.preferredStrategy == nil else { return .blockedByCallerPinnedStrategy }

        // The remap path resolves the symbols it needs in *this* process and
        // hands those addresses to the target. That holds for another macOS
        // process, which maps the same shared cache at the same slide. It does
        // not hold for a target on another platform: an iOS Simulator process
        // is loaded by dyld_sim against the simulator runtime's own shared
        // cache, so an address from here lands on unrelated memory and the
        // target dies the moment it jumps there. Reporting the dlopen refusal
        // honestly is strictly better than that.
        //
        // The dlopen path itself is fine — it resolves against the target's own
        // symbol table (MITargetSymbolResolver) — which is why only the
        // fallback is blocked here and not the injection.
        if let targetPlatform, let daemonPlatform, targetPlatform != daemonPlatform {
            return .blockedByCrossPlatformTarget
        }
        return .allowed
    }

    /// The error for a cross-platform target that refused a `dlopen`.
    ///
    /// Carries the target's own refusal — that text is the actionable part —
    /// plus the reason no fallback was attempted, so the absence of a second
    /// attempt does not read like a bug.
    private static func crossPlatformDlopenRefusalError(pid: pid_t, dlopenFailure: any Error) -> NSError {
        makeError(
            code: ErrorCode.crossPlatformTargetRefusedDlopen,
            description: """
            Process \(pid) refused to load the payload: \(dlopenFailure.localizedDescription)

            It runs on a different platform than this daemon — an iOS Simulator process, or another \
            simulator runtime — so the mach_vm_remap fallback was deliberately not attempted. That \
            path resolves symbols in this process and hands the addresses to the target, which is \
            valid only for a target sharing this machine's shared cache. For a process running \
            under dyld_sim it lands on unrelated memory and kills it.
            """
        )
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

    /// Every failure this service raises goes through here, so this is also where it
    /// is written to the log. The transport layer records that a handler failed;
    /// this records it with the injection context the transport layer cannot see.
    private static func makeError(code: Int, description: String) -> NSError {
        #log(.error, "Injection failed (code \(code, privacy: .public)): \(description, privacy: .public)")
        return NSError(domain: errorDomain, code: code, userInfo: [NSLocalizedDescriptionKey: description])
    }
}
#endif
