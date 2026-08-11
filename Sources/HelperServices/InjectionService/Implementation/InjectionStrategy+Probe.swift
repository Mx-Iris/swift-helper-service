#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
import HelperProcessProbe
import InjectionServiceInterface

extension InjectionStrategy {
    /// Picks the path to *try first* for loading `payloadPath` into `pid`.
    ///
    /// This is a starting point, not a verdict. `dlopen` reports its own
    /// refusal — MachInjector 0.4.3 relays `dlerror`'s message rather than
    /// claiming success — so `InjectionService` can attempt it and fall back to
    /// ``InjectionStrategy/machVirtualMemoryRemap`` once the target has
    /// actually said no. Answering "try dlopen" wrongly costs one attempt;
    /// answering "remap" wrongly can crash the target, so the default leans on
    /// the recoverable side.
    ///
    /// Only one condition still routes straight to remap: a seatbelt profile
    /// that denies `file-map-executable`. That probe answers about the target's
    /// own sandbox and is reliable, and skipping the doomed `dlopen` is worth
    /// doing — a failed attempt permanently leaves a spinning mach thread and
    /// a few pages of shellcode in the target, which MachInjector deliberately
    /// does not reclaim.
    ///
    /// Library validation deliberately does *not* route here; see
    /// ``isLibraryValidationEnforced``.
    ///
    /// A target that has already exited answers `.machVirtualMemoryRemap`:
    /// `sandbox_check` reports "denied" for a pid it cannot find rather than
    /// signalling an error, so the seatbelt probe cannot tell that case apart
    /// from a real deny. It makes no practical difference — either path fails
    /// at `task_for_pid` on a dead target — so the behaviour is documented
    /// rather than worked around.
    static func initialAttempt(forTarget pid: pid_t, payloadPath: String) -> InjectionStrategy {
        if isFileMapExecutableBlocked(pid: pid, path: payloadPath) {
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

    /// Whether `pid` carries AMFI's `CS_REQUIRE_LV` code-signing flag.
    ///
    /// **This does not decide the injection path, and must not.** The flag says
    /// library validation was *requested* for the process; whether it is
    /// *enforced* depends on system state. Measured on macOS 26.5.2 with SIP
    /// disabled and no `amfi_get_out_of_my_way=1` boot argument: a process
    /// signed `--options library,runtime`, whose `csops` status reports
    /// `CS_REQUIRE_LV`, successfully `dlopen`ed unsigned, ad-hoc-signed, and
    /// foreign-Team-ID dylibs alike. A tampered dylib was still SIGKILLed in
    /// the same process, so code-signing enforcement was live — only library
    /// validation was not. Treating the flag as a prediction sent every Apple
    /// application down the remap path, which is how this stopped working.
    ///
    /// **Disabling SIP is not, by itself, what relaxes the enforcement.**
    /// `amfid` only consults
    /// `/Library/Preferences/com.apple.security.libraryvalidation.plist` once
    /// SIP is off (or the machine is Apple-internal); the actual switch is that
    /// file's `DisableLibraryValidation` value. SIP off with the key unset —
    /// the default — still enforces library validation. The measurement above
    /// therefore pins down a machine with *both* conditions met, not just SIP
    /// off, and an earlier version of this comment got that wrong.
    ///
    /// Which is why a target reaching this probe can go either way. The
    /// `task_for_pid` needed to get here already implies SIP is off, but the
    /// plist value varies per machine and is invisible from this flag. The path
    /// has to come from attempting a `dlopen`, never from this predicate.
    ///
    /// Kept because it still explains *why* a target refused a `dlopen`, which
    /// makes for a far better error message than the refusal alone. Returns
    /// `false` when the status cannot be read.
    static func isLibraryValidationEnforced(pid: pid_t) -> Bool {
        var codeSigningStatus: UInt32 = 0
        guard HelperProcessProbeCodeSigningStatus(pid, &codeSigningStatus) == 0 else {
            return false
        }
        return codeSigningStatus & HelperProcessProbeCodeSigningRequiresLibraryValidation != 0
    }
}
#endif
