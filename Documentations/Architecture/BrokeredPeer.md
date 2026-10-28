# Brokered Peer（已移到 swift-injection-peer）

本文连同 `HelperPeer` 的代码一起移到了 **swift-injection-peer**，全文在那里：
[Documentations/Architecture/BrokeredPeer.md](https://github.com/Mx-Iris/swift-injection-peer/blob/main/Documentations/Architecture/BrokeredPeer.md)。

这里留一个存根，因为本仓库多处仍链接到这个路径（`README.md`、`AGENTS.md`、`Glossary.md`、
`Overview.md`、`ModuleLayering.md`）。

## 为什么移走

payload 与它客户端之间的通道**不需要任何特权**，所以它不属于「特权 helper 服务」这个库。完整论证见
提案 [共享 daemon 只管注入，回传通道移到独立库](../Evolutions/0004-daemon-only-injects.md)。

**要紧的是：这不等于「这套协议错了」。** 自带 daemon 的工具（RuntimeViewer、`InjectionScaffold`
生成的项目）把端点注册表挂在自己的 daemon 上，broker 就是它自己，签名要求自己说了算 —— brokered XPC
在那里一直正常工作，而且是主路径。本库移出的只是「**共享** daemon 替 payload 保管端点」这一项：
共享者必须设签名要求，而被校验的是被注入的那个 App，它永远不带本 Team 的签名。

## 本库还留着什么

- **`HelperPeerEndpoint`**（在 `HelperCommunication` 里）—— `Codable` 包装 `XPCEndpoint` 的通用
  类型。它留下是因为注册表的载荷类型要用它，而新库依赖本库即可取用；搬走反而会和本库重复。
- **`InjectionPeer` SPI** —— 新库需要、本库其余部分也仍在自用的那批内部接口（`XPCHelperHandler`
  的初始化器、`XPCConnection` 的 typed `sendMessage` 与端点注册、`ServiceFailureTransport`、
  `HelperServiceFailure.registerForDecoding()`）。它们原本是 `package`，跨 package 访问不到。
  见提案的「详细设计 / 跨 package 的访问级别」。
