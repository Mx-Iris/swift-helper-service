# 架构总览

**读者假设**：你不记得这个项目的任何内部细节。本文从「它解决什么问题」讲起，读完应该能回答
「一条消息从宿主 App 出发，怎么走到以 root 身份执行的那行代码」。

术语见[术语表](../Glossary.md)。本文只讲**为什么这么设计**；具体某个类型的契约看源码的 doc
comment，快速查表看仓库根目录的 `CLAUDE.md`。

## 一、它解决什么问题

macOS 上让一个普通 App 做需要 root 权限的事（安装文件到 `/Library`、注入 dylib、以特权身份启动
进程），标准做法是装一个 **privileged helper tool** —— 一个以 root 运行的常驻守护进程，App 通过
XPC 请它代劳。这条路每个项目都要重写一遍同样的四件事：

1. **手搓无类型的 `xpc_object_t`**。原生 XPC 的消息是字典套字典，发送方写错一个 key、接收方读错
   一个类型，编译期毫无察觉，运行期静默失败。
2. **重复实现安装流程**。`SMAppService.daemon(plistName:)` 的注册、状态查询、引导用户到「登录项」
   设置面板。
3. **手工把多个 XPC 服务塞进一个 helper 二进制**。守护进程只有一个 mach service 名字，但功能是分块
   的，路由得自己写。
4. **自己发明重连与端点交接协议**。当一个进程（比如被注入的目标 App）需要反向连回另一个进程时，
   两边怎么找到对方、断线后怎么重建，每次都得从头设计。

这个包把这四件事做成可复用的原语。

## 二、核心决策：特权进程只做**介绍人**，不做**中间人**

这是整个架构的地基，其余设计基本都是它的推论。

**问题**：特权进程是攻击面。装进去的每一行代码都以 root 运行，出一个洞就是整机沦陷。但功能总要
有地方跑。

**朴素做法**是把所有功能都塞进 helper：宿主 App 发请求 → helper 以 root 执行 → 返回结果。缺点是
helper 越长越大，而它的每一行都在最高权限下运行；并且每次加功能都要更新那个需要用户授权安装的
二进制。

**本项目的做法**：特权进程（下称 **tool**）里**只有一张端点注册表**，没有业务逻辑。功能跑在若干
**非特权**的独立进程（下称 **sub-server**）里。tool 的唯一职责是让宿主 App 和 sub-server 互相
认识，之后就退出通信链路 —— 消息**不经过** tool。

```
┌──────────────┐   ①连接    ┌────────────────────────────┐   ②注册端点   ┌─────────────────┐
│   宿主 App    │ ─────────▶ │   特权 tool (root)          │ ◀──────────  │  sub-server (N)  │
│ HelperClient │            │ HelperServer + MainService  │              │ HelperServer     │
│              │            │      （端点注册表）           │              │ (.plain, 匿名)    │
│              │ ③取端点     └────────────────────────────┘              └─────────────────┘
│              │ ─────────────────────▶ 拿到 XPCEndpoint                          ▲
│              │                                                                 │
│              │ ④直连（不经过 tool）                                              │
│              │ ────────────────────────────────────────────────────────────────┘
└──────────────┘
```

**为什么这样更好**：

- **权限最小化**：需要 root 的操作才放进 tool（如 `InjectionService` 要 `task_for_pid`）。其余
  跑在普通权限的 sub-server 里，被攻破也只是普通用户权限。
- **tool 可以很小很稳**：注册表逻辑只有 [`MainService.swift`](../../Sources/HelperServices/MainService/MainService.swift)
  的 70 行。加功能通常不需要重装那个要用户授权的二进制。
- **消息不绕路**：`XPCEndpoint` 交接完成后是**直连**，没有 tool 转发的延迟和额外拷贝。

**代价（诚实记录）**：多了一次「发现—取端点—连接」的握手，宿主 App 的连接代码比「只连一个
mach service」复杂。这个复杂度被 `HelperClient` 的三个方法封装掉了，但它没有消失。

## 三、为什么是端点注册表，而不是多个 mach service

一个直接的替代方案：让每个 sub-server 也注册自己的 mach service 名字，宿主 App 直接连过去，压根
不需要注册表。

**否决理由**：每个 mach service 都需要一份 launchd plist 和一次安装动作。sub-server 数量一多，
安装流程就变成 N 次授权。而 XPC 的 **anonymous listener + endpoint 传递**机制天然适合这件事 ——
`XPCEndpoint` 是可以放进消息里传输的一等值，一个匿名监听器不需要在系统里注册任何名字。

所以 sub-server 的启动流程是：开一个匿名 `XPCListener` → 连到 tool（它是唯一需要名字的那个）→
调 `RegisterEndpointRequest` 把自己的 `endpoint` 存进注册表。宿主 App 反过来查。

**注册表的键**是 `HelperServerInfo(name:identifier:)`。注意一个实现细节：`name` 取的是
**tool 的 mach service 名**，不是 sub-server 自己的名字 —— 见下文「已知粗糙处」。

## 四、四种进程角色

| 角色 | 链接什么 | 监听器类型 | 典型职责 |
|---|---|---|---|
| **宿主 App** | `HelperClient` + 各 `*ServiceInterface` | 无 | 安装 tool、发现并连接 sub-server、发请求 |
| **特权 tool** | `HelperServer` + 各 `*ServiceImplementation` | `.machService(name:)` | 托管注册表 + 必须以 root 跑的服务 |
| **sub-server** | `HelperServer`（`.plain`）+ 自己那份 Implementation | `.anonymous` | 非特权业务逻辑 |
| **brokered peer** | `HelperPeer` | `.anonymous` | 被注入进第三方进程的 payload，见 [BrokeredPeer.md](BrokeredPeer.md) |

前三种共用 `HelperServer` / `HelperClient`；第四种是一套独立的握手协议，因为它的两端**都不是**
tool，tool 在其中只当引路人。

## 五、一条消息的完整路径

以宿主 App 调用 `FilesService` 为例，跟踪一次 `sendToTool`：

1. **宿主侧**：`HelperClient.sendToTool(request: FileOperationRequest(...))`
2. → `XPCConnection.sendMessage(request:)`（[XPCExtensions.swift](../../Sources/HelperCommunication/XPCExtensions.swift)）
   取出 `type(of: request).identifier`，即 `"com.JH.HelperService.Files.FileOperation"`，用它作为
   XPC 消息名，把 `request` 本身经 `Codable` 编码为消息体。
3. → XPC 传输。
4. **tool 侧**：`XPCListener` 按消息名查到注册的 handler。这个 handler 是
   `HelperServer.init` 期间通过 `service.setupHandler(handlerAdapter)` 装上的。
5. → `FilesService` 的闭包收到**已经解码成 `FileOperationRequest` 的强类型值**，执行
   `FileManager` 操作，返回 `Response`。
6. → 沿原路编码回传，`sendToTool` 的 `await` 恢复，返回值类型由 `Request.Response` 关联类型在
   编译期确定。

**关键点**：第 2 步和第 4 步的「消息名」是同一个 `identifier` 常量，由 `Request` 协议要求。发送方
和接收方不可能写岔 —— 它们引用的是同一个类型的同一个静态属性。这就是[类型化消息层](TypedMessaging.md)
存在的全部理由。

## 六、模块依赖图

```
                    ┌─────────────────────┐
                    │ HelperCommunication │  Request/Response 协议、注册表消息、
                    │  （所有人的地基）      │  SwiftyXPC 适配
                    └──────────┬──────────┘
                               │
          ┌────────────────────┼────────────────────┬──────────────────┐
          │                    │                    │                  │
   ┌──────▼──────┐      ┌──────▼──────┐      ┌──────▼──────┐    ┌──────▼──────┐
   │HelperService│      │HelperClient │      │ HelperPeer  │    │ *Interface  │
   │（纯协议）     │      │  （宿主）     │      │（brokered）  │    │ （消息类型） │
   └──────┬──────┘      └─────────────┘      └─────────────┘    └──────┬──────┘
          │                                                            │
   ┌──────▼──────┐                                             ┌───────▼────────┐
   │HelperServer │◀────────── 托管 ──────────────────────────  │*Implementation │
   │ （守护进程）   │                                            │  （业务逻辑）    │
   └─────────────┘                                             └────────────────┘
```

为什么 `HelperService` 要单独成一个**只有协议、没有实现**的 target：任何想插进 `HelperServer` 或
`HelperPeer` 的业务模块，只需要依赖这一个极小的 target，不必把整个服务器实现拖进依赖图。详见
[ModuleLayering.md](ModuleLayering.md)。

## 七、贯穿全局的三条约束

### 1. 所有长生命周期组件都是 `actor`

`HelperClient`、`HelperServer`、`MainService`、`HelperPeerClient/Server`、每个具体服务 —— 全是
actor。原因不是「跟风并发模型」，而是这些对象都持有**可变的连接状态**（`toolConnection`、
`peerConnection`、注册表字典），而 XPC 的回调是在它自己的队列上触发的。actor 把这些状态的访问串
行化，省掉手写锁。

配套约束：`HelperService` 协议要求 `Sendable`；`SwiftyXPC` 一律 `@preconcurrency` 导入；
`XPCListener` 在 `HelperServer.swift` 里有 `@retroactive @unchecked Sendable` 声明。**编辑时不要
删掉这些标注** —— 删了 Swift 6 严格并发检查就会失败。

### 2. `SwiftyXPC` 不出现在公开 API 上

`HelperCommunication` 之外的模块一律用 `private import SwiftyXPC` 或 `package import`。需要把
XPC 类型放进业务消息时，用 `HelperPeerEndpoint` 这个不透明包装（它的 `Codable` 实现刻意与裸
`XPCEndpoint` **逐位相同**，所以包不包装对线格式没有影响）。

**为什么**：调用方不该被迫 `import SwiftyXPC`。这也留出了将来换 XPC 封装库的余地 —— 虽然目前没有
这个计划。

### 3. 每个具体服务都拆成 Interface / Implementation 两个 target

宿主 App 只链接 Interface（几个 `Codable` 结构体），守护进程链接 Implementation（可能拖着
`MachInjector` 这类重依赖）。**新增服务必须遵守这个拆分**，不要写跨越边界的类型。详见
[ModuleLayering.md](ModuleLayering.md)。

## 八、已知粗糙处

诚实记录，避免下次维护的人以为这些是有意设计：

| 位置 | 问题 |
|---|---|
| `HelperServerType.plain(name:identifier:)` | **`name` 参数从未被读取**。`HelperServer.swift:41` 是 `case .plain(_, let identifier)`，注册表里的 `name` 实际取自 `connectToTool(machServiceName:)` 的参数。这个参数目前是个摆设。 |
| `HelperService.run()` | 协议要求每个服务实现它，但**没有任何地方调用**。所有现有实现都是空的 `{}`。 |
| `Sources/HelperCommunication/HelperTool.swift` | `HelperTool` actor **没有任何使用者**，是死代码。（注意别和满仓库都在用的 `pingHelperTool()` / `isPrivilegedHelperTool` 混淆，那是不同的标识符。） |
| `MainService` 的注册表 | **只增不减**。sub-server 进程退出后，它的 `XPCEndpoint` 仍留在表里，宿主 App 会拿到一个连不上的端点。对比 `InjectedEndpointRegistryService` —— 它用 `DispatchSourceProcess` 监听目标进程退出并自动清理，`MainService` 没有这层。 |
| 错误处理不统一 | `HelperServer` / `HelperPeer` 用 `@Loggable` + `#log`，`HelperClient` 和 `MainService` 用裸 `print(error)`。 |

这些都不影响当前用法，但改动相关代码时值得先知道。

## 九、延伸阅读

| 文档 | 讲什么 | 什么时候读 |
|---|---|---|
| [ModuleLayering.md](ModuleLayering.md) | 模块怎么切、可见性为什么这么定、Interface/Implementation 拆分的规矩 | 新增一个服务、或想把某个 `package` 放开成 `public` 之前 |
| [TypedMessaging.md](TypedMessaging.md) | `Request`/`Response` 协议层的设计，identifier 作为路由键，为什么不用 `NSXPCInterface` | 新增一种消息、或排查「消息发出去没人接」时 |
| [BrokeredPeer.md](BrokeredPeer.md) | `HelperPeer` 的握手/重连协议，两阶段生命周期为什么必须存在 | 用 `HelperPeerClient` / `HelperPeerServer`，或排查握手竞态时 |
| [Evolutions/](../Evolutions/README.md) | 每次实质变更的提案（决策过程、被否方案、实测数据） | 想知道「当初为什么这么改」 |
