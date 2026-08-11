# 0002 - 服务端错误跨 XPC 保住描述，并在 daemon 侧留下日志

- **状态**: Draft
- **作者**: JH
- **创建日期**: 2026-08-11
- **最后更新**: 2026-08-11
- **所属愿景**: 无
- **关联提案**: [0001](0001-injection-strategy-attempt-not-predict.md) —— 本提案修复的正是 0001
  写下的那些诊断文案至今没有一条能到达调用方
- **实现分支 / PR**: 待定
- **配套文档**: 拟新增 `Documentations/Guides/InjectionPrerequisites.md`（注入的运行前提，含
  AMFI library validation 那条）

## 摘要

`swift-helper-service` 的服务端抛出的错误，跨 XPC 到达调用方时**只剩 domain 和 code**，描述文字
全部丢失。这不是某个服务的疏漏，而是通道层的行为：SwiftyXPC 用 `XPCErrorRegistry.BoxedError`
搬运错误，它只搬运 `domain` / `code`，外加「当错误本身是 `Error & Codable` 且**接收方注册过该
domain**」时才写入的完整错误体。`NSError` 不是 `Codable`，所以走前一条路，`userInfo` 连同
`localizedDescription` 在编码阶段就没了 —— `BoxedError.errorUserInfo` 甚至直接硬编码为 `[:]`。

叠加第二个问题：`InjectionService` 在 daemon 侧一行日志都没有。于是失败**两端都不留痕**：调用方
看到 `MIMachInjectorErrorDomain error 1`，daemon 侧什么也没写。

本提案在**通道层**统一修：新增一个 `Codable` 的传输错误类型，在所有 handler 的统一入口把非
`Codable` 的错误包装进去并同时写日志，由 `HelperClient` / `HelperPeer*` 自动完成解码侧的 domain
注册。所有现有服务一行不改即受益。

## 动机

### 谁被卡住了

一个下游项目（`FinderSidebarIconFix`，pin 在 `0.1.4`）注入 Finder 失败，界面上只有一句：

```
The operation couldn't be completed. (MIMachInjectorErrorDomain error 1.)
```

真实原因是 AMFI 的 library validation 拒绝了 payload。`MachInjector` 其实生成了一条足够定位问题的
描述：

```
target process refused to load /Library/Application Support/.../FinderSidebarIconFixPayload: <dlerror 文本>
```

这句话一个字都没到达调用方。定位根因最后是靠翻内核日志完成的 —— 而 `MachInjector` 那边十几种失败
原因全都用 `MIMachInjectorErrorDomain` code 1，所以调用方拿到的信息量**精确地等于零**。

### 病根在通道层，不在 `InjectionService`

上游报告把它归因为 `InjectionService` 的两个 handler 直接把 `NSError` 原样往外抛。这个描述对
`0.1.4` 是准确的，但**修在那里是修错了地方**：

- 病根是 `BoxedError` 的搬运语义，`FilesService`、`ApplicationsService`、
  `InjectedEndpointRegistryService`、`MainService` 抛的错**全部同样降级**。逐个 handler 包一层
  try/catch，等于把同一段代码抄五遍，还漏掉未来新增的服务。
- 更要命的是：**当前 main 上的 `InjectionService` 也照样丢**。0001 在 `makeError(code:description:)`
  里精心写的那几段解释 —— 「需要 entry symbol，且这里附上 dlopen 被拒的原文」「注入报告成功但进程
  没了，多半是页哈希不匹配被内核在 page-in 时杀掉」「目标带 `CS_REQUIRE_LV`，AMFI 可能是原因」——
  调用方一个字也看不到，只能看到 `com.JH.HelperService.InjectionService` + `-2`。

也就是说，0001 花力气产出的诊断信息，**全部烂在 daemon 进程里**。这不是新引入的回归，是从来没通过
的一条路；0001 没有发现它，是因为本仓库没有任何真实 XPC 往返的测试（见 0001 的「验证覆盖与缺口」）。

### 为什么现在特别贵

注入这件事的失败原因高度依赖宿主机状态（SIP、AMFI、签名、沙盒、目标进程是否还活着），**排查全靠
那句描述**。0001 的整个设计前提就是「不预测，让目标自己拒绝，然后把拒绝的原文告诉调用方」——
第二步一直是断的，等于 0001 只落地了一半。

daemon 侧无日志让它彻底不可诊断：错误传不出去，本地又不留痕，只剩翻内核日志这一条路。**这一条比
错误传输更基础** —— 即使将来 `MachInjector` 分配了不同错误码，`dlerror` 的原文仍然是最有价值的
部分，而它只有 daemon 看得见。

## 前期调研

### `BoxedError` 到底搬运了什么

按 `Package.resolved` 里 pin 的 revision `4f67b80d2d21b0968ec6c6c45aa01389f1f1ed05` 核对
（**不是** `.build/checkouts` 里那份 —— 那份的 HEAD 是 `2422440`，与 pin 的对不上；0001 的决策日志
记过同一个坑，这次直接从 GitHub 拉的 pinned 源码）：

| 位置 | 事实 |
|---|---|
| `XPCErrorRegistry.swift:147` | `errorUserInfo` 硬编码为 `[:]` |
| `:179-183` | `error as? (Error & Codable)` 成功才存 `.codable`，否则只存 `.uncodable(code:)` |
| `:211-220` | 编码只写 `domain` / `code`；`encodedError` 仅在 `.codable` 时写 |
| `:197-203` | 解码要 `errorType(forDomain:)` 查得到注册项，否则退回 `.uncodable` |
| `:63-66` | 预注册的只有 `XPCError` 和 `XPCConnection.Error` 两个类型 |

`:63-66` 这一条顺带解释了一件既有的事：`HelperClient.errorIndicatesOutdatedPeer(_:)` 之所以能工作，
正是因为它认的 `XPCConnection.Error` 恰好在预注册名单里。**这也意味着任何修改都不能把它碰坏。**

### 实测：`CustomNSError` 能钉死 `_domain`，同时保住原 code

方案能否成立，取决于一个前提：能不能造一个类型，让 SwiftyXPC 编码时看到的 `_domain` 是一个**固定
的、可注册的**字符串，同时让调用方拿到的 `code` 仍是原始 code。实测（`swiftc -O`，本机 macOS
26.6）：

```swift
struct WrappedFailure: Error, Codable, CustomNSError, LocalizedError {
    static var errorDomain: String { "com.JH.HelperCommunication.ServiceFailure" }
    let underlyingDomain: String
    let underlyingCode: Int
    let message: String
    var errorCode: Int { underlyingCode }
    var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: message] }
    var errorDescription: String? { message }
}
```

结果：

```
_domain      = com.JH.HelperCommunication.ServiceFailure   ← 钉死了，注册表查得到
_code        = 1                                            ← 原 code 透传
localizedDesc= target process refused to load /x: dlerror text
isCodable    = true                                         ← 走 .codable 分支
NSError isCodable = false                                   ← 现状确认：NSError 走 .uncodable
```

两个结论：

1. **`CustomNSError` 的 `static errorDomain` 确实决定 `_domain`**（Foundation 对 `CustomNSError`
   的 `_domain` 默认实现就是 `Self.errorDomain`），而 `errorCode` 是 instance property，可以返回
   原始值。于是**破坏面只有 domain 一项，code 保持不变** —— 比动手前估计的小。
2. **`NSError` 确实不满足 `Error & Codable`**，现状走 `.uncodable`，描述在编码阶段丢失。上游报告的
   诊断成立。

### 包装点盘点

服务端所有会抛错到线上的 handler 入口，只有三类：

| 入口 | 位置 | 覆盖谁 |
|---|---|---|
| `XPCListener.setMessageHandler(requestType:handler:)` | `HelperCommunication/XPCExtensions.swift:13` | **typed 路径的唯一底座**。`XPCHelperHandler` 和 `HelperPeerServer` / `HelperPeerClient` 的 typed 版本都调它，因而覆盖全部 `HelperService` 实现 |
| `HelperPeer*` 的 4 个 name-based `setMessageHandler` 重载 | `HelperPeerServer.swift` / `HelperPeerClient.swift` | 直接调 SwiftyXPC，绕开上面那条 |
| `HelperPeer*` 的握手内部 handler | 同上 | 库自身的握手消息 |

第一条是关键发现：**typed 路径只有一个底座**，改一处就覆盖了所有服务（含未来新增的）。

### 日志设施现状

- `@Loggable` / `#log` 来自 `FrameworkToolbox` 的 `FoundationToolbox`，仓库里已在
  `HelperServer`、`HelperPeerServer`、`HelperPeerClient` 三处使用（都只用于 `errorHandler`）。
- `HelperCommunication` **已经**依赖 `FoundationToolbox`（`Package.swift:158-163`），无需新增依赖。
- `InjectionServiceImplementation` **没有**依赖它 —— 这就是它一行日志都没有的直接原因。
- 另有一处不一致：`HelperClient` 和 `MainService` 用的是裸 `print(error)`（`AGENTS.md` 的
  「Known rough edges」已记录）。本提案不处理，见「非目标」。

## 提议方案

在 `HelperCommunication` 新增传输错误类型 `HelperServiceFailure`，并在通道层统一做三件事：

1. **包装**：handler 抛出的错误若**不是** `Error & Codable`，就地包装成 `HelperServiceFailure`，
   保留原 domain、原 code、`localizedDescription` 全文、`String(describing:)` 全文，以及是哪条
   request 失败的。已经是 `Error & Codable` 的错误**原样放行**，不碰。
2. **记日志**：在同一个包装点写一条 `#log(.error, ...)`，带 request identifier 与完整描述。这样
   即使错误在传输中出了别的岔子，daemon 侧也留痕。
3. **自动注册**：由 `HelperClient.init` / `HelperPeerClient.init` / `HelperPeerServer.init` 调用
   `XPCErrorRegistry.shared.registerDomain(_:forErrorType:)` 注册 `HelperServiceFailure`，调用方
   无需手动注册。

外加一项服务级改动：`InjectionServiceImplementation` 接入 `@Loggable`，在注入路径上记录通道层看不到
的上下文（pid、payload 路径、选了哪条策略、dlopen 被拒的原文）。

### 非目标

- **不改 `MachInjector` 的错误码分配** —— 属上游仓库，已另行上报。本提案让描述文字传得出来，这本身
  就绕开了「十几种原因共用 code 1」的问题，不依赖上游先动。
- **不统一 `HelperClient` / `MainService` 的 `print(error)`** —— 那是另一件事（日志风格一致性），
  牵连面不同，不塞进本提案。
- **不改 `Request` / `Response` 协议，不把错误挪进 Response 载荷** —— 见「替代方案考量」。
- **不为每个服务定义各自的错误类型** —— 那要求调用方逐个注册 domain，漏一个就静默退回现状。
- **不改 `InjectionService` 的选路逻辑与错误码** —— 0001 刚定，本提案只让它的输出传得出去。
- **不引入日志级别配置或日志开关。**

## 详细设计

### `HelperServiceFailure`（新增，`HelperCommunication`，`public`）

```swift
public struct HelperServiceFailure: Error, Codable, Sendable, CustomNSError, LocalizedError {
    /// 钉死的 domain。它是线格式的一部分（解码侧靠它查注册表），
    /// 改动等同破坏性变更 —— 与 `Request.identifier` 同性质。
    public static let errorDomain = "com.JH.HelperCommunication.ServiceFailure"

    /// 原错误的 domain。包装前是调用方在 `(error as NSError).domain` 看到的值。
    public let underlyingErrorDomain: String

    /// 原错误的 code，通过 `errorCode` 透传，所以 `(error as NSError).code` 不变。
    public let underlyingErrorCode: Int

    /// 原错误的 `localizedDescription` 全文。
    public let localizedFailureDescription: String

    /// 原错误的 `String(describing:)` 全文。Swift enum 错误的
    /// `localizedDescription` 往往是无用的通用文案，case 名只在这里看得到。
    public let underlyingErrorDebugDescription: String

    /// 失败的那条消息的 `Request.identifier`。通道层知道，服务实现不必自己填。
    public let requestIdentifier: String?

    public var errorCode: Int { underlyingErrorCode }
    public var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: localizedFailureDescription] }
    public var errorDescription: String? { localizedFailureDescription }
}
```

注册用的 domain 显式传字符串，**不**用 `registerDomain(nil, ...)` 的默认值
`String(reflecting: errorType)` —— 后者是 `"HelperCommunication.HelperServiceFailure"`，改个模块名
或类型名就静默失效，而失效的表现恰好是「退回现状」，不会有任何编译或运行期报错。

### 包装点

`HelperCommunication` 新增一个 `package` 的包装函数：

```swift
package func wrappingFailuresForTransport<Result>(
    requestIdentifier: String?,
    operation: () async throws -> Result
) async throws -> Result
```

行为：
- `operation()` 正常返回 → 原样返回。
- 抛出的错误是 `any Error & Codable` → **原样重抛**。这条保住 SwiftyXPC 自己的
  `XPCConnection.Error` / `XPCError`（因而保住 `errorIndicatesOutdatedPeer`），也保住调用方自定义
  的、已经 `Codable` 的业务错误。
- 其余 → `#log(.error, ...)` 后抛出 `HelperServiceFailure`。

接入位置：
1. `HelperCommunication/XPCExtensions.swift:13` 的 `XPCListener.setMessageHandler(requestType:handler:)`
   —— 一处覆盖全部 typed handler，`requestIdentifier` 填 `requestType.identifier`。
2. `HelperPeerServer` / `HelperPeerClient` 的 4 个 name-based 重载 —— `requestIdentifier` 填
   那个 `name`。
3. `HelperPeer*` 的握手内部 handler。

`XPCHelperHandler`、`HelperServer`、以及全部现有服务实现**一行不改**。

### 注册点

```swift
XPCErrorRegistry.shared.registerDomain(
    HelperServiceFailure.errorDomain,
    forErrorType: HelperServiceFailure.self
)
```

在 `HelperCommunication` 里包一个幂等的 `package` 入口，由 `HelperClient.init`、
`HelperPeerClient.init`、`HelperPeerServer.init` 各调一次（peer 双向都可能收到对端的错误，两边都要
注册）。`XPCErrorRegistry.shared` 是全局单例、注册是幂等赋值，重复调用无害。

不要求调用方做任何事 —— 「忘了注册就静默退回现状」是这类设计最典型的失败模式，必须由库自己关掉。

### `InjectionService` 的日志

`Package.swift` 给 `InjectionServiceImplementation` 加 `FoundationToolbox` 依赖，类型加 `@Loggable`，
在这几处记录通道层拿不到的上下文：

- 进入注入：pid、payload 路径、选定的策略、是否允许退回。
- `dlopen` 被拒、准备退回 remap：**被拒的原文**（这正是本次事故里唯一有用的那句话）。
- 抛出三种 `makeError` 之前：各自的完整描述。

日志用 `privacy: .public` —— daemon 以 root 运行，payload 路径与 pid 不是用户隐私，打成
`<private>` 会让日志重新变得没用。

## 替代方案考量

### 只在 `InjectionService` 的 handler 里包 try/catch

上游报告的建议。改动最小，但把通道层的病当成服务的病来治：其余四个服务照样丢描述，将来每新增一个
服务都要记得抄一遍，而漏抄的表现是「静默退回现状」。**否决**。

### 把诊断信息放进 `Response`，不走错误通道

即让 `InjectApplicationRequest.Response` 从 `VoidResponse` 变成带成功/失败与描述的结构。这样完全
绕开 `BoxedError`。但它把「失败」从 `throw` 变成返回值，调用方的 `try` 不再表达失败，每个调用点都要
手动检查 —— 是把类型系统已经提供的保障换成人工纪律。且要对所有服务做同样的改造。**否决**。

### 保持 `NSError` 的原 domain，让注册表按原 domain 查

这是唯一能让 domain 也不变的方向，但不可行：原 domain 是任意的（`MIMachInjectorErrorDomain`、
`NSPOSIXErrorDomain`、各服务自己的……），解码侧无法预先穷举注册。`XPCErrorRegistry` 也没有通配注册
的 API。这是一个**硬约束**：要么 domain 固定、内容传得出去，要么 domain 保真、内容传不出去，没有
第三种。本提案选前者，并接受 domain 变化作为已知破坏性。

### 给 `XPCErrorRegistry.BoxedError` 补一个 `@retroactive CustomNSError` 空实现

SwiftyXPC 的文档注释建议 Foundation 客户端这么做（`XPCErrorRegistry.swift:117`），能让**未被包装
的**错误的 domain / code 表现正确。它与本提案不冲突，但独立于本提案的目标（那是让 `BoxedError` 表现
得更像 `NSError`，不是让描述传得出去），且是对第三方 public 类型的 retroactive conformance，有其自身
的风险。**本轮不做**，记在这里备查。

### 不做自动注册，让调用方自己注册

少一处库对全局单例的写入，看起来更克制。但代价是：调用方忘记注册 → 解码退回 `.uncodable` →
描述丢失 → **表现与修复前完全一致，且没有任何提示**。这个失败模式的成本远高于自动注册的代价。**否决**。

## 影响

### 源码兼容性（source compatibility）

**编译不破坏** —— 无 API 删除、无签名变更，纯新增。下游重新编译即可通过。

**行为破坏一处**：调用方从服务端收到的错误，`(error as NSError).domain` 从原 domain 变为
`"com.JH.HelperCommunication.ServiceFailure"`。

- `code` **不变**（实测已确认，见前期调研）。
- `localizedDescription` 从「通用无信息文案」变为「服务端的原始描述」—— 这是改进，但依赖它做**字符串
  匹配**的代码会受影响。
- 迁移方式：按 domain 分支的代码改读 `HelperServiceFailure.underlyingErrorDomain`。

评估其影响面：现状下调用方能拿到的只有 domain + code，而 `MachInjector` 十几种失败共用 code 1、
`InjectionService` 的三个 code 是 0.2.0 才引入的 —— **在这个 domain 上做分支本来就得不到有用的
结论**。已知的唯一下游（`FinderSidebarIconFix`）就是因为分支不出任何东西才来报的问题。

### ABI 兼容性

**不适用**。本包以 SPM 源码分发，未启用 library evolution，无 `binaryTarget`。

### 下游影响

- 已知下游 `FinderSidebarIconFix`（现 pin `0.1.4`）：升级后失败原因可直接展示给用户，正是它需要的。
  它没有按 domain 分支的代码。
- 通用调用方：若已在 `catch` 里按 `(error as NSError).domain` 分支，需按上面的迁移方式改。
  `CHANGELOG.md` 要写明这一条，并给出改法。

### 文档与示例

- `AGENTS.md`：「Known rough edges」增补错误传输一节；`InjectionService` 相关处补日志说明。
- `Documentations/Architecture/TypedMessaging.md`：补一节「错误怎么跨边界」—— 这是该文档现有的
  空白，它讲了 `Request` / `Response` 的线格式，没讲错误的。
- 新增 `Documentations/Guides/InjectionPrerequisites.md`（`Guides/` 目录本仓库尚不存在，需新建并
  登记进 `Documentations/README.md`）：注入的运行前提，含下面这条。
- `Documentations/Glossary.md`：`library validation` 词条补充「关 SIP 不等于关 LV」。

#### 待写入指南的运行前提（来源见下）

关闭 SIP **不足以**把非平台签名的 dylib 注入 Apple 平台二进制（Finder、Dock、开关面板服务）。逆
macOS 26.6 的 `/usr/libexec/amfid` 得到的判定链：`sub_1000056EC` 取
`csr_check(CSR_ALLOW_TASK_FOR_PID = 4) != 0`，`sub_100005718` 取
`csr_check(CSR_ALLOW_APPLE_INTERNAL = 16) == 0`；`sub_100005098` 只在「SIP 关了」或「Apple 内部机」
时才去读 `/Library/Preferences/com.apple.security.libraryvalidation.plist` 的
`DisableLibraryValidation`，读到的值写进全局标志；`sub_100002360` 拿这个标志回答内核的查询，为真才
放行并打 `library validation is globally disabled`。

即**关 SIP 只打开了「允许读那份 plist」这道门，真正的开关是 plist 里的值**：

```bash
sudo defaults write /Library/Preferences/com.apple.security.libraryvalidation.plist DisableLibraryValidation -bool true
```

> **来源与验证状态**：判定链来自 `FinderSidebarIconFix` 项目一次排查中对 macOS 26.6 `amfid` 的
> 逆向，**结论已由项目作者验证**（关 SIP 才读 plist、plist 的值才是开关、SIP 开启则直接忽略该
> 文件）。函数名与偏移是那次逆向的产物，换一个系统版本即失效；**结论本身不依赖它们**。

这条同时**订正了本仓库里三处写错的注释**（`InjectionStrategy+Probe.swift` 的
`isLibraryValidationEnforced`、`InjectionStrategy.swift` 的 `.dlopen`、
`InjectionStrategyTests.swift` 的回归测试说明）。原注释断言「关 SIP 本身就放松了 LV 强制」，并据此
推出「凡是能走到这个探测的目标，一般都处于 LV 不强制的配置」。后半句是错的：SIP 关了但 plist 没写
（默认值）的机器上 LV 照样强制，**而这正是本次事故那台机器的状态**。术语表 `library validation`
词条一并订正。

## API 演进与废弃策略

- **`HelperServiceFailure.errorDomain` 的字符串是线格式的一部分**，与 `Request.identifier` 同性质：
  改它会让「新客户端 + 旧 daemon」或反之退回 `.uncodable`（表现为描述丢失，不报错）。除非走提案，
  否则不得改动。
- **字段只增不减**：新增字段必须是 `Optional` 或带默认值，否则旧 daemon 编出的载荷会在新客户端上
  解码失败 —— 而失败的位置在 `BoxedError.init(from:)` 内，会退回 `.uncodable`，同样是静默降级。
- **无废弃项**，不需要 `@available(*, deprecated)`。
- **版本号**：发 **0.3.0**。虽然编译不破坏，但 `NSError.domain` 变了，属行为破坏，不发 patch。

## 落地步骤

1. `Sources/HelperCommunication/HelperServiceFailure.swift`（新增）—— 类型 + 幂等注册入口。
2. `Sources/HelperCommunication/XPCExtensions.swift` —— 包装函数；接进 typed 底座。
3. `Sources/HelperPeer/HelperPeerServer.swift` / `HelperPeerClient.swift` —— 4 个 name-based 重载
   与握手 handler 接入包装；`init` 调注册。
4. `Sources/HelperClient/HelperClient.swift` —— `init` 调注册。
5. `Package.swift` —— `InjectionServiceImplementation` 加 `FoundationToolbox`。
6. `Sources/HelperServices/InjectionService/Implementation/InjectionService.swift` —— `@Loggable`
   + 注入路径日志。
7. 测试（见下）。
8. 文档：`TypedMessaging.md`、新建 `Guides/InjectionPrerequisites.md`、`Documentations/README.md`
   索引、`CHANGELOG.md`。
   - `CHANGELOG.md` 里 0.2.0 那条记录的实测环境只写了「SIP disabled + 无
     `amfi_get_out_of_my_way`」，漏了 plist 这个条件。**已发布条目不改写** —— 在 0.3.0 的新条目里
     补明这个限定，按 CHANGELOG 惯例处理。
   - `AGENTS.md`、`Glossary.md`、0001 的后记、以及三处源码注释的 LV 订正**已先行落地**（2026-08-11，
     独立于本提案的代码改动，因为它们是纯粹的事实订正，不需要等提案批准）。
9. 本提案状态推进到 `Implemented`，与代码同批次提交。

## 验证计划

**先写复现测试，确认它在修复前失败**（全局规矩），再动实现。

### 一、`HelperCommunicationTests` 新增

- `HelperServiceFailure` 的 `Codable` 往返（与现有 round-trip 测试同风格）。
- `_domain` 等于钉死的字符串；`errorCode` 等于 `underlyingErrorCode`；
  `localizedDescription` 等于 `localizedFailureDescription`。
- 包装函数：非 `Codable` 的 `NSError` 被包装且描述保住；`XPCConnection.Error` **原样透传不被包装**
  （这条直接守护 `errorIndicatesOutdatedPeer`）。
- 注册入口幂等。

### 二、真实 XPC 往返（尽力做，做不成如实记为缺口）

本仓库目前**没有任何真实 XPC 往返的测试**，这正是 0001 没能发现本问题的原因。拟尝试在测试进程内用
anonymous `XPCListener` + endpoint 自连，跑一次「服务端抛 `NSError` → 客户端收到完整描述」的端到端
断言。若同进程自连在测试环境下不可行（沙盒 / 权限 / 生命周期），**不迂回、不假装覆盖**，在提案里
如实记为缺口。

### 三、手动验证：真实的 AMFI 拒绝（本轮新增的可能性）

订正 LV 判定链带来一个副产品：**AMFI 的 library validation 拒绝现在是可以按需复现的**。0001 曾判断
它「因 SIP 关闭无法直接复现」（那份提案的「实测：各种拒绝路径的耗时」一节），那个判断建立在「关 SIP
就等于关 LV」这个错误前提上。真实开关既然是 plist 里的值，把它改掉即可在同一台机器上切换：

```bash
# 让 LV 恢复强制（复现被拒）
sudo defaults delete /Library/Preferences/com.apple.security.libraryvalidation.plist DisableLibraryValidation
# 改回放行
sudo defaults write /Library/Preferences/com.apple.security.libraryvalidation.plist DisableLibraryValidation -bool true
```

这条打开了两件本来做不了的验证：

1. **端到端验证本提案的目标** —— 在 LV 强制的状态下注入一个外来 Team ID 的 payload，确认调用方收到
   的是 `dlerror` 原文，而不是 `MIMachInjectorErrorDomain error 1`。这是**本提案唯一的真·验收标准**，
   合成测试替代不了。
2. **0001 遗留的缺口** —— 「`dlopen` 被拒 → 退回 remap」这条链至今没有被真实触发过。

**但不进自动化测试套件**：它要 `sudo`、改的是全机状态、且中途失败会把机器留在 LV 强制的状态下。列为
发布前的手动检查项，步骤写进 `Guides/InjectionPrerequisites.md`。

### 四、已知不覆盖

- 常规注入路径（本仓库的自动化测试从不执行真实注入，与 0001 同）。
- `amfid` 的判定链本身（依赖系统版本，函数偏移换版本即失效）。
- daemon 侧日志是否真的落到 `log stream`（需要一个真实安装的 daemon）。

## 决策日志

- **2026-08-11** —— 起因是 `FinderSidebarIconFix` 的一次排查经由另一个会话转达。上游报告把病因定位
  在 `InjectionService` 的两个 handler，建议逐个包 try/catch。核实后改判：病根在通道层，且 0.1.4
  之后的 main 同样受影响 —— 0001 新写的那些诊断文案也一条都传不出去。修复位置随之从服务层上移到
  通道层。
- **2026-08-11** —— 核对 `BoxedError` 时**没有**读 `.build/checkouts`（其 HEAD `2422440` 与
  `Package.resolved` 的 `4f67b80` 不一致），改从 GitHub 拉 pinned 源码。0001 的决策日志记过同一个
  坑，这次没再踩。
- **2026-08-11** —— 动笔前先用一个独立的 `swiftc` 探针验证 `CustomNSError` 能否钉死 `_domain` 同时
  让 `errorCode` 返回原值。结论成立，于是破坏面从「domain + code 都变」收窄为「只有 domain 变」，
  「影响」一节据此重写。**如果没做这个探针，提案会高估自己的破坏性并可能因此选错方案。**
- **2026-08-11** —— AMFI 那条运行前提经项目作者确认为已验证的结论（关 SIP 只是打开「允许读那份
  plist」的门，plist 里的 `DisableLibraryValidation` 才是开关）。据此订正了源码里三处注释 —— 原注释
  断言「关 SIP 本身就放松 LV 强制」，并推出「走到探测的目标一般 LV 不强制」。**这次事故的机器恰好就
  是被这个错误推论排除掉的那一类**（SIP 关、plist 默认、LV 照常强制）。
- **2026-08-11** —— 订正上一条的副产品：0001 认定「AMFI 拒绝无法直接复现」的前提随之失效，LV 拒绝
  变成可按需复现的。这把本提案从「只能靠合成测试」提升为「有真·验收标准」，并顺带给 0001 留下的
  「dlopen 被拒 → 退回 remap 从未被真实触发」缺口开了一条路。**没有这次订正，本提案会在无法端到端
  验证的前提下落地** —— 而无法端到端验证正是这个 bug 当初能溜过 0001 的原因。
