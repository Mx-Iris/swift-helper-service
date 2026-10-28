# Draft - 共享 daemon 只管注入，回传通道移到独立库

- **状态**: Accepted
- **作者**: JH
- **创建日期**: 2026-10-28
- **最后更新**: 2026-10-28
- **所属愿景**: 无
- **关联提案**: [draft-shared-injection-daemon](draft-shared-injection-daemon.md)（本提案修正它关于
  回传通道归属的决策）、[0001](0001-injection-strategy-attempt-not-predict.md)（注入路径先尝试后
  退回）、[0002](0002-service-errors-that-survive-xpc.md)（服务端错误跨 XPC 保住描述）
- **实现分支 / PR**: `feature/shared-injection-daemon` —— 与上一份提案共用一条分支。那条分支尚未合并进
  `main`，而本提案推翻的正是它关于回传通道归属的决策；叠在同一条分支上，它最终呈现的就是修正后的方案，
  不会留下「先实现被推翻的版本、再实现修正」的历史
- **新建仓库**: `swift-injection-peer`，位于
  `/Volumes/Repositories/Private/Personal/Library/macOS/swift-injection-peer`，与本库、`MachInjector`
  同级。它自己的 API 设计提案写在该仓库内，不属于本提案
- **配套文档**: 待定 —— 落地时登记实现说明 / 使用指南的链接

## 摘要

把「payload 回连它的客户端」整件事从**共享 daemon** 移出去。共享 daemon 只保留 `InjectionService`，
不再挂载端点注册表（`InjectedEndpointRegistryService`）；注册表与 `HelperPeer` 整个从本库移出，搬到
一个新库 `swift-injection-peer`。

**是搬家，不是删除。** 这两样对**自带 daemon** 的工具是正常工作的现役基础设施 —— RuntimeViewer 与
`InjectionScaffold` 生成的项目都把注册表挂在自己的 daemon 上，它们的 broker 就是自己，签名要求自己
说了算。本提案取消的是「**共享** daemon 替 payload 保管端点」这一项，不是「这套代码不该存在」。

起因是一个在真实注入目标上无法回避的失败：daemon 的代码签名要求校验的是**连接对端进程**，而 payload
没有独立的进程身份，于是真正被校验的是**被注入的那个 App**。注入 Dock、Finder 或任意第三方 App 时，
它们的 Team ID 必然不是本 Team，payload 永远拿不到回连端点。唯一的绕法是打开开发模式，而那让 daemon
对本机任何调用方开放 —— 包括注入请求本身，也就是这个要求原本要守住的那一条。

## 动机

### 实测到的失败

2026-10-28 在 `ViewHierarchyCapture` 上做完整端到端验证（这是迁移到共享平台之后的第一次），
在开发模式关闭的状态下得到：

```
Target: pid 11332, native
Channel: brokered XPC
Injecting…
Error: the payload was injected but never opened its channel within 30s.
```

注入本身成功 —— 目标进程的 `vmmap` 里能看到 payload 的 `__TEXT` / `__DATA` 段。失败在回连。
daemon 侧日志给出了确切原因：

```
00:48:30.453  Code-signing requirement (anchor apple generic and
              certificate leaf[subject.OU] = "D5Q73692VW") set on connection
00:48:30.453  activating connection: … peer[92401]…        ← 客户端，已签名，放行
00:48:30.470  Dropping check-in message due to code signing requirement
00:48:30.471  [Payload] Could not open the payload channel: XPCError error 1
```

打开开发模式并重装 daemon 之后，同一条链一次通过，产出 448 KB 的 `.viewhierarchy` 归档，
`topLevelGroups` 的对象统计与靶子的层级吻合。**所以除签名这一跳之外，整条链是通的** —— 本提案要解决
的不是功能缺失，而是这一跳的归属。

### 为什么这不是「把 payload 签上名」就能修

被校验的不是 payload。`xpc_connection_set_peer_code_signing_requirement` 校验连接对端，而 payload
是 `dlopen` 进宿主进程的一个镜像，没有自己的进程身份：连接由宿主进程发起，audit token 与代码签名都
取自宿主的主可执行文件。上面日志里 `peer[11332]` 就是被注入的靶子进程本身。

于是要求变成了「只有本 Team 签名的 App 才能被注入」。而注入工具的目标恰恰是别人的 App 和 Apple 的
App，没有一个满足。给 payload 签 Developer ID 不改变任何事。

### 为什么回传不该留在共享 daemon 里

[draft-shared-injection-daemon](draft-shared-injection-daemon.md) 为共享 daemon 立下的准入判据是：
**没有 root 真的做不到吗？做得到就不该进来。** 按这条判据复核回传：

- **注入**需要 `task_for_pid`，离不开 root。
- **回传**不需要任何特权。它之所以进了 daemon，只是因为 daemon 比客户端长寿、可以替 payload 保管
  一个端点 —— 那是**方便**，不是**必需**。

而这份方便的代价现在清楚了：它把一个身份不可知的调用方引到了 root 服务的门口，于是要么放弃校验，
要么放弃功能。移出去之后这个两难不存在。

**这条判据只约束共享 daemon。** 专属 daemon 的主人可以自己接受这份方便的代价 —— 它只服务自己一个
客户端，可以把签名要求放宽到容纳被注入的进程，而共享者不能（放宽就是对所有工具放宽，包括注入请求
本身）。所以 RuntimeViewer 把注册表挂在自己的 daemon 上不是错，是它有资格做的权衡；本提案移出的是
**共享平台**的那一份。

### 原设计里已经写着矛盾

`HelperPeerClient.swift:93-98` 与 `HelperPeerServer.swift:87-89` 的注释：

> `nil` 是必须的，不是疏漏。peer listener 只有拿到端点的人能找到，而对端是 payload 被注入进去的任意
> 第三方 App —— 它的签名无法事先知道，所以没有能容纳它的要求。**这一跳的访问控制在注册表那里，
> 而注册表在工具自己的要求之后。**

前半句的判断完全正确：被注入进程的身份不可知。后半句把访问控制推给注册表，而注册表恰恰在那个
「无法事先知道的身份」过不去的要求之后。两句话互相否定，本次失败就是它。

## 前期调研

- **签名校验的对象是进程，不是镜像。** SwiftyXPC 在
  `Sources/SwiftyXPC/XPCConnection.swift:128` 调用
  `xpc_connection_set_peer_code_signing_requirement`。实测佐证：daemon 日志把 payload 那一端记为
  `peer[11332]`，即被注入的靶子进程的 pid。
- **要求绑在 listener 上，构造后改不了。** `Sources/HelperServer/HelperServer.swift:30-32` 的注释
  明确写了这一点，并说明想切换的 daemon「必须重启才能做到」。因此无法按服务区分宽严，除非拆成多个
  Mach service。
- **两条传输的角色是相反的。** `Sources/HelperPeer/PeerLink.swift`：`host(...)`（第 54 行）在
  brokered XPC 下是 `HelperPeerClient`、在 loopback socket 下是 `preparedListener`；
  `payload(...)`（第 134 行）正好相反 —— XPC 下是 `HelperPeerServer`，socket 下连出。
- **重连只在 XPC 路径成立。** `PeerLink.swift:89-96`：重连可行是因为 payload 的 listener 比客户端
  长寿，而 socket 路径上监听方是客户端，客户端重启后 payload「拿着一条死连接，且无从被告知新的」。
  沙盒目标因此只能靠重新注入恢复，而镜像不能加载两次，实际意味着目标也要重启。
- **daemon 的注入服务不记录任何注入。** 通读
  `Sources/HelperServices/InjectionService/Implementation/InjectionService.swift`，注入完即返回，
  没有任何登记动作。现在界面上那份「已注入进程」全部来自 payload 事后主动注册。
- **平台界面依赖注册表。** `InjectionPlatformAppCore/PayloadChannel.swift:133-134`，
  `InjectedPayloadRegistry` 的注释就是「Reads the daemon's registry of injected processes」，
  经 `FetchAllInjectedEndpointsRequest` 取数。
- **注入前校验不查 Team ID，ad-hoc 签名是被接受的。**
  `InjectionService.swift:226-264` 只做 `SecStaticCodeCheckValidity`，失败时的提示还直接建议
  `codesign -f -s -`。所以 payload 的签名在**注入**这一关从来不是问题，只在**回连**那一关是。
- **端口推导用 djb2，刻意不用 `Hasher`。** 理由是 `Hasher` 每进程种子不同，两边会算出不同端口，
  而这种错误只在跨进程时显形。这条结论随代码一起搬到新库，不需要任何人重新踩一遍。
- **签名要求默认是「不校验」，共享与专属 daemon 因此处境相反。**
  `Sources/HelperServer/HelperServer.swift` 的 `codeSigningRequirement` 默认 `nil`，其文档写明 `nil`
  「接受本机任何进程」，并要求「共享工具必须传一个要求」。对照之下：RuntimeViewer 的 daemon
  （`RuntimeViewerPackages/Sources/RuntimeViewerService/RuntimeViewerService.swift`）没有传这个参数，
  所以它那边 payload 回连一直是通的；共享 daemon 必须传，于是被挡。**本提案描述的两难是共享 daemon
  独有的** —— 它服务所有工具，不能为某一个放宽；专属 daemon 只服务自己，可以自己选。
- **注册表与 XPC 路径在自带 daemon 的工具里是现役基础设施。** RuntimeViewer 的 daemon 挂着
  `InjectedEndpointRegistryService()`（与 `ApplicationsService`、`InjectionService`、`FilesService`
  并列）；`InjectionScaffold` 生成的 `__NAME__DaemonCore/DaemonMain.swift` 同样挂着它。RuntimeViewer
  还把注册表的四个请求类型扩展成自己的 `RuntimeRequest` / `RuntimeResponse`，并用
  `RuntimeXPCClientConnection(identifier:serverEndpoint:)` 实现「App 重启后重连到已注入的 app」。
  所以删除这两样会破坏它们，而搬家不会。
- **共享平台与 `InjectionScaffold` 是并行的两条路，不互相替代。** 工具型（`ViewHierarchyCapture`
  这类 CLI，不值得自带 daemon）用共享平台；应用型（RuntimeViewer 这类有界面、要重连、已有独立
  daemon）继续自带 daemon，不迁移。新库正是这两条路的公共底座。
- **`HelperPeer` 在本库内部没有任何其他 target 依赖它。** `Package.swift` 里只有它自己的定义和它的
  测试 target，本来就是个叶子模块 —— 摘出去对库内其余部分零影响。

## 提议方案

### 共享 daemon 只剩注入一个服务

共享 daemon 不再挂载 `InjectedEndpointRegistryService`（四个请求：`FetchAllInjectedEndpointsRequest`、
`RegisterInjectedEndpointRequest`、`RemoveInjectedEndpointRequest`，以及载荷类型
`InjectedEndpointInfo`）。摘掉之后它挂载的服务只有：

- `InjectionService` —— 需要 `task_for_pid`
- `DeveloperModeService` —— 写 root 拥有的信任配置
- `HelperServer` 自动挂上的 `MainService`（版本查询与 ping）

于是**连 daemon 的只有发起注入的客户端**，签名要求不再有例外，也不再需要为某个服务开口子。

### 注入记录由共享 daemon 自己维护

界面上那份「已注入进程」改由 daemon 在注入成功时自己记一条，**存在内存里，daemon 重启即清空**。
理由：重装或升级 daemon 本来就会掐断每个 payload 的通道，那时清空是诚实的；持久化只会留下一批
通道已死的历史条目，还要多一份 root 拥有的状态文件。

记录的语义随之变化，界面必须跟着变：它表示「daemon 往这个进程注入过」，**不表示 payload 还活着、
通道还通**。平台界面不再显示实时状态，只呈现这份记录。原先那种「payload 主动注册即证明自己起来了」
的信息随本次改动一并失去 —— 这是自觉接受的代价，换来的是 payload 完全不必连 daemon。

目标进程退出时清理记录的机制可以沿用现有实现（功能分支上那条
`fix(registry): evict endpoints when the process that registered them exits` 的进程监视），
只是监视的触发者从「payload 自报 pid」变成「daemon 自己注入时就知道的 pid」—— 于是
[draft-shared-injection-daemon](draft-shared-injection-daemon.md) 里「注册方自报 pid 可信」
那条假设不再需要成立。

### 回传移出共享 daemon，通道代码搬到新库

**共享 daemon** 不再承担两件事：端点的保管与分发，以及为任何 payload 中转回传。共享平台的契约缩减
为一句话：**把这个镜像放进那个进程，并如实报告成败。**

而通道本身不消失，它搬到 `swift-injection-peer`，**两条传输都保留**：

| 使用者 | 用哪条 |
|---|---|
| 自带 daemon 的应用（RuntimeViewer、`InjectionScaffold` 生成的项目） | XPC 路径，注册表挂到自己的 daemon 上 |
| 共享平台的工具（`ViewHierarchyCapture`、平台的参考载荷） | loopback socket，不碰注册表 |
| 沙盒目标（两类都会遇到） | loopback socket |

新库保留对本库 `HelperCommunication` 的依赖（那套 `Request` 协议与序列化）。四个现役使用者本来全都
依赖本库，所以这不给任何人增加负担，请求类型也不必改。依赖方向是「新库 → 本库」，使用者同时依赖
两者，不成环 —— 平台的参考载荷在 `InjectionPlatform` 仓库里而不在本库里，所以没有循环风险。

### 非目标

- **不在本提案内设计 `swift-injection-peer` 的 API。** 本提案只决定「搬出去、搬到哪、谁还挂注册表」，
  搬过去时 API 原样不动。新库自己的 API 设计（要不要收拢 `PeerLink` 的两条入口、端口碰撞要不要做
  候选序列、要不要在上面加一层 distributed actor）写在新库仓库自己的提案里 —— 那是另一个仓库的
  另一次改动。
- **不动 RuntimeViewer 的签名要求。** 它的 daemon 挂着 `InjectionService()` 却用默认的 `nil`
  （接受本机任何进程）。这不是本次改动造成的，整治归 RuntimeViewer 自己的议程；本提案只在「下游
  影响」里记下回传移出后它有了补上要求的条件。
- **不补沙盒目标的重连。** 沙盒里 payload 不能监听（需要 `com.apple.security.network.server`，
  目标 App 基本不带），只能连出，于是客户端重启后无从被告知新地址。与现状一致，界面与错误信息
  如实说明这一点，不做静默失败。
- **不取消开发模式。** 它回到本来的用途 —— 放行 ad-hoc 签名的客户端（`swift build` 的产物就是），
  不再是让整套机制在真实目标上能用的前提条件。
- **不改注入前的 payload 校验。** 架构切片、platform、签名有效性三项照旧。

## 详细设计

### 移出的 API

整个 `Sources/HelperServices/InjectedEndpointRegistryService/` 目录搬到 `swift-injection-peer`，
**API 形态不变**：

```swift
public struct RegisterInjectedEndpointRequest: HelperRequest { … }
public struct FetchAllInjectedEndpointsRequest: HelperRequest { … }
public struct RemoveInjectedEndpointRequest: HelperRequest { … }
public struct InjectedEndpointInfo: Codable, Sendable { … }
```

随之移出的 product：`InjectedEndpointRegistryService`、
`InjectedEndpointRegistryServiceInterface`、`InjectedEndpointRegistryServiceImplementation`。

**共享 daemon 不再挂载它，但自带 daemon 的工具照旧挂** —— 它们改的只是依赖来源（`package:` 从
`swift-helper-service` 换成 `swift-injection-peer`），import 名与调用代码都不用动。

### `HelperPeer` 的处置

整个模块搬到 `swift-injection-peer`，**两条传输都保留**：`PeerLink`、`HelperPeerServer`、
`HelperPeerClient`、`PeerTransportSelection`、`PeerPortDerivation`、`PeerSocketChannel`、
`PeerSocketFraming`、`PeerSocketHelperHandler`、`PeerConnection`、`PeerHandshakeRequests`。

XPC 那半边（`HelperPeerClient` / `HelperPeerServer` / `PeerHandshakeRequests`）**不能删** —— 它是
自带 daemon 那一类的主路径，而且在那里从来没出过本提案描述的问题：`HelperPeerClient` 的
`machServiceName:` 由调用方传入，broker 是哪个 daemon 完全由使用者决定。

模块移出本库的理由不再是「它依赖一个被取消的前提」，而是归属：它服务的是 payload 与客户端之间的
通道，与「特权 helper 服务的基础设施」是两件事。本库由此回归纯粹 —— XPC 通信、daemon 骨架、服务
挂载、注入服务。

**此处推翻了本提案早先采用的一条假设**（原文标注「未经询问，可在审阅时推翻」）：当时假设 socket
分帧与通道状态机应随 `ViewHierarchyCapture` 一起走、或由它抽成独立小库。实际使用者有四类（见
「下游影响」），让其中一个承接公共基础设施会把另外三个推向复制粘贴 —— 而 `InjectionScaffold` 的
README 已经记着这套管道被 RuntimeViewer、MediaRemoteWizard、HopperMCP 各自手写过一遍，重复造轮子
发生过三次，脚手架本身就是那次教训的产物。所以建公共库，不由单个客户端承接。

### 跨 package 的访问级别：`InjectionPeer` SPI

**这一节是实现时发现的，初版提案没有预见。** `HelperPeer` 的 XPC 那半边
（`HelperPeerClient`、`HelperPeerServer`）用到本库九个 `package` 级成员，而 `package` 严格限于
同一个 Swift package —— 搬到新库之后它们一概访问不到。socket 那半边不碰任何一个，所以这道裂缝
恰好劈在两类使用者之间。

处置是把这九个成员开成 **`@_spi(InjectionPeer)` public**，而不是升为正式 `public`：

| 成员 | 所属 |
|---|---|
| `HelperPeerEndpoint.underlying`、`init(_:)` | `HelperCommunication` |
| `XPCConnection.sendMessage(request:)` | `HelperCommunication` |
| `XPCConnection.pingHelperTool()`、`registerEndpoint(...)`、`fetchEndpoint(...)` | `HelperCommunication` |
| `XPCListener.setMessageHandler(requestType:handler:)` | `HelperCommunication` |
| `HelperServiceFailure.registerForDecoding()` | `HelperCommunication` |
| `ServiceFailureTransport` 与 `wrappingFailures(requestIdentifier:operation:)` | `HelperCommunication` |
| `XPCHelperHandler.init(listener:)` | `HelperService` |

**为什么是 SPI 而不是 `public`**：`package` 的本意是「只给自己人用」，而新库正是自己人、只是换了
package。`@_spi` 精确表达这个语义 —— 不进入正式公开 API、不构成稳定承诺，而且使用方必须在 import
处点名自己才能用。升为 `public` 则会把刻意封装的实现变成公开契约，`HelperPeerEndpoint.underlying`
的原注释写得很直白：`package`-visible 就是为了让只有库内代码能构造和解包它。

**两处连带效应，都要同批次处理**：

- **涉及的文件要把 `package import SwiftyXPC` 升为 `public import`。** SPI 声明本质是 public 声明
  （SPI 只约束谁能点名它），而 public 声明的签名里不能出现 package 类型 —— 实测报
  `property cannot be declared public because its type uses a package type`。影响范围有限：普通
  使用者存储、传递、序列化 `HelperPeerEndpoint` 时从不碰 `XPCEndpoint`，所以仍然不需要
  `import SwiftyXPC`，原设计意图保住了。
- **本库内部调用这些成员的地方也要改成 `@_spi(InjectionPeer) import`。** 这些成员是 `package` 时
  在本库各模块间自由可见，变成 SPI 之后对自己的 package 也不再自动可见。实测受影响的是三个文件：
  `HelperService/XPCHelperHandler.swift`、`HelperClient/HelperClient.swift`、
  `HelperServer/HelperServer.swift`。这是 `@_spi` 相比 `package` 多出来的唯一常态成本 —— 新增一处
  这类调用时，编译器会直截了当地报 `inaccessible due to '@_spi' protection level`，不会静默出错。

### 注入记录

```swift
// Sources/HelperServices/InjectionService/Interface/
public struct FetchInjectionRecordsRequest: HelperRequest {
    public typealias Response = [InjectionRecord]
}

/// 一次成功注入的记录。**只表示 daemon 注入过，不表示 payload 还活着。**
public struct InjectionRecord: Codable, Sendable {
    public let hostProcessIdentifier: pid_t
    public let payloadPath: String
    public let injectedAt: Date
    public let strategy: InjectionStrategy
}
```

记录在 `InjectionService` 内部持有，目标进程退出时移除。不提供写入接口 —— 唯一的写入者是
`InjectionService` 自己。

## 替代方案考量

### 拆成两个 Mach service，只对注入验签名

一个带签名要求的 service 挂 `InjectionService` 与 `DeveloperModeService`，另一个不带要求的挂
端点注册表。单个 launchd plist 可以声明多个 `MachServices`，这条路可行，也不必改
`HelperHandler` 的签名。

**为什么否**：它仍然把一个身份不可知的调用方引到 root 进程的门口，于是「注册方自报 pid 可信」那条
假设破掉，需要为注册表补上「从连接取 pid 而不信自报」的加固；而端点被伪造的风险依然存在。相比之下，
把回传整个移出去少了一个服务、一套加固和一类风险，而代价只是客户端自己实现通道 —— 那本来就是
客户端自己的需求。

### 给 payload 签 Developer ID

**为什么否**：无效。被校验的是宿主进程，payload 的签名不参与。这一条在提出后当场被实测否掉，
留档于此是因为它看起来非常合理，容易被再次提出。

### daemon 注入时下发一次性凭证

由 daemon 在注入时交给 payload 一个凭证，payload 用它证明「我就是刚被注入的那个」，于是身份不可知
的问题用凭证而非签名解决。

**为什么否**：`dlopen` 路径下 payload 的构造函数没有参数通路，凭证只能走环境变量或文件，而沙盒目标
读不到约定路径的文件（[draft-shared-injection-daemon](draft-shared-injection-daemon.md) 已记录过
这一点，RuntimeViewer 正因此放弃了文件式端口发现）。范围显著扩大，而它解决的问题在回传移出平台后
不再存在。

### 保留注册表，但只记录不发布端点

让注册表退化为「谁被注入了」的登记簿，payload 仍来注册，但不存端点。

**为什么否**：payload 仍要连 daemon，签名这一跳的问题原样保留。而且没有必要 —— daemon 执行注入，
它本来就知道往哪个进程放了什么。

### 把注册表与 `HelperPeer` 直接删掉，而不是搬到新库

本提案的初版就是这么写的：既然共享平台不该提供回传，这两个模块连同它们的代码一起消失，客户端各自
实现。

**为什么否**：它把「**共享** daemon 不该做这件事」错误地推广成了「这套代码不该存在」。两者的差别
在于使用者分两类 —— 自带 daemon 的工具（RuntimeViewer、`InjectionScaffold` 生成的项目）的 broker
是它们自己的 daemon，签名要求自己说了算，注册表与 XPC 路径在那里一直正常工作。删掉会凭空破坏两个
现役项目的功能（RuntimeViewer 的「App 重启后重连」直接失去基础），而它们本不该为共享平台的签名
约束付代价。搬到新库则两件事同时成立：共享 daemon 真的不再中转回传，通道代码真的还能复用。

## 影响

### 源码兼容性（source compatibility）

**有破坏。** 需要修改的调用点：

| 调用点 | 改前 | 改后 |
|---|---|---|
| `InjectionPlatformDaemonCore/DaemonMain.swift` | 服务列表含 `InjectedEndpointRegistryService()` | 移除该项（共享 daemon 不再挂） |
| `InjectionPlatformAppCore/PayloadChannel.swift` | `InjectedPayloadRegistry` 经 `FetchAllInjectedEndpointsRequest` 取端点 | 改用 `FetchInjectionRecordsRequest`，不再取端点 |
| `InjectionPlatformAppCore/PayloadChannel.swift` | `PeerLink.host(...)` / `hostReconnecting(...)` 连参考载荷 | 改走 socket 路径；依赖来源换成新库 |
| `InjectionPlatformUI/MenuBarMenu.swift` | 展示 payload 的存活状态 | 改为展示注入记录，措辞相应调整 |
| `ViewHierarchyCapturePayloadCore/PayloadEntry.swift` | `PeerLink.payload(...)` | 调用不变，依赖来源换成新库；传输固定为 socket |
| `ViewHierarchyCaptureCommand` | `PeerLink.host(...)` | 同上 |
| RuntimeViewer、`InjectionScaffold` 模板 | 从本库取 `HelperPeer` 与注册表 | **只改 `package:` 来源**，import 名与调用代码不变 |

不提供 `@available(*, deprecated, renamed:)` 过渡，但理由和初版不同：被移出的 API 不改名、不改签名，
使用者改的是依赖声明而不是代码，没有可以标在旧名字上的过渡期。

### ABI 兼容性

不适用 —— 本库以 SPM 源码分发，使用方每次重新编译。

### 下游影响

使用者分两类，受影响的程度完全不同。初版只列了共享平台那一类，漏了 RuntimeViewer。

**共享平台的工具 —— 行为要改：**

- **`InjectionPlatform`** —— 共享 daemon 少挂一个服务；App 侧的界面语义改变；平台自带的**参考载荷**
  改走 socket 回传（它是验证平台自身是否通畅的工具，不能因为这次改动失去回报能力）。
- **`ViewHierarchyCapture`** —— 受影响最大的那个，但本质是「丢掉 XPC 分支」而非「从零实现通道」：
  socket 那半边随新库原样可用。它现在默认走的 brokered XPC 恰恰是被签名要求堵死的那条，所以改完它
  才第一次能注入非本 Team 签名的目标 —— 对它这是修复，不只是迁移。另外它不用 `hostReconnecting`，
  CLI 是一次性进程，所以「失去 XPC 重连」对它零代价。**新增的负担**是端口碰撞风险从「只有沙盒目标
  会遇到」扩大到「所有目标」。

**自带 daemon 的工具 —— 只改依赖来源：**

- **RuntimeViewer** —— 不迁移到共享平台，继续用自己的 daemon。注册表与 XPC 重连照常工作，改的只是
  从哪个 package 取这两个模块。顺带一个收益：回传不再需要经 daemon 之后，它有条件给自己的 daemon
  补上签名要求（现在是默认的 `nil`，接受本机任何进程，而它挂着 `InjectionService()`）。**这件事
  不属于本提案范围**，归 RuntimeViewer 自己的议程。
- **`InjectionScaffold`** —— 模板的 `Package.swift`、`__NAME__DaemonCore/DaemonMain.swift`、
  `__NAME__AppCore/PayloadChannel.swift`、`__NAME__PayloadCore/PayloadPeer.swift` 换依赖来源。它的
  0002 提案里「payload 为了通道有意多带三个依赖」那条决策不受影响 —— 依赖数量不变，只是出处变了。

### 文档与示例

- 本库 README 中关于 daemon 挂载哪些服务、以及回传通道由平台提供的描述。
- `InjectionPlatform` 的 `CLAUDE.md`：daemon 服务清单那一节明确写着注册表「必须活在 daemon 里，
  因为 daemon 比任何客户端都长寿」—— 这个理由对**共享** daemon 被本提案推翻（它不是不够长寿，是
  签名要求容不下被注入的进程），必须同批次改。
- `ViewHierarchyCapture` 的 `Documentations/Internal/PayloadAndInjection.md` 与使用指南：涉及两条
  传输、传输自动选择、端口推导、重连的部分。改后它只有 socket 一条路，「沙盒目标才改走 socket」
  这类措辞要一并修正。
- `swift-injection-peer` 的 README：说明它服务两类使用者，两条传输各自适用谁，以及 djb2 端口推导
  为什么不能换成 `Hasher`。
- `InjectionScaffold` 的 0002 提案：补一句依赖来源已变更，决策本身不变。

## API 演进与废弃策略

- 被移出的 API 不设废弃期，直接从本库移除。理由：使用方都是本 Team 自己的仓库（四个），可以同批次
  改完；而保留一个「仍能 import 但共享 daemon 已不挂载」的请求类型，失败形态是运行时的
  「no handler」，比编译错误难诊断得多。
- API 形态搬过去时不变，所以使用者的迁移成本是改一行依赖声明，不是改代码。
- 本库需要 **semver major 跃迁**。当前最新 tag 为 `0.3.3`，主版本号仍为 0，按惯例以 minor 跃迁
  表达破坏性变更即可；若此时已发布 `1.0.0`，则本提案要求 `2.0.0`。
- `swift-injection-peer` 从 `0.1.0` 起，位置 `/Volumes/Repositories/Private/Personal/Library/macOS/swift-injection-peer`，
  与本库、`MachInjector` 同级。

## 落地步骤

1. ✅ **建 `swift-injection-peer`，把 `HelperPeer` 与端点注册表搬进去，同一批次里从本库移出。**
   原样搬，不改 API；保留对本库 `HelperCommunication` 的依赖。

   **这两件事必须同批次，不能分开。** SPM 要求 target 名在**整个 package graph** 内唯一，而新库
   依赖本库 —— 只要本库还声明 `HelperPeer`，新库就无法解析（实测报
   `multiple packages declare targets with a conflicting name`）。所以初版设想的「本库两套并存，
   两边都能单独构建与测试」在 SPM 下不存在。本库在功能分支上移出，不影响任何现役使用者：它们依赖的
   是已发布的 0.3.x。
2. ✅ **本库把新库需要的内部接口开成 `InjectionPeer` SPI。** 见「详细设计 / 跨 package 的访问级别」。
   没有这一步，新库的 XPC 那半边编译不过。

   > 第 1、2 步落在 `feature/shared-injection-daemon` 的 `347f2e8`，新库落在它自己仓库的
   > `b1895a1`。两边都编译干净、测试按原始退出码通过（本库 69 个测试 12 个套件，含那个走真实 XPC
   > 连接的套件；新库 32 个测试 4 个套件）。**新库尚无远端仓库 —— 这是第 3 步的前提。**
3. 🟡 **四个使用者改依赖来源。** 把这两个模块的 `package:` 指向新库，同时把 `swift-helper-service`
   升到移出后的版本。

   > **完成一半，另一半被发版阻塞。** `InjectionPlatform` 与 `ViewHierarchyCapture` 本来就用 path
   > 依赖指向本库的功能分支 worktree，可以立刻改，已完成。**RuntimeViewer 依赖已发布的
   > `from: "0.3.1"`，`InjectionScaffold` 模板钉在 `exact: "0.1.4"`** —— 现在改它们就是指向不存在
   > 的版本，必须等本库与新库都发版。发版不属于实现阶段。
   >
   > 两个能改的都用 **local path** 指向新库，而不是 `branch:`：SPM 拒绝「revision-based 依赖自身又
   > 依赖 local package」，而新库只能对移出后的本库解析，那只存在于功能分支上。两处注释都写明了
   > 发版后要换成版本要求。
4. ✅ **共享 daemon 侧补注入记录。** 在 `InjectionService` 内部维护记录与进程退出清理，加
   `FetchInjectionRecordsRequest`。

   > 实现时定的两件事：`inject(request:)` 改为返回**实际生效**的 strategy（原先返回 void），否则
   > 一次 `dlopen` 被拒、回退到 remap 的注入会被记成 `dlopen` —— 而 strategy 正是记录要说明的事。
   > 记录按宿主 pid 索引而非追加成列表：同一进程注入两次是真实序列，有意义的答案是最后那次。
   > 进程退出清理照 `MainService` 的 `DispatchSourceProcess` 模式，但 pid 的来源更可靠 —— daemon
   > 自己执行注入，不需要谁来自报。
5. ✅ **共享 daemon 摘掉 `InjectedEndpointRegistryService()`。** 从 `DaemonMain.swift` 的服务列表移除。
6. ✅ **平台 App 改用注入记录。** `InjectedPayloadRegistry` 换数据源，界面措辞从「活着」改为
   「已注入」，去掉实时状态判断。

   > 实现时定的状态模型（提案只给了一句话指引）：`ResidentPayload` 拆出一个 optional 的
   > `reported`，**两种信息来源不混为一谈** —— 本次会话注入的有 channel，payload 答得出版本与 hook
   > 数；从 daemon 记录继承的只有 pid、注入时间与 payload 路径，`reported` 为 nil，界面就只说
   > 「injected · not reachable from this launch」，不编造版本号或「0 hooks」。`hasStalePayload`
   > 对后者返回 false 而不是猜。进程名对继承的记录用 `NSRunningApplication` 查，查不到（daemon、
   > helper 这类非 App 目标）就退回 payload 的文件名。
   >
   > `PayloadChannel.reconnect(to:)` 与 `reconnectToResidentPayloads()` 一并删除 —— socket 路径上
   > App 是监听方，重连在原理上不存在。后者改名 `loadInjectionRecords()`，只读记录、不假装能重连。
7. ✅ **`ViewHierarchyCapture` 改走 socket。** 去掉传输选择与 XPC 分支。
8. ✅ **平台的参考载荷改走 socket。** 同上，使平台保有自检能力。顺带让 payload 彻底不再连 daemon，
   少两个被映射进第三方进程的库（`HelperClient` 与注册表接口）。
9. 🟡 **文档同批次更新**（见「文档与示例」）。本库 README / AGENTS.md / `BrokeredPeer.md` 存根、
   `InjectionPlatform` 的 `CLAUDE.md`、`ViewHierarchyCapture` 的使用指南与实现说明都已改。
   **剩下本库 `Documentations/` 里的架构文档与术语表**（`Overview.md`、`ModuleLayering.md`、
   `TypedMessaging.md`、`Glossary.md` 等处对 `HelperPeer` 的叙述），它们描述的仍是同一套协议、
   只是位置变了，留待一并整理。
10. **端到端复验：在开发模式关闭的状态下，注入一个非本 Team 签名的目标并完成一次完整往返。**
    这是本提案是否成立的唯一判据 —— 它恰恰是改动前做不到的那件事。

**顺序是有意这样排的**：第 1、2 步是纯搬家，做完任何仓库都不会坏；第 3 步之后才有破坏性。初版把
「移出模块」排在使用者改依赖之前，那会让 RuntimeViewer 与 `InjectionPlatform` 同时编译不过，而它们
该怎么改当时还没定论。

**收尾时必须判断两件事**（结论写进决策日志）：

- 要不要配套专题文章 —— 「为什么**共享** daemon 不中转回传，而专属 daemon 可以」属于下次维护会反复
  追问、而代码本身看不出来的决策（关键在 `codeSigningRequirement` 的默认值与共享/专属的处境差异），
  倾向于写一份实现说明。
- 有没有引入新术语 —— `InjectionRecord` 与既有的「端点」语义不同，需判断是否登记进术语表。
- 新库的 README 是否说清了两类使用者的分工 —— 这是今后最容易被误读成「平台替代脚手架」的地方。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-10-28 | Created as Draft | 起因：`ViewHierarchyCapture` 的首次端到端验证暴露出，daemon 的签名要求校验的是被注入进程而非 payload，导致任何非本 Team 签名的目标都无法回连，唯一绕法是打开开发模式 —— 而那让注入请求本身也失去校验 |
| 2026-10-28 | 查明被校验的是宿主进程，不是 payload | `xpc_connection_set_peer_code_signing_requirement` 校验连接对端，payload 无独立进程身份。daemon 日志把 payload 那一端记为 `peer[11332]`，即靶子进程的 pid |
| 2026-10-28 | 否掉「给 payload 签 Developer ID」 | 无效，签名不参与这一跳的校验。留档是因为这个方案看起来合理、容易被再次提出 |
| 2026-10-28 | 定为「平台只管注入」，回传整个移出 | 按本库的准入判据复核：注入离不开 root，回传不需要任何特权，它进 daemon 只是图方便。移出后「身份不可知的调用方站在 root 服务门口」这个两难不再存在 |
| 2026-10-28 | 否掉「拆两个 Mach service」 | 可行，但仍把不可知身份引到 root 进程门口，还要为注册表补上「不信自报 pid」的加固，且端点伪造风险保留。移出去少一个服务、一套加固、一类风险 |
| 2026-10-28 | 注入记录由 daemon 自己维护，存内存，重启即清 | daemon 执行注入，天然知道往哪个进程放了什么，不需要 payload 来报。重装 daemon 本就掐断所有通道，那时清空是诚实的；持久化只留下通道已死的历史条目，还要多一份 root 拥有的状态文件 |
| 2026-10-28 | 界面只呈现注入记录，不再显示实时状态 | 新记录的语义是「注入过」而非「payload 活着」。与其补一套「通道是否还通」的判断，不如如实降级 —— 实时状态这个需求本身没有强到值得把 payload 重新引向 daemon |
| 2026-10-28 | 沙盒目标的重连明确不支持 | 沙盒里 payload 不能监听（要 `network.server`，目标 App 基本不带），只能连出，客户端重启后无从被告知新地址。与现状一致，不是回退；界面与错误信息如实说明，不静默失败 |
| 2026-10-28 | ~~端口碰撞用「推导候选序列依次尝试」~~ → **移出范围** | 澄清提问中曾就端口碰撞的容忍策略定过方案，随后确认回传整件事交给客户端，于是端口推导、碰撞处理、对端身份确认一并不再是平台要回答的问题。此条保留以说明范围是怎么收窄的 |
| 2026-10-28 | ~~`HelperPeer` 整个从本库移除（删除）~~ → **搬到新库** | 初版的理由是「它的对外入口建立在一个被取消的前提上」。该理由只对共享 daemon 成立：`HelperPeerClient` 的 `machServiceName:` 由调用方传入，自带 daemon 的工具 broker 就是自己，这条路在那里一直正常。见下一条 |
| 2026-10-28 | 开发模式保留，范围缩回原意 | 仍需放行 ad-hoc 签名的客户端 —— `swift build` 的产物没有签名，本次验证中 `vhcapture` 正是补签后才连上 daemon。它不再是让整套机制在真实目标上能用的前提条件 |
| 2026-10-28 | **改为搬家：注册表与 `HelperPeer` 移到新库 `swift-injection-peer`，而不是删除** | 初版把「**共享** daemon 不该替 payload 保管端点」推广成了「这套代码不该存在」，而使用者分两类：自带 daemon 的工具（RuntimeViewer、脚手架生成的项目）broker 是自己的 daemon，签名要求自己说了算，注册表与 XPC 路径在那里从未出过本提案描述的问题。删除会凭空破坏两个现役项目 —— RuntimeViewer 的「App 重启后重连」会直接失去基础 —— 而它们本不该为共享平台的签名约束付代价 |
| 2026-10-28 | 查明两难为共享 daemon 独有 | `HelperServer` 的 `codeSigningRequirement` 默认 `nil`（文档写明「接受本机任何进程」，并要求「共享工具必须传一个要求」）。RuntimeViewer 的 daemon 没传这个参数，所以回连一直是通的；共享 daemon 必须传，于是被挡。共享者服务所有工具、不能为某一个放宽，专属者只服务自己、可以自己选 |
| 2026-10-28 | 推翻「通道代码随 `ViewHierarchyCapture` 走」的假设 | 该假设原标注「未经询问，可在审阅时推翻」。实际使用者有四类，让其中一个承接公共基础设施会把另外三个推向复制粘贴 —— 而 `InjectionScaffold` 的 README 已记着这套管道被 RuntimeViewer、MediaRemoteWizard、HopperMCP 各自手写过一遍，脚手架本身就是那次教训的产物 |
| 2026-10-28 | 新库保留对本库 `HelperCommunication` 的依赖 | 四个现役使用者本来全都依赖本库，保留不给任何人增加负担，请求类型也不必改。依赖方向「新库 → 本库」不成环，因为平台的参考载荷在 `InjectionPlatform` 仓库里而不在本库里。真出现非注入场景的使用者时再考虑泛型化 |
| 2026-10-28 | 落地步骤改为「先建库、再改依赖来源、最后才移出」 | 初版把「移出模块」排在使用者改依赖之前，会让 RuntimeViewer 与 `InjectionPlatform` 同时编译不过。改后第 1、2 步是纯搬家，任何仓库都不会坏，第 3 步之后才有破坏性 |
| 2026-10-28 | RuntimeViewer 的 daemon 不设签名要求：记一笔，不进本次 | 它挂着 `InjectionService()` 却用默认的 `nil`。不是本次改动造成的，纳入会压平本次范围。回传移出后它有了补上要求的条件，整治归 RuntimeViewer 自己的议程 |
| 2026-10-28 | 新库改为无条件 path 依赖本库，删掉条件切换 helper | 从本库抄来的 `local:`/`remote:` 机制在这里有害：它只在设了 `USING_LOCAL_DEPENDENCIES` 时用本地 checkout，否则回落到已发布版本 —— 而新库**没有可回落的版本**（能解析的只有那个功能分支）。于是任何没设该变量的使用者都解析到不存在的 `0.4.0`，`InjectionPlatform` 的 `RunScript.sh` 整个跑不起来。helper 一并删掉而不是留着不用：留着会让人以为存在回落路径，而那正是造成这个 bug 的误读 |
| 2026-10-28 | 纠正：此前报告的「x86_64 多架构链接失败是既有问题」不成立 | 那次 `xcodebuild` 漏了 `-destination 'generic/platform=macOS'`。不加它，SPM 依赖只按宿主架构构建，而 payload target 要 x86_64，于是链接失败 —— 是命令用错，不是依赖的架构覆盖缺陷。`RunScript.sh` 本来就带那个 destination，它的注释也明确警告过这一点。修好依赖解析后它构建通过，daemon 与 payload 都是 `x86_64 arm64 arm64e` |
| 2026-10-28 | 落地步骤 1、2 完成 | 新库 `b1895a1`，本库 `347f2e8`（`feature/shared-injection-daemon`，已推送）。两边编译干净、测试按原始退出码通过 |
| 2026-10-28 | 实测：SPM 不允许「两套并存」，落地顺序改为「搬出与移除同批次」 | target 名必须在整个 package graph 内唯一，而新库依赖本库 —— 只要本库还声明 `HelperPeer`，新库就无法解析。初版落地步骤设想的中间态不存在。改后本库在功能分支上移出，不影响依赖已发布 0.3.x 的现役使用者 |
| 2026-10-28 | 九个 `package` 成员改走 `@_spi(InjectionPeer)`，而非升为 `public` | 跨 package 访问不到 `package`，而这九个成员只被 XPC 那半边用到（socket 半边零错误）。选 SPI 是因为 `package` 的本意就是「只给自己人用」，新库正是自己人、只是换了 package；升 `public` 会把刻意封装的实现变成公开契约。连带：相关文件的 `package import SwiftyXPC` 要升 `public import`（SPI 声明是 public 声明，不能带 package 类型），且本库内部的调用点也要改成 SPI import |
| 2026-10-28 | mach-lookup 探测拆出并改名 `PeerProcessProbe` | `HelperProcessProbe` 的三个函数调用方零重叠：路径检查与签名状态字只服务注入路径，留在本库；mach-lookup 只服务通道，随新库走。改名是必须的 —— 同名 target 作为模块冲突，同名 C 函数作为符号冲突 |
| 2026-10-28 | `BrokeredPeer.md` 随代码搬到新库，本库留存根 | 文档跟着它描述的代码走。存根是因为本库五个文件链接到那个路径（README、AGENTS.md、Glossary、Overview、ModuleLayering），留下可避免断链和读者白找 |
| 2026-10-28 | 新库的 local 依赖暂指向本库的功能分支 worktree | 新库只能对「已经移出这些 target」的本库版本解析，而那只存在于功能分支上。SPM 从目录名推导 path 依赖的 identity，所以要显式传 `name:`（`ViewHierarchyCapture` 已踩过同一个坑）。功能分支合并发版后改成版本要求 |
| 2026-10-28 | 用户批准，开始实现 | 状态 Draft → Accepted。实现叠在 `feature/shared-injection-daemon` 上（见头部「实现分支」）：那条分支未合并，而本提案修正的是它的决策，共用一条分支可避免留下「先实现被推翻的版本、再实现修正」的历史 |
| 2026-10-28 | 调研过「用 distributed actor 实现通道」，不采用 | 自定义 `DistributedActorSystem` 技术上可行，运行时库 `libswiftDistributed` 也随系统提供（SDK 有 `.tbd`，含 arm64e target），payload 不必自带。但它解决的是「远程调用的语法与类型安全」，而端点发现、传输建立、握手、重连、端口推导一概不碰 —— `resolve(id:)` 的前提正是「已经知道 ID」。它只能加在通道之上，省不掉底下任何一行，而现在通道上只有一个请求类型，收益不足。新库的 `PeerMessaging` 抽象不排斥以后在上面加一层 |
