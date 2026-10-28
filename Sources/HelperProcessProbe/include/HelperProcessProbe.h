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

// The mach-lookup probe that used to sit here moved to swift-injection-peer as
// `PeerProcessProbeSandboxCheckMachLookup`. It answered "can a payload in that
// process reach the daemon over XPC at all", which is a question about the
// channel rather than about the injection path — and this library no longer owns
// the channel.

/// `CS_REQUIRE_LV` — set when the process enforces AMFI library validation.
extern const uint32_t HelperProcessProbeCodeSigningRequiresLibraryValidation;

#endif /* HelperProcessProbe_h */
