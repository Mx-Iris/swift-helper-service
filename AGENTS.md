# AGENTS.md

Guidance for coding agents working in this repository. `CLAUDE.md` is a symlink to this file — edit
`AGENTS.md`, not the symlink.

## Purpose

`swift-helper-service` is a Swift Package that eliminates boilerplate when building a macOS privileged helper tool installed via `SMAppService.daemon(plistName:)`. It provides a typed, async/await-based XPC framework on top of `SwiftyXPC`, plus a discovery/endpoint-registry pattern so a single privileged helper can broker connections to any number of additional XPC servers.

**This file is a lookup table, not an explanation.** For *why* the design is shaped this way — the topology, the module split, the visibility rules, the peer handshake — read [`Documentations/Architecture/Overview.md`](Documentations/Architecture/Overview.md) first; the three sibling documents go deeper per area. Decision history lives in [`Documentations/Evolutions/`](Documentations/Evolutions/README.md).

## Build & Test

- Always run `swift package update` before building (per global instructions). The `.build/checkouts` copy has been observed lagging behind `Package.resolved` — reading a stale dependency there once produced a wrong conclusion that shaped an entire design; see Evolution 0001's 决策日志.
- Build the whole package: `swift build 2>&1 | xcsift`
- Build a specific product: `swift build --product HelperClient 2>&1 | xcsift`
- Tests: **`swift test` — judge the result by its exit code. Never by `xcsift`'s summary.** xcsift 1.0.21 does parse swift-testing, but discards that whole batch of results as soon as any swift-testing test fails, including the ones that passed: the summary becomes `"status": "success"`, `"failed_tests": 0`. XCTest results are parsed correctly, so in a mixed target their `passed_tests` / `test_time` keep the summary looking healthy while a swift-testing failure is swallowed. There is no usable tell — a green summary looks identical whether the run was genuinely green or swift-testing blew up. xcsift's own exit code is always 0 as well, even when it does report `"status": "failed"`, so nothing may short-circuit on that either. Piping through xcsift remains useful for *build* diagnostics, which it parses correctly. Verified on macOS 26.5.2 / xcsift 1.0.21 across all four combinations of framework and outcome.
- **Test coverage is narrow — do not mistake a green run for a verified system.** There are exactly two test targets: `HelperCommunicationTests` (`Codable` round-trips, identifier namespacing, `HelperClient.errorIndicatesOutdatedPeer(_:)`) and `InjectionServiceTests` (the injection strategy probes plus `InjectApplicationRequest`'s wire format). **`HelperServer`, `HelperClient`, `MainService`, and the whole `HelperPeer` handshake have no tests at all**, and nothing in this repository ever performs a real injection. See the 验证覆盖与缺口 section of [Evolution 0001](Documentations/Evolutions/0001-injection-strategy-attempt-not-predict.md).
- Swift toolchain: 6.2; platforms declared in `Package.swift` are macOS 10.15+ / macCatalyst 13+. Newer APIs are gated per call site with `@available` rather than by raising the package minimum (`SMAppServiceDaemonInstaller` → macOS 13, `ApplicationsService` → macOS 12, the remap injection path → macOS 11). Almost every source file is wrapped in `#if os(macOS) || targetEnvironment(macCatalyst)`; the two AppKit-dependent services (`ApplicationsService`, `InjectedEndpointRegistryService`) use a bare `#if os(macOS)` to exclude macCatalyst. `canImport(AppKit)` appears only in the test targets, never in `Sources/`. The macCatalyst surface is intentionally minimal — it exists so shared code compiles, not as a supported target.

## Architecture (the part that requires reading multiple files)

The framework models a **two-tier privileged XPC topology**:

1. **The privileged "tool"** (installed via `SMAppService.daemon(plistName:)`, running as root): a `HelperServer` whose listener is `.machService(name:)`. It always hosts the package-internal `MainService`, which is an *endpoint registry* — not feature logic. The tool brokers introductions and then leaves the conversation; business messages do not pass through it.
2. **One or more non-privileged "servers"** (`HelperServerType.plain(name, identifier)`): each opens an *anonymous* `XPCListener`, then connects back to the tool and calls `RegisterEndpointRequest` to publish its `XPCEndpoint` under a `HelperServerInfo`. Note that `.plain`'s `name` associated value is **never read** — the registry key's `name` comes from the `machServiceName` passed to `connectToTool`.

Clients connect through the same chain:
- `HelperClient.daemonInstaller(plistName:)` → an `SMAppServiceDaemonInstaller` actor. There is no `installTool(name:)` / `SMJobBless` path any more; it was removed in `ab34cb8`.
- `HelperClient.connectToTool(...)` → mach-service connection, validated by `PingRequest`.
- `HelperClient.availableServerInfos()` → `ListServerInfosRequest` against `MainService`.
- `HelperClient.connectToServer(info:)` → `FetchEndpointRequest` returns an `XPCEndpoint`; the client opens `.remoteServiceFromEndpoint(endpoint)` and stores the connection keyed by `HelperServerInfo`.
- `sendToTool(request:)` vs `sendToServer(request:for:)` route to the correct connection.

This is why the registry-related request types (`FetchEndpointRequest`, `ListServerInfosRequest`, `RegisterEndpointRequest`) are `package` and re-exported only by `HelperCommunication` — they are internal plumbing, not part of the public API surface.

### Module layout and why each exists

- `HelperCommunication` — shared message-protocol layer. Defines `Request` (with `associatedtype Response`, `static var identifier: String`), `VoidResponse`, `PingRequest`, `FetchVersionRequest`, the registry requests, and `SwiftyXPC` extensions that adapt the untyped XPC API to the `Request`/`Response` protocol. Also defines four **`package`** behaviour extensions on `SwiftyXPC.XPCConnection` (`pingHelperTool`, `registerEndpoint`, `fetchEndpoint`, `listHelperServerInfos`) that in-package code should use *instead of* constructing the registry request types directly. These are not `public` — outside the package, the entry point is `HelperClient`'s own methods.
- `HelperService` — protocol-only target, a few dozen lines. Defines `HelperService`, `HelperHandler`, `HelperServerType`, and `XPCHelperHandler` — a struct wrapping a `SwiftyXPC.XPCListener` whose *type* is `public` (external `HelperService` implementations receive one) but whose storage and initializer are `package` (so `SwiftyXPC` does not leak through the public surface). It is a wrapper, **not** a retroactive `XPCListener: HelperHandler` conformance. Both `HelperServer` and `HelperPeer` mount services through it, which is what lets one service implementation run in either topology unchanged. Anything that plugs into a server or a peer depends only on this target.
- `HelperServer` — the actor that owns the `XPCListener`, prepends `MainService` to the user-supplied services, calls `setupHandler` on each, and (for `.plain` servers) registers its endpoint with the tool. Must be linked into the helper binary. `init` takes a `version:` parameter that is surfaced through `MainService`'s `FetchVersionRequest` handler.
- `HelperClient` — the actor used by the host app. Owns the tool connection and a dictionary of per-server connections, plus the `SMAppService.daemon(plistName:)` installer (`SMAppServiceDaemonInstaller`, `@available(macOS 13, *)`), `fetchToolVersion()` against `MainService`, and the `HelperClient.errorIndicatesOutdatedPeer(_:)` discriminator for callers that need to distinguish "outdated tool binary" from transient XPC failures.
- `HelperPeer` — abstraction layer for the *brokered peer* topology (`host ↔ broker ↔ peer process`). `HelperPeerClient` and `HelperPeerServer` (both `actor`s conforming to `PeerConnection`) handle the anonymous-listener / endpoint-register / reverse-connect / reconnect handshake that previously had to be reimplemented per project. State changes are surfaced through `AsyncStream<PeerConnectionState>` — the module is intentionally UI-framework-agnostic, with no Combine / Observation dependency. Business handlers are mounted via `services: [HelperService]` (same protocol as `HelperServer`).
- `Sources/HelperServices/MainService` — the registry implementation that sits inside the tool. Owns the endpoint registry plus the `FetchVersionRequest` handler. **The registry only grows**: there is no unregister path and no process monitor, so a sub-server or peer that exits leaves a dead `XPCEndpoint` behind for a client to trip over. `InjectedEndpointRegistryService` solves the same problem with a `DispatchSourceProcess` per entry; `MainService` has no equivalent.
- `Sources/HelperServices/{Files,Applications,InjectedEndpointRegistry}Service` — the other bundled services. `FilesService` is the minimal example of the Interface/Implementation shape; `ApplicationsService` (`@available(macOS 12, *)`, AppKit, so `#if os(macOS)`) launches apps and terminates them when the caller PID exits; `InjectedEndpointRegistryService` keeps injected processes' endpoints keyed by pid, with per-pid `DispatchSourceProcess` cleanup.
- `Sources/HelperProcessProbe` — C target wrapping the two pieces of kernel SPI that answer "would this process accept that dylib": `sandbox_check` (variadic, so the call must be emitted by the C compiler) and `csops` (SPI with no Swift-importable declaration). Used only by `InjectionServiceImplementation`, which composes them into `InjectionStrategy.initialAttempt(forTarget:payloadPath:)`. A support target, not a service — it has no Interface/Implementation split because it crosses no XPC boundary.

  **`isLibraryValidationEnforced` must not decide the injection path.** It reports whether the target carries `CS_REQUIRE_LV`, which says library validation was *requested*, not that it is *enforced* — on a SIP-disabled machine it is generally not. Routing on it sent every Apple application to the remap path, which is the path that can crash the target. Keep it for explaining *why* a `dlopen` was refused; see [Evolution 0001](Documentations/Evolutions/0001-injection-strategy-attempt-not-predict.md).
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
| `HelperServerType.plain(name:identifier:)` | The `name` associated value is **never read** (`HelperServer.swift` destructures it as `case .plain(_, let identifier)`). The registry key's `name` comes from `connectToTool(machServiceName:)` instead. |
| `HelperService.run()` | A protocol requirement that **nothing calls**; every implementation is an empty `{}`. Don't put startup work there expecting it to run. |
| `Sources/HelperCommunication/HelperTool.swift` | The `HelperTool` actor has **no references anywhere** — dead code. Not to be confused with `pingHelperTool()` / `isPrivilegedHelperTool`, which are live and unrelated. |
| `MainService`'s registry | **Only grows.** No unregister, no process monitor; entries for dead processes persist. |

Error handling is also inconsistent: `HelperServer` / `HelperPeer*` use `@Loggable` + `#log`, while
`HelperClient` and `MainService` use bare `print(error)`.

## Versioning

- `HelperServer.init(serverType:version:services:)` requires a version string. `MainService` exposes it via `FetchVersionRequest` (`com.JH.HelperCommunication.FetchVersion`).
- Host apps call `HelperClient.fetchToolVersion()`. When the running tool predates `FetchVersionRequest`, the call throws `SwiftyXPC.XPCConnection.Error.unexpectedMessage`; use `HelperClient.errorIndicatesOutdatedPeer(_:)` (only `true` for `.unexpectedMessage`, `false` for every other case, including non-SwiftyXPC errors) to distinguish "tool is outdated, reinstall" from transient XPC failures.

## Installation path

There is exactly one. The legacy `SMJobBless` flow (`installTool(name:)`, `kSMRightBlessPrivilegedHelper`) was removed in `ab34cb8` and no trace of it remains in `Sources/`.

- `HelperClient.daemonInstaller(plistName:)` — returns an `SMAppServiceDaemonInstaller` actor (`@available(macOS 13, *)`) wrapping `SMAppService.daemon(plistName:)`. Exposes `register()` / `unregister()` / `refresh()` / `openLoginItemsSettings()` plus a poll-free `statusStream: AsyncStream<SMAppService.Status>` that yields on every state-mutating call. The library does *not* bump its minimum platform — the gating is per-API via `@available`.

## Documentation

- **`Documentations/Architecture/` explains why the design looks like this.** [Overview.md](Documentations/Architecture/Overview.md) is the entry point; [ModuleLayering.md](Documentations/Architecture/ModuleLayering.md), [TypedMessaging.md](Documentations/Architecture/TypedMessaging.md), and [BrokeredPeer.md](Documentations/Architecture/BrokeredPeer.md) go deeper per area. This file is the lookup table; those carry the reasoning. When the two disagree, the source wins — then fix both.
- `Documentations/README.md` is the index — **every new or renamed document must be registered there**.
- `Documentations/Evolutions/NNNN-*.md` holds one proposal per substantive change, covering its whole lifecycle from research to landing. Do not split a change into separate design / plan / report files. `Documentations/Evolutions/README.md` is the status table and declares the project kind (**library, source-distributed** — so proposals fill in source compatibility and write "not applicable" for ABI).
- `CHANGELOG.md` is public-facing and written in English. Record source-breaking changes explicitly, with the compiler error a downstream project will see.

## Dependencies worth knowing

- [`SwiftyXPC`](https://github.com/MxIris-macOS-Library-Forks/SwiftyXPC) — typed XPC wrapper; the only XPC API used.
- [`MachInjector`](https://github.com/MxIris-Reverse-Engineering/MachInjector) — used solely by `InjectionServiceImplementation`. **0.4.3 or later is required**: that release is what makes `MachInjector.inject` throw when the target refuses the payload instead of reporting success, which is what the `dlopen` → remap fallback keys off. Its report block still cannot see a target that was killed during the load, which is why `InjectionService` checks that the process is still alive afterwards.
