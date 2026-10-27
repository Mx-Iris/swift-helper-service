//
//  HelperProcessProbe.c
//  swift-helper-service
//

#include "HelperProcessProbe.h"

// `sandbox_check` and `csops` are SPI (declared in the private <sandbox.h> and
// <sys/codesign.h>). Declare the prototypes locally rather than importing the
// private headers.
extern int sandbox_check(pid_t pid, const char *operation, uint32_t type, ...);
extern int csops(pid_t pid, uint32_t ops, void *useraddr, size_t usersize);

// Values from the private sandbox headers.
#define HelperProcessProbeSandboxFilterPath 1u
#define HelperProcessProbeSandboxFilterGlobalName 2u
#define HelperProcessProbeSandboxCheckNoReport 0x40000000u

// Values from the private code-signing headers.
#define HelperProcessProbeCodeSigningOperationStatus 0u

const uint32_t HelperProcessProbeCodeSigningRequiresLibraryValidation = 0x00002000u;

int HelperProcessProbeSandboxCheckPath(pid_t pid, const char *operation, const char *path) {
    // NO_REPORT suppresses the sandbox-violation log a plain probe would emit.
    return sandbox_check(pid,
                         operation,
                         HelperProcessProbeSandboxFilterPath | HelperProcessProbeSandboxCheckNoReport,
                         path);
}

int HelperProcessProbeCodeSigningStatus(pid_t pid, uint32_t *outStatus) {
    uint32_t status = 0;
    if (csops(pid, HelperProcessProbeCodeSigningOperationStatus, &status, sizeof(status)) != 0) {
        return -1;
    }
    if (outStatus != NULL) {
        *outStatus = status;
    }
    return 0;
}

int HelperProcessProbeSandboxCheckMachLookup(pid_t pid, const char *globalName) {
    return sandbox_check(pid,
                         "mach-lookup",
                         HelperProcessProbeSandboxFilterGlobalName | HelperProcessProbeSandboxCheckNoReport,
                         globalName);
}
