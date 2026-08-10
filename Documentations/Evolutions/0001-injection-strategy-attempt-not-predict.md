# 0001 - 注入路径改为「先尝试后退回」，不再预测目标是否接受 dlopen

- **状态**: Implemented
- **作者**: JH
- **创建日期**: 2026-08-10
- **最后更新**: 2026-08-10
- **所属愿景**: 无
- **关联提案**: 无
- **实现分支 / PR**: `main`（工作区，未提交）
- **配套文档**: 无专题文章；新增术语见[术语表](../Glossary.md)的 `library validation`、
  `report page`、`seatbelt` 三条。判断理由见决策日志。

## 摘要

`InjectionService` 目前靠 `csops` 读目标进程的 `CS_REQUIRE_LV` 标志位来**预测**它会不会拒绝
`dlopen`，预测为「会拒绝」就改走 `mach_vm_remap`。实测证明这个预测在 SIP 关闭的机器上是错的，
而 SIP 关闭恰好是这条分支唯一有机会触发的环境。本提案把选路从「预测」改为「尝试」：除非 seatbelt
明确拒绝 `file-map-executable`，否则先试 `dlopen`，被目标拒绝时（MachInjector 0.4.3 起能如实回报）
再退回 `mach_vm_remap`；两条路径完成后都补一次目标进程存活检查，堵住「目标已被 SIGKILL 却报成功」
的盲区。同时给 `InjectApplicationRequest` 增加 `preferredStrategy`，让调用方能在需要时覆盖 daemon
的默认判断。

## 动机

### 谁被卡住了

一个下游项目给 Finder 做注入时无法工作，只能把依赖锁回 `exact: "0.1.4"`。原因是 0.1.5 引入的
`InjectionStrategy.forTarget` 把**所有 Apple 应用**一律路由到 `mach_vm_remap`，而在该环境下：

- `dlopen` 其实可用 —— 实测成功注入 Finder 并装上了 hook
- `mach_vm_remap` 是坏的 —— PAC 认证失败，崩溃了 Finder（属 MachInjector 侧问题，已另行上报）

0.1.5 同时删除了 `InjectApplicationViaRemapRequest`，也就是**移除了调用方表达偏好的能力**，于是
没有任何逃生口。

### 判断错在哪一条

`Sources/HelperServices/InjectionService/Implementation/InjectionStrategy.swift:51`：

```swift
public static func forTarget(pid: pid_t, payloadPath: String) -> InjectionStrategy {
    if isFileMapExecutableBlocked(...) { return .machVirtualMemoryRemap }
    if isLibraryValidationEnforced(pid: pid) { return .machVirtualMemoryRemap }  // ← 这一条
    return .dlopen
}
```

`isLibraryValidationEnforced` 读 `csops(CS_OPS_STATUS)` 的 `CS_REQUIRE_LV`（`0x2000`）。源码注释断言：

> Disabling SIP does not lift this; only the `amfi_get_out_of_my_way=1` boot argument does

**这句话不成立**（见下节实测）。`CS_REQUIRE_LV` 这个**标志位**确实置位，但它是否被**强制执行**取决于
系统状态。探测函数把「标志位存在」当成了「会被强制」，这两件事不等价。

### 为什么这个错判特别贵

两种错判的代价严重不对等：

| 错判方向 | 后果 |
|---|---|
| 该 remap 却走了 dlopen | 静默无事发生，用户困惑，但目标进程完好 |
| 该 dlopen 却走了 remap | 目标进程崩溃；且 payload 未提供 `remapEntrySymbol` 时直接抛错，连试都不试 |

当前默认值押在了代价更高的那一侧。

## 前期调研

### 现状代码怎么走的

- `Sources/HelperServices/InjectionService/Implementation/InjectionStrategy.swift:51` —— `forTarget`
  选路，两条 `if` 见上。
- `Sources/HelperServices/InjectionService/Implementation/InjectionService.swift:30` —— `switch`
  分发到 `MachInjector.inject` 或 `MachInjectorRemap.inject`。
- `Sources/HelperProcessProbe/HelperProcessProbe.c` —— `sandbox_check` 与 `csops` 两处内核 SPI 的
  C 包装。
- `Sources/HelperServices/InjectionService/Interface/InjectApplicationRequest.swift:13` —— 请求类型，
  文档明确写「Clients do not choose, and must not」。

### 实测：`CS_REQUIRE_LV` 置位不等于 LV 被强制

环境：macOS 26.5.2、Apple Silicon、SIP **disabled**、`boot-args` 仅 `-arm64e_preview_abi`
（**没有** `amfi_get_out_of_my_way=1`）。

用 `codesign --force --sign - --options library,runtime` 签一个测试进程，`csops` 读回
`status=0x22012201`，`CS_REQUIRE_LV` 确认置位（即 `isLibraryValidationEnforced` 返回 `true`）。
让它 `dlopen` 四种 dylib：

| payload | 若 LV 被强制应当 | 实际 |
|---|---|---|
| ad-hoc 签名 | 拒绝 | **加载成功** |
| 完全未签名 | 拒绝 | **加载成功** |
| Apple Development 身份签名（Team ID `D5Q73692VW`，与 host 不同） | 拒绝 | **加载成功** |
| 签名被改坏（对照组） | 拒绝 | SIGKILL ✓ |

对照组证明代码签名强制本身是活的 —— 唯独 library validation 这一层没在执行。同一组实验由
MachInjector 侧的会话在另一台同配置机器上独立复现，结论一致。作为参照，运行中的 Finder 读回
`status=0x26016a21`，`CS_REQUIRE_LV` 同样置位。

**表述限定**：以上是 SIP disabled 环境的结论。关闭 SIP 本身就会放松 LV 强制，所以准确的说法是
「`CS_REQUIRE_LV` 置位不等于 LV 会被强制，是否强制取决于系统状态」，而非「这个标志位普遍不可靠」。

### 推论：这条分支只在它会判错的环境里才会触发（**推理，未实测**）

能成功 `task_for_pid` 的目标基本只有两类：

1. SIP 关闭 —— 此时 LV 不被强制（上节实测）；
2. 目标自身没有 hardened runtime —— 那它本来也不会带 `CS_REQUIRE_LV`。

SIP 开启时，对签了 hardened runtime 的进程 `task_for_pid` 本身就会被拒。两条路都通向「LV 预测判错」。
窄例外：注入方若持有 `com.apple.system-task-ports.debug` 一类 Apple 签发的私有 entitlement，SIP
开启时也能拿到 task port，那时 LV 可能真的在强制 —— 但那需要 Apple 授权，不是一般场景。

此推论未经实测（无法在开启 SIP 的条件下验证），仅作为「这条分支价值有限」的佐证，方案本身不依赖它。

### 上游能力：MachInjector 0.4.3 已能如实回报 dlopen 拒绝

`Package.resolved` 锁定 `machinjector 0.4.3 / c65d9c2`。该版本的
`c65d9c2 fix(inject): surface a target's dlopen refusal instead of reporting success` 做了：

- 注入器在目标进程内单独 `mach_vm_allocate` 一页可读写的 report page（shellcode 那页映射为
  read+execute，pthread 写不进去）；
- pthread 在 `dlopen` 返回后把 handle 与 `dlerror()` 原文写入该页，**先写内容再写 result code**，
  轮询不会读到半写状态；
- 注入器分两阶段等待：先等 mach 线程的 `DONE`（只证明 `pthread_create` 返回），再轮询 report page
  拿判决。

API 签名未变（`+injectToPID:dylibPath:error:`），行为变了：目标拒绝时返回 `NO`，`error` 携带
`target process refused to load <path>: <dlerror 原文>`。

**注意**：本仓库 `.build/checkouts/MachInjector` 一度停留在 `3678965`（0.3.0 之后 4 个 commit），
即修复之前的代码。调研初期据此得出「MachInjector 无法检测 dlopen 失败」的结论是错的，已作废。
落地前须 `swift package update`。

### 实测：各种拒绝路径的耗时，远小于 2 秒轮询预算

MachInjector 的 report 轮询预算是 `100 × 20ms = 2000ms`，超时按**成功**处理（刻意如此，否则构造函数
慢的 payload 会退化成假错误）。由 MachInjector 侧会话在同配置机器实测的拒绝耗时：

| 拒绝路径 | 耗时 | 注入器看到什么 |
|---|---|---|
| 路径不存在 | 0.29 ms | dlerror，正确报错 |
| seatbelt 挡 `mmap` | 0.67 ms | dlerror（`file system sandbox blocked mmap()`），正确报错 |
| 签名整体无效（10 MB arm64e，冷 vnode，走 amfid） | 15–19 ms | dlerror，正确报错 |
| 页哈希不符 → SIGKILL | 0.42 ms | **什么也看不到，报成功** |

最慢一条 19 ms，余量两个数量级。AMFI library validation 拒绝本身因 SIP 关闭无法直接复现，但它与
「签名无效」共用 `mmap` 时的同一条内核 MAC hook 路径，**推断**同为毫秒量级。

### 实测：目标被 SIGKILL 是 report 机制的盲区

`MIMachInjector.m` 中 `result = YES` 在轮询循环**之前**就设好，循环内：

```c
if (kr != KERN_SUCCESS || bytesRead != sizeof(dlopenReport)) { break; }
```

目标进程已死时 `mach_vm_read_overwrite` 失败，直接 break，`result` 保持 `YES`。也就是说
`Pending` 无法区分「dlopen 还没返回」和「目标已经没了」，两者都按成功返回。

复现配方（**先 ad-hoc 签名，再翻改被逐页哈希的页**，顺序是关键）：

```bash
clang -dynamiclib -o libtampered.dylib payload.c
codesign --force --sign - libtampered.dylib
python3 -c "d=bytearray(open('libtampered.dylib','rb').read()); d[0x1000]^=0xFF; open('libtampered.dylib','wb').write(bytes(d))"
```

同一个 dylib：普通进程内正常加载（1.85 ms），`library,runtime` 进程内 0.42 ms 被 SIGKILL。内核在
该页 page in、页哈希对不上时直接杀进程，走不到 `dlopen` 的返回，因此拿不到 NULL 也拿不到 dlerror。

MachInjector 侧已将「区分『读失败因为目标死了』和『读失败因为别的』」列为待批改动。但在其发版之前，
本库这一层是唯一防线；且「注入后目标还在不在」本就属于调用方的策略判断，两层都有不冲突。

## 提议方案

1. **选路从「预测」改为「尝试」。** `isLibraryValidationEnforced` 不再单独决定路径，降级为生成错误
   信息时的解释性依据。只有 seatbelt 明确拒绝 `file-map-executable` 时才直接走 remap —— 那条判定
   可靠，而且一次注定失败的 `dlopen` 会在目标进程里永久留下一个自旋的 mach 线程和若干页 shellcode
   （MachInjector 有意不回收），能省则省。

2. **dlopen 被拒时自动退回 remap。** 依赖 MachInjector 0.4.3 的如实回报。退回仅在 daemon 自主选路
   时发生 —— 调用方显式指定了策略就不擅自改道（见第 4 点）。

3. **两条路径完成后都检查目标存活。** `kill(pid, 0) == -1 && errno == ESRCH` 即判定失败，堵住
   SIGKILL 盲区。remap 路径同样适用（该路径已知存在崩溃目标的缺陷）。

4. **恢复调用方的覆盖口。** `InjectApplicationRequest` 增加 `preferredStrategy: InjectionStrategy?`
   （默认 `nil` = 由 daemon 决定）。0.1.5 把决定权收进 daemon 的理由是对的（只有 daemon 持有 task
   port 能读到这些状态，两份规则会漂移），但「谁有资格计算默认值」和「调用方能不能覆盖默认值」是两
   件事。默认值仍然只有一份，位置不变。

### 非目标

- **不修 `mach_vm_remap` 的 PAC 崩溃** —— 属 MachInjector 仓库，已另行上报。
- **不自行读目标的 `dyld_all_image_infos` 做加载验证** —— 上游 0.4.3 已提供 dlopen 判决，在库外
  重造它是重复劳动。若将来发现 2 秒 pending 在实际场景中造成漏判，再单开提案。
- **不把 SIP / `amfi_get_out_of_my_way` 状态纳入探测** —— 组合太多、容易再错，且「试了再说」本就
  不依赖对系统状态的任何推断，这正是它更稳的地方。
- **不改 `HelperProcessProbe`** —— 两个探测函数本身没问题，问题在于如何使用它们的结论。
- **不引入 `InjectionStrategy` 之外的第三条注入路径。**

## 详细设计

### `InjectionStrategy` 迁入 Interface target

枚举本身要跨 XPC 边界（作为请求字段），因此移到 Interface；探测逻辑依赖 `HelperProcessProbe`，
留在 Implementation。

`Sources/HelperServices/InjectionService/Interface/InjectionStrategy.swift`（新增）：

```swift
public enum InjectionStrategy: String, Codable, Sendable, Equatable {
    case dlopen
    case machVirtualMemoryRemap
}
```

采用 `String` raw value 而非默认的整型序号，使线格式与 case 声明顺序解耦。

`Sources/HelperServices/InjectionService/Implementation/InjectionStrategy+Probe.swift`
（由原 `InjectionStrategy.swift` 改写）：

```swift
extension InjectionStrategy {
    /// 首先尝试哪条路径。返回值是「先试这个」，不是「只能这个」——
    /// `.dlopen` 失败后由调用点退回 `.machVirtualMemoryRemap`。
    static func initialAttempt(forTarget pid: pid_t, payloadPath: String) -> InjectionStrategy

    static func isFileMapExecutableBlocked(pid: pid_t, path: String) -> Bool
    static func isLibraryValidationEnforced(pid: pid_t) -> Bool
}
```

`forTarget` 更名为 `initialAttempt(forTarget:payloadPath:)`：旧名读起来像是「这个目标的答案」，
而新语义只是「第一次试哪个」，改名让语义变化在调用点可见。

### 请求类型

`Sources/HelperServices/InjectionService/Interface/InjectApplicationRequest.swift`：

```swift
public struct InjectApplicationRequest: Codable, Request {
    public typealias Response = VoidResponse
    public static let identifier: String = "com.JH.HelperService.InjectionService.InjectApplication"

    public let pid: pid_t
    public let dylibURL: URL
    public let remapEntrySymbol: String?
    public let preferredStrategy: InjectionStrategy?

    public init(
        pid: pid_t,
        dylibURL: URL,
        remapEntrySymbol: String? = nil,
        preferredStrategy: InjectionStrategy? = nil
    )
}
```

`preferredStrategy` 为 `Optional` 且带默认值，既是纯新增，也让「未指定」和「指定了某条路径」在类型
上就可区分 —— 这正是自动退回的开关。

### 选路与退回

`Sources/HelperServices/InjectionService/Implementation/InjectionService.swift`：

```swift
@MainActor
private static func inject(request: InjectApplicationRequest) throws {
    let payloadPath = request.dylibURL.path
    let strategy = request.preferredStrategy
        ?? InjectionStrategy.initialAttempt(forTarget: request.pid, payloadPath: payloadPath)
    // 只有 daemon 自主选路时才退回：调用方指定了路径就照做，
    // 悄悄改道会让 preferredStrategy 这个逃生口失去意义。
    let mayFallBackToRemap = request.preferredStrategy == nil

    switch strategy {
    case .dlopen:
        do {
            try MachInjector.inject(pid: request.pid, dylibPath: payloadPath)
        } catch {
            guard mayFallBackToRemap else { throw error }
            try injectViaRemap(request: request, payloadPath: payloadPath, dlopenFailure: error)
            return
        }
    case .machVirtualMemoryRemap:
        try injectViaRemap(request: request, payloadPath: payloadPath, dlopenFailure: nil)
    }

    try requireTargetIsStillRunning(pid: request.pid)
}
```

`injectViaRemap` 内部做 `@available(macOS 11.0, *)` 门禁、`remapEntrySymbol` 缺失检查、调用
`MachInjectorRemap.inject`，末尾同样 `requireTargetIsStillRunning`。`dlopenFailure` 参数用于在
`remapEntrySymbol` 缺失时把 dlopen 的 `dlerror` 原文一并带进错误 —— 否则调用方只会看到「需要
entry symbol」，看不到「为什么会走到 remap」。

### 存活检查

```swift
private static func requireTargetIsStillRunning(pid: pid_t) throws {
    guard kill(pid, 0) == -1, errno == ESRCH else { return }
    throw makeError(code: -3, description: "...")
}
```

判据用 `errno == ESRCH` 而非 `kill` 的返回值：daemon 以 root 运行，对存活进程不会拿到 `EPERM`，
但按 `ESRCH` 判断在任何权限下都正确。

存在一个已知的误报窗口：目标在注入成功之后、检查之前因无关原因退出，会被判为失败。发生概率低，
且从调用方视角看「注入没有持久生效」这个结论仍然成立，因此错误信息描述现象（目标已不在运行）
而不断言成因。

### 错误码

| code | 含义 |
|---|---|
| -1 | remap 路径需要 macOS 11.0+（既有） |
| -2 | 目标需要 remap，但 payload 未提供 `remapEntrySymbol`（既有，新增携带 dlopen 失败原文） |
| -3 | 注入调用已返回，但目标进程已不存在（新增） |

## 替代方案考量

### 只加 `preferredStrategy`，不改默认值

**是什么**：保留 `isLibraryValidationEnforced` 决定路径，仅恢复调用方覆盖能力。

**为什么否**：这只是给错误的默认值配一把钥匙。每个注入 Apple 应用的调用方都得显式传
`.dlopen`，否则踩坑 —— 等于把库的判断失误摊派给所有下游。默认值本身就该修。

### 只删 LV 分支，不做自动退回

**是什么**：把 Apple 应用还给 `dlopen`，不实现失败退回。

**为什么否**：改动确实最小，但它只是把默认值从一侧挪到另一侧，在 LV 真被强制的环境里同样会静默
失败。既然上游 0.4.3 已经把「被拒绝」这个信号做出来了，不用它等于把已有的能力浪费掉。

### 把 SIP / `amfi_get_out_of_my_way` 状态纳入探测

**是什么**：读 `csr_check` 等系统状态，让预测更准。

**为什么否**：组合空间大，且每个 macOS 版本都可能变。把预测做得更准，不如根本不预测 —— 「试了
再说」判断错了只是多花一次尝试，而不是把用户送上一条会崩溃目标进程的路。

### 自行读目标的 `dyld_all_image_infos` 验证加载

**是什么**：注入后通过 `task_info(TASK_DYLD_INFO)` + `mach_vm_read` 走镜像数组，比对 payload 路径
是否真的出现在目标的已加载镜像列表里。

**为什么否**：这是调研初期基于过期 checkout（误以为 MachInjector 无法回报 dlopen 结果）设想的退路。
0.4.3 已经提供了判决，在库外重造它是重复劳动。唯一仍未被覆盖的是 2 秒 pending 的窄窗口 —— 若实际
场景中出现漏判，再单开提案；届时这一节就是它的起点。

### 让 dlopen 失败后不退回，直接把错误抛给调用方

**是什么**：只做检测，不做退回，由调用方决定是否改用 remap。

**为什么否**：调用方能做的判断，daemon 全都能做，而且 daemon 手里还多一个 `dlerror` 原文。把决定
权推给调用方就回到了 0.1.5 之前「两份规则各写一遍」的状态 —— 那正是 0.1.5 要解决的问题，其理由
至今成立。

## 影响

### 源码兼容性（source compatibility）

**纯新增**，现有调用点无需修改。

- `InjectApplicationRequest.init` 新增的 `preferredStrategy` 带默认值 `nil`，既有调用点原样编译。
- `InjectionStrategy` 从 `InjectionServiceImplementation` 移到 `InjectionServiceInterface`。它此前
  是 `public`，但只有链接了 Implementation 的 helper 二进制才够得着；Interface 是 Implementation
  的依赖并被其 `import`，因此原有可见性不减反增。**唯一可能受影响的情形**：某个 target 只链接
  Implementation 而不链接 Interface —— 在本包的 target 图里不存在这种配置。
- `InjectionStrategy.forTarget(pid:payloadPath:)` 更名为 `initialAttempt(forTarget:payloadPath:)`。
  该方法此前是 `public`，但语义已经改变（返回值从「最终答案」变成「先试哪个」），保留旧名会让调用方
  按旧语义使用一个新语义的 API，比编译错误更危险。因此**直接删除而非 deprecate**，理由见「API 演进
  与废弃策略」。

**给下游的迁移说明**：因 0.1.5 的破坏性变更（删除 `InjectApplicationViaRemapRequest`）而锁定
`exact: "0.1.4"` 的项目，可解除锁定并升级；`InjectApplicationRequest` 无需改动即可获得新行为。

### ABI 兼容性

不适用 —— 本库以 SPM 源码分发（`Package.swift` 未启用 `-enable-library-evolution`，无
`binaryTarget`），使用方每次重新编译。

### 下游影响

本仓库内受影响的 target：

- `InjectionServiceInterface` —— 新增 `InjectionStrategy.swift`，`InjectApplicationRequest` 增字段
- `InjectionServiceImplementation` —— 选路与退回逻辑重写
- `InjectionServiceTests` —— 既有的「LV 目标路由到 remap」断言需反转（见落地步骤）

已知外部下游：使用本库注入 Finder 的项目（当前锁在 `exact: "0.1.4"`）。本提案落地后应通知其升级。

### 文档与示例

- `README.md` 第 80 行对 `InjectionService` 的描述写的是「The daemon picks the loading path itself
  ⋯ Clients send a single `InjectApplicationRequest` and do not choose」，需改写为「先试后退」并
  说明 `preferredStrategy`。
- `CLAUDE.md` 无直接涉及注入选路的段落，但需确认「Request/Response convention」一节仍准确。
- 无 DocC 与示例代码。

## API 演进与废弃策略

- **`InjectionStrategy.forTarget(pid:payloadPath:)`**：直接删除，不留 `@available(*, deprecated,
  renamed:)`。理由是语义变更而非单纯改名 —— 旧名承诺「这就是该用的路径」，新方法只承诺「先试这个」。
  用 `renamed:` 做平滑过渡会让调用方在不改一行代码的情况下拿到语义不同的结果，那比编译失败更难
  排查。该方法自 0.1.5 引入至今仅一个版本，公开面很窄。
- **`InjectionServiceImplementation.InjectionStrategy`**：类型未删除，仅换 module，且新 module 是
  旧 module 的依赖，故无需废弃期。
- **版本号**：0.x 阶段，本次发 **0.2.0**。虽然对 `InjectApplicationRequest` 的调用方是纯新增，但
  `forTarget` 被删除属于源码破坏性变更，不应作为 patch 发布。
- **0.1.5 撤回**：该 tag 已从远端删除。它把每个 Apple 应用都路由到 remap，在**唯一能用上注入的
  那类机器上**恰好失效甚至崩溃目标，同时又删掉了调用方绕过它的手段 —— 没有值得保留的使用场景。
  其 commit 仍在 main 历史里，随 0.2.0 一同发布，因此删 tag 不丢代码；受影响的只有按 tag 引用
  （`exact: "0.1.5"` / `from: "0.1.5"`）的下游，它们应直接升到 0.2.0。

## 落地步骤

1. `swift package update` —— 把 `.build/checkouts/MachInjector` 从 0.3.0 系列更新到 0.4.3，否则
   `MachInjector.inject` 不会在 dlopen 被拒时抛错。
2. 新建 `Interface/InjectionStrategy.swift`，把枚举迁过去并加 `String` raw value 与 `Codable`。
3. 把 Implementation 的 `InjectionStrategy.swift` 改写为 `InjectionStrategy+Probe.swift`：只留
   extension，`forTarget` 改名为 `initialAttempt(forTarget:payloadPath:)` 并去掉 LV 那条分支。
4. `InjectApplicationRequest` 增加 `preferredStrategy` 字段与 init 参数。
5. 重写 `InjectionService.inject`：选路、失败退回、存活检查、错误码 -3。
6. 更新测试：
   - 反转 `libraryValidationTargetRoutesToRemap` —— 改为断言 LV 目标现在首选 `.dlopen`。该断言在
     修复前**失败**、修复后通过，是本次的回归测试，永久保留。
   - 保留 `plainTargetStaysOnDlopenPath` 与 `unprobeableTargetReadsAsNotEnforcingLibraryValidation`。
   - 新增 `InjectApplicationRequest` 含 `preferredStrategy` 的 Codable 往返测试，以及
     `InjectionStrategy` raw value 的线格式稳定性断言。
7. 更新 `README.md`；新建 `CHANGELOG.md` 补记 0.1.5 的破坏性变更与本次改动。
8. `swift build` + `swift test` 全绿。

**收尾时必须判断两件事**（结论写进决策日志）：

- 要不要配套专题文章
- 有没有引入新术语

## 决策日志

| 日期 | 变更 | 说明 |
|------|------|------|
| 2026-08-10 | Created as Draft | 下游项目报告 0.1.5 无法注入 Finder，只能锁回 0.1.4；定位到 `isLibraryValidationEnforced` 误判 |
| 2026-08-10 | 调研结论修正 | 初期基于过期 checkout 断言「MachInjector 无法检测 dlopen 失败」，经核对 `Package.resolved` 与本地仓库，0.4.3 已实现该能力，方案据此大幅简化 |
| 2026-08-10 | 新增存活检查 | 发现 report 机制无法区分「dlopen 未返回」与「目标已被 SIGKILL」，两者都按成功处理 |
| 2026-08-10 | Accepted | 用户批准方案，并批准同时加入 `preferredStrategy` 覆盖口 |
| 2026-08-10 | 顺带修复既有断裂 | 落地时发现 `swift test` 自 `4c0b6f8` 起就编译不过：该提交把 `XPCConnection.Error.indicatesOutdatedPeer` 改名为 `HelperClient.errorIndicatesOutdatedPeer(_:)` 却没同步测试。与本提案无关，但它挡住了验证，故一并修正调用点（未动产品代码）并更新 `CLAUDE.md` 中的过时 API 名 |
| 2026-08-10 | Implemented | 19 个测试全绿；回归测试已验证在旧行为下失败（`→ .machVirtualMemoryRemap) == .dlopen`） |
| 2026-08-10 | 配套文章判断：**不写** | 关键的非显然决策（LV 为何不能决定路径、SIGKILL 盲区、2 秒 pending 窗口）已分别落在代码 doc comment、本提案与 `CLAUDE.md`。单独成篇只会把同一批理由再抄一遍，符合「写完只是把代码翻译成中文就不该写」的反向判据。唯一从签名看不出的调用方契约是「pin 了 `preferredStrategy` 就关掉自动退回」，已写在该属性的 doc comment 与 `README.md`，不足以支撑一篇使用指南 |
| 2026-08-10 | 撤回 0.1.5，发布 0.2.0 | 用户决定删除 0.1.5 tag 而非保留。理由见「API 演进与废弃策略」：该版本没有值得保留的使用场景，且其内容随 0.2.0 一同发布，删 tag 不丢代码 |
| 2026-08-10 | 术语判断：**登记 3 条** | 新建 `Documentations/Glossary.md`：`library validation`（「请求」与「强制」之别，正是本次 bug 的成因，属易混淆近义词对）、`report page`（MachInjector 0.4.3 引入的机制及其盲区）、`seatbelt`（说明为何只有它仍直接决定路径） |
