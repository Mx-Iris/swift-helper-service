#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation

/// How a payload is loaded into an injection target.
///
/// There is exactly one reason to prefer ``dlopen``: it is far simpler and far
/// better tested than the remap path, which hand-applies chained fixups and
/// replays dyld's runtime notifications itself. So the daemon tries `dlopen`
/// unless the target is known to refuse it, and falls back to the remap path
/// only once the target has actually said no.
///
/// The daemon picks the path by probing the target — see
/// `InjectionStrategy.initialAttempt(forTarget:payloadPath:)` in
/// `InjectionServiceImplementation`. This type lives in the Interface target
/// because a client may override that choice through
/// ``InjectApplicationRequest/preferredStrategy``, which puts it on the wire.
///
/// The raw values are the wire format: they are spelled out so that reordering
/// or inserting a case cannot silently change what an older peer decodes.
public enum InjectionStrategy: String, Codable, Sendable, Equatable {
    /// Run shellcode in the target that calls `dlopen` on the payload path.
    ///
    /// Two independent enforcement layers can refuse this, and a target only
    /// has to hit one of them:
    ///
    /// - **Seatbelt.** Strict-profile daemons (sharingd, rapportd, and their
    ///   kin) `(deny default)` `file-map-executable` for anything outside a
    ///   hard-coded system whitelist. No sandbox extension unlocks that
    ///   predicate — `APP_SANDBOX_READ` only covers `file-read*`.
    /// - **AMFI library validation.** A process carrying `CS_REQUIRE_LV` may
    ///   only accept Apple-signed or same-Team-ID dylibs. *May* — whether the
    ///   flag is actually enforced depends on system state, not on the flag
    ///   alone; see `isLibraryValidationEnforced` for what was measured.
    case dlopen = "dlopen"

    /// Project the payload's already-mapped segments into the target with
    /// `mach_vm_remap`, bypassing `dlopen` — and therefore both the seatbelt
    /// predicate and AMFI — entirely. Requires the payload to export a
    /// `void *(*)(void *)` entry symbol, because dyld's constructor pass never
    /// runs for a remapped image.
    case machVirtualMemoryRemap = "machVirtualMemoryRemap"
}
#endif
