#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
import HelperProcessProbe

/// How a payload should be loaded into an injection target.
///
/// The decision lives here, in the daemon, rather than in any client: it is
/// answered entirely by probing the target process, the daemon already runs as
/// root with the task port it needs, and keeping a second copy of the rule on
/// the client side is how the two halves drift apart.
///
/// There is exactly one reason to prefer ``dlopen``: it is far simpler and far
/// better tested than the remap path, which hand-applies chained fixups and
/// replays dyld's runtime notifications itself. So the rule is "dlopen unless
/// the target would refuse it", and this type is the single place that decides
/// what "would refuse it" means.
public enum InjectionStrategy: Sendable, Equatable {
    /// Run shellcode in the target that calls `dlopen` on the payload path.
    case dlopen

    /// Project the payload's already-mapped segments into the target with
    /// `mach_vm_remap`, bypassing `dlopen` — and therefore both the seatbelt
    /// predicate and AMFI — entirely. Requires the payload to export a
    /// `void *(*)(void *)` entry symbol, because dyld's constructor pass never
    /// runs for a remapped image.
    case machVirtualMemoryRemap

    /// Picks the strategy for loading `payloadPath` into `pid`.
    ///
    /// Two independent enforcement layers refuse a `dlopen`, and a target only
    /// has to hit one of them:
    ///
    /// - **Seatbelt.** Strict-profile daemons (sharingd, rapportd, and their
    ///   kin) `(deny default)` `file-map-executable` for anything outside a
    ///   hard-coded system whitelist. No sandbox extension unlocks that
    ///   predicate — `APP_SANDBOX_READ` only covers `file-read*`.
    /// - **AMFI library validation.** Any process carrying `CS_REQUIRE_LV` only
    ///   accepts Apple-signed or same-Team-ID dylibs, which rules out a
    ///   developer-signed payload. This covers every Apple application, all of
    ///   which are otherwise unsandboxed — so the seatbelt probe alone reports
    ///   them as permitted and would silently route them onto a path that
    ///   cannot work.
    ///
    /// A target that has already exited answers `.machVirtualMemoryRemap`:
    /// `sandbox_check` reports "denied" for a pid it cannot find rather than
    /// signalling an error, so the seatbelt probe cannot tell that case apart
    /// from a real deny. It makes no practical difference — either path fails
    /// at `task_for_pid` on a dead target — so the behaviour is documented
    /// rather than worked around. `csops` does report an error for an unknown
    /// pid, so the library-validation probe fails closed onto `dlopen`.
    public static func forTarget(pid: pid_t, payloadPath: String) -> InjectionStrategy {
        if isFileMapExecutableBlocked(pid: pid, path: payloadPath) {
            return .machVirtualMemoryRemap
        }
        if isLibraryValidationEnforced(pid: pid) {
            return .machVirtualMemoryRemap
        }
        return .dlopen
    }

    /// Whether `pid`'s sandbox would deny mapping `path` as executable — i.e.
    /// whether a `dlopen(path)` inside that process would be refused by
    /// seatbelt at the `file-map-executable` predicate.
    static func isFileMapExecutableBlocked(pid: pid_t, path: String) -> Bool {
        let result = path.withCString { pathPointer in
            "file-map-executable".withCString { operationPointer in
                HelperProcessProbeSandboxCheckPath(pid, operationPointer, pathPointer)
            }
        }
        // `sandbox_check` returns 0 when allowed (or unsandboxed), a positive
        // value when denied, and -1 on error.
        return result > 0
    }

    /// Whether `pid` runs with AMFI library validation enforced.
    ///
    /// Disabling SIP does not lift this; only the `amfi_get_out_of_my_way=1`
    /// boot argument does, and relying on a machine-wide boot argument is not
    /// something the daemon can assume.
    ///
    /// Returns `false` when the status cannot be read, so an unreadable target
    /// degrades to the simpler, better-tested path rather than the riskier one.
    static func isLibraryValidationEnforced(pid: pid_t) -> Bool {
        var codeSigningStatus: UInt32 = 0
        guard HelperProcessProbeCodeSigningStatus(pid, &codeSigningStatus) == 0 else {
            return false
        }
        return codeSigningStatus & HelperProcessProbeCodeSigningRequiresLibraryValidation != 0
    }
}
#endif
