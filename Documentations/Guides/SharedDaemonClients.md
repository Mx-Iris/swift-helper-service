# 接入共享注入 daemon

写一个注入工具时，**不要再带自己的 daemon**。装一个 [Injection
Platform](https://github.com/Mx-Iris/InjectionPlatform)，让用户在「登录项」里批准一次，本机所有注入
工具共用它。这份文档讲客户端这边要做什么、以及哪些事做不了。

脚手架 `InjectionScaffold` 默认就生成这种形态（`generate.sh --name MyTool`），下面的内容是它生成的
东西背后的理由；手写一个客户端时也照这个来。

## 一、用户要装什么

**只有一件事**：Injection Platform，并在「系统设置 › 通用 › 登录项」批准它的 daemon。

你的工具不装任何东西，也不以 root 运行。`task_for_pid` 是注入唯一需要 root 的地方，而它在 daemon
里。

客户端能做的只有「问」和「报」：

```swift
let daemon = HelperClient()
try await daemon.connectToTool(
    machServiceName: "com.JH.InjectionPlatform.service",   // Debug 构建是 .service.debug
    isPrivilegedHelperTool: true
)
try await daemon.requireToolVersion(atLeast: HelperToolVersion(major: 0, minor: 4, patch: 0))
```

**版本要主动问，不要从失败里猜。** `HelperClient.errorIndicatesOutdatedPeer(_:)` 不可能返回 `true`
（原因见[架构总览](../Architecture/Overview.md)第八节），所以「daemon 太旧」和「连不上」从错误本身
分不出来 —— 而两者的处理方式完全不同：一个是「打开那个 App 升级」，另一个是「去装它」。

**客户端不得安装、卸载或升级 daemon。** 它服务着别的工具，重装会重启它，于是别的工具到它们 payload
的通道全部断掉 —— 而 payload 卸载不掉，每个受影响的目标都得重启。升级入口在平台那个 App 里，并且
那里会把这个后果说给用户听。

## 二、你的二进制要满足什么签名要求

daemon 的 listener 只接受签名匹配的调用方。默认要求是：

```
anchor apple generic and certificate leaf[subject.OU] = "D5Q73692VW"
```

也就是**由这个 Team ID 签名**。要点：

- **日常开发不需要做任何事。** 项目设了 `DEVELOPMENT_TEAM` 的话，Xcode 连 Debug 构建都用 Apple
  Development 证书签名，leaf 的 OU 就是 Team ID，本来就满足。
- **满足不了的是这几种**：ad-hoc 签名的产物（`codesign -s -`，也就是 `swift build` 留下的那种）、
  没有签名证书的机器上的构建、团队外的客户端。
- 这种情况下用**开发模式**（下一节），不要试图绕过。

要求在 **listener 构造时**定死，`XPCListener` 没有在运行中更改的办法。所以切换开发模式必须重装
daemon —— 这是机制决定的，不是实现偷懒。

## 三、开发模式：daemon 不验调用方了

平台 App 里的一个开关，打开之后 daemon 接受**本机任何进程**的请求。

这是一个真实的权限提升面：一个能往任意进程注入代码、又谁都能调的 daemon，等于把整台机器交出去。
所以：

- 平台的界面在它**真的开着**的时候一直挂警告，而不是开关一关就撤掉警告 —— 关掉开关不等于关上门，
  要等 daemon 重启。
- 界面因此要同时显示两件事：**磁盘上的开关状态**，和**正在跑的 daemon 是否真的在验**。两者在重启前
  不一致，把它们合成一个布尔值，就一定会在某个方向上撒谎。
- 开发模式打开时，一个未经验证的客户端也能把它**保持**打开。警告为此不会消失，这是对一个用户主动
  选择进入的状态的诚实表述。

## 四、注入请求长什么样

一条：

```swift
try await daemon.sendToTool(request: InjectApplicationRequest(
    pid: targetProcessIdentifier,
    dylibURL: payloadURL,
    remapEntrySymbol: "my_tool_payload_remap_entry",
    preferredStrategy: nil        // ← 几乎总是 nil
))
```

**`preferredStrategy` 传 `nil`，让 daemon 选。** 它握着目标的 task port，能直接探目标的沙盒与签名
状态；而且它不预测 —— 先试 `dlopen`，等目标真的拒绝了再退到 remap。客户端这边再放一份同样的规则，
两边迟早会漂。

只有在「默认对这个目标判断错了」时才钉死一条路，**钉死同时关掉自动回退**：指定了哪条就只走哪条，
要么成功要么报错，不会悄悄换另一条。

**`remapEntrySymbol` 每次都要给。** 它只有 remap 那条路用得上，但不给就等于在最需要回退的那些目标
上直接失败。payload 侧的要求见下一节。

### payload 放在哪

daemon **不托管 payload**。它以 root 读你给的路径，所以：

- 路径只要**你自己写得了**就行 —— App bundle 里的 framework、`~/Library/Application Support/<你>/`
  都可以，不需要 `/Library`。
- 曾经的做法是经 daemon 的 `FilesService` 拷进 `/Library`。**共享 daemon 不挂那个 service**，发过去
  会得到一条「无法识别的消息」，错误信息离真正的原因很远。
- `dlopen` 那条路上是**目标进程**打开这个文件，所以它要在目标读得到的地方。`/Applications` 下的
  App bundle 任何沙盒配置都允许读；用户家目录下的路径，沙盒目标读不到 —— 但沙盒目标本来也 `dlopen`
  不了外来的 dylib，那正是 remap 存在的理由，而 remap 下只有 daemon 读这个文件。

## 五、注入前 daemon 会拒绝什么

三条校验，不合格直接拒绝并给出能照着改的错误信息。知道它们在挡什么，比看到错误再查快得多：

| 校验 | 拒绝什么 | 为什么值得拒 |
|---|---|---|
| **platform** | payload 的 `LC_BUILD_VERSION` 与目标不兼容 | 早有的检查 |
| **架构切片** | arm64e 目标 + 没有 arm64e 切片的 payload | `dlopen` 回的是「文件加载不了」，读起来像路径写错了；remap 那条路更糟 —— payload 进去了，目标死了 |
| **签名** | **声称有签名但验不过**的 payload | 这正是会杀死目标的那种。**未签名的 payload 是放行的** —— ad-hoc 在开发期很正常，「谁能注入什么」是 listener 要求该管的事，不是这里 |

签名这条有个容易踩的组合：**改过的二进制**。`strip`、`lipo -remove` 之后镜像被重写，原签名失效，
daemon 就会拒。改完要 `codesign --force --sign -` 重签一遍 —— 把签名丢掉让检查形同虚设不是办法。

架构这条对 **Rosetta 目标跳过**：「内核把 arm64e 排在 arm64 前面」这条推断对它不成立。

## 六、回传通道

注入进去的 payload 要能跟你的工具说话。用 `PeerLink`：

```swift
// 宿主侧，注入之前
let link = try await PeerLink.host(
    machServiceName: machServiceName,
    isPrivilegedHelperTool: true,
    targetProcessIdentifier: targetProcessIdentifier
)
link.channel.setMessageHandler(SomeRequest.self) { … }
try await link.channel.activate()

// payload 侧，进去之后。注意它不收 pid —— payload 就是目标，它问 getpid()
let link = try await PeerLink.payload(machServiceName: machServiceName, isPrivilegedHelperTool: true)
```

两条规矩，违反了不会报错、只会挂住：

- **宿主这一端必须在注入之前开起来。** payload 一启动就要找对面。
- **先装 handler，再 `activate()`。** 对面在链路一通就发请求，晚一步注册的 handler 就是一条被回成
  「没有注册处理器」的请求 —— 看起来像版本不匹配。

沙盒目标会自动换成 loopback socket，而且**角色是反的**（宿主监听、payload 拨号）。这对调用方透明，
但两件事要知道：沙盒目标缺 `com.apple.security.network.client` 时连 localhost 都会被拒；而且
**socket 这条路没有重连** —— 宿主重启后 payload 手里的连接已死且无法被告知新的。细节见
[BrokeredPeer.md](../Architecture/BrokeredPeer.md) 第七节。

## 七、hook 用共享的 `HookKit`

不要再生成一份副本。`HookKit` 是本包的 product，每个项目拿到的是同一份 —— 生成副本正是「在一个项目
里学到的教训传不到另一个项目」的来源。用法见 [HookKit.md](../Architecture/HookKit.md)。

## 八、还没被验证的部分

诚实记录，免得把「写出来了」当成「验过了」：

- **整条链路（客户端 → daemon → payload → 通道 → 业务请求）一次真实注入都没跑过。** 共享 daemon
  需要用户在「登录项」里批准，而那一步只能由人来做。
- **沙盒目标的 socket 回传路径从未在真实沙盒进程里跑过。** 它有真实 loopback 端点对连的集成测试，
  但那是两个非沙盒进程。
- **签名要求没有被一个真正不满足它的客户端试过。** 开发模式的兜底值反向验证过（把失败兜底从「关闭」
  翻成「开启」，六个断言立刻变红），但那是单元测试，不是一次被拒的连接。
