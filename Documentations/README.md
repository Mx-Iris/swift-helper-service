# 文档索引

`swift-helper-service` 的内部文档。面向公众的说明在仓库根目录的 [`README.md`](../README.md)，
面向 agent 的架构速查在 [`AGENTS.md`](../AGENTS.md)（`CLAUDE.md` 是指向它的软链）。

**读者假设**：这里的每一篇都假设你不记得这个项目的任何内部细节，包括几个月后的你自己。

## 从这里开始

**第一次接触这个库** → [Architecture/Overview.md](Architecture/Overview.md)。它从「这个包解决什么
问题」讲起，交代核心设计决策（特权进程只做介绍人、不做中间人）和一条消息的完整路径。其余几篇都
预设你读过它。

**卡在某个名词上** → [Glossary.md](Glossary.md)。

## 目录

| 路径 | 内容 |
|------|------|
| [`Architecture/`](Architecture/Overview.md) | 架构与设计说明 —— 整体是什么样、以及**为什么这么设计** |
| [`Guides/`](Guides/InjectionPrerequisites.md) | 使用指南 —— 调用方要遵守的契约、以及从 API 签名上看不出来的坑 |
| [`Evolutions/`](Evolutions/README.md) | 提案 —— 每次实质变更一篇，从调研到落地全生命周期都在同一份文件里 |
| [`Glossary.md`](Glossary.md) | 项目术语表 —— 自造词、本项目特有含义、易混淆的近义词对 |

## 全部文档

### Architecture —— 架构与设计

| 文档 | 讲什么 | 什么时候读 |
|---|---|---|
| [Overview.md](Architecture/Overview.md) | 全景。它解决什么问题；核心决策「特权进程只做介绍人不做中间人」及其推论；四种进程角色；一条消息的完整路径；模块依赖图；贯穿全局的三条约束；已知粗糙处。 | **第一篇**。其余几篇都建立在它之上。 |
| [ModuleLayering.md](Architecture/ModuleLayering.md) | 模块为什么切成这样。Interface/Implementation 拆分的规矩与一次真实的边界考验；`HelperService` 为何是纯协议 target；`package` vs `public` 的判定标准与注册表类型为何刻意不 public；平台门禁；`@preconcurrency` / `@retroactive` 为何不能删。 | 新增一个服务、或想把某个 `package` 放开成 `public` 之前。 |
| [TypedMessaging.md](Architecture/TypedMessaging.md) | `Request`/`Response` 协议层。原生 XPC 的三类隐形错误；`identifier` 是路由键（因而是线格式的一部分）；为什么不用 `NSXPCInterface`；新增消息的完整步骤与兼容性演进；`HelperPeerEndpoint` 为何与裸 `XPCEndpoint` 线格式逐位相同。 | 新增一种消息、排查「消息发出去没人接」、或改动任何 `identifier` 之前。 |
| [BrokeredPeer.md](Architecture/BrokeredPeer.md) | `HelperPeer` 的独立握手协议。Client/Server 命名为何容易误导；初次握手与重连的完整时序；**两阶段 `init` + `activate()` 为何必须存在**（否则有静默丢消息的竞态）；状态流为何用 `AsyncStream` 而非 Combine；与 `HelperServer`/`HelperClient` 的对照表。 | 用 `HelperPeerClient` / `HelperPeerServer`，或排查握手竞态时。**改动握手顺序前必读。** |
| [WireCompatibility.md](Architecture/WireCompatibility.md) | 「只增不改」的承诺：共享 daemon 服务多个独立发版的客户端之后，为什么线格式必须冻结；哪四样东西已经是线格式；允许与不允许的演进；版本协商为什么必须主动问（`errorIndicatesOutdatedPeer` 不可能返回 `true`）；改动前的检查清单。 | 动任何 `Request`、`identifier`、`errorDomain` 或 `rawValue` 之前。 |
| [HookKit.md](Architecture/HookKit.md) | `HookKit` —— 替换宿主进程里的 Objective-C 方法。类型编码校验为什么是整条链路里最值钱的一步、编码必须从活宿主读；多候选拼写的来历（macOS 27 给 Dock 的图标 setter 加参数）与「按宿主实际会调的拼写排序」；全或无的取舍及其代价；「装上了 ≠ 跑起来了」。 | 写 payload 的 hook、或某个 hook 装上了却没生效时。 |
| [Arm64eInjection.md](Architecture/Arm64eInjection.md) | 注入器与 payload 为什么都必须带 arm64e 切片（两者理由不同：一条 PAC 指令在 arm64 下是空操作 vs. 一次实测结论）；Dock tile 插件那个看似相反的旁证为什么推不翻它；daemon 的切片校验在挡什么；让 arm64e 成立的六处配置各自在挡什么；SwiftPM 产不出 arm64e 但 Xcode 项目可以。 | 注入 arm64e 目标失败时，或改动任何与架构有关的构建设置之前。 |

### Guides —— 使用指南

| 文档 | 讲什么 | 什么时候读 |
|---|---|---|
| [InjectionPrerequisites.md](Guides/InjectionPrerequisites.md) | 注入的运行前提 —— 那些「代码没错但就是注不进去」的宿主机状态。**关 SIP 不等于关掉 library validation**（真正的开关是一份 plist 里的值）；走 remap 路径为何必须导出入口符号；seatbelt 与「注入成功但目标被内核杀掉」；以及怎么读 daemon 日志。 | 注入失败排查时；调用 `InjectApplicationRequest` 之前。 |
| [SharedDaemonClients.md](Guides/SharedDaemonClients.md) | 怎么写一个共享注入 daemon 的客户端：用户只需装平台 App 并批准一次；客户端**不得**安装或升级 daemon 以及为什么；签名要求满足不了时才用开发模式，以及它为什么需要两个布尔值；注入请求为什么应该把路径选择留给 daemon；payload 放哪、daemon 注入前会拒绝什么（含 strip 之后必须重签）；回传通道的两条顺序规矩；哪些部分还没被验证。 | 把一个工具接到共享 daemon 上之前。 |

### Evolutions —— 提案

见 [Evolutions/README.md](Evolutions/README.md) 的状态总表。

- [0001 - 注入路径改为「先尝试后退回」，不再预测目标是否接受 dlopen](Evolutions/0001-injection-strategy-attempt-not-predict.md)
  —— 把 `InjectionService` 的选路从读 `CS_REQUIRE_LV` 预测，改为先试 `dlopen`、被拒再退回
  `mach_vm_remap`，并补上目标进程存活检查。含实测数据、被否方案，以及一节**验证覆盖与缺口**。
- [0002 - 服务端错误跨 XPC 保住描述，并在 daemon 侧留下日志](Evolutions/0002-service-errors-that-survive-xpc.md)
  —— 服务端抛的错到达调用方时只剩 domain + code，描述全丢；daemon 侧又无日志，失败两端不留痕。
  在通道层统一包装成一个 `Codable` 的传输错误类型并记日志，所有现有服务一行不改即受益。落地时还
  带来了本仓库**第一个真实 XPC 往返测试**，并借此发现 `errorIndicatesOutdatedPeer` 一直是失效的。
- [draft - 一个共享的注入 daemon](Evolutions/draft-shared-injection-daemon.md) —— 把「每个注入工具
  各带一个特权 daemon」改成「全机一个共享 daemon」：用户只在登录项批准一次，此后所有工具作为客户端
  连它。daemon 里只放注入与端点注册表；本库补上标准回传通道、注入前的 payload 校验与 `HookKit`。
  含 arm64e 切片的五处配置加一个 destination、与 `InjectionScaffold` 的分工，以及冻结接口前的清理
  批次。状态 **Accepted**，实现在 `feature/shared-injection-daemon`。

### 其他

- [术语表](Glossary.md) —— 目前收录 `library validation`（「请求」与「强制」之别）、`report page`、
  `seatbelt`、`broker`、`endpoint registry`、`wire format`、`两阶段激活` 七条。

## 约定

- 提案文件名用 `NNNN-kebab-case-slug.md`（编号互引、编号排序即时间序）；其余文档目录与文件名一律
  PascalCase。
- 正文中文，标识符与技术术语保持英文。
- **新增或重命名任何文档都必须同步更新这份索引**，否则文档等于不存在。
- 架构文档记录**为什么**；某个类型的具体契约写在源码的 doc comment 里，不在这里重复。发现两处
  冲突时以源码为准，并回来订正文档。
