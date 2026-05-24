# swift-helper-service

A Swift Package that eliminates boilerplate when building a macOS **privileged helper tool** installed via `SMJobBless` or the modern `SMAppService.daemon(plistName:)` API. It layers a typed, `async/await`-friendly request/response framework on top of [SwiftyXPC](https://github.com/MxIris-macOS-Library-Forks/SwiftyXPC), plus a discovery/endpoint-registry pattern so a single privileged helper can broker connections to any number of additional XPC servers — and a brokered peer-to-peer topology for processes that need to talk through the helper without the helper sitting in the middle of every message.

## Why?

Writing a privileged helper on macOS traditionally means:

- Hand-rolling untyped `xpc_object_t` payloads.
- Reimplementing the `SMJobBless` install dance in every project.
- Wiring up multiple XPC services into a single helper binary by hand.
- Inventing your own re-connection / endpoint-handoff protocol when one process needs to reverse-connect to another through the helper.

`swift-helper-service` ships opinionated, reusable primitives for each of those steps. You declare typed `Request`/`Response` payloads in a small *Interface* target, implement them in a small *Implementation* target, and the rest of the plumbing — install, handshake, discovery, reconnection — is provided.

## Requirements

- Swift toolchain **6.2** (`swift-tools-version: 6.2`)
- macOS **10.15+** / macCatalyst **13+** (per `Package.swift`)
- A handful of modern-only APIs are gated per-call site:
  - `SMAppServiceDaemonInstaller` — `@available(macOS 13, *)`
  - `HelperPeer*` and the `XPCConnection+MainService` behaviour extensions — `#if canImport(AppKit) && !targetEnvironment(macCatalyst)`

The library does not bump its minimum platform; gating is per-API via `@available` / `#if`.

## Installation

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/<your-fork>/swift-helper-service", from: "0.1.0"),
],
```

Then pick the products that match each binary's role:

| Binary                     | Products to link                                                                        |
| -------------------------- | --------------------------------------------------------------------------------------- |
| Host app                   | `HelperClient`, every `*ServiceInterface` you call into                                 |
| Privileged tool (the root) | `HelperServer`, every `*ServiceImplementation` you host, every `*ServiceInterface` too  |
| Non-privileged sub-server  | `HelperServer` (with `HelperServerType.plain`), the service Implementation it provides  |
| Brokered peer process      | `HelperPeer`, plus the `Request` types it exchanges                                     |

The Interface/Implementation split is the canonical pattern — it keeps heavyweight dependencies (e.g. `MachInjector`) out of the host app.

## Architecture

`swift-helper-service` models a **two-tier privileged XPC topology**:

```
┌──────────────┐       ┌────────────────────────────┐       ┌─────────────────┐
│   Host app   │◀────▶│  Privileged tool (root)    │◀────▶│ Sub-server (N)  │
│ HelperClient │  XPC  │ HelperServer + MainService │  XPC  │ HelperServer    │
└──────────────┘       │   (endpoint registry)      │       │ (.plain)        │
                       └────────────────────────────┘       └─────────────────┘
```

1. **The privileged "tool"** is installed via `SMJobBless` (or `SMAppService.daemon(...)`), runs as `root`, and exposes a `.machService(name:)` `XPCListener`. It always hosts the package-internal `MainService`, which is an *endpoint registry* — not feature logic.
2. **Zero or more non-privileged "servers"** (`HelperServerType.plain(name, identifier)`) open *anonymous* `XPCListener`s, connect back to the tool, and publish their `XPCEndpoint` into the registry under a `HelperServerInfo`.
3. **The host app** uses `HelperClient` to connect to the tool, discover sub-servers via `MainService`, and fetch their endpoints to open direct XPC connections.

Routing is explicit: `sendToTool(request:)` vs `sendToServer(request:for:)`.

### Modules

| Module                          | Role                                                                                                                                                       |
| ------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `HelperCommunication`           | Shared message-protocol layer: `Request`, `VoidResponse`, `PingRequest`, `FetchVersionRequest`, registry requests, and `XPCConnection` extensions.         |
| `HelperService`                 | Protocol-only target — defines `HelperService`, `HelperHandler`, `HelperServerType`. Depend on this from anything that plugs into a server.                |
| `HelperServer`                  | The actor that owns the `XPCListener`, prepends `MainService`, calls `setupHandler` on every service, and (for `.plain`) registers with the tool.          |
| `HelperClient`                  | The actor used by the host app — install flow, tool connection, per-server connection cache, and `fetchToolVersion()`.                                     |
| `HelperPeer`                    | Brokered host ↔ peer-process topology — `HelperPeerClient` and `HelperPeerServer` actors implementing the anonymous-listener / endpoint-handoff handshake. |
| `HelperServices/MainService`    | Registry implementation that sits inside the tool. Also serves `FetchVersionRequest`.                                                                      |
| `HelperServices/<Name>Service`  | Concrete services — always split into `Interface` (request types) and `Implementation` (handlers + heavyweight deps).                                      |

Two bundled services ship as examples:

- **`FilesService`** — privileged file operations (`createDirectory`, `remove`, `move`, `copy`, `write`).
- **`InjectionService`** — `dlopen`-style dylib injection into a target PID, backed by [`MachInjector`](https://github.com/MxIris-Reverse-Engineering/MachInjector).

## Quick start

### 1. Define a `Request`

Interface target — depends only on `HelperCommunication`:

```swift
import HelperCommunication

public struct EchoRequest: Codable, Request {
    public static let identifier = "com.example.MyService.Echo"

    public struct Response: Codable, Sendable {
        public let echoed: String
    }

    public let text: String
    public init(text: String) { self.text = text }
}
```

### 2. Implement a `HelperService`

Implementation target — pulls in `HelperService` and whatever your handler needs:

```swift
import HelperService
import MyServiceInterface

public actor MyService: HelperService {
    public init() {}

    public func setupHandler(_ handler: some HelperHandler) async {
        handler.setMessageHandler { (request: EchoRequest) -> EchoRequest.Response in
            .init(echoed: request.text)
        }
    }

    public func run() async throws {}
}
```

### 3. Boot the privileged tool

In the helper's `main.swift`:

```swift
import HelperServer
import MyServiceImplementation
import InjectionServiceImplementation

let server = try await HelperServer(
    serverType: .machService(name: "com.example.HelperTool"),
    version: "1.0.0",
    services: [
        MyService(),
        InjectionService(),
    ]
)
await server.activate()
RunLoop.main.run()
```

`MainService` is added automatically — do **not** register it yourself.

### 4. Drive it from the host app

```swift
import HelperClient
import MyServiceInterface

let client = HelperClient()

// Legacy SMJobBless install:
try await client.installTool(name: "com.example.HelperTool")

// Or the modern installer (macOS 13+):
if #available(macOS 13, *) {
    let installer = client.daemonInstaller(plistName: "com.example.HelperTool.plist")
    try await installer.register()
    for await status in installer.statusStream {
        print("daemon status: \(status)")
    }
}

try await client.connectToTool(
    machServiceName: "com.example.HelperTool",
    isPrivilegedHelperTool: true
)

let response = try await client.sendToTool(request: EchoRequest(text: "hi"))
print(response.echoed) // "hi"
```

### 5. (Optional) Discover sub-servers

If the tool is hosting `.plain` sub-servers that registered into `MainService`:

```swift
let infos = try await client.availableServerInfos()
for info in infos {
    try await client.connectToServer(info: info)
    try await client.sendToServer(request: SomeOtherRequest(), for: info)
}
```

## Versioning

`HelperServer.init(serverType:version:services:)` requires a version string. `MainService` exposes it via `FetchVersionRequest`. The host calls:

```swift
let version = try await client.fetchToolVersion()
```

When the running tool predates `FetchVersionRequest`, the call throws `SwiftyXPC.XPCConnection.Error.unexpectedMessage`. Distinguish "outdated tool, prompt for reinstall" from transient XPC failures with:

```swift
do {
    let version = try await client.fetchToolVersion()
    // ...
} catch {
    if HelperClient.errorIndicatesOutdatedPeer(error) {
        // tool binary is older than expected; offer reinstall
    } else {
        // transient — surface to user, retry, etc.
    }
}
```

This wraps the SwiftyXPC-specific check so callers don't need to import or pattern-match `SwiftyXPC.XPCConnection.Error` directly.

## Installation flows

Two install flows coexist; pick whichever matches your deployment target:

| API                                        | Availability    | Notes                                                                                       |
| ------------------------------------------ | --------------- | ------------------------------------------------------------------------------------------- |
| `HelperClient.installTool(name:)`          | All supported   | Legacy `SMJobBless` path. Still required for older clients.                                 |
| `HelperClient.daemonInstaller(plistName:)` | macOS 13+       | Returns an `SMAppServiceDaemonInstaller` actor wrapping `SMAppService.daemon(plistName:)`. |

`SMAppServiceDaemonInstaller` exposes `register()` / `unregister()` / `refresh()` / `openLoginItemsSettings()` and a poll-free `statusStream: AsyncStream<SMAppService.Status>` that yields on every state-mutating call.

## Brokered peer topology (`HelperPeer`)

For workflows where the host app talks to a *peer process* (e.g. an injected payload, a debug agent, a sidecar) through the privileged tool — but doesn't want every message to bounce off the tool — use `HelperPeer`:

```
┌──────────────┐       ┌───────────────┐       ┌──────────────┐
│   Host app   │◀────▶│  Helper tool  │◀────▶│ Peer process │
│ HelperPeer-  │  XPC  │   (broker)    │  XPC  │ HelperPeer-  │
│   Client     │       │               │       │   Server     │
└──────────────┘       └───────────────┘       └──────────────┘
        ▲                                              ▲
        └──────────── direct XPC after handshake ──────┘
```

Both sides conform to `PeerConnection`, expose an `AsyncStream<PeerConnectionState>` for state changes, and accept business `HelperService`s via the `services:` parameter.

### Two-phase lifecycle

`HelperPeerClient.init(...)` / `HelperPeerServer.init(...)` only construct the listener, broker connection, and lib-internal handshake handlers (`PingRequest`, `ServerLaunchedNotification`, `ClientReconnectedNotification`). They do **not** activate the listener or register the endpoint with the broker.

This lets you install your own business handlers via `setMessageHandler(...)` *before* the peer can route any inbound message — eliminating a race where the peer would send messages before the handlers are wired up.

Call `activate()` exactly once after installing handlers. The peer then completes the handshake and transitions to `.connected`.

```swift
let peer = try await HelperPeerClient(
    machServiceName: "com.example.HelperTool",
    isPrivilegedHelperTool: true,
    identifier: "io.example.injection-payload"
)

peer.setMessageHandler(MyRequest.self) { request in
    // ...
    return MyRequest.Response()
}

try await peer.activate()

for await state in peer.stateStream {
    switch state {
    case .connecting:           print("handshake in progress")
    case .connected:            print("peer is live")
    case .disconnected(let e):  print("peer dropped: \(e)")
    case .cancelled:            print("peer torn down"); return
    }
}
```

The module is intentionally UI-framework-agnostic: no Combine / Observation dependency.

## Conventions specific to this repo

- **Module visibility is deliberate.** `package` is preferred for cross-target plumbing, `public` only for what the host app or helper binary calls. The registry request types (`FetchEndpointRequest` / `RegisterEndpointRequest` / `ListServerInfosRequest`) and `HelperServerInfo.init` are intentionally `package` — the public surface for talking to `MainService` is the `XPCConnection+MainService` behaviour extensions (`pingHelperTool` / `registerEndpoint` / `fetchEndpoint` / `listHelperServerInfos`). Don't loosen those request types to `public` — broaden the behaviour extensions instead.
- **Every concrete service is split into two targets.** The Interface target exposes only the `Request`/payload types and depends only on `HelperCommunication`. The Implementation target conforms to `HelperService` and pulls in heavyweight dependencies. Two product names exist per service so a host app can link the minimal dependency set (e.g. `InjectionServiceInterface` only).
- **Identifier prefixes are reserved.** `HelperCommunication` reserves `com.JH.HelperCommunication.*`, `HelperPeer` reserves `com.JH.HelperPeer.*`, concrete services reserve `com.JH.HelperService.<Name>.*`. Keep the `com.JH.*` prefix for new identifiers unless your project intentionally uses a different namespace.
- **`MainService` is added automatically** by `HelperServer.init` — do not register it manually, and do not add other services with overlapping request identifiers.
- **Use the typed `setMessageHandler` overload from `HelperHandler`.** Don't call SwiftyXPC's untyped APIs directly from feature code — the typed overload uses `Request.identifier` to register handlers and is the only supported path.

## Concurrency

- All long-lived components (`HelperClient`, `HelperServer`, `MainService`, every concrete service, both peer types) are `actor`s.
- `SwiftyXPC` is imported `@preconcurrency`; `XPCListener` is declared `@retroactive @unchecked Sendable` in `HelperServer.swift`. Preserve those imports/declarations when editing — removing them breaks Swift 6 strict concurrency.
- `HelperService` instances must be `Sendable`; the protocol requires it.

## Build & test

```bash
swift package update
swift build 2>&1 | xcsift          # or plain `swift build`
swift test  2>&1 | xcsift          # or plain `swift test`
```

The test suite (`HelperCommunicationTests`) covers:

- `CodableTests` — `Codable` round-trips for every shared request type plus the `XPCConnection+MainService` behaviour extensions, exercised against an in-process broker.
- `OutdatedPeerTests` — `HelperClient.errorIndicatesOutdatedPeer(_:)` returns `true` only for `SwiftyXPC.XPCConnection.Error.unexpectedMessage` and `false` for every other error case.

## Dependencies

- [`SwiftyXPC`](https://github.com/MxIris-macOS-Library-Forks/SwiftyXPC) — typed XPC wrapper; the only XPC API used.
- [`MachInjector`](https://github.com/MxIris-Reverse-Engineering/MachInjector) — used solely by `InjectionServiceImplementation`.
- [`FrameworkToolbox`](https://github.com/Mx-Iris/FrameworkToolbox) — `FoundationToolbox` (`@Loggable` and friends).

## License

See [LICENSE](LICENSE).
