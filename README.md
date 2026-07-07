# Cline Governance Framework 开发者指南

> **生命周期**：永久保留——开发者入口文档，随版本更新。
>
> **目标读者**：想用本框架治理 Cline AI agent 的开发者。读完这两份文档，不用重新读源码就能上手开发。

---

## 这是什么

一套 **Cline AI agent 治理框架**，用五层架构组织"会话交接 / 证据治理 / 评审纪律 / 经验沉淀"：

| 层 | 目录 | 职责 |
|----|------|------|
| L1 Core | `.governance/core/` | 跨项目通用宪法 |
| L2 Rules | `.governance/rules/` | 装好即生效的薄入口 |
| L3 Capability | `.governance/capabilities/` | "怎么做"的代码模块 |
| L4 Hooks | `.governance/hooks/` | "什么时候调用"的事件驱动检查 |
| L5 Runtime | `HANDOFF.md` + `.governance/runtime/` | 动态状态文件 |

框架模板仓库：[https://github.com/zk-0808/cline-plus.git](https://github.com/zk-0808/cline-plus.git)

---

## 文档导航

本指南拆成两份文档，按你的需求选择：

### 📖 [设计思考与实验发现](design-thinking.md)

**读这份如果你想知道"为什么"**——框架的设计依据、源码探查发现、A/B 测试结论。

- 框架设计哲学与 ADR 演进
- Cline System Prompt 分层注入机制（源码穿透结论）
- 协同前缀效应（A/B 测试 Round 1 + Round 2，n=10）
- Rule 失效 6 场景诊断决策树
- 为什么不改源码（3 方案评估 + 负面影响）
- 8 条方法论教训

### 🔧 [实践开发指南](development-guide.md)

**读这份如果你想知道"怎么写代码"**——平台 API、开发步骤、诊断方法。

- Quickstart：30 分钟从 clone 到跑通
- Cline 插件平台 7 层生命周期 + 扩展点速查
- 框架目录契约与加载顺序
- Capability 开发 7 步 SOP + 代码骨架
- 诊断手册（plugin 不加载 / rule 不生效 / codec bug）
- 已知局限与路线图

### 🗺️ [Cline Plugin Architecture Atlas](cline-plugin-architecture-atlas.md)

**通用 Cline 插件平台深入参考**——逐层函数级架构地图，想深入 Cline 源码时查阅。

- 7 层生命周期逐层函数签名、错误模式
- 文件 → 函数 → 行号速查表
- 跨层关注点（超时策略、SDK 隔离、崩溃恢复）

---

## Quickstart

### 1. 获取框架

```bash
# 方式 1: GitHub Template（推荐）
# 到 cline-plus 仓库右上 "Use this template" → 创建你的项目 → git clone
git clone https://github.com/zk-0808/cline-plus.git my-project

# 方式 2: 叠加到已有项目
cd your-existing-project
git remote add template https://github.com/zk-0808/cline-plus.git
git fetch template main
git checkout template/main -- .governance/ .clinerules HANDOFF.md scripts/
git remote remove template
```

### 2. 改参数

打开 `.governance/core/constitution.md` 底部"项目可调参数"区，按你的项目调整取值（阈值、路径等）。判定动作不动，只改取值。

### 3. 安装插件到 CLI

> 以下脚本在框架模板仓库的 `scripts/` 目录中。

```powershell
# Windows
powershell -ExecutionPolicy Bypass -File scripts\sync-governance-plugin.ps1

# macOS/Linux
bash scripts/sync-governance-plugin.sh
```

这会把 `.governance/plugin/` 同步到 `~/.cline/plugins/installed/local/governance/`——Cline CLI 只扫描用户主目录。

### 4. 验证

```bash
cline -i
```

在 CLI 里问模型：

> What is the title of section 1 in Core Constitution?

如果模型直接回答（不调工具），说明 rule 注入成功。

检查 marker 文件是否存在：

```bash
cat .governance/runtime/plugin-loaded.marker
# 应输出 "loaded at <timestamp>"
```

### 5. 修改代码后重新同步

每次修改 `.governance/plugin/` 或 `.governance/capabilities/` 的代码后，重新执行 Step 3 的同步命令。

---

## 我想做什么

| 我想... | 读哪里 |
|---------|--------|
| 30 分钟跑通 | 上面 Quickstart |
| 理解为什么这么设计 | [设计思考](design-thinking.md) §1 |
| 理解 prompt 注入原理 | [设计思考](design-thinking.md) §2 |
| 看协同前缀实验数据 | [设计思考](design-thinking.md) §3 |
| 写一个新 Capability | [开发指南](development-guide.md) §4 |
| 理解 Cline 插件系统 | [开发指南](development-guide.md) §2 |
| 诊断 plugin 不加载 | [开发指南](development-guide.md) §5 |
| 知道当前有什么坑 | [开发指南](development-guide.md) §6 |
| 深入 Cline 源码函数级 | [Architecture Atlas](cline-plugin-architecture-atlas.md) |
| VS Code 插件不工作 | `scripts/patch-vscode-plugin-support.ps1` |

---

## 版本基准

| 组件 | 版本 |
|------|------|
| Cline CLI | 3.0.37 |
| VS Code Extension | 4.0.x（plugin 系统不可用） |
| SDK | v0.0.56 |
| 框架版本 | v1.0-alpha |
| 最近更新 | 2026-07-07 |

---

## License

Apache-2.0
