# Changelog

All notable changes to this package are documented here. Versions follow
[Semantic Versioning](https://semver.org); while the package is pre-1.0, a minor bump may carry
source-breaking changes.

This file starts at 0.2.0. Earlier releases are not covered.

## [Unreleased]

### Fixed

- **The endpoint registry no longer grows forever.** A sub-server or peer that exited used to leave
  its `XPCEndpoint` in `MainService`'s registry, so the next client to look it up received a handle
  it could never connect to. Entries are now evicted when the process that registered them exits.

  `RegisterEndpointRequest` gained an optional `registrantProcessIdentifier`, filled in by the
  `registerEndpoint` behaviour extension rather than by callers. It is optional on purpose: a peer
  built before this field existed sends a message without it, which decodes to `nil` and leaves
  that one entry with the old grows-only behaviour instead of failing the registration.

### Removed

- **`HelperService.run()` is gone.** Nothing ever called it and every implementation was an empty
  `{}`. Removing a protocol requirement does not break conforming types — a leftover `run()` on
  your service still compiles, it is simply no longer an override. Only a direct `service.run()`
  call would break, and there were none.
- **`HelperTool` is gone.** Dead `package` actor with no references; never part of the public API.
  Not to be confused with `pingHelperTool()` / `isPrivilegedHelperTool`, which are live.

### Changed

- **`HelperServerType.plain(name:identifier:)` → `.plain(identifier:)`.** The `name` was never
  read: `HelperServer` destructured the case as `case .plain(_, let identifier)`, and the registry
  key's `name` has always come from `connectToTool(machServiceName:)`.

  Construction keeps working through a deprecated static factory, so existing call sites compile
  with a warning:

  ```
  'plain(name:identifier:)' is deprecated: The name was never read; use .plain(identifier:) instead
  ```

  **Pattern matching does break**, and no deprecation can soften it. A downstream that destructures
  the case sees:

  ```
  error: tuple pattern has the wrong length for tuple type '(identifier: String)'
  ```

  Fix by dropping the first binding: `case .plain(let identifier)`.

- `MainService`'s process monitors run on a private serial queue instead of `.main`.

## [0.3.1] — 2026-08-11

### Changed

- **The MachInjector requirement is now `from: "0.5.0"`, up from `0.4.3`.** 0.4.3 crashes the target
  on the `mach_vm_remap` path: it copied the payload as it looked *after* the injector's own
  `dlopen`, so process-private state the Swift/ObjC runtime had written into `__DATA` (generic
  metadata caches, `swift_once` flags, realized-class records) travelled into the target. Chained
  fixups do not cover those words, so the injector's own pointers arrived intact in another process.
  MachInjector 0.5.0 fixes it by restoring the payload's writable segments from its file before the
  remap, and additionally reports a target killed mid-load instead of claiming success.

  In practice a package resolving `swift-helper-service` 0.3.0 already got MachInjector 0.5.0,
  because `from: "0.4.3"` is up-to-next-major and 0.5.0 was the newest 0.x — this release makes the
  floor say what we actually require, rather than leaving a resolution that lands on 0.4.3 possible.
  **A downstream that pins MachInjector to 0.4.x will now fail to resolve.** That is the intent: the
  alternative is running the remap path with a known crash in it.

  `InjectionService` keeps its own liveness check (`kill(pid, 0)` plus `ESRCH`) rather than relying
  on MachInjector's new error code for the same condition. The check is pure POSIX and depends on
  nothing upstream.

## [0.3.0] — 2026-08-11

### Changed

- **Service errors keep their description across the XPC boundary.** Anything a service threw used
  to reach the caller as domain + code and nothing else: SwiftyXPC moves errors as
  `XPCErrorRegistry.BoxedError`, which only carries the full body for errors that are
  `Error & Codable`. `NSError` is not, so `userInfo` — `localizedDescription` included — was dropped
  at the encoding stage. Handlers now wrap non-`Codable` failures in `HelperServiceFailure`, so a
  caller sees what actually went wrong (for a refused injection, `dlerror`'s text). Every existing
  service benefits without a line of change, because the wrapping sits at the transport layer.

  **Source-breaking at runtime, not at compile time.** `(error as NSError).domain` becomes
  `"com.JH.HelperCommunication.ServiceFailure"` for errors originating in a service. The compiler
  will not flag this. Code that branches on the domain:

  ```swift
  // Before
  if (error as NSError).domain == "MIMachInjectorErrorDomain" { … }
  // After
  if let failure = error as? HelperServiceFailure,
     failure.underlyingErrorDomain == "MIMachInjectorErrorDomain" { … }
  ```

  `(error as NSError).code` is **unchanged** — `HelperServiceFailure` forwards the original code
  through `CustomNSError.errorCode`.

  **Both ends must be on 0.3.0 to see descriptions.** A client that predates this release has not
  registered the error domain, so it decodes back to a bare box: it sees the new domain, the
  original code, and still no description.

- **`InjectionService` logs to the daemon's `os.Logger`.** A failed injection used to leave no trace
  at either end. It now records the target pid, payload path, chosen strategy, the full text of a
  refused `dlopen`, and every error it raises, under subsystem
  `com.JH.HelperService.InjectionService`. The transport layer logs handler failures generally,
  under `com.JH.HelperCommunication`.

### Added

- `HelperServiceFailure` (in `HelperCommunication`) — the wire form of a service-side failure,
  carrying the original domain, code, `localizedDescription`, `String(describing:)`, and the
  `Request.identifier` that failed. `HelperClient`, `HelperPeerClient` and `HelperPeerServer`
  register it for decoding from their initializers; callers do not have to.
- `Documentations/Guides/InjectionPrerequisites.md` — the host-machine state injection depends on.
  Notably: **disabling SIP does not disable library validation.** The real switch is
  `DisableLibraryValidation` in `/Library/Preferences/com.apple.security.libraryvalidation.plist`;
  turning SIP off only permits `amfid` to read that file. The 0.2.0 note below records its test
  environment as "SIP disabled and no `amfi_get_out_of_my_way`" without this qualifier — on a
  machine where SIP is off but that key was never written, library validation is still enforced.

### Known issues

- **`HelperClient.errorIndicatesOutdatedPeer(_:)` cannot fire, and never could.** Uncovered by this
  release's tests, but present since the discriminator was introduced. SwiftyXPC throws
  `XPCConnection.Error.unexpectedMessage` in exactly one place, and that path reports it to the
  *receiving* process's own error handler without replying to the sender; the caller times out and
  sees `XPCError.connectionInterrupted` instead. So `fetchToolVersion()`'s "tool is outdated,
  reinstall" branch reads an old daemon as a transient failure. Unaffected by the error-wrapping
  change, and tracked separately.

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
