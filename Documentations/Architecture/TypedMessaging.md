# 类型化消息层

**前置**：[架构总览](Overview.md)第五节走过一条消息的完整路径。本文讲这一层为什么长成这样，以及
新增消息时的规矩。

## 一、原生 XPC 的问题

XPC 的消息是 `xpc_object_t` —— 本质是个动态类型的字典。原生写法大致是：

```objc
xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
xpc_dictionary_set_string(message, "operation", "copy");
xpc_dictionary_set_string(message, "source", sourcePath);
// 接收端：
const char *operation = xpc_dictionary_get_string(message, "operation");
```

三类错误编译器完全看不见：**key 拼错**、**类型取错**（`get_string` 读一个存进去的 int，返回
`NULL`）、**请求和响应对不上**（发 A 请求却按 B 响应解码）。这些全都在运行期以静默失败或崩溃的形式
出现，而且是在一个**跨进程、其中一端以 root 运行的守护进程**里 —— 最不适合靠打印调试的地方。

## 二、解法：一个类型就是一条消息

```swift
public protocol Request<Response>: Codable, Sendable {
    associatedtype Response: Codable & Sendable
    static var identifier: String { get }
}
```

三个要素各自消掉一类错误：

| 要素 | 消掉什么 |
|---|---|
| `Codable` | key 拼错、类型取错 —— 编解码由编译器合成，两端引用同一个类型定义 |
| `associatedtype Response` | 请求与响应对不上 —— `sendMessage(request:)` 的返回类型由请求类型在编译期决定 |
| `static var identifier` | 路由错 —— 发送方和接收方引用的是同一个静态常量，不可能写岔 |

配套的 `VoidResponse` 用于没有返回值的操作（一个空结构体，`.empty` 是它唯一的值）。

### `identifier` 是路由键，不是文档

这是最容易被误解的一点。看 [`XPCExtensions.swift`](../../Sources/HelperCommunication/XPCExtensions.swift)：

```swift
extension SwiftyXPC.XPCConnection {
    package func sendMessage<Request: HelperCommunication.Request & Sendable>(request: Request) async throws -> Request.Response {
        try await sendMessage(name: type(of: request).identifier, request: request)   // ← identifier 当消息名
    }
}

extension SwiftyXPC.XPCListener {
    package func setMessageHandler<Request: ...>(requestType: Request.Type = Request.self, handler: ...) {
        setMessageHandler(name: requestType.identifier) { ... }                        // ← 同一个常量
    }
}
```

**`identifier` 的字符串值就是 XPC 消息名。** 所以：

- 它一旦发布就是**线格式的一部分**。改掉它 = 老客户端发的消息在新守护进程里找不到 handler，反之
  亦然。改 `identifier` 等同于破坏性变更。
- 两个不同的 `Request` 类型用了同一个 `identifier`，后注册的会**覆盖**先注册的，而且没有任何警告。

### 命名空间约定

| 前缀 | 归属 |
|---|---|
| `com.JH.HelperCommunication.*` | `HelperCommunication` 保留（`Ping`、`FetchVersion`、注册表三件套） |
| `com.JH.HelperPeer.*` | `HelperPeer` 保留（`ServerLaunched`、`ClientReconnected`） |
| `com.JH.HelperService.<Name>.*` | 具体服务 `HelperServices/<Name>Service` |

`CodableTests` 里有一条 `builtInIdentifiersUseHelperCommunicationNamespace` 守着内置的那批前缀。
新增服务时保持这个前缀，除非明确要换命名空间。

## 三、为什么不用 `NSXPCInterface`

Foundation 自带的 `NSXPCConnection` / `NSXPCInterface` 也提供类型化的远程调用，看起来是更"官方"的
选择。没有采用，理由是：

1. **`NSXPCInterface` 的类型检查是运行期的**。你用 `setInterface(NSXPCInterface(with: MyProtocol.self))`
   声明协议，但白名单（`setClasses(_:for:argumentIndex:ofReply:)`）配错、参数类型不在白名单里，都是
   运行期抛异常。而 `Request`/`Response` 的对应关系是编译期的。
2. **它要求 `@objc` 协议**，于是所有载荷类型都得是 `NSObject` 子类并 conform `NSSecureCoding`。
   Swift 的 `struct` + `Codable` 用不了，值语义也丢了。
3. **`async/await` 桥接是后加的**，回复块的语义（只能调一次、不调就泄漏）仍然渗透在 API 里。
4. `SwiftyXPC` 已经把 `Codable` 与底层 `xpc_object_t` 的编解码做好了（包括 `XPCEndpoint` 这类原生
   类型的特化），本层只需在它之上加一个 `identifier` 路由约定。

**代价**：多一个第三方依赖，且这个依赖是 fork 出来的。这是明确接受的取舍。

## 四、新增一种消息的完整步骤

### 1. 在 Interface target 声明请求类型

```swift
// Sources/HelperServices/FooService/Interface/BarRequest.swift
#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
import HelperCommunication

public struct BarRequest: Codable, Request {
    public typealias Response = VoidResponse          // 或自定义 Codable & Sendable 结构体
    public static let identifier: String = "com.JH.HelperService.Foo.Bar"

    public let someParameter: String

    public init(someParameter: String) {
        self.someParameter = someParameter
    }
}
#endif
```

### 2. 在 Implementation target 装处理器

```swift
public func setupHandler(_ handler: some HelperHandler) async {
    handler.setMessageHandler { (request: BarRequest) -> BarRequest.Response in
        // 干活
        return .empty
    }
}
```

`HelperHandler.setMessageHandler` 这个重载**从闭包参数的类型推导出 `Request` 类型**，再用它的
`identifier` 注册。所以不需要（也不应该）手写消息名。

> **绝不要在业务代码里直接调用 `SwiftyXPC` 的无类型 API。** 那会绕过 `identifier` 约定，把本层想
> 消掉的三类错误重新引入。

### 3. 演进时的兼容性

新增字段用 `Optional` 并给默认值，这样老客户端发来的、不含该字段的载荷仍能解码：

```swift
public let preferredStrategy: InjectionStrategy?      // nil = 老客户端 / 未指定

public init(..., preferredStrategy: InjectionStrategy? = nil) { ... }
```

`InjectionStrategyTests` 里的 `requestFromAPeerPredatingPreferredStrategyDecodes` 用一段手写 JSON
钉住了这个行为 —— 新增可选字段时照抄这个测试。

**枚举上线要用显式 raw value**：

```swift
public enum InjectionStrategy: String, Codable, Sendable, Equatable {
    case dlopen = "dlopen"
    case machVirtualMemoryRemap = "machVirtualMemoryRemap"
}
```

用 `String` 而非默认的整型序号，是为了让线格式与 case 的**声明顺序**解耦 —— 否则中间插一个 case
就会静默改变旧 peer 的解码结果。`injectionStrategyRawValuesAreStable` 守着这一点。

## 五、把 XPC 原生类型放进业务消息

有时消息里要带 `XPCEndpoint`（例如把一个被注入进程的监听端点登记到注册表）。直接用
`SwiftyXPC.XPCEndpoint` 会迫使调用方 `import SwiftyXPC`，违反[隐藏依赖](ModuleLayering.md#三xpchelperhandler一个刻意做成半透明的适配器)
那条约束。

`HelperPeerEndpoint` 是为此而设的不透明包装，关键在它的 `Codable` 实现：

```swift
public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    self.underlying = try container.decode(SwiftyXPC.XPCEndpoint.self)
}
public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(underlying)
}
```

走 `singleValueContainer` 是**刻意的**：这样 `XPCEncoder`/`XPCDecoder` 会命中它们对 `XPCEndpoint`
的内建特化，直接读写原生 `xpc_endpoint_t`，而不是去调 `XPCEndpoint.encode(to:)`（SwiftyXPC 那边
那个方法是个会抛错的占位实现）。

**结果是线格式与裸 `XPCEndpoint` 逐位相同** —— 包一层不改变守护进程或 peer 看到的字节。所以可以
在一端用包装、另一端用裸类型，不会出问题。

## 六、错误怎么跨边界

前面几节讲的都是**成功路径**的线格式。失败路径走另一套机制，而且它有一个不看代码就撞不上的坑。

### 通道只搬 domain 和 code

SwiftyXPC 用 `XPCErrorRegistry.BoxedError` 搬运错误。它写上线的只有两样东西：`domain` 和 `code`。
完整的错误体只在**同时满足**两个条件时才写入：

1. 抛出的错误是 `Error & Codable`；
2. **接收方**用 `XPCErrorRegistry.shared.registerDomain(_:forErrorType:)` 注册过这个 domain。

`NSError` 不是 `Codable`，所以它走第一条的反面：`userInfo` 连同 `localizedDescription` 在编码阶段
就没了（`BoxedError.errorUserInfo` 直接硬编码为 `[:]`）。Swift 的 enum 错误只要没实现 `Codable`
也是一样。

也就是说，**服务端在错误里写的任何解释文字，默认都到不了调用方**。调用方拿到的是
`SomeErrorDomain error 1.` 这种东西。

### 包装：`HelperServiceFailure`

修法在通道层，不在各个服务里。`ServiceFailureTransport.wrappingFailures(requestIdentifier:operation:)`
包住每一个 handler：

- 抛出的错误**已经是** `Error & Codable` → 原样重抛，不碰。SwiftyXPC 自己能把它完整搬过去。
- 其余（含全部 `NSError`）→ 包装成 `HelperServiceFailure`，同时在 daemon 侧记一条 `#log(.error, …)`。

`HelperServiceFailure` 靠 `CustomNSError` 把 `_domain` 钉死成
`"com.JH.HelperCommunication.ServiceFailure"`（注册表要靠它查类型），同时用实例属性 `errorCode`
透传原始 code。**于是调用方那边 `code` 不变，只有 `domain` 变**，原 domain 保存在
`underlyingErrorDomain` 里。

`localizedFailureDescription` 与 `underlyingErrorDebugDescription` 两个字段都存在，是因为它们互相
补不上对方：Swift enum 错误没实现 `errorDescription` 时 `localizedDescription` 是一句通用废话，
case 名只在 `String(describing:)` 里。

### 两条不能碰的线

**`HelperServiceFailure.errorDomain` 那个字符串是线格式的一部分**，与 `Request.identifier` 同性质。
改它 → 两端对不上 → 退回 `BoxedError` → 描述又丢了，**而且不报错**。字段也只增不减，新增必须
`Optional` 或带默认值。

**`Error & Codable` 的放行分支不能去掉。** SwiftyXPC 自己的 `XPCConnection.Error` 就在预注册名单
里，`HelperClient.errorIndicatesOutdatedPeer(_:)` 认的正是它；一旦被包装成 `HelperServiceFailure`，
那个判别器会对所有错误返回 `false`。`swiftyXPCErrorFromAHandlerIsRelayedIntact` 守着这条。

### 注册由库自己做

`HelperClient.init`、`HelperPeerClient.init`、`HelperPeerServer.init` 各自调一次
`HelperServiceFailure.registerForDecoding()`。**不要求调用方注册**是刻意的：忘记注册的表现是「静默
退回修复前的行为」，没有任何编译错误或运行期提示——这类失败模式必须由库自己关掉。

### 已知缺陷：消息名不认识时，调用方分辨不出来

`XPCConnection.Error.unexpectedMessage` 在整个 SwiftyXPC 里**只有一处抛出**
（`XPCConnection.respond(to:)` 找不到 handler 时），而那一处把错误交给**接收方自己的**
`errorHandler` 后就 `return` 了，**不回复发送方**。发送方一直等不到回复，最后拿到的是
`XPCError.connectionInterrupted`。

后果：`HelperClient.errorIndicatesOutdatedPeer(_:)` 永远不会返回 `true`，
`fetchToolVersion()` 那条「tool 太旧，请重装」的分支实际上打不开，旧 daemon 会被误判成临时故障。
这个缺陷自 `a49e713` 引入起就存在，与错误包装无关，也没有被本次改动改善或恶化。
`unhandledMessageDoesNotReachTheCallerAsUnexpectedMessage` 把当前这个（错误的）行为钉住了 ——
哪天上游改成会回复，那个测试会失败并提醒我们判别器可以重新信任了。
