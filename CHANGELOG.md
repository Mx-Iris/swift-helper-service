# Changelog

All notable changes to this package are documented here. Versions follow
[Semantic Versioning](https://semver.org); while the package is pre-1.0, a minor bump may carry
source-breaking changes.

This file starts at 0.2.0. Earlier releases are not covered.

## [0.2.0] — 2026-08-10

Supersedes the withdrawn 0.1.5 and carries everything it contained; see below.

### Changed

- **`InjectionService` attempts a `dlopen` instead of predicting whether the target would refuse
  one.** The withdrawn 0.1.5 read the target's `CS_REQUIRE_LV` code-signing flag through `csops` and
  routed every process carrying it — which is every Apple application — to the `mach_vm_remap` path.
  The flag being set does not mean AMFI library validation is *enforced*; whether it is depends on
  system state. Measured on macOS 26.5.2 with SIP disabled and no `amfi_get_out_of_my_way=1` boot
  argument, a process signed `--options library,runtime` loaded unsigned, ad-hoc-signed, and
  foreign-Team-ID dylibs alike, while a tampered dylib was still killed — so code-signing
  enforcement was live and only library validation was not. The daemon now runs the `dlopen` and
  falls back to remap only on an actual refusal, which
  [`MachInjector`](https://github.com/MxIris-Reverse-Engineering/MachInjector) 0.4.3 reports
  faithfully along with `dlerror`'s message. A seatbelt profile denying `file-map-executable` still
  routes straight to remap: that refusal is knowable up front, and a doomed attempt permanently
  leaves a spinning thread and a few pages of shellcode in the target.

- **The daemon chooses the injection path; clients no longer have to.** Whether a payload can be
  `dlopen`ed into a target or has to be projected in with `mach_vm_remap` depends on the target's
  seatbelt profile and code-signing status, which only the daemon is positioned to read. A client
  that needs to override the choice does so through `preferredStrategy` rather than by sending a
  different request type.

- **`InjectApplicationRequest` gained `remapEntrySymbol`** (optional), used only when the daemon
  takes the remap path, where dyld's constructor pass never runs and an exported
  `void *(*)(void *)` is the only way in.

- **`InjectionStrategy` lives in `InjectionServiceInterface`**, not `InjectionServiceImplementation`,
  and has `String` raw values, because it now travels on the wire. Targets already linking
  `InjectionServiceImplementation` see no change — `Interface` is one of its dependencies.

### Added

- **`InjectApplicationRequest.preferredStrategy`** — pins the injection path when the daemon's
  default is wrong for a specific target. Defaults to `nil`, meaning "the daemon decides", which is
  what nearly every caller should use. Pinning a path also disables the automatic fallback: a
  caller that asked for one path gets that path or an error, never the other one.

- **A liveness check after every injection.** A dylib whose page hashes do not match its signature
  is killed by the kernel on page-in, before `dlopen` ever returns — so the injector's report block
  stays `Pending`, which is indistinguishable from a slow load and is treated as success. The
  service now fails with `code -3` when the target is gone after an injection that reported
  success.

- `HelperProcessProbe`, a C target wrapping the `sandbox_check` and `csops` kernel SPI.

### Fixed

- `OutdatedPeerTests` called `XPCConnection.Error.indicatesOutdatedPeer`, an API that was renamed
  to `HelperClient.errorIndicatesOutdatedPeer(_:)` without the test being updated. The test target
  had not compiled since.

### Removed

- **`InjectApplicationViaRemapRequest` (source-breaking).** Clients no longer pick a path by
  choosing a request type. Projects still referencing it fail to compile with
  `cannot find 'InjectApplicationViaRemapRequest' in scope`; send an `InjectApplicationRequest`
  instead, with `remapEntrySymbol` set, and `preferredStrategy: .machVirtualMemoryRemap` if the path
  must be pinned.

- **`InjectionStrategy.forTarget(pid:payloadPath:)`** — replaced by
  `InjectionStrategy.initialAttempt(forTarget:payloadPath:)`. This is a rename *and* a change of
  meaning: the old name promised the path to use, the new one only promises the path to try first.
  No `@available(*, deprecated, renamed:)` shim is provided, because a caller that kept compiling
  would silently be reading a different guarantee. The old name only ever existed in the withdrawn
  0.1.5.

## [0.1.5] — Withdrawn

**The `0.1.5` tag has been deleted and must not be used.** It routed every Apple application to the
`mach_vm_remap` path on the strength of the `CS_REQUIRE_LV` flag, which made injection fail — or
crash the target — on exactly the machines where injection is possible at all, and it removed the
means for a client to work around that. Its commits are part of this repository's history and ship
as part of 0.2.0, with the routing corrected; nothing is lost by upgrading straight past it.

Projects pinned to `exact: "0.1.5"` or resolving `from: "0.1.5"` no longer resolve. Move to 0.2.0.
