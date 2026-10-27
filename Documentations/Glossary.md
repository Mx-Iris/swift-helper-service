# 术语表

本项目专有名词与约定用法。

跨项目通用的术语（ABI 与源码兼容性之别、`SPI` 的两个含义、Mach-O、metadata、demangle 等）
收录在全局术语表中，本表只收本项目特有的，不重复登记。全局表不在本仓库内，
位于 iCloud Global 镜像的 `Documentations/Glossary.md`。

## 收录范围

**收**：项目自造词与内部代号；本项目内反复出现的缩写；通用术语在本项目里的**特定含义**；容易混淆
的近义词对，说明如何区分。

**不收**：语言与框架的通用术语（Swift 的 `optional`、AppKit 的 `NSView`）。

## 维护约定

提案或专题文章引入新术语时，**同批次**登记进本表。文档里首次出现该术语时展开一次并链到这里，
之后不必每篇重复解释。

## 术语

按英文名 / 标识符字母序排列。

### broker（引路人）

本项目里特指**特权 tool 在 `HelperPeer` 拓扑中扮演的角色**：它让两个互相找不到对方的非特权进程
交换 `XPCEndpoint`，交换完成后**退出通信链路** —— 后续消息直连，不经过它。

**不要理解成「消息中转」**。tool 不转发任何业务消息，这正是这套设计的要点：特权进程做介绍人，
不做中间人。

- **主要出现在**：`Sources/HelperPeer/`
- **延伸阅读**：[BrokeredPeer.md](Architecture/BrokeredPeer.md)、[Overview.md 第二节](Architecture/Overview.md#二核心决策特权进程只做介绍人不做中间人)

### endpoint registry（端点注册表）

`MainService` 持有的 `[HelperServerInfo: XPCEndpoint]` 字典，是特权 tool 里**唯一**的状态。
sub-server 和 peer 都往里存自己的匿名监听端点，需要连对方的一方从里面取。

它**不理解任何业务语义** —— 只是键值映射。正因如此，同一张表被 `HelperServer` 的 sub-server 发现
流程和 `HelperPeer` 的握手流程两种完全不同的用途复用。

**已知局限**：只增不减，进程退出后条目残留。

- **主要出现在**：`Sources/HelperServices/MainService/MainService.swift`
- **延伸阅读**：[Overview.md 第三节](Architecture/Overview.md#三为什么是端点注册表而不是多个-mach-service)

### library validation：「请求」与「强制」之别

macOS 的一项代码签名策略：进程只接受 Apple 签名或与自身 Team ID 相同的 dylib。**本项目里必须区分
两件常被当成一件的事：**

- **请求（requested）** —— 进程带有 `CS_REQUIRE_LV` 标志位（`0x2000`），可用 `csops(CS_OPS_STATUS)`
  读出。这是二进制签名时用 `--options library` 写进去的**意图**。
- **强制（enforced）** —— 内核 AMFI 真的按该策略拒绝 dylib 加载。是否强制取决于**系统状态**，
  而且要**同时**满足两个条件才会关掉：SIP 关闭，**并且**
  `/Library/Preferences/com.apple.security.libraryvalidation.plist` 里的 `DisableLibraryValidation`
  为真。

**「关了 SIP 就不会被 LV 拦」是错的**，这是本项目踩过的坑。`amfid` 的判定链是：只有 SIP 关闭
（或机器是 Apple 内部机）时它**才去读**那份 plist，读到的值才是真正的开关。所以关 SIP 只是打开了
「允许读那份 plist」这道门 —— SIP 关了但 plist 没写（默认值），library validation **照样强制**。
打开它：

```bash
sudo defaults write /Library/Preferences/com.apple.security.libraryvalidation.plist DisableLibraryValidation -bool true
```

把前者当成后者，正是把每个 Apple 应用都错误路由到 remap 路径的原因。探测函数
`isLibraryValidationEnforced` 的名字读起来像在报告后者，实际只能报告前者 —— 因此它不允许决定注入
路径。

- **主要出现在**：`Sources/HelperServices/InjectionService/Implementation/InjectionStrategy+Probe.swift`
- **延伸阅读**：[提案 0001](Evolutions/0001-injection-strategy-attempt-not-predict.md)（含实测数据）

### report page

MachInjector 0.4.3 起，注入器在**目标进程**内单独分配的一页可读写内存，被注入的 pthread 在
`dlopen` 返回后把 handle 与 `dlerror()` 原文写进去，注入器轮询它拿判决。不是 shellcode 那一页
（那页映射为 read+execute，pthread 写不进去）。

**它有一个盲区**：目标进程若在加载过程中被杀，这一页永远停在 `Pending`，与「`dlopen` 还没返回」
无法区分，超时后按成功处理。`InjectionService` 的注入后存活检查就是为了堵这个盲区。

- **主要出现在**：`Sources/HelperServices/InjectionService/Implementation/InjectionService.swift`
- **延伸阅读**：[提案 0001](Evolutions/0001-injection-strategy-attempt-not-predict.md)

### seatbelt

macOS 沙箱机制的内部名（`sandbox_check` 等 SPI 属于它）。本项目只关心其中一条谓词：
`file-map-executable` —— 严格 profile 的守护进程会 `(deny default)` 这条，导致 `dlopen` 无法把
payload 映射为可执行。这是**唯一**仍然直接决定走 remap 路径的判据，因为它可靠且可提前知晓。

- **主要出现在**：`Sources/HelperProcessProbe/HelperProcessProbe.c`

### wire format（线格式）

本项目里特指**改动之后不会产生编译错误、只会在运行期让两端静默失配**的那些值。目前有四样：
`Request.identifier`（XPC 消息名）、`HelperServiceFailure.errorDomain`、`InjectionStrategy` 的
`rawValue`，以及 `FetchVersionRequest` 回的版本串必须是 `major.minor.patch` 这条**格式**约定。

**与「源码兼容性」是两回事**，而且可以各自独立地破坏：去掉 `HelperServerType.plain` 的一个废参数
是源码破坏但线格式不变；给某个 `Request` 加一个必填字段可能连 Swift 签名都没怎么变，线格式却已经
断了。判断时看的是消息，不是签名。

共享 daemon 出现之前，本库的 tool 与宿主 App 总是一起编译、一起升级，线格式失配没有存在的空间；
之后才需要「只增不改」这条明确承诺。

- **延伸阅读**：[WireCompatibility.md](Architecture/WireCompatibility.md)

### 两阶段激活（two-phase activation）

`HelperPeerClient` / `HelperPeerServer`（以及 `HelperServer`）刻意把生命周期切成 `init` 和
`activate()` 两段：**`init` 在线上不做任何动作**，只开监听器、连 broker、装包内部的握手 handler；
真正的握手在 `activate()` 里发生。

**为什么不能合并**：调用方的业务 handler 只能在 `init` 返回之后才装得上。如果 `init` 就完成握手，
对方可能在 handler 装好之前就发来第一条业务请求，那条消息会命中一个没有对应 handler 的监听器并被
**静默丢弃**。这是随调度和负载变化的偶发竞态，开发机上可能永远不复现。

- **主要出现在**：`Sources/HelperPeer/PeerConnection.swift` 的 `activate()` 文档
- **延伸阅读**：[BrokeredPeer.md 第四节](Architecture/BrokeredPeer.md#四为什么必须是两阶段init-之后还要-activate)
