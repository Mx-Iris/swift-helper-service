# Brokered Peer：两个非特权进程通过 tool 互相认识

**前置**：[架构总览](Overview.md)第二节（特权进程只做介绍人）。本文讲 `HelperPeer` 这套独立握手
协议 —— 它和 `HelperServer`/`HelperClient` 那套是**两回事**，容易混淆。

## 一、它解决什么问题

场景：宿主 App 把一个 payload dylib 注入进第三方进程（比如 Finder），payload 里跑着一个调试代理，
宿主 App 要和它双向通信。

难点在于**两端谁都无法直接找到对方**：

- payload 跑在别人的进程里，**不能注册 mach service**（那需要 launchd plist，而它不是一个独立的
  可执行体）。
- 宿主 App 不知道 payload 什么时候完成加载、也拿不到它的任何句柄。
- 双方都不是特权进程，没有系统级的引荐机制可用。

**唯一的共同锚点**是那个已经装好的特权 tool —— 两端都知道它的 mach service 名字。

所以 tool 在这里当**引路人（broker）**：两端各自开一个匿名监听器，把端点存进 tool 的注册表，从
注册表里取到对方的端点后**直连**。之后消息不经过 tool。

```
        ┌──────────── tool（broker）────────────┐
        │       MainService 端点注册表            │
        └───▲───────────────────────────▲───────┘
   ①注册端点 │                           │ ②取对方端点、注册自己
            │                           │
   ┌────────┴────────┐            ┌─────┴───────────┐
   │ HelperPeerClient│◀──③直连──▶ │ HelperPeerServer │
   │  （宿主 App 侧）  │            │ （被注入进程侧）    │
   └─────────────────┘            └─────────────────┘
```

## 二、Client / Server 的命名容易误导

**这两个名字指的是握手中的角色，不是「谁请求谁响应」。** 建立连接后两端完全对等 —— 都能
`send(_:)`，都能 `setMessageHandler(_:handler:)`。

| 角色 | 在握手里干什么 | 典型是谁 |
|---|---|---|
| `HelperPeerClient` | **先到**。注册自己的端点，然后**等**对方来敲门 | 宿主 App |
| `HelperPeerServer` | **后到**。从注册表**取**对方端点，主动连过去，并通知对方「我起来了」 | 被注入的 payload |

这个不对称完全来自时序：宿主 App 先运行、发起注入，payload 后加载。先到的那个只能留下地址等人。

## 三、握手时序

### 初次握手

```
HelperPeerClient (宿主)                tool                  HelperPeerServer (payload)
        │                               │                              │
  init  │ 开匿名 listener                │                              │
        │ 连 tool，装握手 handler          │                              │
        │   （Ping + ServerLaunched）     │                              │
        │                               │                              │
activate│ ── listener.activate() ──      │                              │      ← 先激活再注册
        │ ── registerEndpoint ─────────▶ │ 存 client 端点                 │
        │                               │                              │
        │                               │                    init      │ 开匿名 listener、连 tool
        │                               │                              │ 装握手 handler
        │                               │                              │  （Ping + ClientReconnected）
        │                               │ ◀──── fetchEndpoint ──────── │ activate
        │                               │ 返回 client 端点               │
        │ ◀════════ 直连 + Ping ═══════════════════════════════════════ │
        │                               │                              │ listener.activate()  ← 先激活
        │ ◀═══ ServerLaunched(自己的端点) ═══════════════════════════════ │
        │ 存 server 端点，反向直连                                          │
        │                               │ ◀── registerEndpoint ─────── │ 登记自己，供日后重连
        │ yield .connected              │                              │ yield .connected
```

两处「先激活监听器」的顺序是**刻意的**，源码里也各有注释：

- Client 在 `registerEndpoint` **之前** `listener.activate()` —— 一旦端点进了注册表，server 随时
  可能连过来。
- Server 在发 `ServerLaunchedNotification` **之前** `listener.activate()` —— 宿主收到这条通知后会
  立刻发业务请求，那时监听器必须已经在收。

### 重连

payload 所在的进程还活着，但宿主 App 重启了。宿主此时**已经知道** server 的端点（存在别处，比如
`InjectedEndpointRegistryService` 里），于是走 `HelperPeerClient` 的第二个 init：

```
HelperPeerClient.init(..., serverEndpoint:)   → 记下端点，暂不连
activate()                                    → 直连 server 端点
                                              → Ping
                                              → 发 ClientReconnectedNotification(自己的新端点)
HelperPeerServer.handleClientReconnected      → 用新端点建反向连接
                                              → 取消旧的 peerConnection
                                              → yield .connected
```

**重连路径完全不经过 tool** —— 端点是现成的，不需要再查注册表。

## 四、为什么必须是两阶段：`init` 之后还要 `activate()`

这是这个模块里最重要、也最不直观的设计，值得单独一节。

### 竞态

假如把握手全部塞进 `init`，调用方的代码会是：

```swift
let peer = try await HelperPeerServer(machServiceName: ..., identifier: ...)
// ⚠️ 到这一行时，握手已经完成，对方可能已经发来业务请求
peer.setMessageHandler(SomeBusinessRequest.self) { ... }   // 太晚了
```

`init` 返回的那一刻，`ServerLaunchedNotification` 已经发出去了，宿主 App 完全可能在下一微秒就发来
第一条业务请求。而调用方的 handler 要在 `init` 返回**之后**才装得上。这段窗口里到达的消息会命中
一个没有对应 handler 的监听器 —— **静默丢失**。

这不是理论风险：它随进程调度、消息大小、机器负载而变，在开发机上可能永远不复现，在用户机器上偶发。

### 解法

把生命周期切成两段，语义写死在 `PeerConnection` 协议的文档里：

```swift
/// - Important: `init` is intentionally a no-op on the wire — it only
///   constructs the listener and the lib-internal handshake handlers.
///   Callers MUST install every business handler before invoking
///   `activate()`.
func activate() async throws
```

- **`init`**：开监听器、连 tool、装**包内部的**握手 handler（`PingRequest` +
  `ServerLaunched`/`ClientReconnected`）。**线上没有任何动静** —— 监听器没激活，端点没注册，
  通知没发。
- **`activate()`**：真正的握手。调用方在这之前把业务 handler 全部装好。

于是正确的用法是：

```swift
let peer = try await HelperPeerServer(machServiceName: ..., identifier: ...)
peer.setMessageHandler(SomeBusinessRequest.self) { ... }    // 先装
peer.setMessageHandler(AnotherRequest.self) { ... }
try await peer.activate()                                    // 后握手
```

`activate()` 用 `hasActivated` 标志保证只能调一次，重复调抛 `Error.alreadyActivated`。

**另一条等价途径**：两个 init 都接受 `services: [HelperService] = []`，会在 init 内部就调
`setupHandler`。用这条路时业务 handler 在 `init` 期间就装好了，同样安全 —— 而且和
`HelperServer` 挂载服务的方式完全一致，这正是[把 `HelperService` 拆成独立协议 target](ModuleLayering.md#二为什么-helperservice-是一个只有协议的-target)
换来的复用。

## 五、状态流：为什么是 `AsyncStream` 而不是 Combine / Observation

```swift
public enum PeerConnectionState: Sendable {
    case connecting
    case connected
    case disconnected(any Error)
    case cancelled
}

public nonisolated var stateStream: AsyncStream<PeerConnectionState> { get }
```

**因为这个模块要能跑在被注入的 payload 里。** payload 加载进的是**第三方进程** —— Finder、Safari、
某个完全不受控的 App。在那种环境里：

- 不该假设宿主进程有 AppKit/SwiftUI 的运行环境，也不该把 Combine 或 Observation 的运行时拖进去。
- payload 越小、依赖越少，注入成功率越高、越不容易和宿主进程的既有符号冲突。

`AsyncStream` 是标准库的，零额外依赖，且调用方要转成 Combine `Publisher` 或 `@Observable` 都很容易。
**这个模块刻意不认识任何 UI 框架**，编辑时请保持。

### 状态转换

```
                 ┌──────────────┐
     init ──────▶│  .connecting │
                 └──────┬───────┘
                        │ 握手成功
                 ┌──────▼───────┐   传输失败    ┌────────────────────┐
                 │  .connected  │─────────────▶│ .disconnected(err) │
                 └──────┬───────┘               └────────────────────┘
                        │ cancel()
                 ┌──────▼───────┐
                 │  .cancelled  │──▶ stream.finish()
                 └──────────────┘
```

注意 `.disconnected` **不是终态** —— 重连成功后会再次 yield `.connected`（见
`handleClientReconnected`）。只有 `.cancelled` 之后流才结束。

`cancel()` 是幂等的：关监听器、断两条连接、yield `.cancelled`、`finish()` 流。

## 六、和 `HelperServer` / `HelperClient` 的关系

这是最容易混淆的地方，列表对照：

| | `HelperServer` + `HelperClient` | `HelperPeer*` |
|---|---|---|
| 拓扑 | 宿主 ↔ tool ↔ sub-server（三方，tool 是其中一端） | 宿主 ↔ peer（两方对等，tool 只引路） |
| tool 的角色 | 既是注册表**也是**业务服务的宿主 | **只**是注册表，不参与业务 |
| 谁开匿名监听器 | 只有 `.plain` 的 sub-server | 两端都开 |
| 连接方向 | 宿主单向发起 | 双向 —— 两端都能主动 `send` |
| 重连 | 没有内建协议，重新走一遍发现流程 | 有专门的 `ClientReconnected` 路径 |
| 状态可观测 | 无（只有 `isConnectedToTool` 这个一次性查询） | `AsyncStream<PeerConnectionState>` |

两者**共用**：`HelperCommunication` 的 `Request`/`Response` 协议、`MainService` 的端点注册表、
`HelperService` 的服务挂载协议。也就是说注册表被复用于两种完全不同的用途 —— 这是它被设计成
「只存 `(HelperServerInfo) → XPCEndpoint` 映射、不理解语义」的回报。

## 七、已知粗糙处

- **注册表条目不会被清理**。peer 进程退出后端点仍留在 `MainService` 里（见
  [Overview.md 第八节](Overview.md#八已知粗糙处)）。业务上需要清理的场景目前靠
  `InjectedEndpointRegistryService` 自己用 `DispatchSourceProcess` 监听进程退出解决，`HelperPeer`
  这条线没有对应机制。
- **`HelperPeer` 没有测试**。仓库根目录 `CLAUDE.md` 一度描述存在 `HelperPeerTests`，以及
  `HelperPeerClient`/`HelperPeerServer` 上有 `@_spi(Testing)` 的测试用 init 接受 `toolEndpoint:`
  —— **这两样在源码里都不存在**，已在补写本文时更正。上面所有握手时序都是**读代码得出的，未经
  自动化测试覆盖**。
