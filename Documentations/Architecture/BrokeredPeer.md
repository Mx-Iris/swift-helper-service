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

## 七、沙盒目标：这套握手根本用不了

上面整套机制有一个前提：**两端都能 lookup tool 的 mach service**。目标被沙盒时这个前提不成立，
而且不是「慢一点」或「要重试」，是彻底不通：

- **App Sandbox 的 App**（`com.apple.security.app-sandbox`）跑在 `(deny default)` 的 profile 下，
  它的 `mach-lookup` 白名单里永远不会有第三方服务。
- **带 seatbelt profile 的系统守护进程**同样是 `(deny default)`，却**不带** app-sandbox
  entitlement —— 所以靠嗅 entitlement 判断会漏掉它们，必须实测。

于是 payload 连 tool 都连不上，注册端点、取对方端点这两步全都做不了。

### 退路：loopback socket，而且角色是反的

| | XPC 路径 | socket 路径 |
|---|---|---|
| 谁先到、谁等 | 宿主留下端点等人 | 宿主**监听** |
| 谁主动 | payload 取端点后连过去 | payload **连出去** |
| 怎么找到对方 | 经 tool 的注册表交换端点 | 两边**各自推导**出同一个端口 |

**角色必须反过来**：沙盒进程可以向 localhost 外连，但没有任何人能发现它 bind 了哪个端口 ——
tool 这条路正是被挡的那条，文件也不行（沙盒 App 和宿主没有共享目录，RuntimeViewer 正因此放弃了
文件式端口发现）。让宿主监听，就把「通报一个端口」变成了「约定一个端口」。

### 端口怎么约定

`PeerPortDerivation.port(for:)`，djb2 哈希到 49152–65535。三条约束：

- **不能用 `Hasher`**。它每进程种子不同，两边会算出不同端口然后互相干等，而这个错误只在跨进程时
  才显形。测试里独立重算了一遍期望值来钉死算法。
- **identifier 必须含目标 pid**（用 `channelIdentifier(serviceName:targetProcessIdentifier:)`
  生成），否则同时注入两个进程会撞到同一端口，第二个 listener 直接 bind 失败。
- **撞上无关软件是可能的**，这个范围和全机的临时端口共享。监听方会报 bind 失败，**不会**自动换一个
  端口重试 —— 对面没有办法跟着换。

### 选路

`PeerTransportSelection.transport(forProcess:machServiceName:channelIdentifier:)`。宿主在注入**前**
问目标 pid，payload 进去之后问 `getpid()` —— 同一个问题，同一个答案，不需要协商（而且需要协商的
那个场景恰恰没有通道可协商）。

一个反直觉的细节：`sandbox_check` 对**内核找不到的 pid 回答「拒绝」而不是报错**。照字面处理会把
已退出的目标推上 socket 路径去无限等待，所以探测前先确认进程存在 —— 按 `ESRCH` 判断，因为属于其他
用户的活进程回的是 `EPERM`，那不是跳过探测的理由。

### 传输本身

`PeerSocketChannel`，建在 Network.framework 上。XPC 自带的东西这里都要自己做：

- **分帧**：`UInt32` 大端长度前缀。大端不是品味问题 —— 字节序弄反时，读端会看到一个貌似合理的巨大
  长度然后永远等下去，所以超过 16 MiB 直接报错而不是等。
- **请求/响应配对**：每条请求一个 correlation 号。一条流上同时有多个请求在飞，少了它第二个调用方
  会拿到第一个的答复，而这种错只在并发下出现。
- **超时**：socket 不会告诉你对面已经不管了（XPC 的连接中断会自己冒出来）。默认 30 秒。
- **取消时必须唤醒所有等待者**：没被 resume 的 `CheckedContinuation` 不只是丢一个回复，而是让那个
  task 永远不返回。

**没有认证也没有加密**，它只绑 `127.0.0.1`。暴露面是本机其他进程，而那些进程本来就能和 daemon 说话。

沙盒目标若缺 `com.apple.security.network.client`，连 localhost 也会被沙盒拒绝 —— 实测 Books、Maps、
Calculator 都带这个 entitlement，但这不是保证，所以连接失败的错误信息里点名了这一条。

### 调用方看不见选了哪条路

`PeerMessaging` —— 两条路都能做的那四件事：发类型化请求、接类型化请求、看状态流、关掉。
`PeerConnection` 现在细化自它，额外带两样只有 XPC 有的东西：可发布的 listener endpoint，以及
SwiftyXPC 白送的那套按名字的无类型 RPC。

**为什么不把 socket 塞进 `PeerConnection`**：`listenerEndpoint` 对 socket 毫无意义 —— 两边之所以
靠推导约定端口，正是因为没有通道可以交换地址。硬套只会得到一堆唯一行为是抛错的方法。

`PeerLink.host(...)` / `PeerLink.payload(...)` 把「探测 → 选路 → 构造对应的那一端」合成一步，返回
`any PeerMessaging` 加上选中的 `transport`（值得记日志：链路起不来时它是第一个要知道的事，而线上
看不出来）。**两边必须算出同一个答案**，把这段计算收在一处是唯一能防止它们漂移的办法 —— 宿主选
XPC 而 payload 选 socket 不会报错，只会挂住。

payload 侧的工厂**不收 pid**：payload 就是目标，它问 `getpid()`。传进来就等于造出一条让两边分歧的
路，而那正是这套设计要排除的唯一故障。

`HelperService` 也能挂在 socket 上（`PeerSocketHelperHandler`）。不然一个写一次的 service 会在非沙盒
目标上正常、在沙盒目标上静默什么都不做。

### 两阶段，socket 也一样

`preparedListener(onPort:)` / `preparedDialer(toPort:)` 只构造不上线，`activate()` 才上线。理由与 XPC
那边同构（见第四节）：socket 这边是 payload 的第一帧可能在 registry 还空着的时候就到了，对面会收到
「没有注册处理器」—— 看起来像编程错误，实际是竞态。

**顺序是固定的：宿主先起，payload 后拨。** 拨号方需要有东西可拨。放到生产里这句话读作「注入之前
先把宿主这一端开起来」—— payload 对着还没起来的 listener 启动会得到 connection refused，而没有任何
东西会去重试。

**重连只有 XPC 有。** XPC 下能重连是因为 payload 的 listener 活得比宿主 App 久；socket 下 listener 在
宿主这边，宿主重启后 payload 手里那条连接已经死了，而且没有办法把新的告诉它。
`PeerLink.hostReconnecting(...)` 对沙盒目标直接抛错并说明这一点，而不是给出一条永远连不上的链路。

## 八、已知粗糙处

- **注册表条目不会被清理** —— 这条已在共享 daemon 提案的清理批次中修掉：`MainService` 现在按注册方
  pid 挂 `DispatchSourceProcess`，进程退出即移除。
- **XPC 握手仍然没有自动化测试**。上面第三、四节的握手时序是**读代码得出的**。socket 这条路有测试
  （`PeerSocketChannelTests` 与 `PeerMessagingTests` 用两个真实的 loopback 端点对连，覆盖往返、并发
  配对、错误传播、取消、超时、两阶段生命周期与 service 挂载），**XPC 那条没有** —— 不要把这里的
  绿色当成整个 `HelperPeer` 都被覆盖了。
- **`PeerLink` 的选路分支只有 socket 那一半被测到**。XPC 那半要求有一个活着的 daemon，测试进程里
  没有；`PeerTransportSelection` 的判断本身另有测试覆盖。
- **沙盒目标里的 socket 路径从未真跑过**。本仓库不做真实注入，所以上面关于沙盒的结论来自
  `sandbox_check` 的语义和 RuntimeViewer 的生产经验，不是本仓库测出来的。
