# 线格式兼容性：只增不改

**前置**：[类型化消息层](TypedMessaging.md)——`Request.identifier` 为什么是路由键。本文讲的是
在那之上加的一条**承诺**，以及它为什么从某个时刻起变成必需的。

## 一、以前不需要这条承诺，现在需要

在[共享注入 daemon](../Evolutions/draft-shared-injection-daemon.md) 之前，每个 App 自带一个特权
tool，两者**一起编译、一起安装、一起升级**。线格式变了也没人看得见——没有任何一刻存在「新客户端
对老 tool」的组合。

共享 daemon 把这个前提拿掉了。一个 daemon 同时服务若干独立发版的客户端，于是必然出现：

- 新客户端 + 老 daemon（用户还没升平台 App）
- 老客户端 + 新 daemon（平台升了，某个工具没升）

**第二种必须永远能工作**，否则升级平台就会打断手上所有工具。第一种要能被**认出来**并给出可操作
的提示，而不是以一个莫名其妙的连接错误收场。

## 二、承诺

**已发布的消息类型不改签名。要变就加新的。**

具体到四样东西，它们都已经是线格式，改动不会有编译错误、只会在运行期静默失配：

| 东西 | 为什么是线格式 |
|---|---|
| `Request.identifier` | 它就是 XPC 消息名，收发两端靠它对上。详见 [TypedMessaging.md](TypedMessaging.md) |
| `HelperServiceFailure.errorDomain` | 改了之后两端都退回裸 box，描述丢失且无编译错误。详见 [Evolution 0002](../Evolutions/0002-service-errors-that-survive-xpc.md) |
| `InjectionStrategy` 的 `rawValue` | 字符串是刻意写死的，使重排或插入 case 不会改变老对端的解码结果 |
| `FetchVersionRequest.Response.version` 的**格式** | 见第四节：它是 `major.minor.patch`，而不只是「某个字符串」 |

### 允许的演进

- **加一个新的 `Request` 类型。** 这是扩展能力的默认手段。老 daemon 收到不认识的消息不会崩，
  只是不回复（后果见第四节）。
- **给已有的 `Request` 加字段，但必须是 `Optional` 或有默认值。** 老对端发来的消息没有这个字段，
  必须解码成 `nil` 而不是失败。`RegisterEndpointRequest.registrantProcessIdentifier` 就是按这条
  加的：老 peer 不报 pid，那一条注册退化回原来的只增不减行为，而不是整个注册失败。
- **加一个 `enum` case**，前提是老对端遇到它时的行为是定义好的。

### 不允许的

- 改 `identifier` 字符串，包括「只是改个拼写」。
- 改已有字段的类型、名字，或把 `Optional` 收紧成必填。
- 删除已发布的 `Request` 类型或它的字段。
- 改 `InjectionStrategy` 已有 case 的 `rawValue`。

需要一个形状完全不同的请求时，加一个新类型、新 identifier，让老的继续工作。

## 三、这条承诺不管什么

**Swift API 的源码兼容性是另一回事。** 本库以源码分发，使用方每次重新编译，所以改一个 Swift 签名
只会产生编译错误——吵，但不会静默出错。线格式的失配才是静默的，这条承诺针对的是后者。

一次改动可以源码破坏而线格式兼容（`HelperServerType.plain` 去掉那个废参数就是），也可以反过来
（给 `Request` 加一个必填字段，Swift 侧可能只是多一个带默认值的参数，线格式却已经断了）。
**判断时看的是消息，不是签名。**

## 四、版本协商：主动问，不要从错误里猜

### 为什么必须主动问

看起来最省事的做法——发一条新消息，从失败里判断对端是不是太老——**行不通**，而且不是实现缺陷，
是上游行为决定的：

`HelperClient.errorIndicatesOutdatedPeer(_:)` 只在 `SwiftyXPC.XPCConnection.Error.unexpectedMessage`
时返回 `true`。SwiftyXPC 只在一个地方抛它：`XPCConnection.respond(to:)` 遇到未知消息名时。而那条
路把错误交给**接收方自己**的 `errorHandler`，然后**直接返回、不回复**。发送方那边等到的是
`XPCError.connectionInterrupted`——和网络抖动、daemon 崩溃完全一样。

所以**过旧的 daemon 与掉线无法区分**。这个判别器保留着，是因为测试
`unhandledMessageDoesNotReachTheCallerAsUnexpectedMessage` 钉住了上游这个行为：哪天 SwiftyXPC 改成
回复一个错误，那个测试就会失败，届时判别器才重新可用。**在那之前不要依赖它。**

### 怎么问

```swift
let client = HelperClient(...)
try await client.connectToTool(machServiceName: "com.JH.injectiond", isPrivilegedHelperTool: true)

// Right after connecting, before anything version-dependent goes out.
try await client.requireToolVersion(atLeast: HelperToolVersion(major: 1, minor: 2, patch: 0))
```

不满足时抛 `HelperToolVersionMismatch`，它分两种情况：daemon 确实更旧，或者 daemon 报了个读不出
来的版本串。**后者也当作不满足**——读不出版本的 daemon 无法被证明满足要求，放行只会让问题推迟到
某个与版本无关的调用点上爆发。

### 为什么版本要有个类型

`FetchVersionRequest` 回的是 `String`，而直接比较字符串是错的：`"0.10.0" < "0.9.0"` 为真。
`HelperToolVersion` 是对那个字符串的**约定解释**（`major.minor.patch`），线格式一个字节都没改。
`HelperToolVersionTests` 里专门有一条用例把这个字符串比较的陷阱钉住。

### daemon 侧填什么

`HelperServer.init(serverType:version:services:)` 的 `version` 必须是 `major.minor.patch`。
**daemon 的版本独立于本库的版本**，它描述的是「这个 daemon 二进制提供哪些能力」。加了新的
`Request` 就递增 minor；只是修 bug 递增 patch。

## 五、改动检查清单

动任何 `Request`、`identifier`、`errorDomain` 或 `rawValue` 之前：

1. 这是**加**还是**改**？改——停下，换成加一个新类型。
2. 新字段是 `Optional` 或有默认值吗？不是——老对端的消息会解码失败。
3. 老 daemon 收到这条新消息会怎样？它不回复，客户端等到 `connectionInterrupted`。所以依赖新消息
   的客户端必须先 `requireToolVersion(atLeast:)`。
4. daemon 的 `version` 递增了吗？加了新能力就要递增，否则客户端没办法要求它。
5. `CHANGELOG.md` 写了吗？线格式变更和源码破坏都要写，源码破坏还要附上调用方会看到的编译错误。
