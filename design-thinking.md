# 设计思考与实验发现

> **生命周期**：永久保留——框架设计依据与实验产出，跨版本保留。
>
> **定位**：回答"为什么这么设计"——源码探查结论、A/B 测试数据、架构决策推理。读完这份文档，你不需要重新读 Cline 源码就能理解框架的每一个设计选择。
>
> **证据来源**：全部结论基于源码探查（unminified `.ts` 文件）和实测验证（n=3 到 n=10）。每条结论标注 Confidence 和来源。
>
> **完整调查文档**：本文引用的调查笔记和 ADR 均存放在 [cline-plus 模板仓库](https://github.com/zk-0808/cline-plus) 的 `docs/decisions/` 目录下，此处仅引用结论。

---

## 目录

1. [框架设计哲学](#1-框架设计哲学)
2. [System Prompt 分层注入机制](#2-system-prompt-分层注入机制)
3. [协同前缀效应](#3-协同前缀效应)
4. [为什么不改源码](#4-为什么不改源码)
5. [经验教训](#5-经验教训)

---

## 1. 框架设计哲学

### 1.1 核心问题

AI coding agent（Cline）在长会话中面临三个退化：

| 退化 | 表现 | 传统解法 |
|------|------|---------|
| **上下文遗忘** | 会话越长，模型越容易遗忘早期决策 | 写更多 context（但 context window 有上限）|
| **证据漂移** | 模型凭印象推断，不区分"已验证"和"假设" | 人工审查（但人也会漏）|
| **经验不沉淀** | 每次新会话从零开始，重复踩坑 | 写文档（但文档没人读）|

本框架不是解决"让模型更聪明"，而是解决**"治理基础设施缺失"**——让会话交接、证据分级、经验沉淀有标准化的容器和流程。

### 1.2 五层架构的设计推理

```
L1 Core Constitution    ← 为什么要 ≤800 token？
L2 Rules (薄入口)       ← 为什么要 ≤50 行？
L3 Capability           ← 为什么要 pass/block/inject 三态？
L4 Hooks                ← 为什么要 Capability 与 Hook 正交？
L5 Runtime              ← 为什么要 HANDOFF.md 在根部？
```

**L1 为什么 ≤800 token？**

宪法通过 `registerRule` 注入 system prompt（详见 §2）。Token 占用直接影响：
- 200k context window 模型：0.4% → 安全
- 32k context window 模型：2.5% → 仍安全
- 但超过 2000 token 开始挤占有用上下文

实测结论（第二轮源码探查 Task I）：base prompt 仅 ~600 token，registerRule 增量 ~925 token，总量 <2k token。800 token 上限是保守但合理的。

> **证据**：cline-plus 仓库 `docs/decisions/investigation/investigation-note-cline-prompt-layering-round2.md` Task I

**L2 为什么 ≤50 行？**

Rules/ 是"装好即生效"的入口——它不是治理内容的载体，而是触发器。真正的治理内容在 `examples/`（需手动复制）或 `core/`（宪法）。如果入口规则超过 50 行，说明它承载了不该承载的内容。

这与 `core/` 的 ≤800 token 形成一致的防膨胀纪律：**入口要薄，内容要精**。

**L3 为什么 pass/block/inject 三态？**

同一个 Capability 可被多个 Hook 调用（如 `git-checker` 既被 PreToolUse 调用做阻断，也被 SessionStart 调用做注入）。如果返回值语义不统一（有时返回 bool，有时返回 string），Hook 无法正确分发。

三态是**最小完备集**：
- `pass` = 不干预
- `block` = 阻断（仅 PreToolUse 有效）
- `inject` = 注入上下文（SessionStart / PreToolUse / PreCompact）

**L4 为什么 Capability 与 Hook 正交？**

如果 Capability 既判断又执行，它就绑定了特定 Hook。比如 `git-checker` 需要在 PreToolUse 阻断、在 SessionStart 注入——如果它自带执行逻辑，两个场景的执行代码会耦合在一个模块里。

正交分离后：Capability 只表达意图（"该不该 block"），Hook 执行动作（"把 skip 返回给 runtime"）。同一 Capability 被不同 Hook 调用时，行为一致。

**L5 为什么 HANDOFF.md 在根部？**

| 候选位置 | 整洁性 | 可发现性 | 判定 |
|---------|--------|---------|------|
| `.governance/runtime/handoff.md` | 高（隐藏）| 低（埋深 + 点前缀）| ✗ 活文件不该藏 |
| `HANDOFF.md`（根部）| 中 | 高（每次会话读写）| ✓ 选用 |

HANDOFF.md 是高频人工交互文件，可发现性 > 整洁性。`snapshot.json` 是机器写、人不读，埋进 `.governance/runtime/` 无妨。

> **证据**：cline-plus 仓库 `docs/decisions/delivery-framework-design.md` §2.3

### 1.3 ADR 演进路线

框架的核心决策记录在 7 份 ADR 中，按时间线阅读可以理解设计演进：

| ADR | 日期 | 核心决策 | 为什么 |
|-----|------|---------|--------|
| ADR-001 | 2026-06-23 | handoff/compact/memory 架构方向 | 最初立项，选 A+B'+D'+F 方向 |
| ADR-002 | 2026-06-23 | Plugin 作为实验线 | 薄 Skills + 单点 WebSearch + Plugin 实验线 |
| ADR-004 | 2026-06-27 | P5 Spike 暂停 | CLI 载体稳定性不足 |
| ADR-005 | 2026-06-28 | Compaction vs Handoff 拆分 | Cline 原生 compaction 与插件 handoff 是正交问题 |
| ADR-006 | 2026-06-28 | 原生机制优先 | 绝不用规则解决运行时问题 |
| ADR-007 | 2026-07-04 | registerRule 静态注入 | messageBuilder 服从度不足，静态内容必须走 registerRule |

**最关键的转折点是 ADR-007**。最初的设计是"用 messageBuilder 注入 handoff/snapshot 上下文"，但实测发现：

> messageBuilder 注入的 system 消息被 cline agent 训练偏好压过，模型忽略注入内容；registerRule 注入到系统提示词顶层后模型直接引用。

这个发现直接改变了注入策略，也催生了后续的 prompt 分层探查和协同前缀实验。

> **证据**：cline-plus 仓库 `docs/decisions/adr/ADR-007-snapshot-registerRule-static-injection.md`

### 1.4 分发形态：为什么是 git template Repo

| 候选 | 优势 | 劣势 | 判定 |
|------|------|------|------|
| npm 包 | 版本管理好 | 用户需 npm install + 配置 | ✗ 门槛高 |
| CLI plugin 打包 | Cline 原生 | plugin 系统仍不稳定 | ✗ 双形态实现坑 |
| **git template repo** | clone 即用 | 无自动更新 | ✓ 选用 |

git template repo 的核心理念：**框架是文件的集合，不是运行时依赖**。用户 clone 后获得全部源码，自行修改、自行版本管理。Plugin 代码作为文件存在于 repo 中，用户自行决定是否启用。

---

## 2. System Prompt 分层注入机制

> **状态**：✅ Fully Verified（两轮源码探查 + 实测验证）
>
> **穿透深度**：SDK runtime 层 → Cline 应用层 → base prompt 模板内部

### 2.1 System Prompt 的三层结构

Cline 的 system prompt 由三个独立机制叠加而成：

```
┌─────────────────────────────────────────────┐
│ 1. Base System Prompt (模板 + 占位符替换)     │
│    sdk/packages/shared/src/prompt/system.ts  │
│    含角色定义 / 通用指引 / Remember 段 /      │
│    {{CLINE_RULES}} / {{CLINE_METADATA}}      │
├─────────────────────────────────────────────┤
│ 2. registerRule 注册的规则 (append 在 base 后)│
│    sdk/packages/core/src/runtime/safety/     │
│    rules.ts: mergeSystemPromptRules()        │
│    格式: # Rules → ## rule-name → content    │
├─────────────────────────────────────────────┤
│ 3. registerMessageBuilder (每次 turn 执行)    │
│    作用于整个 Message[]，不限于 system prompt │
└─────────────────────────────────────────────┘
```

### 2.2 Base Prompt 内部分层

`DEFAULT_CLINE_SYSTEM_PROMPT` 是一个**单体模板字符串**（`system.ts:3-62`），9 个 section 从顶到底：

| # | Section | ~字符数 | 说明 |
|---|---------|--------|------|
| 1 | 角色定义 | ~250 | "You are Cline, an AI coding agent..." |
| 2 | 通用指引 | ~400 | "Always gather all necessary context..." |
| 3 | 环境信息 | ~150 | `<env>` 块：Platform / Date / IDE / CWD |
| 4 | Remember 段 | ~900 | 8 条 "Always/Do not" 规则 |
| 5 | 工具调用指引 | ~400 | 并行工具调用、batch 模式 |
| 6 | 任务完成指引 | ~200 | "When you have completed the task..." |
| 7 | 简单问题指引 | ~80 | "If user asked a simple question..." |
| 8 | `{{CLINE_RULES}}` | 0~∞ | 占位符 |
| 9 | `{{CLINE_METADATA}}` | 0~∞ | 占位符 |

**关键发现**：base prompt 仅 ~600 token（VS Code）/ ~850 token（CLI）。占 context window 极小比例。

> **证据**：cline-plus 仓库 `docs/decisions/investigation/investigation-note-cline-prompt-layering-round2.md` Task G + Task I

### 2.3 registerRule 注入机制

**注入点**：`session-runtime-orchestrator.ts:657-666` 的 `composeSystemPrompt()` 方法

**注入逻辑**：`mergeSystemPromptRules(base, rules)` 纯字符串拼接：

```typescript
function mergeSystemPromptRules(systemPrompt, rules) {
    const base = systemPrompt.trim();
    const additional = rules.map(r => r.trim()).filter(Boolean).join("\n\n");
    if (base && additional) return `${base}\n\n${additional}`;
    return base || additional;
}
```

**关键结论**：

| 问题 | 结论 |
|------|------|
| registerRule 被覆盖吗？ | ❌ 不被覆盖——纯 append |
| 有长度截断吗？ | ❌ 无——由 API 层 context window 兜底 |
| content 支持动态求值吗？ | ⚠️ 支持 lazy function，但**只在 session 启动时求值一次** |
| 同名 rule 会怎样？ | 后者静默覆盖前者 |
| Rule 有优先级吗？ | ❌ 按 name 字母序排列，无 priority/weight |

**求值一次的含义**：`registerRule` 的 `content()` 函数在 session 启动时求值一次，运行时**永不重新求值**。这意味着：
- ✅ 适合静态资产（constitution / handoff / snapshot——启动时读一次正是它们的语义）
- ❌ 不适合动态 per-turn 内容（如 per-turn 变化的 loop guard warning）

> **证据**：cline-plus 仓库 `docs/decisions/investigation/investigation-note-cline-prompt-layering.md` + `investigation-note-cline-prompt-layering-round2.md` Task F

### 2.4 Rule 失效 6 场景

"Rule 注入了但不生效"有 6 种根因，按排查顺序排列：

| # | 场景 | 触发条件 | 表现 | 可排查性 |
|---|------|----------|------|----------|
| ① | 显式禁用 | frontmatter `disabled: true` | rule 不出现 | ✅ 明确 |
| ② | 解析失败 | YAML 格式错误、空 body、缺 name | rule 静默消失 | ⚠️ 无提示 |
| ③ | 目录未加载 | rule 文件不在 watcher 监控目录 | rule 不存在 | ⚠️ 需检查目录 |
| ④ | 同名覆盖 | 多目录同名 rule，后者覆盖前者 | 静默替换 | ⚠️ 需检查加载顺序 |
| ⑤ | Prompt 过长 | rule 总量超出 context window | API 层截断 | ❌ cline 无主动管理 |
| ⑥ | **位置+服从惯性** | registerRule 在 base prompt 末尾，模型对前半部分有更强服从倾向 | rule 技术上注入成功但模型不服从 | ⚠️ 需行为指令前缀 |

**场景 ⑥ 是本框架最重要的发现**，也是协同前缀实验的起点。

**诊断决策树**：

```
"rule 不生效"
  │
  ├─ rule 是否出现在 system prompt 中?
  │    ├─ 否 → 检查: disabled? 解析失败? 目录未加载? 同名覆盖?
  │    └─ 是 ↓
  │
  ├─ rule 是否与 base prompt 指令冲突?
  │    ├─ 否 → rule 应生效，检查是否是模型能力问题
  │    └─ 是 ↓
  │
  ├─ 冲突类型?
  │    ├─ 指令方向相反 ("DO X" vs "Always do Y")
  │    │    → 根因: 位置 + 服从惯性
  │    │    → 解法: 用更强措辞 + 行为指令前缀（见 §3）
  │    │
  │    ├─ 指令范围重叠 (rule 重复 base prompt 已有内容)
  │    │    → 根因: 冗余，模型忽略重复
  │    │    → 解法: 删除冗余 rule
  │    │
  │    └─ 指令优先级不明 (rule 和 base prompt 都是 "should" 级)
  │         → 根因: 语气平级，模型自行判断
  │         → 解法: rule 用 MUST/SHALL 提升优先级
  │
  └─ 以上都不是 → 检查: 模型能力不足? token 预算耗尽? API 截断?
```

> **证据**：cline-plus 仓库 `docs/decisions/investigation/investigation-note-cline-prompt-layering-round2.md` Task J

### 2.5 base prompt 的强约束力来源

base prompt section 4 "Remember" 段用 "Always/Do not" 措辞（非 MUST/SHALL），但其强约束力不来自措辞本身，而来自：

1. **位置靠前**——在 system prompt 前半部分，与角色定义紧密相邻
2. **重复强化**——8 条规则围绕 "Always/Do not" 形成一致性语气
3. **训练偏好**——模型在训练中学到"遵循 system prompt 前半部分的指令"

这意味着 registerRule 注入的内容（在 base prompt 末尾）天然处于**服从劣势位**。当 rule 的指令与 base prompt 方向不一致时（如 "DO NOT RE-READ FILES" vs base prompt 的 "Always gather all necessary context"），模型倾向于遵循位置靠前的指令。

**这个发现直接催生了协同前缀实验**——用行为指令前缀对抗位置劣势。

---

## 3. 协同前缀效应

> **状态**：✅ Verified（A/B 测试 Round 1 n=3 + Round 2 n=10）
>
> **模型**：deepseek-v4-flash (DeepSeek, 128k context)
>
> **这是本框架最有价值的实验产出**——揭示了 LLM prompt 服从的非线性现象。

### 3.1 实验动机

第二轮源码探查结论为"registerRule 在 base prompt 末尾，模型对前半部分有位置+服从惯性"。由此产生两个假说：

| 假说 | 推导 | 解法 |
|------|------|------|
| **位置假说** | 末尾 = 服从洼地，搬到前面就好 | 把 constitution 从 section 10 搬到 section 8 |
| **冲突假说** | rule 与 base prompt 指令方向相反 | 消除冲突 |

外部评审提出关键质疑：

1. **位置假说最脆**——LLM 注意力分布有 primacy + recency 双峰，section 10 未必是"最差"
2. **"DO NOT RE-READ" 前缀有效本身就是反证**——如果 section 10 真是服从洼地，一个前缀不该救得回来
3. **真实机制可能是"冲突+歧义"**——建议 A/B 差分测试

### 3.2 Round 1：位置假说证伪

**变量**：

| 变量 | 变体 A | 变体 B |
|------|--------|--------|
| `.clinerules` 读文件表述 | 硬指令（"必须读 constitution.md"）| 软条件（"若未出现注入段，手动读"）|

| 变量 | +prefix | -prefix |
|------|---------|---------|
| registerRule 前缀 | "DO NOT RE-READ FILES" + 5 条行为指令 | 无行为指令 |

**结果**（n=3，复杂问题"What are all the governance rules for this project?"）：

| 变体 | 工具调用次数 |
|------|------------|
| A-prefix | [2, 0, 2] = 4 |
| B-prefix | [1, 2, 1] = 4 |
| B+prefix | [0, 0, 1] = 1 |

**结论**：

1. ❌ **位置假说证伪**——A vs B 差异在 ±1 次噪声内，搬位置无服从收益
2. ✅ **前缀是唯一杠杆**——B-prefix → B+prefix 从 4 降到 1，方向一致

> **统计局限声明**：n=3 不足以区分 A vs B。唯一被数据稳稳支撑的结论是"前缀有效"。

### 3.3 Round 2：前缀分解实验

**问题**：前缀的哪一部分在起作用？是"DO NOT RE-READ"这个否定祈使，还是"内容已在下方"这个事实陈述？

**三个变体**（n=10，复杂问题）：

| 变体 | 前缀内容 | 组件 |
|------|---------|------|
| R2-A1（事实陈述） | "The following project context is auto-loaded by the governance plugin." | 事实陈述 only |
| R2-A2（否定祈使） | "DO NOT RE-READ FILES. DO NOT call readFile/search/run_commands." | 否定祈使 only |
| R2-A3（当前=生产） | 事实陈述 + 5 条行为指令 + 否定祈使 | **两者** |

**结果**：

| 变体 | n | 有工具调用的运行 | 冗余读率 |
|------|---|----------------|---------|
| R2-A1（事实 only） | 10 | 10 (100%) | 100% |
| R2-A2（祈使 only） | 8 | 8 (100%) | 100% |
| R2-A3（两者组合） | 10 | 2 (20%) | 10% |

### 3.4 核心发现：协同效应，非主效应

> **Neither alone does the work. The combination creates a synergistic effect.**

| 组件 | 单独效果 | 合并效果 |
|------|---------|---------|
| 事实陈述（"内容已自动加载"）| 100% 工具调用率 | — |
| 否定祈使（"DO NOT RE-READ"）| 100% 工具调用率 | — |
| **两者组合** | — | **20% 工具调用率** |

这不是加性效应（100% + 100% → 50%），而是**相变效应**（100% + 100% → 20%）。两个组件单独完全无效，组合后效果跃升。

**机制假说**：

- 事实陈述 alone → 模型知道内容在那里，但不确定是否"够用" → 仍验证
- 否定祈使 alone → 模型被禁止读，但不信任内容完整性 → 仍读（违反指令）
- **两者组合** → 模型知道内容在那里 + 被明确告知不要验证 → 信任建立，停止读取

**启示**：LLM 的指令服从不是线性的。两个看似冗余的组件（"内容在这里" + "不要重新读"）在认知层面产生了非线性叠加——前者消除不确定性，后者抑制验证冲动，两者同时才建立足够信任。

### 3.5 冗余/合理标签结论

R2-A3 的 2 次有工具调用的运行进一步分析：

| Run | 冗余读 | 合理读 | 类型 |
|-----|--------|--------|------|
| Run 2 | 3 | 6 | 混合——读了注入段内的 constitution/rules（冗余），也读了注入段外的 examples/hooks（合理）|
| Run 10 | 0 | 0 | 工具调用是 search（非 file read），路径未被捕获 |

**结论**：
- 冗余读率 = 1/10 = **10%**
- Run 2 的 6 次合理读表明模型确实在读注入段外的内容——这些是**合理验证**
- **10% 是合理下限，不应继续往 0 压**

### 3.6 当前生产配置

经 n=10 验证的最优配置已部署：

**`.clinerules`（条件语言）**：

```markdown
## 新会话首动作

若下方 System Prompt 中出现 "GOVERNANCE SESSION CONTEXT" 注入段
（governance plugin 启用时自动注入，含 Constitution / Rules / Handoff / Snapshot / Git Status），
直接使用其中内容，无需手动读取上述文件。

若未出现注入段（plugin 未启用），手动读 `HANDOFF.md` 获取会话上下文。
```

**registerRule 前缀（事实陈述 + 否定祈使，不可拆分）**：

```typescript
const md: string[] = [
  "# GOVERNANCE SESSION CONTEXT (AUTO-INJECTED — DO NOT RE-READ FILES)",
  "",
  "The following project context is auto-loaded by the governance plugin.",
  "When answering questions about project state, constitution, rules, handoff, git status, or snapshots:",
  "1. USE the information below DIRECTLY — do NOT call readFile/search/run_commands to re-read these files",
  "2. If the user asks about constitution rules, quote from the 'Core Constitution' section below",
  "3. If the user asks about git status, quote from the 'Git Status' section below",
  "4. If the user asks about handoff or pending todos, quote from the 'Handoff' section below",
  "5. Only call tools if the requested information is NOT in the context below",
  "",
  "--- CONTEXT START ---",
  "",
];
```

> ⚠️ **不可拆分警告**：R2-A1 和 R2-A2 已证明单独任一组件 100% 无效。不要为了"简化"而移除任何一个。

### 3.7 对框架设计的影响

| 原排序 | 数据裁决 | 新排序 |
|--------|----------|--------|
| P0: 胖入口搬位置 | ❌ 位置假说证伪 | 降为 P2（纯工程改进）|
| P2: 前缀强化 | ✅ 唯一被验证有效 | **升为 P0** |

**不做的事**：
- ❌ 不做胖入口——位置假说不成立
- ❌ 不做路径检测——不需要
- ❌ 不做指纹幂等去重——前提不成立
- ❌ 不在扩大样本前继续把 10% 往 0 压——可能正在优化一个已经接近合理下限的指标

> **证据**：cline-plus 仓库 `docs/decisions/investigation/ab-test-clinerules-conflict.md` §四-§七

---

## 4. 为什么不改源码

> **状态**：✅ 评估完成（3 方案 + 负面影响分析）
>
> **结论**：不建议修改源码。当前 plugin 层方案已达合理下限，源码修改的收益不存在且副作用不可控。

### 4.1 修改方案

基于 §2 的源码探查，有三种修改路径：

**方案 A：修改 Base Prompt 措辞**（最小改动）

在 `system.ts:7-10` 的 "Always gather all necessary context" 后面加例外子句。改动 ~3 行。

**方案 B：修改 `mergeSystemPromptRules` 插入位置**

将 `rules.ts:95-106` 的纯 append 改为在 base prompt 指定位置插入。改动 ~10 行。

**方案 C：新增 `{{INJECTED_CONTEXT}}` 占位符**（最彻底）

在 base prompt 模板中新增占位符，修改 `buildClineSystemPrompt()` 签名和两条调用路径。改动 ~50-80 行，涉及 4-5 个文件。

### 4.2 负面影响分析

#### 🔴 Fork 维护成本（所有方案共同问题）

Cline 是活跃开源项目，base prompt 是高频变更区域。每次 upstream 更新 `system.ts`，patch 可能冲突。一旦 patch 失效，所有依赖注入服从的 plugin 行为退化——A/B 测试显示没有前缀时工具调用率是 **100%**。

#### 🔴 全局副作用

Base prompt 是**所有用户、所有插件、所有模型**共享的。修改它的影响面：
- 没有 plugin 注入上下文的普通会话：例外子句变成无用噪音
- 其他 plugin 的 registerRule 内容：可能被错误地当作"auto-injected"而跳过验证
- 模型变更：服从惯性是 deepseek-v4-flash 的特性，换模型可能不需要这个 workaround

#### 🟡 位置假说已被证伪（方案 B 前提不成立）

A/B 测试 Round 1 的核心结论：**位置假说证伪**。把 registerRule 从 section 10 搬到 section 4，服从度不会提升。方案 B 改了位置但不改措辞，预期收益为零。

#### 🟡 协同效应的脆弱性

§3 的核心发现是**相变效应**：事实陈述单独 100% 无效，否定祈使单独 100% 无效，组合后 20%。源码修改（方案 A）本质上是把"事实陈述"硬编码进 base prompt，但事实陈述**单独完全无效**。如果源码修改后 plugin 不再带"否定祈使"前缀，工具调用率仍然是 100%。

> 源码修改**不能替代**当前 plugin 前缀，最多只能减少前缀中事实陈述部分的内容量。节省约 2 行代码，但引入 fork 维护成本。

### 4.3 综合判断

| 维度 | 当前 Plugin 方案 | 源码修改方案 |
|------|-----------------|-------------|
| 冗余读率 | 10%（合理下限）| 预期不优于 10% |
| 改动成本 | 0（已完成）| 0.5-1 天 |
| 维护成本 | 低 | 高（fork + rebase）|
| 副作用面 | 仅 governance plugin | 全局所有用户/插件/模型 |
| 可逆性 | 高 | 低 |

**如果未来需要从源头解决**，前置条件应该是：
1. 先在 Claude/GPT 等多模型上验证前缀策略的通用性
2. 确认问题不是 deepseek-v4-flash 特有的
3. 向上游提 PR 而非维护 fork

---

## 5. 经验教训

> 从三周开发中提炼的 8 条方法论教训。每条都有具体触发事件和沉淀产出。

### L1 契约优先：读类型定义先于写代码

**触发事件**：v0.6.0 的 4 处契约违反（toolName=undefined / content 类型不匹配 / workspacePath 字段名错误 / registerRule id vs name 混淆），全部靠用户多轮排查才定位。

**教训**：API 参数结构不能假设，必须读类型定义。静默失败比报错更危险——hook 不触发 / 字段 undefined 都不会报错，只是"什么都不发生"。

### L2 死代码也要修

**触发事件**：F1 bug（compaction.ts 的 buildCompactionSummary content 为 string 类型）当前未被注入，但与 A1 bug 同模式。如果只修 A1 不修 F1，未来某个改动激活 F1 路径时会再次触发 codec crash。

**教训**：同模式 bug 必须预防性修复，不只修当前触发路径。

### L3 workaround ≠ 环境可用

**触发事件**：V6 路径（afterTool + messageBuilder）绕开了 codec bug，但不可抗力声明未解除。

**教训**：workaround 期间实测结果仅证明"避开 bug 的路径可用"，不证明"环境完整可用"。不可抗力声明的解除需要上游 PR 合并 + release tag + 回归实测。

### L4 单源声明必须降级

**触发事件**：PR #5246 单源声明（未来日期 2026-07-14）被主 agent 直接采信为 Verified，后排除为幻觉。

**教训**：单一来源的声明必须降级为 Hypothesis，需独立交叉验证后才能升级。日期异常（未来日期）是幻觉强信号。

### L5 命题三翻触发流程审查

**触发事件**：VS Code Plugin 支持命题三翻（不支持 → 支持 → 运行时层不支持），每次翻转都基于不同证据层。

**教训**：核心命题翻转 ≥2 次须重新验证证据链，而非连续覆盖。检查是否在同一个证据类型里打转（违反 Evidence Collapse）、是否跳级。

### L6 minified 代码只用于定位

**触发事件**：codec bug 调查用 minified bundle 锚点定位 `Nd` 函数 `n.content.map(eK)`，但语义结论（设计意图、目录结构）必须读 unminified 源码确认。

**教训**：minified 可用于定位（入口 / 调用链 / 字符串），不可单独用于语义结论。

### L7 穿透边界判据

**触发事件**：第一轮源码探查停在 SDK runtime 层（`composeSystemPrompt()`），回答了"registerRule 注入在 base 之后"，但没穿透到 base prompt 内部如何拼装。导致"rule 不生效"根因分析不完整。

**教训**：源码探查必须穿透分层边界：
- 涉及"某值从哪里来" → 不可停在值的消费方，必须穿透到值的构造方
- 涉及"某机制为什么不生效" → 不可只看机制本身，必须穿透到环境上下文
- 遇到"已构造好的字符串/对象"作为输入 → 不可当作黑盒

### L8 源码探查成果强制固化

**触发事件**：多次会话中重复 Grep 同一源码位置、重复问同一契约问题。

**教训**：源码探查完成后必须回流到文档，附源码文件:行号定位 + Verified 标记 + 关键代码片段 + 来源链接。避免后续会话遇到相同问题时反复读源码。

---

## 引用

以下文档均存放在 [cline-plus 模板仓库](https://github.com/zk-0808/cline-plus) 的 `docs/` 目录下：

- `docs/decisions/investigation/investigation-note-cline-prompt-layering.md` — 第一轮源码探查
- `docs/decisions/investigation/investigation-note-cline-prompt-layering-round2.md` — 第二轮源码探查
- `docs/decisions/investigation/ab-test-clinerules-conflict.md` — A/B 测试报告（Round 1 + Round 2）
- `docs/decisions/adr/ADR-007-snapshot-registerRule-static-injection.md` — registerRule 静态注入决策
- `docs/decisions/delivery-framework-design.md` — 框架目录契约
- `docs/plugin/development-summary.md` — context-snapshot 插件开发总结

---

*本文档基于 Cline CLI 3.0.37 + SDK v0.0.56 源码探查 + deepseek-v4-flash 模型实测。跨模型通用性待验证。*
