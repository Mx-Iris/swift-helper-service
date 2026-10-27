//
//  HelperProcessProbe.h
//  swift-helper-service
//
//  Thin C wrappers over the kernel SPI needed to ask "would this process be
//  allowed to load that dylib". Both answers gate the choice of injection
//  path, and neither is reachable from Swift directly.
//

#ifndef HelperProcessProbe_h
#define HelperProcessProbe_h

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

/// Asks `pid`'s sandbox whether it would permit `operation` on `path` — e.g.
/// `"file-map-executable"`, the predicate a strict seatbelt profile uses to
/// refuse `dlopen` of anything outside its whitelist.
///
/// Lives in C because `sandbox_check` is variadic: the arm64 variadic ABI
/// passes variadic arguments on the stack, which cannot be expressed through
/// Swift's `@convention(c)` function pointers, so the call must be emitted by
/// the C compiler.
///
/// Returns `0` when permitted (including for an unsandboxed process), a
/// positive value when the sandbox denies it, and `-1` on error. Note that a
/// pid the kernel cannot find answers "denied" rather than reporting an error.
int HelperProcessProbeSandboxCheckPath(pid_t pid, const char *operation, const char *path);

/// Reads `pid`'s code-signing status word into `outStatus` — the `CS_*` flag
/// set, of which `CS_REQUIRE_LV` (AMFI library validation) decides whether the
/// process would accept a dylib that is neither Apple-signed nor signed with
/// its own Team ID.
///
/// Lives in C because `csops` is SPI with no Swift-importable declaration.
/// Readable for any pid, including processes owned by another user.
///
/// Returns `0` on success and `-1` when the status could not be read (an
/// unknown or exited pid, most commonly).
int HelperProcessProbeCodeSigningStatus(pid_t pid, uint32_t *outStatus);

/// Asks `pid`'s sandbox whether it would permit looking up the Mach service
/// `globalName` — the question that decides whether an injected payload can
/// reach the daemon over XPC at all.
///
/// Two unrelated sandbox flavours answer "no", which is why this probes rather
/// than sniffing entitlements: App Sandbox apps run a `(deny default)` profile
/// whose `mach-lookup` allowlist will not contain a third-party service, and
/// seatbelt-profiled system daemons are equally closed while carrying no
/// `com.apple.security.app-sandbox` entitlement to notice.
///
/// Same return convention as the path check: `0` permitted (including for an
/// unsandboxed process), positive denied, `-1` on error. Callable for any pid,
/// including `getpid()`, so a host and the payload inside its target reach the
/// same conclusion about that target.
int HelperProcessProbeSandboxCheckMachLookup(pid_t pid, const char *globalName);

/// `CS_REQUIRE_LV` — set when the process enforces AMFI library validation.
extern const uint32_t HelperProcessProbeCodeSigningRequiresLibraryValidation;

#endif /* HelperProcessProbe_h */
