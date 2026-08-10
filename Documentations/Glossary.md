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

### library validation：「请求」与「强制」之别

macOS 的一项代码签名策略：进程只接受 Apple 签名或与自身 Team ID 相同的 dylib。**本项目里必须区分
两件常被当成一件的事：**

- **请求（requested）** —— 进程带有 `CS_REQUIRE_LV` 标志位（`0x2000`），可用 `csops(CS_OPS_STATUS)`
  读出。这是二进制签名时用 `--options library` 写进去的**意图**。
- **强制（enforced）** —— 内核 AMFI 真的按该策略拒绝 dylib 加载。是否强制取决于**系统状态**，
  在 SIP 关闭的机器上一般**不**强制。

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
