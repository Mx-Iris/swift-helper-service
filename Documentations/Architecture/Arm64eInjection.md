# arm64e：注入器和 payload 为什么都必须带这个切片

Apple Silicon 上的系统进程 —— Dock、Finder、`/System/Applications` 下的每一个 App —— 都是 arm64e。
往它们注入时，**注入器与 payload 都必须带 arm64e 切片**，而两者的理由完全不同。缺任何一边，失败的
表现都不指向真正的原因。

这份文档讲原因，以及让它成立的六处配置各自在挡什么。配置的操作步骤在 `InjectionScaffold` 的
[BuildingForArm64eTargets](https://github.com/Mx-Iris/InjectionScaffold) 指南里；这里讲的是为什么。

## 一、注入器必须 arm64e：因为一条指令在 arm64 下是空操作

注入 arm64e 进程要给目标线程的程序计数器做指针认证签名。`MIMachInjector.m` 里：

```c
__darwin_arm_thread_state64_set_pc_fptr(
    threadState,
    ptrauth_sign_unauthenticated((void *)code, ptrauth_key_asia, 0));
```

`ptrauth_sign_unauthenticated` 编译成 arm64e 时是一条真正的 PAC 指令；**编译成 arm64 时它是空操作**，
原样返回指针。于是注入器交给目标的是一个没有签名的地址，目标进程执行时认证失败。

注意这里失败的是**目标**，不是注入器。注入器一切正常地跑完，然后目标崩了 —— 这是整件事最误导人的
地方。

对共享 daemon 来说，这意味着 **daemon 二进制必须带 arm64e 切片**。客户端不需要：客户端只是发一条
请求。

## 二、payload 必须 arm64e：实测结论，机制未查明

**实测：arm64-only 的 payload 进不了 arm64e 的系统进程。** 这一条在 RuntimeViewer 上验证过。
**具体原因尚未查明**，所以这里只记录结论与证据，不给机制解释。

dyld 的架构降级表支持这个结论：`archs_arm64e[] = { arm64e }`
（`mach_o/GradedArchitectures.cpp:162`）—— 开着指针认证的 arm64e 进程只接受 arm64e 的库，只有
keys-off 的变体才接受 arm64。反过来 `archs_arm64[] = { arm64, arm64_alt }` 同样不接受 arm64e。

本机实测分布：`/System/Applications` 下 47 个 App 全部 arm64e，`/Applications` 下 174 个里 171 个
只有 arm64。**两边都要覆盖，所以 payload 必须 `arm64 + arm64e` 双切片。**

### 有一个看起来相反的旁证，不要被它说服

Dock 用来加载第三方 Dock tile 插件的宿主进程 `com.apple.dock.external.extra.arm64.xpc` 自己是
arm64e，而它加载的插件只有 arm64。**这个观察属实**，复核过。

但它**不足以推翻上面那条实测**：Dock tile 插件走的是什么加载路径、那个宿主进程以何种方式启动，都
没有查证过，而注入场景下的加载路径与之未必相同。一个没查清机制的旁证，推不翻一次直接实测。

留着这段，是为了避免下次有人重新发现 Dock 这个例子、又得出相反的结论。真要推翻现在这条，需要的是
「arm64-only payload 成功注入 arm64e 系统进程」的实测。

## 三、daemon 会在注入前拦住切片不对的 payload

`InjectionService` 读目标主可执行的架构列表，推断它实际执行哪个切片，再比对 payload 有没有那个
切片；没有就拒绝，并在错误信息里写明目标执行什么、payload 有什么。

没有这条检查时，两条注入路径的表现分别是：`dlopen` 回一句「文件加载不了」，读起来像路径写错了；
remap 那条更糟 —— payload 进去了，然后**目标死了**。

两条边界：

- **读不出来一律放行。** 与既有的 platform 守卫一致 —— 看不清就拦，会把每个无法解析的文件变成一次
  失败的注入。
- **Rosetta 目标跳过这项检查。** 「内核把 arm64e 排在 arm64 前面」这条推断对它不成立。

## 四、六处配置，各自在挡什么

缺任何一处，构建都会「成功」，然后在注入时失败。

| # | 配置 | 不做会怎样 |
|---|---|---|
| 1 | 独立的 `.xcworkspace`，且本地包是它的成员 | 第 2 条无从生效。`.xcodeproj` 内嵌的那个 `project.xcworkspace` 会被忽略；包若以文件夹引用的形式留在 pbxproj 里，Xcode 把它当普通文件夹而不是 Swift 包 |
| 2 | workspace 设置里 `iOSPackagesShouldBuildARM64e = true` | 本地 Swift 包不产出 arm64e 切片。名字里的 `iOS` 有误导性，它对 macOS 同样有效 |
| 3 | **项目级** `ONLY_ACTIVE_ARCH = NO` | 本地包是用项目级设置构建的，target 级够不着。Debug 默认 `YES`，会把包裁回本机架构，arm64e 切片刚产出就被丢掉 |
| 4 | **只在 target 级** `ENABLE_POINTER_AUTHENTICATION = YES` | 没有它，`ARCHS_STANDARD` 不展开出 arm64e。**绝不要提到项目级** —— 提上去之后本地包的 arm64e 切片会**替换**掉 arm64 而不是追加，macro plugin（必须是宿主架构）随即链接失败，报一长串 swift-syntax 符号缺失 |
| 5 | `PrecompiledLibraries/swift-syntax` 作为 workspace 成员 | 宏要从源码构建 swift-syntax，而它可能按不同切片构建导致链接失败。预编译的 xcframework 自带全部切片，不受任何架构设置影响 |
| 6 | 构建时 `-destination 'generic/platform=macOS'` | **最隐蔽的一条，前五处全对也会栽在这里。** `platform=macOS` 是「为这台机器构建」，会把架构收敛到宿主架构，**无论 `ARCHS` 和 `ONLY_ACTIVE_ARCH` 怎么设，而且不报任何错**。Xcode GUI 里这就是「My Mac」与「Any Mac」的区别 |

验收办法是看产物，不是看构建有没有通过：

```
正确： 包的产物     x86_64 arm64 arm64e     ← 追加
错误： 包的产物     arm64e                  ← 第 4 条提到项目级了，替换掉了 arm64
错误： 包的产物     arm64                   ← 第 2、3 或 6 条没做
```

## 五、SwiftPM 产不出 arm64e，但 Xcode 项目可以

这两句话都对，而把前一句推成「所以 payload 只能是纯 Objective-C」是错的 —— `ViewHierarchyCapture`
的提案 0001 当初就是这么推的。

Xcode 项目用**项目自己的 `ARCHS`** 构建本地包的 target，第 2 条把这一点延伸到包。所以 payload 可以
是 Swift 和 Objective-C 混合的，只要它由 Xcode 项目构建。实测产物：
`ViewHierarchyCapturePayload.framework` 为 `x86_64 arm64 arm64e`，其中含 Swift 代码。

这个错误推断在 payload 不需要 Swift 时没有代价。迁移到共享 daemon 之后，回传通道是 Swift 写的，它才
成为真正的障碍。
