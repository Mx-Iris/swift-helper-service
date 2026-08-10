# 文档索引

`swift-helper-service` 的内部文档。面向公众的说明在仓库根目录的 [`README.md`](../README.md)，
面向 agent 的工作约定在 [`CLAUDE.md`](../CLAUDE.md)。

## 目录

| 路径 | 内容 |
|------|------|
| [`Evolutions/`](Evolutions/README.md) | 提案 —— 每次实质变更一篇，从调研到落地全生命周期都在同一份文件里 |
| [`Glossary.md`](Glossary.md) | 项目术语表 —— 自造词、本项目特有含义、易混淆的近义词对 |

## 全部文档

### Evolutions

- [0001 - 注入路径改为「先尝试后退回」，不再预测目标是否接受 dlopen](Evolutions/0001-injection-strategy-attempt-not-predict.md)
  —— 把 `InjectionService` 的选路从读 `CS_REQUIRE_LV` 预测，改为先试 `dlopen`、被拒再退回
  `mach_vm_remap`，并补上目标进程存活检查。

### 其他

- [术语表](Glossary.md) —— 目前收录 `library validation`（「请求」与「强制」之别）、`report page`、
  `seatbelt` 三条。

## 约定

- 提案文件名用 `NNNN-kebab-case-slug.md`（编号互引、编号排序即时间序）；其余文档目录与文件名一律
  PascalCase。
- 正文中文，标识符与技术术语保持英文。
- **新增或重命名任何文档都必须同步更新这份索引**，否则文档等于不存在。
