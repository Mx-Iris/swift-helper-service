# 模块分层与可见性

**前置**：先读[架构总览](Overview.md)的第二节和第六节。本文回答两个问题：模块为什么切成现在这样，
以及什么该 `public`、什么该 `package`。

## 一、Interface / Implementation 拆分

### 规矩

**每个具体服务都是两个 target**：

```
Sources/HelperServices/<Name>Service/
├── Interface/         → target <Name>ServiceInterface       仅依赖 HelperCommunication
│   └── FooRequest.swift        只有 Codable 的消息类型
└── Implementation/    → target <Name>ServiceImplementation  依赖 Interface + HelperService + 重依赖
    └── FooService.swift        conform HelperService，真正干活
```

`Package.swift` 里对应三个 product：聚合的 `<Name>Service`、单独的 `<Name>ServiceInterface`、
单独的 `<Name>ServiceImplementation`。**新增服务必须照抄这个布局**，这样调用方能挑最小的依赖集。

### 为什么

宿主 App 只需要知道**消息长什么样**，不需要知道**怎么执行**。`InjectionService` 是最能说明问题的
例子：它的 Implementation 依赖 [`MachInjector`](https://github.com/MxIris-Reverse-Engineering/MachInjector)
（含汇编 shellcode、Objective-C、Mach 内核调用）和 `HelperProcessProbe`（两处内核 SPI 的 C 包装）。
宿主 App 只是想发一句「把这个 dylib 注入到那个 pid」，不该为此把注入器的全部机器码链进自己的
二进制。

拆开之后：

| 二进制 | 链接 | 结果 |
|---|---|---|
| 宿主 App | `InjectionServiceInterface` | 只多了两个 `Codable` 结构体 |
| 特权 tool | `InjectionServiceImplementation` | 拿到全部注入能力 |

### 硬性约束：不要写跨越边界的类型

Interface 里的类型会**上线传输**，Implementation 里的类型不会。一个类型如果同时想干两件事，就会
把重依赖拖过边界。

真实案例：`InjectionStrategy` 这个枚举原本整个放在 Implementation 里，因为它带着探测函数
（`isFileMapExecutableBlocked` 等）而那些函数依赖 `HelperProcessProbe`。后来
[提案 0001](../Evolutions/0001-injection-strategy-attempt-not-predict.md) 需要让调用方能覆盖策略，
枚举就得上线。**处理办法是把枚举本身移到 Interface，探测逻辑留在 Implementation 的 extension 里** ——
而不是把 `HelperProcessProbe` 也拖到 Interface。

```swift
// Interface/InjectionStrategy.swift —— 纯数据，可上线
public enum InjectionStrategy: String, Codable, Sendable, Equatable { ... }

// Implementation/InjectionStrategy+Probe.swift —— 探测逻辑，依赖内核 SPI
extension InjectionStrategy {
    static func initialAttempt(forTarget pid: pid_t, payloadPath: String) -> InjectionStrategy { ... }
}
```

这是拆分边界被真正考验过的一次，值得作为模板。

## 二、为什么 `HelperService` 是一个只有协议的 target

[`Sources/HelperService/`](../../Sources/HelperService/) 只有三个文件、几十行，定义
`HelperService`、`HelperHandler`、`HelperServerType`，外加 `XPCHelperHandler` 适配器。

**如果把这些协议直接放进 `HelperServer`**，那么任何想写一个业务服务的模块都得依赖
`HelperServer` —— 也就是把整个守护进程实现（`XPCListener` 持有、注册表接线、生命周期管理）拖进
依赖图，只为了 conform 一个协议。

拆出来之后，依赖方向是干净的：

```
<Name>ServiceImplementation ──▶ HelperService（协议）◀── HelperServer（实现）
                                                    ◀── HelperPeer（实现）
```

`HelperServer` 和 `HelperPeer` 是两套完全不同的拓扑（见 [BrokeredPeer.md](BrokeredPeer.md)），但
它们**共用同一个 `HelperService` 协议**来挂载业务处理器。所以同一个服务实现既能装进守护进程，也能
装进被注入的 payload，一行不改。这个复用是拆分的直接回报。

## 三、`XPCHelperHandler`：一个刻意做成半透明的适配器

```swift
public struct XPCHelperHandler: HelperHandler, @unchecked Sendable {
    package let listener: SwiftyXPC.XPCListener      // ← package
    package init(listener: SwiftyXPC.XPCListener)     // ← package
    public func setMessageHandler<Request: ...>(...)  // ← public
}
```

**类型是 `public`，存储和初始化器是 `package`。** 这个组合看起来别扭，但每一半都有理由：

- `public`：外部写的 `HelperService` 实现，其 `setupHandler(_ handler: some HelperHandler)` 会收到
  这个类型的值，所以类型本身必须可见。
- `package`：外部拿不到里面的 `XPCListener`，也造不出一个新的 —— 于是 `SwiftyXPC` 不会从这条缝里
  漏到公开 API 上。

这是「隐藏依赖」这条约束的一个具体落点，也是理解本仓库可见性风格的最好例子：**可见性是按每个成员
分别决定的，不是按类型一刀切。**

## 四、`package` vs `public` 的判定标准

### 标准

> `public` 只给宿主 App 或守护进程**真正会调用**的东西。跨 target 的内部管道一律 `package`。

### 注册表消息类型：故意不 public

`FetchEndpointRequest` / `RegisterEndpointRequest` / `ListServerInfosRequest`，以及
`HelperServerInfo.init`，全是 `package`。

**为什么**：这些消息的语义依赖一条不变量 —— **注册表只有一份，在 `MainService` 里**。如果调用方
能自由构造 `RegisterEndpointRequest` 发给任意监听器，这条不变量就没了保障。把类型收在 `package`，
外部就只能通过受控的行为走这条路。

对应的行为封装在 [`XPCConnection+MainService.swift`](../../Sources/HelperCommunication/XPCConnection+MainService.swift)：

```swift
extension SwiftyXPC.XPCConnection {
    package func pingHelperTool() async throws
    package func registerEndpoint(_ endpoint: XPCEndpoint, machServiceName: String, identifier: String) async throws
    package func fetchEndpoint(machServiceName: String, identifier: String) async throws -> XPCEndpoint
    package func listHelperServerInfos() async throws -> [HelperServerInfo]
}
```

**注意这四个也是 `package`，不是 `public`。** 它们是给包内的 `HelperServer` / `HelperPeer` 用的；
包外的宿主 App 走的是 `HelperClient` 上的 `availableServerInfos()` / `connectToServer(info:)`，
那才是公开入口。

> 仓库根目录的 `CLAUDE.md` 与 `README.md` 一度把这四个方法描述成「public，是与 `MainService` 对话的
> 唯一公开入口」。那是不准确的 —— 已在补写本文时更正。

**要放开怎么办**：如果确实需要给外部新增一种与注册表交互的能力，**加一个新的行为方法**，不要把
请求类型放开成 `public`。理由同上：放开类型等于放弃那条不变量。

## 五、平台门禁

- `Package.swift` 声明 `platforms: [.macOS(.v10_15), .macCatalyst(.v13)]`。
- 几乎所有源文件都包在 `#if os(macOS) || targetEnvironment(macCatalyst)` 里；涉及 AppKit 的
  （如 `ApplicationsService`）用 `#if os(macOS)`，把 macCatalyst 也排除掉。
- 现代 API 逐个用 `@available` 门禁，**不抬高整个包的最低版本**：
  - `SMAppServiceDaemonInstaller` → `@available(macOS 13.0, macCatalyst 16.0, *)`
  - `ApplicationsService` → `@available(macOS 12, *)`
  - `InjectionService` 内的 remap 路径 → 运行期 `guard #available(macOS 11.0, *)`

**为什么按 API 门禁而不是抬最低版本**：抬版本会把所有下游一起抬上去，哪怕它们根本用不到那个 API。
macCatalyst 那一面是刻意做得很薄的 —— 它存在只是为了让共享代码能编过，不是一个被认真支持的目标。

## 六、`@preconcurrency` 与 `@retroactive` 导入

散落在多处、看起来像噪音，其实每一处都必要：

```swift
@preconcurrency private import SwiftyXPC     // HelperServer / HelperClient / HelperPeer / MainService
@preconcurrency package import SwiftyXPC     // HelperCommunication / XPCHelperHandler
extension SwiftyXPC.XPCListener: @retroactive @unchecked Sendable {}   // HelperServer.swift
```

`SwiftyXPC` 没有为 Swift 6 严格并发做完整标注，它的 `XPCListener` / `XPCConnection` 会跨隔离域传递。
`@preconcurrency` 把由此产生的并发诊断降级为警告，`@retroactive @unchecked Sendable` 则显式承担
`XPCListener` 的线程安全责任（其内部是线程安全的 dispatch source 封装）。

**删掉任何一处，Swift 6 严格并发检查就会失败。** 编辑这些文件时保留它们。

`private import` / `package import` 的选择则是第三节那条约束的落实：能 `private` 就 `private`，
让 `SwiftyXPC` 尽可能少地出现在模块接口里。
