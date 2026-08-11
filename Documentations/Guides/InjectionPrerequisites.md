# 注入的运行前提

`InjectionService` 能不能把 payload 装进目标进程，取决于**宿主机的状态**，而不只是代码是否正确。
这一篇列出那些「代码没问题但就是注不进去」的前提条件。

面向调用 `InjectApplicationRequest` 的人，以及排查注入失败的人。

## 先看错误里写了什么

从 0.3.0 起，服务端失败的完整描述会传到调用方（此前只剩 domain + code，见
[TypedMessaging 第六节](../Architecture/TypedMessaging.md#六错误怎么跨边界)）。所以**第一步永远是
把 `error.localizedDescription` 打出来**，它通常直接说明了原因，例如 `dlopen` 被拒时会带上
`dlerror` 的原文。

daemon 侧同时有日志：

```bash
log stream --predicate 'subsystem == "com.JH.HelperService.InjectionService"' --level info
```

要看历史记录（比如失败已经发生过了）：

```bash
log show --predicate 'subsystem == "com.JH.HelperService.InjectionService"' --last 30m --info
```

## 前提一：library validation —— 关 SIP 不等于关掉它

**这是最容易误判的一条。**

想把**非平台签名**的 dylib 注入 Apple 的平台二进制（Finder、Dock、各种设置面板服务），只关闭 SIP
是**不够的**。真正的开关是一份 plist 里的值：

```bash
sudo defaults write /Library/Preferences/com.apple.security.libraryvalidation.plist \
    DisableLibraryValidation -bool true
```

关闭 SIP 只是打开了「允许 `amfid` 去读那份 plist」这道门。**SIP 关了但 plist 没写（默认状态）的
机器上，library validation 照常强制** —— 这正是最初那次线上事故的机器状态，也是当时排查跑偏的原因。

判定链（逆 macOS 26.6 的 `/usr/libexec/amfid` 得到，已由项目作者实机验证）：`amfid` 只在「SIP 关」
或「Apple 内部机」时才去读那份 plist；读到的 `DisableLibraryValidation` 才是真正决定放行与否的
标志，放行时会打一条 `library validation is globally disabled`。函数偏移换个系统版本就失效，但
**结论本身不依赖它们**。

术语上「请求」与「强制」的区别见[术语表](../Glossary.md)的 `library validation` 词条。

### 表现

目标进程拒绝 `dlopen`，`dlerror` 大意是 code signature / library validation 相关。服务端会自动退回
`mach_vm_remap` 路径 —— 但那条路**需要 payload 导出一个入口符号**（见下）。

### 复现与恢复

```bash
# 让 library validation 恢复强制（用于复现被拒）
sudo defaults delete /Library/Preferences/com.apple.security.libraryvalidation.plist DisableLibraryValidation
# 改回放行
sudo defaults write /Library/Preferences/com.apple.security.libraryvalidation.plist DisableLibraryValidation -bool true
```

这两条会改**全机状态**，且需要 `sudo`。因此它**不在自动化测试里**，是发布前的手动检查项。

## 前提二：走 remap 路径时，payload 必须导出入口符号

`mach_vm_remap` 把 payload 的页直接映射进目标，**dyld 的构造函数那一轮根本不会跑**。所以没有
`__attribute__((constructor))` 这种自动执行的入口，只能靠一个导出的
`void *(*)(void *)` 符号，由调用方通过 `InjectApplicationRequest.remapEntrySymbol` 告知。

没给这个符号又必须走 remap 时，服务端抛的错会同时带上「当初 `dlopen` 是怎么被拒的」——因为只知道
「remap 需要符号」的调用方无从判断**为什么**轮到了 remap。

remap 路径要求 macOS 11.0+。

## 前提三：目标进程的 seatbelt profile

目标若被沙盒策略禁止 `file-map-executable`，`dlopen` 一定失败。这一条是**可以提前知道**的，所以
`InjectionStrategy.initialAttempt(forTarget:payloadPath:)` 会直接选 remap，不做无谓尝试 —— 一次注定
失败的 `dlopen` 会在目标里永久留下一个空转线程和几页 shellcode。

## 前提四：目标得活着，而且要能活下来

注入「成功」不等于目标还在。页哈希与签名对不上的 dylib，会在 page-in 时被内核直接 SIGKILL，
**`dlopen` 根本来不及返回**，注入器那边看不到任何错误。

`InjectionService` 因此在注入后检查进程是否还在，不在就报失败（`targetNoLongerRunning`），描述里
说明了这个成因。这不是危言耸听式的猜测：`MachInjector` 的 report block 由目标进程内部的 pthread
写回，目标没了就永远停在 `Pending`，与「`dlopen` 很慢」无法区分。

## 已知不覆盖

- 本仓库的自动化测试**从不执行真实注入**，上面每一条都要手动验证。
- `amfid` 的判定链依赖系统版本。
