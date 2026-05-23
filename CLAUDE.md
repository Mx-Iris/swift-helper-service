# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

`swift-helper-service` is a Swift Package that eliminates boilerplate when building a macOS privileged helper tool installed via `SMJobBless`. It provides a typed, async/await-based XPC framework on top of `SwiftyXPC`, plus a discovery/endpoint-registry pattern so a single privileged helper can broker connections to any number of additional XPC servers.

## Build & Test

- Always run `swift package update` before building (per global instructions).
- Build the whole package: `swift build 2>&1 | xcsift`
- Build a specific product: `swift build --product HelperClient 2>&1 | xcsift`
- Tests: `swift test 2>&1 | xcsift`. `HelperCommunicationTests` covers `Codable` round-trips, `XPCConnection.Error.indicatesOutdatedPeer`, and the `XPCConnection+MainService` behaviour extensions via an in-process broker. `HelperPeerTests` covers the brokered peer handshake / reconnect / state stream via `@_spi(Testing)` test inits on `BrokeredPeerClient` / `BrokeredPeerServer`.
- Swift toolchain: 6.2; platforms: macOS 11+, macCatalyst 14+. Many files are guarded with `#if os(macOS)` or `#if canImport(AppKit) && !targetEnvironment(macCatalyst)` — the macCatalyst surface is intentionally minimal.

## Architecture (the part that requires reading multiple files)

The framework models a **two-tier privileged XPC topology**:

1. **The privileged "tool"** (installed via `SMJobBless`, running as root): a `HelperServer` whose listener is `.machService(name:)`. It always hosts the package-internal `MainService`, which is an *endpoint registry* — not feature logic.
2. **One or more non-privileged "servers"** (`HelperServerType.plain(name, identifier)`): each opens an *anonymous* `XPCListener`, then connects back to the tool and calls `RegisterEndpointRequest` to publish its `XPCEndpoint` under a `HelperServerInfo`.

Clients connect through the same chain:
- `HelperClient.installTool(name:)` → `SMJobBless` with `kSMRightBlessPrivilegedHelper`.
- `HelperClient.connectToTool(...)` → mach-service connection, validated by `PingRequest`.
- `HelperClient.availableServerInfos()` → `ListServerInfosRequest` against `MainService`.
- `HelperClient.connectToServer(info:)` → `FetchEndpointRequest` returns an `XPCEndpoint`; the client opens `.remoteServiceFromEndpoint(endpoint)` and stores the connection keyed by `HelperServerInfo`.
- `sendToTool(request:)` vs `sendToServer(request:for:)` route to the correct connection.

This is why the registry-related request types (`FetchEndpointRequest`, `ListServerInfosRequest`, `RegisterEndpointRequest`) and `HelperTool` are `package` and re-exported only by `HelperCommunication` — they are internal plumbing, not part of the public API surface.

### Module layout and why each exists

- `HelperCommunication` — shared message-protocol layer. Defines `Request` (with `associatedtype Response`, `static var identifier: String`), `VoidResponse`, `PingRequest`, `FetchVersionRequest`, the registry requests, and `SwiftyXPC` extensions that adapt the untyped XPC API to the `Request`/`Response` protocol. Also defines four `public` behaviour extensions on `SwiftyXPC.XPCConnection` (`pingHelperTool`, `registerEndpoint`, `fetchEndpoint`, `listHelperServerInfos`) that callers should use *instead of* constructing the registry request types directly — the registry types themselves remain `package`.
- `HelperService` — protocol-only target. Defines `HelperService`, `HelperHandler`, `HelperServerType`, and the retroactive `XPCListener: HelperHandler` conformance shared by `HelperServer` and `HelperPeer`. Anything that wants to plug into a `HelperServer` or a `BrokeredPeerClient` / `BrokeredPeerServer` depends only on this.
- `HelperServer` — the actor that owns the `XPCListener`, prepends `MainService` to the user-supplied services, calls `setupHandler` on each, and (for `.plain` servers) registers its endpoint with the tool. Must be linked into the helper binary. `init` now takes a `version:` parameter that is surfaced through `MainService`'s `FetchVersionRequest` handler.
- `HelperClient` — the actor used by the host app. Owns the tool connection and a dictionary of per-server connections, plus the `SMJobBless` install flow, the modern `SMAppService.daemon(plistName:)` installer (`SMAppServiceDaemonInstaller`, `@available(macOS 13, *)`), `fetchToolVersion()` against `MainService`, and the `XPCConnection.Error.indicatesOutdatedPeer` discriminator for callers that need to distinguish "outdated tool binary" from transient XPC failures.
- `HelperPeer` — abstraction layer for the *brokered peer* topology (`host ↔ broker ↔ peer process`). `BrokeredPeerClient` and `BrokeredPeerServer` (both `actor`s conforming to `PeerConnection`) handle the anonymous-listener / endpoint-register / reverse-connect / reconnect handshake that previously had to be reimplemented per project. State changes are surfaced through `AsyncStream<PeerConnectionState>` — the module is intentionally UI-framework-agnostic, with no Combine / Observation dependency. Business handlers are mounted via `services: [HelperService]` (same protocol as `HelperServer`).
- `Sources/HelperServices/MainService` — the registry implementation that sits inside the tool. Owns the endpoint registry plus the `FetchVersionRequest` handler.
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

- Module visibility is deliberate: prefer `package` for cross-target plumbing, `public` only for things the host app or helper binary calls. **The registry request types (`FetchEndpointRequest` / `RegisterEndpointRequest` / `ListServerInfosRequest`) and `HelperServerInfo.init` are intentionally `package`**; the only public surface for talking to `MainService` is the `XPCConnection+MainService.swift` behaviour extensions (`pingHelperTool` / `registerEndpoint` / `fetchEndpoint` / `listHelperServerInfos`). Do not loosen those request types to `public` — broaden the behaviour extensions instead.
- `MainService` is added by `HelperServer.init` automatically — do not register it manually, and do not add other services with overlapping request identifiers.
- Two product names exist for split services (`InjectionService` aggregates both Interface and Implementation; `InjectionServiceInterface` / `InjectionServiceImplementation` expose them individually). When adding a new service, mirror this product layout in `Package.swift` so client apps can pick the minimal dependency set.
- Existing identifier strings use `com.JH.*`. `HelperCommunication` reserves `com.JH.HelperCommunication.*`; `HelperPeer` reserves `com.JH.HelperPeer.*`; concrete `HelperServices/<Name>Service` reserve `com.JH.HelperService.<Name>.*`. Keep that prefix for new identifiers unless the user explicitly changes the namespace.
- `@_spi(Testing)` inits on `BrokeredPeerClient` / `BrokeredPeerServer` accept a `toolEndpoint:` in lieu of `machServiceName + isPrivilegedHelperTool` so tests can run against an in-process anonymous broker. These are not part of the public API surface and must remain hidden behind `@_spi(Testing)`.

## Versioning

- `HelperServer.init(serverType:version:services:)` requires a version string. `MainService` exposes it via `FetchVersionRequest` (`com.JH.HelperCommunication.FetchVersion`).
- Host apps call `HelperClient.fetchToolVersion()`. When the running tool predates `FetchVersionRequest`, the call throws `SwiftyXPC.XPCConnection.Error.unexpectedMessage`; use `XPCConnection.Error.indicatesOutdatedPeer` (only `true` for `.unexpectedMessage`, `false` for every other case) to distinguish "tool is outdated, reinstall" from transient XPC failures.

## Installation paths

Two installation flows coexist:

- `HelperClient.installTool(name:)` — legacy `SMJobBless` path, still supported for clients on older OS versions.
- `HelperClient.daemonInstaller(plistName:)` — returns an `SMAppServiceDaemonInstaller` actor (`@available(macOS 13, *)`) wrapping `SMAppService.daemon(plistName:)`. Exposes `register()` / `unregister()` / `refresh()` / `openLoginItemsSettings()` plus a poll-free `statusStream: AsyncStream<SMAppService.Status>` that yields on every state-mutating call. The library does *not* bump its minimum platform — the gating is per-API via `@available`.

## Dependencies worth knowing

- [`SwiftyXPC`](https://github.com/MxIris-macOS-Library-Forks/SwiftyXPC) — typed XPC wrapper; the only XPC API used.
- [`MachInjector`](https://github.com/MxIris-Reverse-Engineering/MachInjector) — used solely by `InjectionServiceImplementation`.
