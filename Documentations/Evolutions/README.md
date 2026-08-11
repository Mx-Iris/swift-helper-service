# Evolution 提案索引

- **项目类型**: 库（源码分发）

`swift-helper-service` 以 SPM 源码分发，只有 `.library` product，未启用 library evolution，
也没有 `binaryTarget`。因此提案的「影响」一节按**库**填写：源码兼容性必填，ABI 兼容性写「不适用」。

## 状态总表

| # | 标题 | 状态 |
|---|------|------|
| [0001](0001-injection-strategy-attempt-not-predict.md) | 注入路径改为「先尝试后退回」，不再预测目标是否接受 dlopen | Implemented |
| [0002](0002-service-errors-that-survive-xpc.md) | 服务端错误跨 XPC 保住描述，并在 daemon 侧留下日志 | Implemented |

## 状态机

`Draft` → `In Review` → `Accepted` → `In Progress` → `Implemented`，另有 `Rejected` /
`Deferred` / `Withdrawn`。

被否的提案**保留不删** —— 它是「当初为什么没这么做」的唯一记录。
