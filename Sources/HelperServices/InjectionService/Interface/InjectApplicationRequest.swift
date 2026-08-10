#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
import HelperCommunication

/// Inject `dylibURL` into `pid`.
///
/// The daemon decides how — a `dlopen` inside the target, or a `mach_vm_remap`
/// projection of the payload's segments — because the answer depends on the
/// target's sandbox and code-signing status, which only the daemon is
/// positioned to read. Rather than predict which one the target will accept, it
/// tries `dlopen` and falls back to remap once the target has actually refused.
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

    /// Overrides the daemon's choice of path. `nil` — the default — lets the
    /// daemon decide, which is what nearly every caller should do: it holds the
    /// task port and can probe the target, and a second copy of the rule on the
    /// client side is how the two halves drift apart.
    ///
    /// Set it to pin a path when the default is wrong for a specific target:
    /// to force `dlopen` past a target that reads as remap-only, or to force
    /// remap for a payload whose `dlopen` reports success without taking
    /// effect. **Pinning also disables the automatic fallback** — a caller that
    /// asked for one path gets that path or an error, never the other one.
    public let preferredStrategy: InjectionStrategy?

    public init(
        pid: pid_t,
        dylibURL: URL,
        remapEntrySymbol: String? = nil,
        preferredStrategy: InjectionStrategy? = nil
    ) {
        self.pid = pid
        self.dylibURL = dylibURL
        self.remapEntrySymbol = remapEntrySymbol
        self.preferredStrategy = preferredStrategy
    }
}

#endif
