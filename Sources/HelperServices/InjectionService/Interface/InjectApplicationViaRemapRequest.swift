#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
import HelperCommunication

/// Inject `payloadURL` into `pid` using MachInjector's `mach_vm_remap` path,
/// invoking `entrySymbol` on a fresh pthread inside the target.
///
/// This is the sibling to ``InjectApplicationRequest`` for strict-seatbelt
/// daemons whose sandbox profile denies `file-map-executable` and therefore
/// refuses any `dlopen(payloadURL.path)` inside the target. The remap path
/// projects the payload's Mach-O segments straight into the target's VM space
/// (bypassing the file-map-executable predicate entirely) and requires the
/// payload to expose an exported `void *(*)(void *)` entry symbol because
/// `dyld`'s constructor pass is not run for remapped images.
///
/// Client selects between this and the dlopen request based on a
/// `sandbox_check(pid, "file-map-executable", SANDBOX_FILTER_PATH, path)`
/// probe of the payload path against the target.
public struct InjectApplicationViaRemapRequest: Codable, Request {
    public typealias Response = VoidResponse

    public static let identifier: String = "com.JH.HelperService.InjectionService.InjectApplicationViaRemap"

    public let pid: pid_t

    public let payloadURL: URL

    public let entrySymbol: String

    public init(pid: pid_t, payloadURL: URL, entrySymbol: String) {
        self.pid = pid
        self.payloadURL = payloadURL
        self.entrySymbol = entrySymbol
    }
}

#endif
