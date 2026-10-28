# 0003 - 一个共享的注入 daemon

- **状态**: Implemented
- **作者**: JH
- **创建日期**: 2026-10-27
- **最后更新**: 2026-10-28
- **所属愿景**: 无
- **关联提案**: [0001](0001-injection-strategy-attempt-not-predict.md)（注入路径先尝试后退回）、[0002](0002-service-errors-that-survive-xpc.md)（服务端错误跨 XPC 保住描述）、[0004](0004-daemon-only-injects.md)（修正本提案关于回传通道归属的决策）
- **实现分支 / PR**: `feature/shared-injection-daemon`（已合入 `main`）
- **配套文档**: 无独立实现说明。架构决策留在本文；daemon 服务清单与信任模型记在 `InjectionPlatform` 的 `CLAUDE.md`

## 摘要

把「每个注入工具各带一个特权 daemon」改成「全机一个共享 daemon」。用户装一个菜单栏 App
（新仓库 `InjectionPlatform`），在「登录项」里批准一次，此后所有注入工具都作为客户端连它，不再各自
安装、各自请求授权。

daemon 里只放必须 root 的两件事：注入，以及让被注入 payload 与宿主互相找到对方的端点注册表。本库
在此基础上补三块目前各工具各写一遍的能力：一条标准的 payload 回传通道、注入前的 payload 校验，
以及从 `InjectionScaffold` 抽出来的 `HookKit`。本提案的范围到第一个客户端
（`ViewHierarchyCapture`）跑通为止。

## 动机

### 一、同一套特权 daemon 被装了五遍

本机 `/Library/LaunchDaemons/` 下已有四个自建 daemon（`com.JH.MachXPCService`、
`com.JH.SimpleXPCService`、`com.JH.hoppermcpd`、`com.JH.mediaremotedd`），加上 RuntimeViewer 的
`com.mxiris.runtimeviewer.service` 与 LookInside 的 `app.lookinside.LookInsideInjector`。

清点下来，真正重复的**不是**注入本身 —— mach 层只有 `MachInjector` 一份，路径选择与回退也已经在
[提案 0001](0001-injection-strategy-attempt-not-predict.md) 收进本库。重复的是外面那圈壳，每一份
都近乎同构：

| 实现 | daemon 形态 | 取权方式 | 回传通道 |
|---|---|---|---|
| RuntimeViewer | 自有 target，39 行 | `SMAppService` | XPC / 本地 TCP / Bonjour 三选一自适应 |
| LookInside | 独立 Tuist 工程，约 40 行 | `SMAppService` | 固定本地 TCP 端口段 47170–47174 |
| DockIconOverride | 脚手架生成 | `SMAppService` | — |
| MediaRemoteWizard | 自有 target | `SMAppService` | — |
| MachInjector Example `Injectd` | 示例，`main.swift:13-39` | `SMAppService` | XPC 回 `Result` |
| ViewHierarchyCapture | **没有 daemon** | 用户 `sudo` 跑 CLI | 文件交换目录 + 轮询 |

代价有三层。对用户：每装一个工具就要去「系统设置 › 通用 › 登录项」批准一次，这一步无法跳过。对
维护：daemon 骨架、`SMAppService` 安装流程、launchd plist 接线、arm64e 构建配置，每个仓库各留一份，
任何一处的修正都要手工传播。对可靠性：三套互不相同的回传通道意味着同一类 bug 要在三个地方各查一次。

### 二、`ViewHierarchyCapture` 被 `sudo` 彻底卡住

这个工具没有 daemon，靠用户 `sudo` 跑 CLI 拿 `task_for_pid`。本机 `sudo` 需要交互输入密码，于是它
提案里的四项验证**一项都没跑过**，至今停在那里：Catalyst 目标、`--inject-method remap`、补上的两个
snapshot 请求、以及唯一一次真实捕获之外的任何样本。

调研中还发现了第二层、更隐蔽的阻塞：**它的 CLI 本身是 arm64**（SwiftPM 产物），而注入 arm64e 目标
要求注入方自己也是 arm64e（理由见下节）。也就是说那四项里注入 Books 那条**即便有 root 也会失败**，
与 `sudo` 无关。接上一个 arm64e 的共享 daemon，两个问题一起消失。

### 三、这个问题解决过一次，但解法是另一条路线

`InjectionScaffold`（`Personal/Scaffolds/InjectionScaffold`）的 README 开宗明义：

> Extracted from RuntimeViewer, MediaRemoteWizard and HopperMCP, which had each rebuilt the same
> plumbing by hand.

它的解法是**代码生成** —— 一条命令生成四个二进制（App、daemon、payload framework、payload 入口），
把样板从「手写」降到「生成」。DockIconOverride 就是它的产物，而且它已经消化了本提案绕不开的全部
arm64e 陷阱（见下节）。

但生成解决的是**编写**成本，没有解决**安装**成本：生成出来的项目仍然各带一个 daemon，用户仍然要
逐个批准，回传通道仍然各写各的。本提案要补的正是这一层，不是推翻脚手架 —— 两者的关系在「提议方案」
里明确。

## 前期调研

### `MachInjector` 的能力与边界

版本 0.5.1（`Personal/Library/macOS/MachInjector`，零外部依赖，纯 Objective-C）。三条注入路径：

| 路径 | 机制 | 架构 |
|---|---|---|
| `MIMachInjector` | `task_for_pid` → 远程 mach 线程 → `pthread_create_from_mach_thread` → `dlopen` | arm64 / arm64e / x86_64 |
| `MIMachInjectorAsync` | 同上，完成信号改为监听线程端口的 `MACH_SEND_DEAD` | 仅 arm64 / arm64e |
| `MIMachInjectorRemap` | `mach_vm_remap` 投射段，自行重放 chained fixups 与 dyld 的运行时通知，完全不经 dyld | 仅 arm64 / arm64e |

对本提案关键的三条事实：

- **三条路径都要 `task_for_pid`**，也就是都要 root（`README.md:26-28`）。换路径救不了 task port
  失败 —— 这正是必须有特权 daemon 的根本原因。
- **一个参数都传不进去。** 三个 API 都没有给 payload 传数据的槽；remap 路径的 `arg` 被
  `MIMachInjectorRemapPayloadConfig` 占满（12 个 `uint64_t` 全是元数据）。`ViewHierarchyCapture`
  的文件交换目录就是为绕开这一条发明的。
- **remap 路径完全没有回传。** `injectToPID:` 返回 `YES` 只表示段已映射、线程已启动，payload 的
  实际成败注入方无从得知（`MIMachInjectorRemap.h:354-371`）。

### 本库已经具备的

[架构总览](../Architecture/Overview.md)记录了核心决策：特权进程只做介绍人，不做中间人。据此已有：

- `HelperServer` / `HelperClient` / `HelperCommunication` —— 类型化 XPC 消息层，收发两端引用同一个
  `Request.identifier`，不可能写岔
- `InjectionService` —— 包住 `MachInjector`，按提案 0001 先试 `dlopen` 后退回 remap
- `InjectedEndpointRegistryService` —— 按 pid 存被注入进程的回连端点，用 `DispatchSourceProcess`
  在目标退出时自动清理
- `HelperPeer` —— 两个都不是 tool 的进程经注册表交换 `XPCEndpoint` 后直连的握手协议
  （见 [BrokeredPeer.md](../Architecture/BrokeredPeer.md)）
- `SMAppServiceDaemonInstaller` —— `SMAppService.daemon(plistName:)` 的注册 / 注销 / 状态流

也就是说本提案不需要发明新的通信机制，要做的是**把这些能力从「每个 App 各组装一遍」变成「装一次」**，
并补上三块缺口（标准回传通道、payload 校验、HookKit）。

### arm64e：注入方与 payload 都必须带这个切片

`InjectionScaffold` 仓库的 `Documentations/Guides/BuildingForArm64eTargets.md` 已经把这一块查透
（跨仓库，故不给相对链接）。**注入方必须 arm64e** 的根因在 `MIMachInjector.m`：

```c
__darwin_arm_thread_state64_set_pc_fptr(
    thread_state,
    ptrauth_sign_unauthenticated((void *)code, ptrauth_key_asia, 0));
```

`ptrauth_sign_unauthenticated` 编译成 arm64e 时是一条真正的 PAC 指令，**编译成 arm64 时是空操作**，
原样返回指针。注入方交给目标的于是是个没签名的地址，目标执行时认证失败。

**payload 是否也必须 arm64e：以实测为准，必须。** 这里有一处文档冲突，裁决如下 ——

- 脚手架指南称 payload 不需要 arm64e，理由是 arm64e 进程能加载 arm64 库，并举 Dock 的插件宿主为例。
  该例子本身属实（实测 `com.apple.dock.external.extra.arm64.xpc` 是 arm64e，而本机装着的
  `CodexDockTilePlugin.docktileplugin` 是 arm64 单切片）。
- 但 RuntimeViewer 上的实测结论相反：arm64e 系统进程必须要 payload 带 arm64e，arm64-only 的 payload
  行不通，**具体原因未查明**。
- dyld 的架构降级表 `archs_arm64e[] = { arm64e }`（`mach_o/GradedArchitectures.cpp:162`）支持后者。

实测优先于静态推断，且保守方向的代价只是多编一个切片。**本提案按「payload 必须 arm64e」执行**，
并作为本批次的一部分更正脚手架指南中那段论断（保留原记录，标注为实测推翻、原因待查）。

拿到 arm64e 切片需要五处配置同时成立，外加构建命令里的一个 destination，缺一处就会得到一个「构建
成功但注入时以毫无线索的错误失败」的产物。脚手架已全部踩过：

1. 独立的 `.xcworkspace`，且本地包是它的成员（`.xcodeproj` 内嵌的那个 workspace 不算）
2. workspace 共享设置里 `iOSPackagesShouldBuildARM64e = true`
3. 项目级 `ONLY_ACTIVE_ARCH = NO`（本地 Swift 包是按项目级设置构建的）
4. daemon 与 payload 的 `ENABLE_POINTER_AUTHENTICATION = YES`，**只能在 target 级** —— 提到项目级会
   让包的 arm64e 切片*替换*掉 arm64，macro plugin 随即链接失败
5. `PrecompiledLibraries/swift-syntax`（预编 xcframework，使 macro 不受架构设置影响）
6. 构建命令用 `-destination 'generic/platform=macOS'`；写成 `platform=macOS` 会塌缩到本机架构，
   **无论 `ARCHS` 与 `ONLY_ACTIVE_ARCH` 怎么设**

以及：命令行强制 `ARCHS=arm64e` 不可行（实测 81 个错误），它会把 macro plugin 这类构建宿主工具也
强制成 arm64e，于是它们不出现在产物目录里。

构建后必须校验切片真的在 —— 一个悄悄产出 arm64-only daemon 的构建，和正确的构建长得一模一样。

### payload 不是非 SwiftPM 不可

`ViewHierarchyCapture` 的 `build_payload.sh:9-15` 断言「SwiftPM 根本编不了这个 dylib，因为它不支持
arm64e」。这句话对 `swift build` 成立，对 `xcodebuild` 不成立：`LookInsideServer` 是个**纯 SwiftPM 包**
（5 个 target，其中 125 个 Swift 文件），由 `package-xcframework.sh` 用
`xcodebuild ... ARCHS="x86_64 arm64 arm64e" EXCLUDED_ARCHS=` 直接驱动，实测产出三切片齐全的动态库。

本提案仍按 RuntimeViewer 那条路（Xcode workspace + 上述六处配置）执行 —— 它是本机验证最充分的一条，
且脚手架已经把配置固化。这条记录在此，是为了说明「payload 必须离开 SwiftPM」不是约束，而是选择。

### 回传通道现状

三套实现，payload 侧全部是 Swift：

- RuntimeViewer：`RuntimeViewerServer.swift:56-80` 按 `SandboxProbe.isRuntimeViewerServiceMachLookupBlocked`
  三选一 —— 沙盒目标里 seatbelt 挡住 mach-lookup 时退回本地 socket，非 macOS 走 Bonjour。
  实现在 `RuntimeViewerCommunication/Connections/`，六个连接类共约 3300 行。
- LookInside：`LookinCoreImpl/Transport/FrameListener.swift` 裸 socket 绑 `127.0.0.1:<固定端口>`。
- ViewHierarchyCapture：`CaptureExchange.swift:71-171`，JSON 文件写在 payload 旁边，CLI 轮询。

**「XPC 在沙盒目标里会被 seatbelt 挡住、必须有 TCP 回退」是已经踩实的结论**，标准通道必须带这条
回退，不是可选项。

## 提议方案

### 进程拓扑

```
┌────────────────┐                    ┌──────────────────────────┐
│ InjectionPlatform.app              │ com.JH.injectiond (root) │
│  菜单栏常驻                          │                          │
│  - 装 / 升 daemon（唯一有权者）  ───▶ │  InjectionService        │
│  - daemon 状态、已注入进程列表        │  端点注册表 (MainService) │
│  - 开发模式开关                      │  —— 仅此两者              │
└────────────────┘                    └───────▲──────────────────┘
                                              │ ①注入请求（签名白名单校验）
┌────────────────┐                            │
│ 客户端工具      │ ───────────────────────────┘
│ RuntimeViewer  │                            │ ②取 / 存端点
│ ViewHierarchy… │ ◀═══════ ③直连，不经 daemon ═══════▶ ┌──────────────┐
│ DockIconOver…  │        XPC，沙盒目标退回本地 TCP      │ 目标进程内    │
└────────────────┘                                     │ payload      │
                                                       └──────────────┘
```

客户端自己准备 payload 文件并把路径交给 daemon；daemon 校验后注入；payload 起来后经端点注册表与
宿主完成握手，之后直连。消息不经过 daemon —— 沿用本库既有的「介绍人而非中间人」原则。

### 七项决定

1. **归属与安装。** 新仓库 `Personal/App/InjectionPlatform`，菜单栏常驻 App，daemon 嵌在其中走
   `SMAppService` 注册，label `com.JH.injectiond`。本库的改动仍留在本仓库。

   **App 的 UI 技术栈**：生命周期仍由 AppKit 掌管（`NSApplicationDelegate`），**SwiftUI 不接管
   生命周期**；状态栏界面用 SwiftUI 写，控件用
   [`MacControlCenterUI`](https://github.com/orchetect/MacControlCenterUI)（MIT，macOS 11+），
   经 `NSHostingSceneRepresentation` + `NSApplication.addSceneRepresentation(_:)` 挂进 AppKit
   宿主。`NSHostingSceneRepresentation` 是 **macOS 26.0** 引入的，因此平台 App 的部署目标定在
   macOS 26.0 —— 这只约束平台 App，不影响本库（仍是 macOS 10.15+，新 API 逐调用点 `@available`
   门禁）。

2. **特权面。** daemon 里只有 `InjectionService` 与端点注册表。`FilesService`、`ApplicationsService`
   这些不需要 root 的照旧跑在各客户端自己的非特权 sub-server 里。

3. **谁能连。** 按 Team ID 签名白名单，用 `XPCListener(codeSigningRequirement:)`。另有一个显式的
   **开发模式开关**放行本机 ad-hoc 签名的构建，开启期间菜单栏界面持续显示警告。与此正交地，
   Debug 与 Release 使用不同的 mach service 名（照搬 DockIconOverride 的现成做法），使开发中的构建
   与已安装的正式版不互相抢注册。

4. **版本策略。** daemon 接口**只增不改**：已发布的 `Request` 类型不改签名，要变就加新的。老客户端
   永远能用新 daemon。作为交换，冻结之前先做一次清理（见落地步骤 1）。

5. **谁能升 daemon。** 只有平台 App。客户端发现 daemon 太旧只能提示用户去平台 App 升级，自己绝不
   注销或重装。平台 App 在升级前明确告知这会打断当前正在进行的注入会话。

   **「发现太旧」必须靠主动查询，不能靠错误判别。** 本库的
   `HelperClient.errorIndicatesOutdatedPeer(_:)` **不可能返回 `true`**，而且从来不可能：SwiftyXPC
   只在 `XPCConnection.respond(to:)` 遇到未知消息名时抛 `unexpectedMessage`，而那条路把错误交给
   **接收方自己**的 `errorHandler` 后直接返回、**不回复**，于是调用方等到的是
   `XPCError.connectionInterrupted` —— 老 daemon 与掉线无法区分。所以客户端连上后主动调
   `HelperClient.fetchToolVersion()`（走 `FetchVersionRequest`）取版本号比较。这对本提案成立的前提
   是共享 daemon 从第一版起就带 `FetchVersionRequest`，不存在「老到不认识这条消息」的区间。

6. **标准回传通道。** 平台提供一条默认通道：XPC 优先，沙盒目标退回本地 TCP。payload 侧以 Swift 库
   形式交付（`HelperPeer` 之上的薄层）。

   ~~端口由 payload 绑 0 让内核分配，再经已有的端点注册表上报给宿主。~~ **这条在实现时被推翻** ——
   沙盒目标的 payload 连不上 daemon（`mach-lookup` 正是被挡的那一跳），所以「经注册表上报」无从谈起；
   文件也不行，沙盒 App 与宿主没有共享目录。改为 RuntimeViewer 已在生产验证的做法：**角色反转**
   （宿主监听、payload 连出，因为沙盒进程可以向 localhost 外连，但没人能发现它 bind 的端口），
   **端口由两边从同一个 identifier 确定性推导**，谁都不用告诉谁。详见决策日志。

7. **payload 校验而非托管。** 平台不负责 payload 的存储与分发（三种现有方式各留各的），但在注入前
   校验架构切片、platform 与签名，不合格直接拒绝并给出能照着改的错误 —— 把「切片不对导致目标静默
   拒绝」这个最常见也最难查的失败，变成一句明确的报错。

### 与 `InjectionScaffold` 的关系

脚手架**加一个开关**，两种形态都能生成：默认生成连平台的客户端形态（不含 daemon），加参数仍可生成
自带 daemon 的现有形态。两套模板都要维护 —— 这是明确接受的代价，换取已生成项目不被强制迁移，以及
平台不可用时仍有退路。

`HookKit`（带签名校验的 Objective-C 方法替换）从脚手架模板抽出来，成为平台的客户端库，与回传通道库
并列。它不需要 root，因此不进 daemon。

### 非目标

- **不做 payload 卸载。** dylib 注入后取不出来。界面只读展示已注入进程，并提供「退出该 App」作为
  唯一的撤销手段，不提供「断开通道」之类让 payload 休眠的半吊子状态。
- **Bonjour 不进平台。** 本次只做 macOS，它是给 iOS 设备用的。
- **不迁移 RuntimeViewer、LookInside、DockIconOverride、MediaRemoteWizard。** 各自另开提案。
- **不做 daemon 热替换。** 升级即打断，由用户知情确认。
- **不支持 x86_64 / Rosetta 目标**（沿用 `MachInjector` 的既有边界）。
- **不开放第三方往 daemon 注册服务。** 那等于让任意代码在 root 里跑，签名白名单将失去意义。

## 详细设计

### 新增的消息类型

payload 校验作为注入请求的前置步骤，不单独成一个往返。现有 `InjectApplicationRequest` 按「只增不改」
原则不动签名，校验结果经失败路径返回 —— [提案 0002](0002-service-errors-that-survive-xpc.md) 已经让
服务端错误能带着描述跨过 XPC 边界：

```swift
public enum PayloadValidationFailure: Codable, Sendable, Equatable {
    /// 目标是 arm64e 进程，而 payload 没有 arm64e 切片。
    case missingArchitecture(required: String, present: [String])
    /// payload 的 LC_BUILD_VERSION platform 与目标不兼容。
    case incompatiblePlatform(payload: UInt32, target: UInt32)
    /// 签名不可信，且当前未开启开发模式。
    case untrustedSignature(reason: String)
    /// 走 remap 路径但 payload 没有导出所需的入口符号。
    case missingRemapEntrySymbol(String)
}
```

~~端点注册表需要容纳 TCP 回退的端口号，`InjectedEndpointInfo` 追加一个可选的 `localSocketPort`。~~

**这个字段不需要了，而且加了也没用。** 退回 socket 的前提恰恰是 payload 连不上 daemon，所以它没有
任何办法把端口写进注册表。端口改由两边各自推导（见下节），谁都不必转达，注册表因此一个字段都不用动。

### 标准通道的选路（已实现）

~~payload 侧库在握手时自行判定，宿主不参与。~~ **两边都要判定，而且必须判出同一个答案** —— 因为
需要协商的那个场景，恰恰是没有通道可供协商的场景。

```swift
public enum PeerTransport: Sendable, Equatable {
    case brokeredXPC                  // 默认：经 tool 的注册表交换端点后直连
    case loopbackSocket(port: UInt16) // 宿主监听、payload 连出
}

public enum PeerTransportSelection {
    /// 宿主在注入前问目标 pid，payload 进去之后问 getpid() —— 同一个问题，同一个答案。
    public static func transport(
        forProcess processIdentifier: pid_t,
        machServiceName: String,
        channelIdentifier: String
    ) -> PeerTransport
}
```

判定依据沿用 RuntimeViewer 已验证的做法：`sandbox_check` 探 `mach-lookup`（而不是嗅 entitlement
—— 挡住它的两种沙盒形态从外面长得不一样）。两条路之上是同一套 `Request` / `Response` 类型化消息，
调用方看不出走的是哪条。

**三处容易想当然、但会致命的地方：**

- **socket 路径上角色是反的**：宿主监听、payload 连出。沙盒进程可以向 localhost 外连，但没有任何人
  能发现它 bind 了哪个端口。让宿主监听，就把「通报一个端口」变成了「约定一个端口」。
- **端口推导用 djb2，不能用 `Hasher`**。`Hasher` 每进程带不同的种子，两边会算出不同端口然后互相干等
  —— 而这个错误只在跨进程时才显形。测试里独立重算了一遍期望值来钉住它。
- **identifier 必须含目标 pid**，否则同时注入两个进程会撞到同一个端口，第二个 listener 直接 bind 失败。

另有一个实现时才暴露的坑：`sandbox_check` 对**内核找不到的 pid 回答「拒绝」而不是报错**。照字面处理
会把已退出或不存在的目标推上 socket 路径去无限等待，而 XPC 路径至少会明确失败。所以探测前先确认进程
存在（按 `ESRCH` 判，因为属于别的用户的活进程回的是 `EPERM`，那不是跳过探测的理由）。

### 开发模式的存放

开关状态由 daemon 持有（root 拥有的 plist，位于 daemon 自己的支持目录），只能经平台 App 修改 ——
客户端无法自行开启。daemon 每次接受 ad-hoc 签名连接时留一条日志，平台 App 据此在界面上显示警告。

## 替代方案考量

- **继续每 App 一个 daemon，只把样板压到零（即维持脚手架现状）。** 否决理由：它解决编写成本，不解决
  安装成本。用户每装一个工具仍要去登录项批准一次，回传通道仍然各写各的。不过这条路**没有被废弃**
  —— 它作为脚手架的非默认分支保留。

- **多个 App 内嵌同一 label、同一签名的 daemon，谁先装谁生效。** 否决理由：`SMAppService` 对「多个
  App 注册同一 label」的行为没有明确文档，需要实测；而卸载任意一个 App 很可能把其余 App 的 daemon
  一起带走。

- **客户端声明最低版本，daemon 自动升级。** 否决理由：要做一条更新通道，而自动更新一个 root daemon
  本身就是攻击面。改为只有平台 App 能升，由用户知情确认。

- **按主版本号并存多个 daemon（`com.JH.injectiond.v1`、`.v2`）。** 否决理由：这是退回多 daemon，只是
  把粒度从「每 App 一个」放粗成「每大版本一个」，用户仍要批准多次。

- **daemon 不设签名校验（`MachInjector` 示例 `Injectd` 目前就是 `codeSigningRequirement: nil`）。**
  否决理由：共享之后风险被放大 —— 一个任何本机进程都能驱动的 root 注入服务，是一个完整的提权原语。

- **daemon 统一分配 TCP 端口。** 否决理由：多一次往返，且 daemon 多出一块需要在客户端崩溃后自清理的
  状态。让 payload 绑 0 交给内核、经已有注册表转达，不需要新机制也不可能冲突。

- **平台托管 payload 的存储与分发。** 否决理由：要接管文件生命周期与沙盒目标的读权限，范围明显变大，
  而三种现有分发方式各自都能工作。校验挡住的是真正高发的失败，托管解决的不是。

- **daemon 支持热替换，老连接服务到自然结束。** 否决理由：两个 root 进程同时持有 task port 与端点
  注册表，交接逻辑本身就是一大块新代码，而换来的只是免去一次用户知情的打断。

- **把 `FilesService` / `ApplicationsService` 也放进 daemon，一站式。** 否决理由：违反本库「特权进程
  只做介绍人」的地基决策，让不需要 root 的代码跑在 root 里。

## 影响

### 源码兼容性

**有破坏**，集中在落地步骤 1 的清理批次，三处：

| 改动 | 破坏性 | 调用点 |
|---|---|---|
| `HelperServerType.plain(name:identifier:)` 去掉从未被读取的 `name` | **是** | 本仓库内仅 `HelperServer.swift:41`（以 `_` 忽略）。下游凡起 sub-server 处各需改一行 |
| 从 `HelperService` 协议移除 `run()` | 几乎无 | 本仓库 5 个实现全是空的 `{}`，无任何调用点。移除一条 requirement 后，实现方多出来的方法仍可编译 |
| 删除 `HelperTool` | **否** | `package actor`，非 public，仓库内零使用者 |

改前 / 改后：

```swift
// 改前
HelperServer(serverType: .plain(name: "unused", identifier: "com.example.sub"), services: […])
// 改后
HelperServer(serverType: .plain(identifier: "com.example.sub"), services: […])
```

`.plain` 这一处可用 `@available(*, deprecated, renamed:)` 保留一个版本平滑过渡；另两处无需。

另有一处**行为变更而非接口变更**：`MainService` 的端点注册表改为在进程退出时清理（现状只增不减，
宿主会拿到连不上的端点）。做法照抄 `InjectedEndpointRegistryService` 已有的 `DispatchSourceProcess`。

**第五处已知粗糙不在清理范围内。** `AGENTS.md` 还列了
`HelperClient.errorIndicatesOutdatedPeer(_:)` —— 它不可能返回 `true`（理由见「七项决定」第 5 条）。
但它不是死代码，而是**等上游修复的占位**：测试
`unhandledMessageDoesNotReachTheCallerAsUnexpectedMessage` 钉住了「未知消息不回复」这个上游行为，
SwiftyXPC 一旦开始回复，该测试就会失败，判别器随即恢复可用。删掉它等于丢掉这个哨兵，所以保留，
只在文档里写明调用方不该依赖它。

### ABI 兼容性

不适用 —— 本库以 SPM 源码分发，未启用 library evolution，也没有 `binaryTarget`，使用方每次重新编译。

### 下游影响

本仓库内：`HelperServer`、`HelperService`、`HelperCommunication`、`InjectedEndpointRegistryService`
四个 target，外加新增的通道库与 `HookKit`。

跨仓库，按依赖传导点名：

- **`ViewHierarchyCapture`** —— 本提案范围内迁移，改动最大（见落地步骤 9）。
- **`RuntimeViewer`**、**`LookInside`** —— `.plain` 签名变更需各改一行；迁移到共享 daemon 各自另开提案。
- **`DockIconOverride`**、**`MediaRemoteWizard`** —— 同上。
- **`InjectionScaffold`** —— 模板加开关，并更正 arm64e 指南中关于 payload 切片的论断。

### 文档与示例

- 本库 [架构总览](../Architecture/Overview.md)第八节「已知粗糙处」中被清理掉的条目要删除。
- 需要一份新的使用指南：客户端如何接入共享 daemon（装平台 App、签名要求、开发模式、payload 校验会
  拒绝什么）。
- 需要一份实现说明：为什么 daemon 和 payload 都必须 arm64e，以及那六处配置各自在挡什么。
- `InjectionScaffold` 仓库的 `Documentations/Guides/BuildingForArm64eTargets.md` 中「payload 本身
  其实不需要 arm64e」一段需更正 —— **已在本批次一并处理**，并在该文档加了修订记录一节。

## API 演进与废弃策略

- `HelperServerType.plain(name:identifier:)` —— 以 `@available(*, deprecated, renamed:)` 保留一个
  版本，下游全部改完后移除。
- `HelperService.run()`、`HelperTool` —— 直接删除，无使用者，不设废弃期。
- **冻结点**：清理批次合并后，`InjectionService` 与端点注册表的全部 `Request` 类型进入「只增不改」
  承诺。此后新增能力一律加新的 `Request`，不改既有签名。
- 版本号：清理批次含破坏性改动，需要一次 minor 跃迁（0.x 阶段）。共享 daemon 本身是纯新增。

## 落地步骤

1. **[已完成]** **清理三处死接口并修注册表泄漏。** `.plain` 去掉废参数（带废弃标注）、移除
   `HelperService.run()`、删除 `HelperTool`、`MainService` 注册表接上 `DispatchSourceProcess` 清理。
   更新架构总览第八节、`AGENTS.md` 与 `CHANGELOG.md`。这一步不依赖平台，可单独构建与测试。
   新增测试 target `MainServiceTests`（3 个用例，拿真实子进程的退出驱动），全量 44 个测试通过。
2. **[已完成]** **冻结接口，并把版本协商定死。** 新增
   [WireCompatibility.md](../Architecture/WireCompatibility.md)：只增不改的承诺、已经是线格式的
   四样东西、允许与不允许的演进、改动前的检查清单。新增 `HelperToolVersion`（可比较、可解析）与
   `HelperClient.requireToolVersion(atLeast:)`，线格式不变（`FetchVersionRequest` 仍回 `String`，
   这个类型是对它的约定解释）。文档写明**判断 daemon 是否过旧一律用主动查询，不得依赖
   `errorIndicatesOutdatedPeer(_:)`**。术语表新增 `wire format`。全量 50 个测试通过。
3. **[已完成]** **新建 `InjectionPlatform` 仓库。** 位于 `Personal/App/InjectionPlatform`，
   GitHub 私有仓库 `Mx-Iris/InjectionPlatform`。由 `InjectionScaffold` 生成后做四处实质改造：
   daemon 去掉 `FilesService`、去掉客户端侧的注入路径开关、payload target 重定位为参考载荷、
   依赖指向本功能分支的 worktree（并修掉脚手架停留在 0.1.4 所欠的那处已删 API）。

   **验收：构建产物校验通过。** daemon 与 payload 均为 `x86_64 arm64 arm64e`，App 为
   `x86_64 arm64`（它不需要 arm64e），macro plugin 为单一的 `arm64` —— 最后一项是
   `ENABLE_POINTER_AUTHENTICATION` 有没有被误提到项目级的判据。launchd plist 的 `Label` /
   `BundleProgram` / `MachServices` 三处一致，Debug 带 `.debug` 后缀。
   `SMAppService` 的实际注册需要用户在「登录项」批准，留到有界面之后一并验。
4. **[已完成]** **接入信任模型。** 库侧给 `HelperServer.init` 加可选的 `codeSigningRequirement`
   （默认 `nil`，保持源码兼容；`HelperPeer` 的三个匿名 listener 维持 `nil` 并加注释说明为什么）。
   平台侧 daemon 用 Team ID 要求，并新增 `DeveloperModeService`（Interface / Implementation 拆分）
   与 root 拥有的开关文件。Debug/Release 分服务名脚手架已有。
   新增 7 个测试，**反向验证过**：把失败兜底值从「关闭」翻成「开启」，6 个断言立刻变红。

   两处落地时才清楚的事实：**要求在 listener 构造时定死**，运行中换不了，所以切换开发模式必须重装
   daemon，而 `FetchDeveloperModeRequest` 要同时回「磁盘上的状态」和「正在跑的 daemon 是否真的在
   验」——两者在重启前不一致。以及**开发模式比设想的窄**：本项目设了 `DEVELOPMENT_TEAM`，Xcode 连
   Debug 构建都用 Apple Development 证书签名、leaf 的 OU 即 Team ID，本来就满足要求；它只对完全没有
   可用签名的二进制（ad-hoc、无证书的机器、团队外客户端）才有意义。
5. **[已完成]** **注入前校验。** platform 一项之前已有；本批补上**架构切片**与**签名**，失败经
   提案 0002 的错误通道带描述返回。新增 `MachOArchitecture`（沿用既有解析器的边界检查风格）与
   6 个测试，全量 59 个通过。

   落地时定下的三条边界：**读不出来一律放行**（与既有的 platform 守卫一致——看不清就拦会把每个
   无法解析的文件变成一次失败的注入）；**未签名的 payload 放行**（ad-hoc 在开发期很正常，「谁能注入
   什么」是 listener 要求该管的事，不是这里），只拒绝「声称有签名但校验不过」的那种——那正是会杀死
   目标的那种；**Rosetta 目标跳过架构检查**，因为「内核把 arm64e 排在 arm64 前面」这条推断对它不成立。

   另外把「选哪个切片」的推断从文件读取里拆出来（`preferredExecutingArchitecture(from:)`），否则它
   只能靠机器上恰好存在的二进制来测——实测 `/bin/ls` 是 `x86_64 arm64e`，没有纯 arm64 切片，而
   `/usr/lib/libobjc.A.dylib` 在磁盘上根本不存在（已并入 dyld shared cache），这两条都写进了测试。
6. **[已完成]** **标准回传通道。**
   - **[已完成]** 选路与端口推导：C 侧的 `mach-lookup` 探测、`PeerTransport` / `PeerTransportSelection`
     / `PeerPortDerivation`，以及 9 个测试（全量 66 个通过）。原定的「绑 0 + 经注册表上报」在此被
     推翻，改为角色反转 + 确定性推导，理由见上文「标准通道的选路」。`InjectedEndpointInfo` 不动。
   - **[已完成]** socket 传输层：`PeerSocketFraming`（长度前缀分帧）与 `PeerSocketChannel`
     （建在 Network.framework 上，带 correlation 配对、超时、取消唤醒等待者）。19 个新测试，
     其中 8 个是**两个真实 loopback 端点对连**的集成测试，全量 85 个通过。
   - **[已完成]** 两条路统一在一个调用面之下。**没有**把 socket 塞进 `PeerConnection` ——
     `listenerEndpoint` 对 socket 毫无意义，硬套只会得到一堆唯一行为是抛错的方法。改为抽出
     `PeerMessaging`（两条路都能做的四件事），让 `PeerConnection` 细化自它并保留 XPC 专有的两样；
     `PeerSocketChannel` 遵循 `PeerMessaging`，并补上与 XPC 同构的两阶段生命周期
     （`preparedListener` / `preparedDialer` + `activate()`）。`PeerLink.host(...)` /
     `PeerLink.payload(...)` 把「探测 → 选路 → 构造对应的那一端」合成一步。`HelperService` 经
     `PeerSocketHelperHandler` 也能挂在 socket 上。6 个新测试，全量 91 个通过。

     两处落地时才清楚的事实：**两端的启动顺序是固定的（宿主先起、payload 后拨）**，生产里读作
     「注入之前先把宿主这一端开起来」；以及**重连只有 XPC 有** —— socket 下 listener 在宿主这边，
     宿主重启后 payload 手里的连接已死且无法被告知新的，`hostReconnecting` 对沙盒目标直接抛错
     并说明原因，而不是给出一条永远连不上的链路。
7. **[已完成]** **抽出 `HookKit`。** 作为 `swift-helper-service` 的新 target 与 product，与
   `HelperPeer` 并列 —— 它不需要 root，所以不进 daemon；放进本包而非另开仓库，是因为客户端本来就
   依赖这个包，多一个仓库只为 340 行代码不划算。平台改为依赖它，删掉生成的那份副本。
   新增 [HookKit.md](../Architecture/HookKit.md)，10 个测试（移植 9 个 + 新增 3 个），全量 101 个通过。

   **搬的是 `DockIconOverride` 里那份，不是脚手架模板里那份。** 脚手架那份只有签名校验与原子安装；
   多候选拼写是 macOS 27 给 Dock 的图标 setter 加参数之后在 `DockIconOverride` 里长出来的，提案写
   「保留多候选拼写」时默认它已经在模板里 —— 实际不在。一并带过来的还有 `HookActivityReporter`
   （「装上了 ≠ 跑起来了」）。

   一处落地时的改写：`HookActivityReporter` 原来用 `Synchronization.Atomic`，那是 macOS 15，而本包
   下限是 10.15，改为 `os_unfair_lock`。快路径从「一次 relaxed load」变成「一次无竞争加锁」，渲染
   路径上够用，这一点在代码注释与文档里都写明了，没有含糊成「等价替换」。
8. **[已完成]** **菜单栏管理界面。** daemon 状态、已注入进程列表（只读 + 退出目标 App）、开发模式
   警告、升级入口（含「会打断当前注入会话」的告知）。App 生命周期回到 AppKit，界面是 SwiftUI +
   MacControlCenterUI；部署目标 15.0 → 26.0（`NSHostingSceneRepresentation` 的要求）。新增
   `InjectionPlatformUI` target 与 `DeveloperModeController`；`PrivilegedDaemonController` 拆出
   只查不装的 `refreshResidentVersion()`，因为界面要先**提供**升级再执行升级，而重装会掐掉每个
   payload 的通道。

   **两处实测推翻了原计划，都写进了平台的 `CLAUDE.md`：**

   - **`@main` 贴在 `NSApplicationDelegate` 上不会让它成为 delegate。** AppKit 给它的 `main()`
     默认实现只有 `exit(NSApplicationMain(...))` 一行，既不构造那个类型也不赋值 `NSApp.delegate`；
     Xcode 的 AppKit 模板靠 `MainMenu.xib` 的 File's Owner 连 outlet 补上这一步，Apple 自己的
     `NSHostingSceneRepresentation` 文档示例也默认了那个前提。本项目没有 nib，结果是 App 起来、
     run loop 转着、**一个 delegate 方法都没调用**，而且哪里都不报错。补法是在 delegate 类上自己
     写一个 `static func main()` —— 具体类型上的成员会盖掉协议扩展里的默认实现。delegate 实例放在
     `static let` 里而不是 `main()` 的局部变量：`NSApplication.delegate` 是弱引用，局部变量只是靠
     「`NSApplicationMain` 不返回」才活着，那不是改这个函数的人应该先知道的事。（初版另建了一个
     `main.swift`，效果相同，但把入口点和它构造的类型分在两处，已删除。）
   - ~~**`MenuBarExtra` 装不进 `NSHostingSceneRepresentation`。**~~ → **这条判错了，已纠正。**
     见下。

   **一次判错，以及它为什么看起来合理。** 症状是菜单栏空的，当时的结论是 `MenuBarExtra` 不能托管，
   理由也站得住：那个类的文档把它持有的场景描述成**被呈现**的（环境动作或外部 URL 触发），而
   `MenuBarExtra` 不由任何人呈现。于是状态栏项被改成手写的 `NSStatusItem` + `NSPanel`。

   **真正的原因就是上面那条 `@main` 的坑** —— `applicationWillFinishLaunching` 压根没跑，
   `addSceneRepresentation` 从未被调用。两个问题是先后发现的，修掉第二个之后没有回头重试第一个。

   补做的对照实验，四种写法各看进程内 `NSApp.windows` 里有没有 `NSStatusBarWindow`：直接写在表示的
   scene builder 里、包一层自定义 `Scene`、自定义 `Scene` 里 `MenuBarExtra` + `Window`、以及
   delegate 直接建 `NSStatusItem` 的对照组 —— **四种都在 t+1s 就有**。已改回 `MenuBarExtra`，
   `MenuBarController` / `NSPanel` 那套删掉。

   **方法上的教训比结论重要**：状态栏项**不出现在 `CGWindowListCopyWindowInfo` 里**（系统合成，不是
   每个 App 自己的窗口），当时用的正是这个外部探针，于是「探针看不到」被读成了「东西不存在」。唯一
   可靠的判据是进程内的 `NSApp.windows` —— AppKit 给每个状态栏项建一个 `NSStatusBarWindow`。

   **同一批实验里出来的第二条，这一条是真的**：设置窗口必须是 `Settings` 场景，不能是
   `Window(id:)`。`Settings { … }` + `environment.openSettings()` 开得出来；
   `Window(id:)` + `environment.openWindow(id:)` **什么都不发生** —— 没有窗口对象、没有报错。
   bundle 里外、`NSApplicationMain` / `NSApplication.run()`、`.accessory` / 先切 `.regular`，
   四种条件都试过，全都一样。改用 `Settings` 之后顺带拿到 ⌘, 和 App 菜单项，而且它本来就是设置窗口。

   **补上主菜单，这是接管 AppKit 生命周期的连带代价。** 一个菜单栏小工具也需要 `NSApp.mainMenu`：
   `cut:` / `copy:` / `paste:` / `selectAll:` 是靠主菜单的 key equivalent 绑到聚焦的文本控件上的
   —— 没有主菜单就没有 Edit 菜单，⌘C 什么都不做，而且不报错。设置窗口里有好几处
   `.textSelection(.enabled)` 的内容（daemon 版本、最后一条注入错误、payload 的自检报告），它们
   存在的意义就是被复制出去，而**能选不能复制比纯文本更糟，因为它看起来该能用**。顺带拿到的还有
   ⌘, 打开设置、⌘W 关窗、⌘Q 退出、Hide/Hide Others，以及 Window 菜单里的窗口列表 —— SwiftUI
   `App` 白送这一整套，接管了 AppKit 生命周期就得自己接管这一份。

   用 UIFoundation 的 `MainMenu` result builder 装配，不画 nib：这个菜单只有四个顶级项，nib 的
   内容在 diff 里没法审，而那个 builder 直接给出模板的标准项（标准 selector 与快捷键都接好了）。
   不放 Format（没东西可格式化）、View（没有视图选项）、Help（没有帮助书，一个点不开任何东西的
   Help 菜单比没有更糟）；File 只留 Close，因为 ⌘W 总得有地方待。Settings… 的 action 发给 `nil`
   走响应链，终点是 App delegate 的 `showSettings(_:)`。有了主菜单也**不能**删掉
   `ApplicationActivationPolicyController`：`.accessory` 的 App 不显示自己的菜单栏，key equivalent
   照样生效但用户看不见，所以开窗之前切 `.regular` 这一步还在。

   **验证到哪一步：** App 构建通过；真实 App 启动后日志里有
   `Menu bar status item installed, button: true, visible: true` —— 那是
   `menuBarExtraAccess` 的 introspection 回调，说明托管场景里的 `MenuBarExtra` 确实建出了状态栏项。
   **菜单栏上肉眼可见、以及点开之后菜单长什么样，仍然没有验证** —— 本机未授予终端屏幕录制权限，
   `screencapture` 取不到画面。
9. **[已完成]** **迁移 `ViewHierarchyCapture`。** 分支 `feature/shared-injection-platform-client`。
   新增 `ViewHierarchyCapture.xcworkspace` 与 `ViewHierarchyCapturePayload.xcodeproj`（只有一个
   framework target），SwiftPM 包保留并接管全部源码；payload **只换通信层** —— 已验证的 Objective-C
   逐行未改，外面加 `ViewHierarchyCapturePayloadCore` 接 `PeerLink`；删掉交换目录、轮询与 `sudo`
   路径。全量 49 个测试通过（新增 `ViewHierarchyCaptureInterfaceTests` 5 个）。

   **更正了提案 0001 关于 payload 切片的论断。** 原文说「SwiftPM 不支持 arm64e，所以 payload 这一层
   出不了 SwiftPM；Swift 本身也不正式支持 arm64e」—— 前半句属实，后半句不成立：Xcode 项目用项目级
   `ARCHS` 构建本地包的 target，`iOSPackagesShouldBuildARM64e` 把这一点延伸到包。实测产物
   `x86_64 arm64 arm64e` 且含 Swift。当时这个推断没有代价（payload 不需要 Swift），迁移之后回传通道
   是 Swift 的，它才成为障碍。

   三处落地时才清楚的事实：

   - **捕获结果必须经通道回传，不能给路径。** 沙盒目标与客户端之间没有共同目录 —— 这正是原方案一直
     没真正跑通的那一格。payload 写进自己的临时目录，再把 `[相对路径: Data]` 发回去。
   - **嵌进 CLI 的 payload 从 336 KB 涨到 9.6 MB**（带上 Swift 回传层），而那份 base64 是提交进仓库的
     源码。去 x86_64 切片 + strip + raw DEFLATE 压到 1.5 MB。
   - **strip 之后必须 ad-hoc 重签。** strip 重写镜像使 Xcode 的签名失效，而落地步骤 5 加的那条检查会
     拒绝「声称有签名却验不过」的 payload。不重签的话每次注入都会被拒，而错误信息说的是签名，不是
     导致它的瘦身。

   顺带修掉 `main` 上一个既有的编译失败：`MachOPlatformReader.platforms` 里局部 `let platforms` 遮蔽了
   同名静态方法，编译器报的是「failed to produce diagnostic for expression」。
10. **[部分完成]** **端到端验证。** 对 AppKit 靶子与一个 arm64e 系统 App 各跑一次 ——
    **AppKit 靶子那一半 2026-10-28 做掉了，arm64e 系统 App 仍未做。**

    **卡点已解除**：用户自己安装并批准了 daemon，于是这一步不再需要 agent 完成那个只能由人做的
    授权。随后在 `probe-target`（AppKit，ad-hoc 签名因此不带本 Team 签名）上跑通了完整往返：
    注入 → loopback socket 通道 → 捕获 → 回传，产出 440 KB 归档（解压 2.3 MB），内容含
    `NSStackView` / `NSTableView` / `NSViewController` / `NSLayoutGuide`，与靶子的层级吻合。
    开发模式**保持关闭**。详见 [0004](0004-daemon-only-injects.md) 的落地步骤 10。

    **仍未做的是 arm64e 系统 App**（Dock、Finder 这类）—— 它要走 remap 路径，而上面那次是
    `dlopen`。列为后续项，不阻塞本提案落地。

    **原卡点的记录**（保留，因为它解释了为什么这一步积压了这么久）：共享 daemon 必须由用户在
    「系统设置 › 通用 › 登录项」批准，`SMAppService.register()` 触发的是一个只能由人完成的授权。
    agent 做不了这一步，也不该替用户做。换言之卡点从 `ViewHierarchyCapture` 原来的「`sudo` 要
    交互输密码」换成了「登录项要人批准」，并没有消失 —— 直到用户自己完成了它。

    **在这个边界之内验证到的：**

    - 平台 App 构建通过；daemon 与 payload 均为 `x86_64 arm64 arm64e`，App 为 `x86_64 arm64`，
      launchd plist 的 `Label` / `BundleProgram` / `MachServices` 三处一致。
    - `vhcapture` 对一个真实目标（Finder）跑到 daemon 那一跳：目标分型正确（`native,
      com.apple.finder`）、Xcode 解析正确、连不上 daemon 时给出的是「装平台 App 并在登录项批准」
      而不是一条 XPC 错误码。
    - 脚手架两种形态都生成并**构建**通过（不只是生成）。
    - 全量测试：`swift-helper-service` 101 个、`ViewHierarchyCapture` 53 个。

    **这一步顺带发现并修掉一个必然导致全部注入失败的缺陷**：平台的 `PayloadInjectionCoordinator`
    仍在用 `FileOperationRequest` 把 payload 拷进 `/Library`，而共享 daemon 刻意不挂 `FilesService`
    （落地步骤 3 定的）。每一次注入都会在 staging 这一步失败，错误信息是「无法识别的消息」，离真正
    的原因很远。改为直接从 App bundle 注入。这正是端到端验证该抓的那类问题 —— 它被抓到了，只是靠
    读代码而不是靠跑起来。

    **剩下的四项仍然积压**，清单见 `ViewHierarchyCapture` 的
    `Documentations/Internal/PayloadAndInjection.md#验证到哪一步了`。
11. **[已完成]** **`InjectionScaffold` 加开关。** 分支 `feature/platform-client-form`。
    `generate.sh --form platform-client|standalone-daemon`，默认前者。客户端形态没有 daemon target、
    没有 `HookKit` 副本（改依赖 `swift-helper-service` 的 product）、界面上 daemon 那一节只读。
    两种形态都生成并**构建**通过。

    **一处对提案的偏离，方向是减少重复**：提案写的是「两套模板都要维护 —— 这是明确接受的代价」。
    落地时改为**一棵模板 + 一层覆盖**（`TemplateOverlays/PlatformClient/`）。两种形态真正不同的只有
    八个文件，相同的有四十来个；复制四十个去让八个不同，代价不是磁盘而是**那四十个会慢慢变得不
    一样，而且两边各自都能构建**。外部行为不变。维护约定写进了
    `Documentations/Guides/MaintainingTheTwoForms.md`。

    **一个值得记下来的坑**：从 pbxproj 里删 target 不能按行过滤「含某个 id 的行」。
    `TargetAttributes` 里的条目是嵌套对象，只删掉开头那行会留下孤儿行，Xcode 报的是「project is
    damaged … parse error」，不说在哪 —— 而且**生成这一步完全看不出来**，只有 `xcodebuild -list`
    或真正构建才会暴露。必须按块删，数花括号时还要跳过引号里的内容（那个生成 plist 的 `shellScript`
    字符串里全是 `${…}`）。第一次就是这么错的。

    客户端形态依赖 **0.4.0** —— 第一个带 `HookKit` 与 `PeerLink` 的版本。在它发布之前生成出来的项目
    解析不了依赖，`generate.sh` 会在结尾说明这件事。
12. **[已完成]** **收尾。** 使用指南
    [SharedDaemonClients.md](../Guides/SharedDaemonClients.md)（客户端怎么接入：装什么、签名要求、
    开发模式、注入请求、payload 放哪、daemon 会拒绝什么、通道的两条顺序规矩、哪些部分还没验过）与
    实现说明 [Arm64eInjection.md](../Architecture/Arm64eInjection.md)（注入器与 payload 为什么都要
    arm64e，六处配置各自在挡什么）各一份，均已登记进文档索引。术语表新增「平台 daemon」「标准通道」
    「开发模式」三条。架构总览第八节里被清理掉的四项已从表中移除。

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-10-27 | Created as Draft | 起因：注入工具链里每个 App 各带一个特权 daemon，用户逐个批准、样板逐份维护。经五轮澄清提问定下形状后创建 |
| 2026-10-27 | 归属定为独立的菜单栏平台 App 内嵌 daemon，走 `SMAppService` | 需要界面承载 daemon 状态、已注入进程与开发模式警告；`SMAppService` 要求 daemon 嵌在 app bundle 内 |
| 2026-10-27 | daemon 只放注入与端点注册表 | 沿用本库「特权进程只做介绍人」的地基决策，不需要 root 的代码不进 root |
| 2026-10-27 | 信任模型定为 Team ID 签名白名单 + 开发模式开关 | 共享之后，不设防的 root 注入服务是一个完整的提权原语；而 ad-hoc 签名的本地构建需要一条显式、可见的口子 |
| 2026-10-27 | 版本策略定为接口只增不改，且只有平台 App 能升 daemon | 自动升级会让一个工具替其余工具做出打断决定，而自动更新 root daemon 本身是攻击面 |
| 2026-10-27 | 冻结前先做一次清理 | 架构总览第八节与 `AGENTS.md` 自列五处粗糙，其中端点注册表只增不减是真 bug。冻结之后改签名就要走废弃流程 |
| 2026-10-27 | 五处粗糙中只清理四处，`errorIndicatesOutdatedPeer` 保留 | 它不是死代码而是等上游修复的占位：SwiftyXPC 收到未知消息时不回复，于是老 daemon 读起来与掉线相同。测试 `unhandledMessageDoesNotReachTheCallerAsUnexpectedMessage` 钉住了这个行为，上游一旦开始回复该测试就会失败、判别器即恢复可用。删掉它等于丢掉这个哨兵 |
| 2026-10-27 | 版本检测改为主动查询 `FetchVersionRequest`，不依赖错误判别器 | 承上：判别器不可能返回 `true`。共享 daemon 从第一版起就带这条消息，因此不存在「老到不认识它」的区间，主动查询总能拿到版本号 |
| 2026-10-27 | 回传通道由平台提供标准实现，TCP 回退是必选项 | 沙盒目标里 seatbelt 挡住 mach-lookup 已被 RuntimeViewer 踩实，不是可选优化 |
| 2026-10-27 | TCP 端口由 payload 绑 0 交内核分配，经端点注册表上报 | 复用现有机制，不写分配器，不硬编码端口段，并发注入同一目标也不会撞 |
| 2026-10-27 | payload 只做注入前校验，不做托管 | 校验挡住的是高发失败（切片不对导致静默拒绝），托管解决的不是，而范围显著变大 |
| 2026-10-27 | 已注入进程不提供卸载，也不提供「断开通道」 | dylib 注入后取不出来；休眠中的 payload 对目标仍有影响，是谁都没设计过的状态。界面直说唯一撤销手段是重启目标 |
| 2026-10-27 | ~~脚手架不再生成 daemon~~ → **加一个开关，两种形态都能生成** | 初版建议砍掉脚手架的 daemon 模板以消除重复。改为保留：已生成的项目不被强制迁移，平台不可用时仍有退路。代价是两套模板都要维护 |
| 2026-10-27 | `HookKit` 抽成平台客户端库 | 每个注入工具都要，但不需要 root。它的积累（类型编码须从活宿主读、多候选拼写应对版本变化、原子安装）值得集中一处维护 |
| 2026-10-27 | 范围到 `ViewHierarchyCapture` 跑通为止 | 它最简单（无 GUI、无历史包袱）且收益最直接；平台落地时有一个真实使用者验证过，设计里的错不会留到下一份提案才暴露 |
| 2026-10-27 | `ViewHierarchyCapture` 的 payload 只换通信层，`sudo` 路径删除 | 已验证过的 Objective-C 捕获逻辑不动，出问题能立刻分清是通信层还是旧逻辑；保留两条取权路径则意味着每次改动都要在两边验证，而 `sudo` 那条恰恰是无法自动测的 |
| 2026-10-27 | payload 必须带 arm64e 切片，不采纳脚手架指南中的相反结论 | RuntimeViewer 上实测 arm64-only payload 进不了 arm64e 系统进程（原因未查明）；dyld 的 `archs_arm64e[] = { arm64e }` 支持该结论。实测优先于静态推断，且多编一个切片的代价可忽略。脚手架指南中那段一并更正 |
| 2026-10-27 | 记录：`ViewHierarchyCapture` 现有 CLI 是 arm64，因此注入 arm64e 目标本就会失败 | 注入方必须 arm64e（`ptrauth_sign_unauthenticated` 在 arm64 下是空操作）。其积压的四项验证中注入系统 App 那条与 `sudo` 无关，迁到 arm64e 的共享 daemon 后自动消失 |
| 2026-10-27 | 记录：payload 离开 SwiftPM 是选择而非约束 | `LookInsideServer` 以纯 SwiftPM 包经 `xcodebuild ARCHS=...` 实测产出三切片。仍选 Xcode workspace 路线，因其在本机验证最充分且脚手架已固化配置 |
| 2026-10-27 | 用户批准，开始实现。实现分支 `feature/shared-injection-daemon` | 开工前复核提案时发现两处与现实不符，已在本次一并修正（见上方两行关于 `errorIndicatesOutdatedPeer` 与版本协商的记录）|
| 2026-10-27 | 平台 App 的 UI：AppKit 掌管生命周期，状态栏界面用 SwiftUI + `MacControlCenterUI`，经 `NSHostingSceneRepresentation` 挂载 | 用户指定。连带把平台 App 的部署目标定在 macOS 26.0（该 API 的引入版本），本库不受影响 |
| 2026-10-27 | 注册表的清理键用「注册方自报的 pid」，不从 XPC 连接取 audit token | 取 audit token 要把连接对象透进消息 handler，那要改 `HelperHandler` 的签名——牵动每一个服务，代价远大于收益。注册方是经签名白名单准入的自己人，且报错 pid 的唯一后果是清理时机不对，不会造成越权 |
| 2026-10-27 | `RegisterEndpointRequest` 的新字段设为 `Optional` | 它是线格式。设成必填会让不带该字段的老 peer 整个注册失败；设成可选则退化回原来的只增不减行为，只影响那一个条目 |
| 2026-10-27 | 重复注册同一 identifier 时，先把它从旧 pid 的监视下摘掉 | sub-server 崩溃重启会用新 pid 重新注册同一 identifier。不摘，旧进程的退出事件稍后就会把刚接替它的那个活条目清掉。已由 `reRegisteringRebindsTheEntryToTheNewProcess` 钉住 |
| 2026-10-27 | 进程监视改用私有串行队列，不用 `.main` | 事件处理只是跳进 actor，不需要主队列；而依赖主队列会让清理在任何不转主队列的环境里不可观察——包括测试进程 |
| 2026-10-27 | 平台 App 用 `InjectionScaffold` 生成，而不是手写 | 那套 Xcode 工程把 arm64e 的五处配置、launchd plist 的构建期生成、embed 规则都固化了，手搓 pbxproj 搞错的表现是「构建成功、注入时失败」。用户在两种路径间选了这一条 |
| 2026-10-27 | 生成出来的 payload target 保留，重新定位为平台自带的**参考载荷**，而不是删除 | 本会话没有 Xcode MCP 与 xcodeproj MCP，从 pbxproj 删一个 target 要同步改八九个 section，漏一处就打不开工程。而保留它还有正面价值：脚手架的 bring-up 顺序里本就有「先证明 payload 能挂上、此时不声明任何 hook」这一环，平台需要它把「平台自身有没有问题」与「客户端有没有问题」分开，端到端验证那一步也用得上 |
| 2026-10-27 | 平台 daemon 不挂 `FilesService` | 脚手架挂它是为了把 payload 放进 `/Library`（那确实要 root）。但本提案已决定平台不托管 payload 存储，客户端自备路径、daemon 只校验，于是它没有存在理由。去掉后 daemon 里剩下的每一样都离不开 root |
| 2026-10-27 | 去掉客户端侧的注入路径开关，`preferredStrategy` 传 `nil` | 生成出来的代码有个 `InjectionMethod` 开关，两条路各发一条消息——那正是[提案 0001](0001-injection-strategy-attempt-not-predict.md) 要消除的「客户端侧的第二份规则」。daemon 持有 task port、能探测目标，让它决定；入口符号则总是带上，因为只有 daemon 知道会不会用到 remap |
| 2026-10-27 | ~~TCP 端口由 payload 绑 0 交内核分配、经端点注册表上报~~ → **角色反转（宿主监听、payload 连出）+ 两边从同一 identifier 确定性推导端口** | 原方案在实现时被证明不成立，而且是两处同时不成立：退回 socket 的前提就是 payload 连不上 daemon（`mach-lookup` 正是被挡的那一跳），所以它无从上报；而文件也不是出路——沙盒 App 与宿主没有共享目录，RuntimeViewer 正因此放弃了文件式端口发现。改用它已在生产验证的做法。代价是推导出的端口可能与无关软件相撞，且两条传输的角色相反、抽象起来更麻烦 |
| 2026-10-27 | 端口推导用 djb2，明确不用 `Hasher` | `Hasher` 每进程种子不同，两边会算出不同端口并互相干等，而这个错误只在跨进程时显形。测试独立重算期望值钉住该算法 |
| 2026-10-27 | 探测 `mach-lookup` 前先确认进程存在 | `sandbox_check` 对内核找不到的 pid 回答「拒绝」而非报错，照字面处理会把已退出的目标推上 socket 路径无限等待。按 `ESRCH` 判断，使属于其他用户的活进程（回 `EPERM`）仍被正常探测。这个缺陷是测试发现的 |
| 2026-10-27 | 平台 App 暂时以本地 path 依赖指向本功能分支的 worktree，并用 `.package(name:path:)` 显式指定 identity | 它需要本分支新增的注册表清理与 `requireToolVersion`，而这些尚未发版。`name:` 不是装饰：SwiftPM 按目录 basename 推断 path 依赖的 identity，而 worktree 目录名按约定带后缀，不指定就全部解析失败。**本分支合并发版后必须换成版本依赖** |
| 2026-10-27 | `MenuBarExtra` 装不进 `NSHostingSceneRepresentation`，状态栏项改回 AppKit `NSStatusItem` | 实测：托管场景里声明一个，状态栏项从未被创建。与该类的文档一致 —— 它持有的场景是被**呈现**的，而 `MenuBarExtra` 不由任何人呈现。设置窗口仍是托管的 SwiftUI `Window`，与原要求一致 |
| 2026-10-27 | `@main` 贴在 `NSApplicationDelegate` 上不会让它成为 delegate，补了 `main.swift` | AppKit 给它的 `main()` 默认实现只有 `exit(NSApplicationMain(...))` 一行。Xcode 模板靠 `MainMenu.xib` 的 outlet 补这一步，Apple 自己的文档示例也默认了那个前提。没有 nib 的结果是 App 起来、run loop 转着、一个 delegate 方法都没调用，且哪里都不报错 |
| 2026-10-27 | 平台的 payload 不再经 `FilesService` 拷进 `/Library`，直接从 App bundle 注入 | 落地步骤 3 让共享 daemon 不挂 `FilesService`，但协调器那段代码留着没改 —— 每次注入都会在 staging 这一步失败。daemon 以 root 读 bundle，沙盒目标走 `dlopen` 时读的是 `/Applications`，任何沙盒配置都允许 |
| 2026-10-27 | 脚手架两种形态用「一棵模板 + 一层覆盖」，不是两棵完整模板 | 提案原写「两套模板都要维护」。真正不同的只有八个文件、相同的四十来个；复制四十个去让八个不同，代价是那四十个会慢慢漂移而两边各自都能构建。方向是减少重复，外部行为不变 |
| 2026-10-27 | 落地步骤 10（端到端验证）**受阻，不勾完成** | 共享 daemon 要用户在「登录项」批准，这一步只能由人做。卡点从 `sudo` 换成了登录项批准，没有消失。边界之内能验的都验了，包括一个必然导致全部注入失败的缺陷 |
| 2026-10-27 | 落地步骤 1–9、11–12 完成，10 受阻；待合并 | 全量测试：`swift-helper-service` 101 个、`ViewHierarchyCapture` 53 个、脚手架两种形态各构建通过 |
| 2026-10-27 | ~~`MenuBarExtra` 装不进 `NSHostingSceneRepresentation`，状态栏项改回 AppKit~~ → **判错，已改回 `MenuBarExtra`** | 真正的原因是 `@main` 那条坑让 `addSceneRepresentation` 从未被调用；两个问题先后发现，修掉第二个之后没回头重试第一个。补做的四种写法对照实验全部在 t+1s 建出 `NSStatusBarWindow`。方法上的错是用 `CGWindowListCopyWindowInfo` 去否定，而状态栏项根本不出现在那里面 |
| 2026-10-27 | 设置窗口改用 `Settings` 场景，不用 `Window(id:)` | 实测：托管场景里 `openWindow(id:)` 不呈现 `Window`，而 Apple 文档示例用的 `Settings` + `openSettings()` 可以。bundle 内外、两种 main、两种激活策略都试过。`Settings` 也正是这个窗口的身份，顺带拿到 ⌘, 和 App 菜单项 |
| 2026-10-28 | 给平台 App 补主菜单，用 UIFoundation 的 `MainMenu` result builder 装配 | `cut:` / `copy:` / `paste:` / `selectAll:` 靠主菜单的 key equivalent 绑到聚焦的文本控件上，没有主菜单则 ⌘C 静默失效 —— 而设置窗口里几处可选中的内容（daemon 版本、最后一条注入错误、payload 自检报告）存在的意义正是被复制出去，能选不能复制比纯文本更糟。SwiftUI `App` 白送这一整套，接管 AppKit 生命周期就得自己接管。装配而不画 nib：只有四个顶级菜单，而 nib 的内容在 diff 里没法审。不放 Format / View / Help |
| 2026-10-28 | ~~补了一个 `main.swift`~~ → **入口点改为 delegate 类上的 `static func main()`**，`main.swift` 删除 | 发现本身不变（`@main` 贴在 `NSApplicationDelegate` 上不会让它成为 delegate），改的是补法：具体类型上的成员会盖掉协议扩展里的默认实现，于是入口点和它构造的类型留在同一处。delegate 实例放 `static let` 而不是局部变量 —— `NSApplication.delegate` 是弱引用，局部变量只是靠 `NSApplicationMain` 不返回才活着 |
| 2026-10-28 | 端到端验证的卡点解除，第 10 步由 [受阻] 改为 [部分完成] | 用户自己安装并批准了 daemon，那个只能由人完成的授权不再挡路。随后在 AppKit 靶子上跑通完整往返（详见 [0004](0004-daemon-only-injects.md) 的落地步骤 10）。**arm64e 系统 App 仍未验证** —— 它走 remap 而非 `dlopen`，列为后续项 |
| 2026-10-28 | 实现完成，取号 0003，状态 Implemented，合入 `main` | 12 个落地步骤中 11 个完成，第 10 步部分完成（见上）。本提案关于「平台提供标准回传通道」的决策随后被 [0004](0004-daemon-only-injects.md) 修正 —— 那不是本提案未实现，而是实现之后被实测推翻：共享 daemon 的签名要求校验连接对端进程，而 payload 没有独立进程身份 |
| 2026-10-28 | 文档判断：不需要额外的使用指南或实现说明 | 架构论证留在本文，daemon 的服务清单与信任模型记在 `InjectionPlatform` 的 `CLAUDE.md`，回传通道的协议随代码移到 `swift-injection-peer` 的 `BrokeredPeer.md`。未引入需要登记进术语表的新术语 |
| 2026-10-28 | 发 0.4.0，平台 App 换成版本依赖 | 「清理批次含破坏性改动，需要一次 minor 跃迁」照此执行（0.3.3 → 0.4.0）。`InjectionPlatform` 的 path 依赖（先指向 worktree、后指向主 checkout）换成 `from: "0.4.0"`，上面那条「本分支合并发版后必须换成版本依赖」的待办结清。发版同时暴露出 SwiftyXPC 下限必须提到 0.5.105，详见 [0004](0004-daemon-only-injects.md) 的决策日志 |
