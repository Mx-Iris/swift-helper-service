# AGENTS.md

Guidance for coding agents working in this repository. `CLAUDE.md` is a symlink to this file — edit
`AGENTS.md`, not the symlink.

## Purpose

`swift-helper-service` is a Swift Package that eliminates boilerplate when building a macOS privileged helper tool installed via `SMAppService.daemon(plistName:)`. It provides a typed, async/await-based XPC framework on top of `SwiftyXPC`, plus a discovery/endpoint-registry pattern so a single privileged helper can broker connections to any number of additional XPC servers.

**This file is a lookup table, not an explanation.** For *why* the design is shaped this way — the topology, the module split, the visibility rules, the peer handshake — read [`Documentations/Architecture/Overview.md`](Documentations/Architecture/Overview.md) first; the sibling documents go deeper per area. Decision history lives in [`Documentations/Evolutions/`](Documentations/Evolutions/README.md).

## Build & Test

- Always run `swift package update` before building (per global instructions). The `.build/checkouts` copy has been observed lagging behind `Package.resolved` — reading a stale dependency there once produced a wrong conclusion that shaped an entire design; see Evolution 0001's 决策日志.
- Build the whole package: `swift build 2>&1 | xcsift`
- Build a specific product: `swift build --product HelperClient 2>&1 | xcsift`
- Tests: **`swift test` — judge the result by its exit code. Never by `xcsift`'s summary.** xcsift 1.0.21 does parse swift-testing, but discards that whole batch of results as soon as any swift-testing test fails, including the ones that passed: the summary becomes `"status": "success"`, `"failed_tests": 0`. XCTest results are parsed correctly, so in a mixed target their `passed_tests` / `test_time` keep the summary looking healthy while a swift-testing failure is swallowed. There is no usable tell — a green summary looks identical whether the run was genuinely green or swift-testing blew up. xcsift's own exit code is always 0 as well, even when it does report `"status": "failed"`, so nothing may short-circuit on that either. Piping through xcsift remains useful for *build* diagnostics, which it parses correctly. Verified on macOS 26.5.2 / xcsift 1.0.21 across all four combinations of framework and outcome.
- **Test coverage is narrow — do not mistake a green run for a verified system.** There are five test targets: `HelperCommunicationTests` (`Codable` round-trips, identifier namespacing, `HelperClient.errorIndicatesOutdatedPeer(_:)`, and the error-transport round trips), `InjectionServiceTests` (the injection strategy probes plus `InjectApplicationRequest`'s wire format), `MainServiceTests` (registry eviction, driven by real child processes exiting), `HelperPeerTests` (transport selection, port derivation, framing, the two-phase lifecycle, and **real loopback round trips** between two channels), and `HookKitTests` (candidate-spelling resolution, encoding mismatch reporting, batch atomicity, the activity reporter). **`HelperServer`, `HelperClient`, and the `HelperPeer` XPC handshake have no tests at all** (the socket transport does), and nothing in this repository ever performs a real injection. See the 验证覆盖与缺口 section of [Evolution 0001](Documentations/Evolutions/0001-injection-strategy-attempt-not-predict.md).
- **`ServiceFailureTransportTests` is the only test that puts a message on a real XPC connection**, via an anonymous `XPCListener` the test process connects back to. Reach for that pattern before assuming something cannot be tested end to end — the transport bug Evolution 0002 fixed, and the dead `errorIndicatesOutdatedPeer(_:)` discriminator it uncovered, both survived precisely because every earlier test checked `Codable` shapes in isolation.
- Swift toolchain: 6.2; platforms declared in `Package.swift` are macOS 10.15+ / macCatalyst 13+. Newer APIs are gated per call site with `@available` rather than by raising the package minimum (`SMAppServiceDaemonInstaller` → macOS 13, `ApplicationsService` → macOS 12, the remap injection path → macOS 11). Almost every source file is wrapped in `#if os(macOS) || targetEnvironment(macCatalyst)`; the two AppKit-dependent services (`ApplicationsService`, `InjectedEndpointRegistryService`) use a bare `#if os(macOS)` to exclude macCatalyst. `canImport(AppKit)` appears only in the test targets, never in `Sources/`. The macCatalyst surface is intentionally minimal — it exists so shared code compiles, not as a supported target.

## Architecture (the part that requires reading multiple files)

The framework models a **two-tier privileged XPC topology**:

1. **The privileged "tool"** (installed via `SMAppService.daemon(plistName:)`, running as root): a `HelperServer` whose listener is `.machService(name:)`. It always hosts the package-internal `MainService`, which is an *endpoint registry* — not feature logic. The tool brokers introductions and then leaves the conversation; business messages do not pass through it.
2. **One or more non-privileged "servers"** (`HelperServerType.plain(identifier:)`): each opens an *anonymous* `XPCListener`, then connects back to the tool and calls `RegisterEndpointRequest` to publish its `XPCEndpoint` under a `HelperServerInfo`. The registry key's `name` half comes from the `machServiceName` passed to `connectToTool`, which is why the case carries only the identifier. `RegisterEndpointRequest` also carries the registrant's pid (filled in by the `registerEndpoint` behaviour extension, never by callers) so the registry can evict the entry when that process exits.

Clients connect through the same chain:
- `HelperClient.daemonInstaller(plistName:)` → an `SMAppServiceDaemonInstaller` actor. There is no `installTool(name:)` / `SMJobBless` path any more; it was removed in `ab34cb8`.
- `HelperClient.connectToTool(...)` → mach-service connection, validated by `PingRequest`.
- `HelperClient.availableServerInfos()` → `ListServerInfosRequest` against `MainService`.
- `HelperClient.connectToServer(info:)` → `FetchEndpointRequest` returns an `XPCEndpoint`; the client opens `.remoteServiceFromEndpoint(endpoint)` and stores the connection keyed by `HelperServerInfo`.
- `sendToTool(request:)` vs `sendToServer(request:for:)` route to the correct connection.

This is why the registry-related request types (`FetchEndpointRequest`, `ListServerInfosRequest`, `RegisterEndpointRequest`) are `package` and re-exported only by `HelperCommunication` — they are internal plumbing, not part of the public API surface.

### Module layout and why each exists

- `HelperCommunication` — shared message-protocol layer. Defines `Request` (with `associatedtype Response`, `static var identifier: String`), `VoidResponse`, `PingRequest`, `FetchVersionRequest`, the registry requests, `HelperServiceFailure` + `ServiceFailureTransport` (see Error transport below), and `SwiftyXPC` extensions that adapt the untyped XPC API to the `Request`/`Response` protocol. Also defines four **`package`** behaviour extensions on `SwiftyXPC.XPCConnection` (`pingHelperTool`, `registerEndpoint`, `fetchEndpoint`, `listHelperServerInfos`) that in-package code should use *instead of* constructing the registry request types directly. These are not `public` — outside the package, the entry point is `HelperClient`'s own methods.
- `HelperService` — protocol-only target, a few dozen lines. Defines `HelperService`, `HelperHandler`, `HelperServerType`, and `XPCHelperHandler` — a struct wrapping a `SwiftyXPC.XPCListener` whose *type* is `public` (external `HelperService` implementations receive one) but whose storage and initializer are `package` (so `SwiftyXPC` does not leak through the public surface). It is a wrapper, **not** a retroactive `XPCListener: HelperHandler` conformance. Both `HelperServer` and `HelperPeer` mount services through it, which is what lets one service implementation run in either topology unchanged. Anything that plugs into a server or a peer depends only on this target.
- `HelperServer` — the actor that owns the `XPCListener`, prepends `MainService` to the user-supplied services, calls `setupHandler` on each, and (for `.plain` servers) registers its endpoint with the tool. Must be linked into the helper binary. `init` takes a `version:` parameter that is surfaced through `MainService`'s `FetchVersionRequest` handler, and an optional `codeSigningRequirement:`. **The requirement defaults to `nil`, which accepts any process on the machine** — fine for a tool only its own app talks to, wrong for a shared one. It is fixed at listener construction, so switching it means restarting the daemon. `HelperPeer`'s three anonymous listeners keep `nil` on purpose: the peer is whatever third-party process the payload landed in, and its signature cannot be known ahead of time.
- `HelperClient` — the actor used by the host app. Owns the tool connection and a dictionary of per-server connections, plus the `SMAppService.daemon(plistName:)` installer (`SMAppServiceDaemonInstaller`, `@available(macOS 13, *)`), `fetchToolVersion()` against `MainService`, and the `HelperClient.errorIndicatesOutdatedPeer(_:)` discriminator for callers that need to distinguish "outdated tool binary" from transient XPC failures.
- `HelperPeer` — abstraction layer for the *brokered peer* topology (`host ↔ broker ↔ peer process`). `HelperPeerClient` and `HelperPeerServer` (both `actor`s conforming to `PeerConnection`) handle the anonymous-listener / endpoint-register / reverse-connect / reconnect handshake that previously had to be reimplemented per project. State changes are surfaced through `AsyncStream<PeerConnectionState>` — the module is intentionally UI-framework-agnostic, with no Combine / Observation dependency. Business handlers are mounted via `services: [HelperService]` (same protocol as `HelperServer`).

  **A sandboxed target cannot use any of that**, because its `mach-lookup` of the tool is denied, so `PeerTransportSelection` picks between the brokered XPC path and a loopback socket (`PeerSocketChannel`) — and on the socket path **the roles invert: the host listens and the payload dials out**, because nothing can discover a port a sandboxed process bound. The port is derived identically on both sides by `PeerPortDerivation` (djb2, *not* `Hasher`, whose per-process seed would have them compute different ports). See [BrokeredPeer.md](Documentations/Architecture/BrokeredPeer.md) 第七节.
- `Sources/HelperServices/MainService` — the registry implementation that sits inside the tool. Owns the endpoint registry plus the `FetchVersionRequest` handler. Entries are evicted when the process that registered them exits, via a `DispatchSourceProcess` per registrant pid (its own serial queue, not `.main` — the handler only hops into the actor, and depending on `.main` would make eviction unobservable wherever that queue is not serviced). A registrant that reports no pid — an older peer, since the field is additive and optional — keeps the original grows-only behaviour for its entry. Re-registering an identifier from a new pid detaches it from the old monitor first, so a crashed-and-restarted sub-server does not get evicted by its own predecessor's exit.
- `Sources/HelperServices/{Files,Applications,InjectedEndpointRegistry}Service` — the other bundled services. `FilesService` is the minimal example of the Interface/Implementation shape; `ApplicationsService` (`@available(macOS 12, *)`, AppKit, so `#if os(macOS)`) launches apps and terminates them when the caller PID exits; `InjectedEndpointRegistryService` keeps injected processes' endpoints keyed by pid, with per-pid `DispatchSourceProcess` cleanup.
- **Pre-injection guards.** Before either injection path runs, `InjectionService` refuses three things, each because its natural failure mode points somewhere else: a payload built for a **different platform** (`MachOPlatform`), a payload with **no slice for the architecture the target executes** (`MachOArchitecture`), and a payload whose **code signature does not validate**. The last two are new; the architecture one is the most valuable, because an arm64e process refusing an arm64-only library reads like a missing file, and on the remap path it kills the target instead. **Unreadable input passes every one of them** — a guard that blocks when it cannot see clearly turns every unparseable file into a failed injection — and an *unsigned* payload passes too, since ad hoc binaries are ordinary in development and gatekeeping belongs to the listener's requirement. Which slice a target executes is an **inference** (the kernel grades arm64e above arm64), not an observation; `preferredExecutingArchitecture(from:)` is split out so that grading can be tested without needing a binary of every shape.
- `Sources/HelperProcessProbe` — C target wrapping the two pieces of kernel SPI that answer "would this process accept that dylib": `sandbox_check` (variadic, so the call must be emitted by the C compiler) and `csops` (SPI with no Swift-importable declaration). Used only by `InjectionServiceImplementation`, which composes them into `InjectionStrategy.initialAttempt(forTarget:payloadPath:)`. A support target, not a service — it has no Interface/Implementation split because it crosses no XPC boundary.

  **`isLibraryValidationEnforced` must not decide the injection path.** It reports whether the target carries `CS_REQUIRE_LV`, which says library validation was *requested*, not that it is *enforced*. Enforcement turns on two pieces of machine state that the flag cannot see: **SIP has to be off *and* `/Library/Preferences/com.apple.security.libraryvalidation.plist` has to carry `DisableLibraryValidation`.** Disabling SIP alone does not lift enforcement — it only lets `amfid` read that file. Routing on the flag sent every Apple application to the remap path, which is the path that can crash the target. Keep it for explaining *why* a `dlopen` was refused; see [Evolution 0001](Documentations/Evolutions/0001-injection-strategy-attempt-not-predict.md) (and its 后记, which corrects 0001's SIP premise), [Guides/InjectionPrerequisites.md](Documentations/Guides/InjectionPrerequisites.md), and the `library validation` entry in [Glossary.md](Documentations/Glossary.md).

  `InjectionServiceImplementation` is `@Loggable` under subsystem `com.JH.HelperService.InjectionService` — it records the pid, payload path, chosen strategy, a refused `dlopen`'s full text, and every error it raises. The subsystem is spelled out because a daemon has no bundle for `@Loggable` to infer one from. Read it with `log stream --predicate 'subsystem == "com.JH.HelperService.InjectionService"' --level info`.
- `Sources/HelperServices/<Name>Service/{Interface,Implementation}` — **every concrete service is split into two targets**. The Interface target exposes only the `Request`/payload types and depends only on `HelperCommunication`; the Implementation target conforms to `HelperService` and pulls in heavyweight dependencies (e.g., `MachInjector`). The client app links the Interface; the helper binary links the Implementation. **New services must follow this split** — don't add types that bridge across the boundary.

### Request/Response convention

To add a new operation:
1. In the service's `Interface` target, declare a `struct FooRequest: Codable, Request` with `typealias Response = VoidResponse` (or a custom `Codable & Sendable` struct), and a stable `static let identifier: String` (existing identifiers use the `com.JH.<area>.<Name>` convention).
2. In the service's `Implementation` target, the `HelperService.setupHandler(_:)` body calls `handler.setMessageHandler { (request: FooRequest) -> FooRequest.Response in ... }`. The `setMessageHandler` overload on `HelperHandler` uses the `Request.identifier` to register the handler — never call SwiftyXPC's untyped APIs directly from feature code.

### Concurrency

- All long-lived components (`HelperClient`, `HelperServer`, `MainService`, every concrete service) are `actor`s.
- `SwiftyXPC` is imported `@preconcurrency`; `XPCListener` is declared `@retroactive @unchecked Sendable` in `HelperServer.swift`. Preserve those imports/declarations when editing — removing them breaks Swift 6 strict concurrency.
- `HelperService` instances must be `Sendable`; the protocol requires it.

## Conventions specific to this repo

- Module visibility is deliberate: prefer `package` for cross-target plumbing, `public` only for things the host app or helper binary calls. **The registry request types (`FetchEndpointRequest` / `RegisterEndpointRequest` / `ListServerInfosRequest`) and `HelperServerInfo.init` are intentionally `package`** — their semantics rest on the invariant that there is exactly one registry and it lives in `MainService`, which stops holding if callers can send those messages anywhere. In-package code goes through the `XPCConnection+MainService.swift` behaviour extensions (`pingHelperTool` / `registerEndpoint` / `fetchEndpoint` / `listHelperServerInfos`), which are themselves `package`, not `public`; outside the package the entry point is `HelperClient`. Do not loosen the request types to `public` — add a behaviour method instead. Rationale in [ModuleLayering.md](Documentations/Architecture/ModuleLayering.md).
- `MainService` is added by `HelperServer.init` automatically — do not register it manually, and do not add other services with overlapping request identifiers.
- Two product names exist for split services (`InjectionService` aggregates both Interface and Implementation; `InjectionServiceInterface` / `InjectionServiceImplementation` expose them individually). When adding a new service, mirror this product layout in `Package.swift` so client apps can pick the minimal dependency set.
- Existing identifier strings use `com.JH.*`. `HelperCommunication` reserves `com.JH.HelperCommunication.*`; `HelperPeer` reserves `com.JH.HelperPeer.*`; concrete `HelperServices/<Name>Service` reserve `com.JH.HelperService.<Name>.*`. Keep that prefix for new identifiers unless the user explicitly changes the namespace.
- **`HelperPeerClient` / `HelperPeerServer` and `HelperServer` are two-phase: `init` does nothing on the wire, `activate()` performs the handshake.** Callers must install every business handler between the two (or pass them as `services:` to `init`). Folding the handshake into `init` reintroduces a race in which the peer's first business message arrives before its handler exists and is silently dropped. Preserve this split; see [BrokeredPeer.md](Documentations/Architecture/BrokeredPeer.md).

## Known rough edges

Found by reading the source; recorded so they are not mistaken for intent. None is currently
load-bearing, but all four will surprise you if you touch the surrounding code. Changing any of them
is a source-breaking change and needs a proposal.

| Where | What |
|---|---|
| `HelperClient.errorIndicatesOutdatedPeer(_:)` | **Cannot return `true`, and never could.** Kept deliberately as a sentinel — see Versioning below. |

Four more were cleaned up in the `draft-shared-injection-daemon` proposal's first batch and are
no longer rough: `HelperServerType.plain`'s unread `name` (now `.plain(identifier:)`, with the old
spelling kept as a deprecated static factory), the uncalled `HelperService.run()` requirement, the
dead `HelperTool` actor, and `MainService`'s grows-only registry (it now hangs a
`DispatchSourceProcess` off the registrant's pid, matching `InjectedEndpointRegistryService`).

Error handling is also inconsistent: `HelperServer` / `HelperPeer*` use `@Loggable` + `#log`, while
`HelperClient` and `MainService` use bare `print(error)`. Note this is about *connection-level*
error handlers — failures thrown out of message handlers are logged uniformly by
`ServiceFailureTransport`, see below.

## Error transport

**Service-side errors are wrapped before they cross XPC. Do not undo this by catching in a service.**

`ServiceFailureTransport.wrappingFailures(requestIdentifier:operation:)` wraps every message
handler the package installs. A failure that is not already `Error & Codable` becomes a
`HelperServiceFailure` and gets logged on the daemon side; one that *is* `Codable` is rethrown
untouched. Without the wrapping, SwiftyXPC's `BoxedError` carries only `domain` and `code` and the
description is lost at the encoding stage — see
[TypedMessaging.md](Documentations/Architecture/TypedMessaging.md) 第六节 and
[Evolution 0002](Documentations/Evolutions/0002-service-errors-that-survive-xpc.md).

Three things must not be broken when touching this:

- **`HelperServiceFailure.errorDomain` is wire format**, like `Request.identifier`. Changing it makes
  both ends fall back to a bare box — silently, with no compile error. Fields are add-only, and new
  ones must be `Optional` or defaulted.
- **The `Error & Codable` passthrough must stay.** `XPCConnection.Error` rides on it; wrapping that
  type would make `errorIndicatesOutdatedPeer(_:)` answer `false` for everything.
- **Registration is the library's job**, done from `HelperClient.init` / `HelperPeerClient.init` /
  `HelperPeerServer.init`. Never push it onto callers: forgetting it degrades silently back to the
  old behaviour.

All 15 handler installation sites in `Sources/` are covered: 7 go through the typed baseline in
`XPCExtensions.swift` (`XPCHelperHandler`, `HelperPeer*`'s typed `setMessageHandler`, and the four
peer handshake handlers), and `HelperPeer*`'s 8 name-based `setMessageHandler` overloads wrap
individually because they call SwiftyXPC directly. **A new installation site that bypasses both must
do its own wrapping.**

## Versioning

- `HelperServer.init(serverType:version:services:)` requires a version string, and it **must be `major.minor.patch`** — that format is now part of the wire contract, see [WireCompatibility.md](Documentations/Architecture/WireCompatibility.md). `MainService` exposes it via `FetchVersionRequest` (`com.JH.HelperCommunication.FetchVersion`).
- **To find out whether a tool is too old, ask: `HelperClient.requireToolVersion(atLeast:)`.** It fetches the version, parses it into a `HelperToolVersion`, and throws `HelperToolVersionMismatch` when the tool is older or reports something unparseable. Do not compare the raw strings — `"0.10.0" < "0.9.0"` is `true`, and a test pins that trap.
- Host apps can still call `HelperClient.fetchToolVersion()` for the raw string, or `fetchToolVersionNumber()` for the parsed form. `HelperClient.errorIndicatesOutdatedPeer(_:)` is meant to tell "tool is outdated, reinstall" apart from transient XPC failures, and returns `true` only for `SwiftyXPC.XPCConnection.Error.unexpectedMessage`.
- **That discriminator cannot fire in practice — assume an outdated tool is indistinguishable from a dropped connection.** SwiftyXPC throws `unexpectedMessage` in exactly one place (`XPCConnection.respond(to:)`, on an unknown message name) and that path hands the error to the *receiving* process's own `errorHandler` and returns **without replying**. The caller waits, then gets `XPCError.connectionInterrupted`. So a tool predating `FetchVersionRequest` reads as a transient failure. Present since `a49e713`; found while writing Evolution 0002's round-trip tests, and pinned by `unhandledMessageDoesNotReachTheCallerAsUnexpectedMessage` — **if that test ever fails, upstream started replying and the discriminator can be trusted again.**

## Installation path

There is exactly one. The legacy `SMJobBless` flow (`installTool(name:)`, `kSMRightBlessPrivilegedHelper`) was removed in `ab34cb8` and no trace of it remains in `Sources/`.

- `HelperClient.daemonInstaller(plistName:)` — returns an `SMAppServiceDaemonInstaller` actor (`@available(macOS 13, *)`) wrapping `SMAppService.daemon(plistName:)`. Exposes `register()` / `unregister()` / `refresh()` / `openLoginItemsSettings()` plus a poll-free `statusStream: AsyncStream<SMAppService.Status>` that yields on every state-mutating call. The library does *not* bump its minimum platform — the gating is per-API via `@available`.

## Documentation

- **`Documentations/Architecture/` explains why the design looks like this.** [Overview.md](Documentations/Architecture/Overview.md) is the entry point; [ModuleLayering.md](Documentations/Architecture/ModuleLayering.md), [TypedMessaging.md](Documentations/Architecture/TypedMessaging.md), [BrokeredPeer.md](Documentations/Architecture/BrokeredPeer.md), and [WireCompatibility.md](Documentations/Architecture/WireCompatibility.md) go deeper per area. **Read WireCompatibility before touching any `Request`, `identifier`, `errorDomain` or `rawValue`** — those are wire format, and breaking them produces no compile error. This file is the lookup table; those carry the reasoning. When the two disagree, the source wins — then fix both.
- `Documentations/Guides/` is for contracts a caller cannot infer from a signature. [InjectionPrerequisites.md](Documentations/Guides/InjectionPrerequisites.md) is the host-machine state injection depends on — **disabling SIP does not disable library validation**; the switch is `DisableLibraryValidation` in `/Library/Preferences/com.apple.security.libraryvalidation.plist`.
- `Documentations/README.md` is the index — **every new or renamed document must be registered there**.
- `Documentations/Evolutions/NNNN-*.md` holds one proposal per substantive change, covering its whole lifecycle from research to landing. Do not split a change into separate design / plan / report files. `Documentations/Evolutions/README.md` is the status table and declares the project kind (**library, source-distributed** — so proposals fill in source compatibility and write "not applicable" for ABI).
- `CHANGELOG.md` is public-facing and written in English. Record source-breaking changes explicitly, with the compiler error a downstream project will see.

## Dependencies worth knowing

- [`SwiftyXPC`](https://github.com/MxIris-macOS-Library-Forks/SwiftyXPC) — typed XPC wrapper; the only XPC API used.
- [`MachInjector`](https://github.com/MxIris-Reverse-Engineering/MachInjector) — used solely by `InjectionServiceImplementation`. **`Package.swift` declares `from: "0.5.0"`.** 0.4.3 was the release that made `MachInjector.inject` throw when the target refuses the payload instead of reporting success, which is what the `dlopen` → remap fallback keys off — but the floor is 0.5.0, not 0.4.3, because 0.4.3 carries a crash on the remap path: `mach_vm_remap` copied the payload as it looked *after* the injector's own `dlopen`, so process-private state the Swift/ObjC runtime had written into `__DATA` (generic metadata caches, `swift_once` flags, realized-class records) travelled into the target — not covered by chained fixups, so `apply_fixups()` could not repair it. Fixed in 0.5.0 by restoring writable segments from the payload file before the remap. Verify with `git tag --contains c89d0c1`.
  - 0.5.0 also made the *synchronous* path report a target killed mid-load (its code 29) rather than claiming success. `InjectionService.requireTargetIsStillRunning(pid:strategy:)` keeps its own check anyway — it is pure POSIX (`kill(pid, 0)` plus `ESRCH`) and depends on nothing upstream, whereas code 29 rests on a decision path with no real-machine record. **Do not delete our check in favour of code 29 until that path has been verified on real hardware.** The two agree except under pid reuse, where ours reports "alive" for a recycled pid and MachInjector's dead-name probe does not.
