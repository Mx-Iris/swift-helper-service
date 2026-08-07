#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
import HelperCommunication

/// Inject `dylibURL` into `pid`.
///
/// The daemon picks how — a `dlopen` inside the target, or a `mach_vm_remap`
/// projection of the payload's segments — by probing the target itself. Clients
/// do not choose, and must not: the answer depends on the target's sandbox and
/// code-signing status, which only the daemon is positioned to read, and a
/// second copy of the rule on the client side is how the two halves drift
/// apart.
public struct InjectApplicationRequest: Codable, Request {
    public typealias Response = VoidResponse

    public static let identifier: String = "com.JH.HelperService.InjectionService.InjectApplication"

    public let pid: pid_t

    public let dylibURL: URL

    /// Exported `void *(*)(void *)` symbol in `dylibURL`, invoked on a fresh
    /// pthread inside the target when the daemon takes the `mach_vm_remap`
    /// path. Required only for that path: a remapped image never gets dyld's
    /// constructor pass, so there is no other way in.
    ///
    /// Leave `nil` for a payload that has no such entry. The injection then
    /// fails with a descriptive error if — and only if — the target turns out
    /// to need remap, which is more honest than making every caller invent a
    /// symbol name it cannot supply.
    public let remapEntrySymbol: String?

    public init(pid: pid_t, dylibURL: URL, remapEntrySymbol: String? = nil) {
        self.pid = pid
        self.dylibURL = dylibURL
        self.remapEntrySymbol = remapEntrySymbol
    }
}

#endif
