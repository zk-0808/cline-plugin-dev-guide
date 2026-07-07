# 实践开发指南

> **生命周期**：永久保留——开发者操作手册，随版本更新。
>
> **定位**：回答"怎么写代码"——Cline 插件平台 API、框架目录契约、Capability 开发 7 步、诊断方法。读完这份文档，不用重新读 Cline 源码就能上手开发。
>
> **前置阅读**：[设计思考与实验发现](design-thinking.md)——理解"为什么这么设计"后再读本文档。
>
> **框架文件**：本文引用的 `.governance/` 目录结构和脚本均在 [cline-plus 模板仓库](https://github.com/zk-0808/cline-plus) 中。

---

## 目录

1. [Cline 插件平台](#1-cline-插件平台)
2. [框架架构](#2-框架架构)
3. [配置系统](#3-配置系统)
4. [Capability 开发](#4-capability-开发)
5. [诊断手册](#5-诊断手册)
6. [已知局限与路线图](#6-已知局限与路线图)

---

## 1. Cline 插件平台

> **证据来源**：Cline SDK 源码探查（unminified `.ts`）+ CLI 3.0.37 实测。本节是 Cline 平台通用知识，不特定于 governance 框架。逐层函数级细节见 [Architecture Atlas](cline-plugin-architecture-atlas.md)。

### 1.1 插件生命周期 7 层

每个 Cline 插件从发现到运行经过 7 层，bug 出在任何一层都会中断链路：

```
Layer 1: Discovery     →  paths.ts                    在磁盘上找插件文件
Layer 2: Install       →  plugin-install.ts           下载/克隆/暂存
Layer 3: Load          →  plugin-loader.ts            进程内导入 + setup
Layer 4: Module Import →  plugin-module-import.ts     jiti 实时 TS→JS 转译
Layer 5: Sandbox       →  plugin-sandbox-bootstrap.ts 子进程入口
Layer 6: Runtime       →  subprocess-sandbox.ts       child_process IPC
Layer 7: Registry      →  plugin-sandbox.ts (host)    注册 builders/tools/hooks
```

**关键事实**：

- sandbox 是 **Node.js 子进程**，不是文件系统沙箱。`fs.writeFileSync()` 直接写宿主文件系统
- TypeScript 通过 [jiti](https://github.com/unjs/jiti) 实时转译，无需编译步骤
- `console.log()` 在 VS Code 中**不出现**在 DevTools——用 file marker 或 `ctx.logger.log()` 调试

### 1.2 插件骨架

```typescript
import type { AgentPlugin } from "@cline/core";
import { createTool } from "@cline/core";

const myPlugin: AgentPlugin = {
  name: "my-plugin",
  manifest: {
    capabilities: ["tools", "hooks"],  // 必须显式声明
  },
  setup(api, ctx) {
    api.registerTool(createTool({ /* ... */ }));
  },
  hooks: {
    beforeRun({ snapshot }) { /* ... */ },
    afterRun({ result }) { /* ... */ },
  },
};

export default myPlugin;
```

### 1.3 扩展点速查

| Capability | API 方法 | 入口 | 说明 |
|------------|---------|------|------|
| `tools` | `api.registerTool()` | setup() | async execute |
| `commands` | `api.registerCommand()` | setup() | sync/async |
| `rules` | `api.registerRule()` | setup() | content 求值一次，session 启动时 |
| `messageBuilders` | `api.registerMessageBuilder()` | setup() | **sync** build，每次 turn 调用 |
| `providers` | `api.registerProvider()` | setup() | — |
| `automationEvents` | `api.registerAutomationEventType()` | setup() | — |
| `hooks` | plugin.hooks 字段 | **不在** setup 里 | 生命周期回调 |

### 1.4 Hook 生命周期

```
beforeRun     → 运行循环开始前（不能注入 messages）
  beforeModel   → 每次模型请求前（能替换整个 messages）
  afterModel    → 每次模型响应后、工具执行前
  beforeTool    → 每次工具执行前（可返回 { skip: true } 拦截）
  afterTool     → 每次工具执行后
afterRun      → 运行循环结束后（成功/失败/中断都触发）
onEvent       → 任何 AgentRuntimeEvent 触发
```

**Hook 契约表**（from `@cline/shared/dist/agent.d.ts` L238-248）：

| Hook | Context 类型 | 返回类型 | 能注入 messages? |
|------|-------------|---------|-----------------|
| `beforeRun` | `{ snapshot }` | `{ stop?, reason? }` | ❌ 不能 |
| `afterRun` | `{ snapshot, result }` | `void` | ❌ |
| `beforeModel` | `{ snapshot, request }` | `{ stop?, reason?, messages?, tools?, options? }` | ✅ 能 |
| `afterModel` | `{ snapshot, assistantMessage, finishReason }` | `{ stop?, reason? }` | ❌ |
| `beforeTool` | `{ snapshot, tool, toolCall, input }` | `{ skip?, stop?, reason?, input?, policy? }` | N/A |
| `afterTool` | `{ snapshot, tool, toolCall, input, result, ... }` | `{ stop?, reason?, result? }` | N/A |
| `onEvent` | `AgentRuntimeEvent` | `void` | ❌ |

### 1.5 registerRule vs registerMessageBuilder

| 维度 | `registerRule` | `registerMessageBuilder` |
|------|----------------|------------------------|
| 注入位置 | system prompt 字符串 | 整个 Message[] 数组 |
| 执行时机 | session 启动（composeSystemPrompt） | 每次 model request 前 |
| 执行频率 | 1 次 / session | N 次 / session |
| 求值方式 | content() 求值一次 | build() 每次调用 |
| 服从度 | ✅ 模型直接引用 | ⚠️ 被 cline agent 训练偏好压过 |
| 适用场景 | **静态资产**（constitution/handoff/snapshot） | 动态 per-turn 内容 |

> ⚠️ **关键发现**：messageBuilder 注入的 system 消息被 cline agent 训练偏好压过，模型忽略注入内容。**静态内容必须走 registerRule**。详见 [设计思考 §2](design-thinking.md#2-system-prompt-分层注入机制)。

### 1.6 关键约束

| 约束 | 原因 | 影响 |
|------|------|------|
| VS Code Extension 4.0.x 不支持 plugin | `plugin-sandbox-bootstrap.js` 缺失 | 只能用 CLI |
| `setup()` 必须同步且快 | 运行在第一次 LLM 调用前 | async 初始化会延迟 agent |
| 所有 tool 必须在 `setup()` 注册 | 不能在 lifecycle hook 里注册 | tool 必须在第一次 iteration 前可用 |
| hook 返回的 messages 必须用 `ContentBlock[]` 格式 | codec bug——string content 会导致 `n.content.map()` 崩溃 | 禁止 string content |
| `beforeTool` 必须同步返回 `{ skip: true, reason }` | runtime 期望同步返回 | PreToolUse 类逻辑必须用同步 API |
| CLI 3.0.37 重命名了全部工具 | 见下表 | beforeTool 过滤逻辑需覆盖新旧名 |

### 1.7 工具名变更（CLI 3.0.37）

| 旧名（≤3.0.34） | 新名（3.0.37+） | 类型 |
|----------------|----------------|------|
| `write_to_file` | `editor` | 文件创建/编辑 |
| `replace_in_file` | `editor` | 文件编辑 |
| `execute_command` | `run_commands` | 命令执行 |
| `read_file` | `readFile` | 文件读取 |
| `insert_content` | `editor` | 文件插入 |
| — | `applyPatch` | diff patch（新增）|
| — | `bash` | shell 命令（新增）|

完整 HubToolExecutorName（`hub.d.ts` L311）：
```typescript
"readFile" | "search" | "bash" | "webFetch" | "editor" | "applyPatch" | "skills" | "askQuestion" | "submit"
```

> ⚠️ **教训**：工具名是 CLI 版本相关的。plugin 代码里硬编码工具名时，必须同时覆盖新旧名。写 beforeTool/afterTool 过滤逻辑时，先 `cline -i` 跑一次看实际 `toolCall.toolName`。

### 1.8 双重 setup() 现象

CLI 3.0.34+ 每次 `cline -i` 启动时 `setup()` 被调用**两次**，间隔 300-500ms。第一条 workspace=unknown，第二条 workspace=实际路径。

**坑点**：setup() 里不要做幂等性假设——注册逻辑必须能承受双调用。`api.registerMessageBuilder()` / `api.registerTool()` / `api.registerRule()` 已验证可承受双调用。

### 1.9 调试方法

| 方法 | CLI | VS Code |
|------|-----|---------|
| `console.log()` | ✅ stdout | ❌ 被 bridge 吞掉 |
| `ctx.logger.log()` | ✅ | ✅ (Cline output channel) |
| File-based markers | ✅ | ✅ |
| DevTools Console | N/A | ❌ (plugin 在独立进程) |

**推荐**：在 `setup()` 和 `build()` 里写 marker 文件（带时间戳），不依赖 `console.log`。

```typescript
function debugMarker(msg: string) {
    try {
        const markerPath = join(state.workspacePath, ".governance", "runtime", "debug.log");
        appendFileSync(markerPath, `[${new Date().toISOString()}] ${msg}\n`);
    } catch { /* ignore */ }
}
```

### 1.10 源码定位速查

| 主题 | 关键文件 |
|------|---------|
| 插件发现 | `shared/src/storage/paths.ts` |
| 插件安装 | `core/src/services/plugin-install.ts` |
| 插件加载 | `core/src/extensions/plugin/plugin-loader.ts` |
| Sandbox 引导 | `core/src/extensions/plugin/plugin-sandbox-bootstrap.ts` |
| 模块导入 (jiti) | `core/src/extensions/plugin/plugin-module-import.ts` |
| IPC 传输 | `core/src/runtime/tools/subprocess-sandbox.ts` |
| rules 注入 | `core/src/runtime/safety/rules.ts` (mergeSystemPromptRules) |
| system prompt 构造 | `shared/src/prompt/cline.ts` (buildClineSystemPrompt) |
| base prompt 模板 | `shared/src/prompt/system.ts` (DEFAULT_CLINE_SYSTEM_PROMPT) |
| compact 执行 | `core/src/extensions/context/compaction.ts` |
| turn 准备 | `agents/src/agent-runtime.ts` (prepareTurnForModelRequest) |

> 逐层函数签名、行号、错误模式详见 [Architecture Atlas](cline-plugin-architecture-atlas.md)。

---

## 2. 框架架构

### 2.1 五层架构

```
┌──────────────────────────────────────────────────────┐
│ L1 Core    .governance/core/constitution.md          │ ≤800 token 通用宪法
├──────────────────────────────────────────────────────┤
│ L2 Rules   .governance/rules/                         │ ≤50 行薄入口（装好即生效）
├──────────────────────────────────────────────────────┤
│ L3 Cap     .governance/capabilities/                  │ pass/block/inject 三态模块
├──────────────────────────────────────────────────────┤
│ L4 Hooks   .governance/hooks/                         │ 事件驱动调用 Capability
├──────────────────────────────────────────────────────┤
│ L5 Runtime HANDOFF.md + .governance/runtime/         │ 动态状态文件
└──────────────────────────────────────────────────────┘
```

### 2.2 目录契约

| 目录 | 存什么 | 加载机制 | 可删? |
|------|--------|---------|-------|
| `.clinerules` | 薄入口，指向 `.governance/` | Cline 原生自动读取 | ❌ 加载链起点 |
| `.governance/core/` | ≤800 token 通用宪法 | registerRule 静态注入 | ❌ 框架基石 |
| `.governance/rules/` | 装好即生效的薄规则 | Cline Rules 条件加载 | ⚠️ 入口不建议删 |
| `.governance/examples/` | 参考实现包（不自动加载）| 用户手动复制 | ✅ 可删 |
| `.governance/capabilities/` | pass/block/inject 模块 | Hook 调用 | ❌ Hook 依赖 |
| `.governance/hooks/` | 事件驱动检查 | Cline Hooks 生命周期 | ⚠️ 单个可删 |
| `.governance/plugin/` | CLI 端运行时入口 | Cline CLI plugin 加载 | ⚠️ 不用 CLI 可删 |
| `HANDOFF.md` | 会话交接文件 | SessionStart hook 读取 | ⚠️ 条件式可删 |
| `.governance/runtime/` | snapshot.json + marker | Hook 写入 | ⚠️ 条件式可删 |

### 2.3 加载顺序

```
Session 启动
  ├─ 1. .clinerules 触发
  │     └─ Cline 原生机制读取根部 .clinerules
  ├─ 2. plugin setup() 执行
  │     ├─ loadConfig() 读 hooks/config.json
  │     ├─ preloadSessionContext() 同步读取:
  │     │   ├─ constitution.md
  │     │   ├─ rules/*.md
  │     │   ├─ HANDOFF.md
  │     │   ├─ snapshot.json
  │     │   └─ git status
  │     └─ registerRule({ content: () => sessionContextContent })
  ├─ 3. composeSystemPrompt() 求值 content()
  │     └─ mergeSystemPromptRules(base, rules) → append
  └─ 4. rules/ 按场景条件加载

Session 进行中
  ├─ 5. beforeTool（每次工具调用前）
  │     └─ git-checker: dirty count ≥ 阈值 → { skip: true }
  ├─ 6. messageBuilder.build()（每次 turn）
  │     └─ 保存 messages 副本（用于 compaction 检测）
  └─ 7. afterTool（每次工具调用后）
        └─ 占位（未来接入 rule-appender）

Session 压缩
  └─ 8. beforeModel（每次 model request）
        └─ 检测消息长度突变 → dispatchPreCompact → 写 snapshot.json
```

### 2.4 Plugin 入口结构

```
.governance/plugin/
├── index.ts              ← 插件入口（setup + hooks）
├── config-loader.ts      ← 读取 hooks/config.json
├── types.ts              ← PluginState / SessionContext / HooksConfig
├── package.json          ← cline 字段声明 capabilities
├── tsconfig.json
├── verify-governance.ts  ← 验证脚本
└── hooks/
    ├── session-start.ts  ← SessionStart 逻辑（当前内联在 index.ts）
    ├── pre-tool.ts       ← PreToolUse 逻辑（当前内联在 index.ts）
    ├── pre-compact.ts    ← PreCompact 逻辑（detectCompaction + dispatchPreCompact）
    └── post-tool.ts      ← PostToolUse 逻辑（当前占位）
```

### 2.5 删除矩阵

| 用户场景 | 删什么 | 保留什么 | 结果 |
|---------|--------|---------|------|
| **完整示例** | 不删 | 全部 | 照着 examples/ 改 |
| **自建规则** | rules/ 入口规则 | core/ + 自建 rules + HANDOFF.md | 骨架 + 自定义 |
| **最小安装** | examples/ + hooks/ + capabilities/ | core/ + rules/ + runtime/ | 纯骨架 |
| **不用 Hook** | hooks/ + capabilities/ + snapshot.json | core/ + rules/ + HANDOFF.md | 纯文档治理 |
| **只用宪法** | 其他全删 | core/constitution.md + .clinerules | 一页纸治理 |

---

## 3. 配置系统

### 3.1 config.json 结构

`.governance/hooks/config.json` 是配置驱动核心——声明哪些 Capability 在哪些 Hook 中启用：

```json
{
  "session-start": {
    "enabled": true,
    "capabilities": {
      "handoffProvider": {
        "enabled": true,
        "args": {
          "constitutionPath": ".governance/core/constitution.md",
          "rulesDir": ".governance/rules",
          "handoffPath": "HANDOFF.md",
          "snapshotPath": ".governance/runtime/snapshot.json"
        }
      },
      "gitChecker": {
        "enabled": true,
        "args": {
          "threshold": 5,
          "excludePatterns": ["node_modules/", "dist/", ".git"]
        }
      }
    }
  },
  "pre-tool": {
    "enabled": true,
    "skipTools": ["readFile", "search", "webFetch"],
    "capabilities": {
      "gitChecker": {
        "enabled": true,
        "args": {
          "threshold": 5,
          "excludePatterns": ["node_modules/", "dist/", ".git"]
        }
      }
    }
  },
  "pre-compact": {
    "enabled": true,
    "capabilities": {
      "snapshotWriter": {
        "enabled": true,
        "args": {
          "snapshotPath": ".governance/runtime/snapshot.json"
        }
      }
    }
  },
  "post-tool": {
    "enabled": false,
    "capabilities": {}
  }
}
```

### 3.2 配置规则

- `args` 字段名必须与 Capability `types.ts` 中的定义完全一致
- 每个新 Capability 需要 `enabled: true` 才会被加载
- 如果 Capability 在多个 Hook 中使用，需要在每个 Hook 节点下分别配置
- `skipTools` 是 PreToolUse 专有字段——白名单内的工具跳过检查
- `args` 中的路径是相对于 workspace root 的

### 3.3 项目可调参数

在 `.governance/core/constitution.md` 底部：

| 参数 | 默认值 | 含义 |
|------|--------|------|
| `independent_evidence_count` | 2 | 关键结论独立证据类型最小数 |
| `uncommitted_file_threshold` | 5 | handoff 触发器 b 文件堆积阈值 |
| `evidence_expiry_days` | 14 | 结论时效性过期天数 |

这些参数在 `config.json` 的 `args` 中引用，改取值不改判定动作。

---

## 4. Capability 开发

### 4.1 前置概念

- **Capability** = 表达"意图"的模块，返回 `pass | block | inject`
- **Hook** = 执行"动作"的运行时入口，调用 Capability 获取意图后执行
- **正交原则**：Capability 只判断，Hook 只执行。同一 Capability 可被多 Hook 复用

### 4.2 三态语义

| intent | 含义 | 调用方动作 | 适用 Hook |
|--------|------|-----------|----------|
| `pass` | 不干预 | 继续 | 所有 |
| `block` | 阻断 | 取消工具调用，附 reason | PreToolUse |
| `inject` | 注入上下文 | additionalContext 注入 | SessionStart / PreToolUse / PreCompact |

### 4.3 共用类型

```typescript
interface SessionContext {
  cwd: string;
  gitBranch?: string;
  gitDirtyCount: number;
  sessionId: string;
  startedAt: string;
  loadedRules: string[];
  compactCount: number;
  recentDecisions: DecisionRef[];
  pendingTodos: TodoRef[];
}

interface HookEvent {
  type: "SessionStart" | "PreToolUse" | "PostToolUse" | "PreCompact";
  timestamp: string;
  toolName?: string;
  toolArgs?: unknown;
  additionalContext?: string;
}
```

### 4.4 7 步开发流程

#### Step 1 — 定义职责

回答三个问题（写在产出物文件头注释中）：

1. 这个 Capability 做什么？（一句话，动词开头）
2. 它返回什么 intent？（pass / block / inject，可多选）
3. 它被哪些 Hook 调用？

**反模式**：如果一个 Capability 需要在所有 4 种 Hook 中返回不同 intent，说明职责太宽，应该拆分。

#### Step 2 — 定义接口 (`types.ts`)

```typescript
// types.ts — MyCapability 类型定义
export interface MyCapInput {
  ctx: SessionContext;
  event: HookEvent;
  args: {
    threshold: number;
    path: string;
  };
}

export interface MyCapResult {
  intent: "pass" | "block" | "inject";
  data?: {
    reason?: string;          // intent=block 时附
    additionalContext?: string; // intent=inject 时附
  };
  metadata?: {
    error?: string;
  };
}
```

**规则**：
- `args` 中每个字段必须对应 `config.json` 中的配置项
- `data.reason` 仅在 `intent=block` 时有意义
- `data.additionalContext` 仅在 `intent=inject` 时有意义
- `metadata` 永远可选——用于诊断，不用于逻辑分支

#### Step 3 — 实现 (`index.ts`)

```typescript
// index.ts — MyCapability 实现
import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { execSync } from "node:child_process";
import type { MyCapInput, MyCapResult } from "./types.js";

export * from "./types.js";

export async function myCapability(input: MyCapInput): Promise<MyCapResult> {
  const { ctx, event, args } = input;

  try {
    // 1. 前置检查（非 git 仓库 / 文件不存在 → pass，不阻断）
    if (!existsSync(join(ctx.cwd, ".git"))) {
      return { intent: "pass" };
    }

    // 2. 核心逻辑
    const output = execSync("git status --porcelain", {
      cwd: ctx.cwd,
      encoding: "utf-8",
      timeout: 5000,
      stdio: ["pipe", "pipe", "pipe"],
    });
    const count = output.trim().split("\n").filter(l => l.length > 0).length;

    // 3. 返回 intent
    if (count >= args.threshold) {
      return {
        intent: "block",
        data: { reason: `未 commit 文件 ≥ ${args.threshold}（当前 ${count}）` },
      };
    }
    return { intent: "pass" };
  } catch {
    // 失败安全：任何异常 → pass（不阻断）
    return { intent: "pass", metadata: { error: "check failed" } };
  }
}
```

**实现规范**：

| 规范 | 要求 | 理由 |
|------|------|------|
| 零外部依赖 | 仅 `node:` 内置模块 | 插件自包含，同步不装 npm 包 |
| 失败安全 | 任何异常 → `pass` | 宁可放过，不可误杀 |
| 超时保护 | `execSync` 必须 `{ timeout: 5000 }` | 防止挂起会话 |
| 路径截断 | 文件列表 `slice(0, 20)` | 防止注入超长 |

#### Step 4 — 注册到 Plugin

在 `.governance/plugin/index.ts` 中接入：

**4a. SessionStart（同步预加载）**：

在 `preloadSessionContext()` 函数中添加同步读取逻辑。因为 `registerRule.content()` 必须同步返回，SessionStart 类 Capability 在这里是内联同步实现。

```typescript
// 在 preloadSessionContext() 中
if (config.capabilities.myNewCap?.enabled) {
  try {
    const result = mySyncLogic(workspacePath, config.capabilities.myNewCap.args);
    parts.push(result);
  } catch (err) {
    errors.push(`myNewCap: ${err}`);
  }
}
```

**4b. PreToolUse（`beforeTool` hook）**：

```typescript
hooks: {
  beforeTool(context: any) {
    // ... 现有 git-checker 逻辑 ...
    
    // 新增 Capability
    if (preToolConfig.capabilities.myNewCap?.enabled) {
      // 必须同步返回 { skip: true, reason }
      const result = mySyncCheck(state.workspacePath);
      if (result.shouldBlock) {
        return { skip: true, reason: result.reason };
      }
    }
    
    return undefined;
  },
}
```

> ⚠️ `beforeTool` 必须**同步返回**。不能用 `await`。PreToolUse 类 Capability 的逻辑必须用同步 API。

**4c. PreCompact（`beforeModel` hook）**：

```typescript
hooks: {
  beforeModel(context: any) {
    // 检测 compaction
    if (detectCompaction(state.lastFullMessages, currentMessages)) {
      // 可以异步
      dispatchPreCompact(sessionCtx, config, /* ... */)
        .then(result => { /* ... */ })
        .catch(err => { /* ... */ });
    }
    return undefined; // 不修改 messages（codec bug 规避）
  },
}
```

**4d. PostToolUse（`afterTool` hook）**：

```typescript
hooks: {
  afterTool(_context: any) {
    const postToolConfig = state.config["post-tool"];
    if (!postToolConfig?.enabled) return undefined;
    // 新增 Capability 逻辑
    return undefined;
  },
}
```

#### Step 5 — 配置 (`hooks/config.json`)

在对应 Hook 节点下添加：

```json
{
  "pre-tool": {
    "enabled": true,
    "capabilities": {
      "myNewCap": {
        "enabled": true,
        "args": {
          "threshold": 10,
          "path": ".governance/some-file.md"
        }
      }
    }
  }
}
```

#### Step 6 — 测试

**6a. 单元测试**：

```typescript
// test.ts — 手动测试脚本
// 运行: npx tsx capabilities/my-cap/test.ts

import { myCapability } from "./index.js";

// Case 1: 正常路径
const result1 = await myCapability({
  ctx: { cwd: process.cwd(), gitDirtyCount: 0, sessionId: "test", startedAt: new Date().toISOString(), loadedRules: [], compactCount: 0, recentDecisions: [], pendingTodos: [] },
  event: { type: "PreToolUse", timestamp: new Date().toISOString() },
  args: { threshold: 5, path: "test.md" },
});
console.assert(result1.intent === "pass", "Case 1 should pass");

// Case 2: 阈值触发
// Case 3: 文件不存在 → pass (不阻断)
// Case 4: 非 git 仓库 → pass
```

**三段式验证模板**（推荐用于 🟡 B / 🔴 C 档验证）：

```
Test 1: 核心功能（happy path）
Test 2: 辅助功能（git/tool 状态）
Test 3: 降级场景（非 git / 空目录 / 边界值）
+ Summary + exit code（CI 可集成）
```

**6b. CLI 集成测试**：

1. 运行 `scripts/sync-governance-plugin.ps1` 同步到 CLI 发现路径
2. 启动 `cline -i`
3. 检查 `plugin-loaded.marker` 是否更新
4. 验证 Capability 的预期行为（block 是否生效、inject 是否注入）

#### Step 7 — 文档更新

1. 更新 `capabilities/README.md`：职责、接口、算法、失败模式
2. 更新复用矩阵：标记新 Capability 在哪些 Hook 中使用
3. 更新实现状态表
4. 更新 `docs/handoff.md`

### 4.5 代码骨架

#### registerRule 骨架（静态资产注入）

```typescript
setup(api, ctx) {
  const workspacePath = ctx.workspaceInfo.rootPath;  // 闭包捕获

  // 预加载（I/O 在 setup 完成，content 只读）
  let contentA = "";
  try { contentA = readFileSync(join(workspacePath, "some-asset.md"), "utf8"); }
  catch (e) { console.error(`preload failed: ${e}`); }

  // 双 id 独立降级
  api.registerRule({ id: "governance:asset-a", content: () => contentA });
}
```

**关键约束**：
- `content()` 是纯函数——只读预加载 state，禁止 I/O
- `id` 唯一——用 namespace 前缀（如 `governance:`）
- 求值一次——只能用于静态资产

#### registerMessageBuilder 骨架（动态 per-turn）

```typescript
const builder: AgentExtensionMessageBuilder = {
  id: "my-builder",
  build(ctx) {
    // ⚠️ content 必须是 ContentBlock[]，不能是 string
    return [{
      role: "user",
      content: [{ type: "text", text: "injected per-turn context" }],
    }];
  },
};

setup(api, ctx) {
  api.registerMessageBuilder(builder);
}
```

> ⚠️ **服从度不足**——messageBuilder 注入被 cline agent 训练偏好压过。静态内容优先走 registerRule。

#### setup() 闭包捕获 workspacePath

```typescript
setup(api, ctx) {
  // ✅ 正确：从 PluginSetupContext 闭包捕获
  const workspacePath = ctx.workspaceInfo.rootPath;

  // ❌ 错误 1：从 beforeRun context 拿（undefined！）
  // ❌ 错误 2：硬编码绝对路径（不可移植）
}
```

> `AgentRunLifecycleContext` 只有 `snapshot`，无 `workspacePath`。hook 运行时拿不到，必须 setup 时闭包捕获。

### 4.6 插件同步

每次修改 `.governance/plugin/` 或 `.governance/capabilities/` 的代码后：

```powershell
# Windows
powershell -ExecutionPolicy Bypass -File scripts\sync-governance-plugin.ps1

# macOS/Linux
bash scripts/sync-governance-plugin.sh
```

> 以上脚本在 [cline-plus 模板仓库](https://github.com/zk-0808/cline-plus) 的 `scripts/` 目录中。

**为什么必须同步**：Cline CLI 只扫描 `~/.cline/plugins/installed/local/`，不扫描项目级 `.cline/plugins/`。

**双目录陷阱**：CLI 扫描 `installed/` 和 `_installed/`（junction），两个目录都必须同步。

**自包含约束**：Capability 如果依赖 `../../capabilities/` 等跨目录 import，同步后路径会断裂。同步脚本会复制整个 `capabilities/` 目录，import 路径必须改为 `../capabilities/`。

**验证同步成功**：检查目标文件的 `LastWriteTime` 和内容，不要只看 Copy-Item 无报错。

### 4.7 检查清单

完成 7 步后逐项确认：

- [ ] `types.ts` 中 `args` 字段与 `config.json` 一一对应
- [ ] `index.ts` 零外部依赖（仅 `node:` 内置模块）
- [ ] `index.ts` 所有异常路径返回 `pass`（不阻断）
- [ ] `index.ts` 中 `execSync` 有 `timeout: 5000`
- [ ] 文件列表有 `slice(0, 20)` 截断
- [ ] `plugin/index.ts` 中对应 Hook 已接入分发逻辑
- [ ] `hooks/config.json` 中 `enabled: true`
- [ ] `sync-governance-plugin.ps1` 执行成功
- [ ] CLI 集成测试通过（marker 更新 + 行为验证）
- [ ] `capabilities/README.md` 已更新
- [ ] 如有跨目录依赖，已复制到插件安装路径并修正 import 路径

### 4.8 常见陷阱

| # | 陷阱 | 症状 | 解决 |
|---|------|------|------|
| 1 | 跨目录 import 路径断裂 | 同步后插件加载失败 | import 改为 `../capabilities/` |
| 2 | beforeTool 用了 await | runtime 报错或 skip 不生效 | 必须同步返回，用 `execSync` |
| 3 | intent=block 在非 PreToolUse 中返回 | block 被忽略 | block 只在 beforeTool 有效 |
| 4 | SessionStart 用异步 API | content() 返回空 | 必须同步内联实现 |
| 5 | config.json 路径写绝对路径 | 换机器后失效 | 用 `join(ctx.cwd, args.path)` 拼接 |

---

## 5. 诊断手册

> 按症状组织，不按探查时间线。遇到问题从这里开始。

### 5.1 Plugin 不加载

**症状**：`plugin-loaded.marker` 不存在 / 模型不知道 governance 内容

**诊断流程**：

```
Plugin 不加载?
  │
  ├─ marker 文件存在吗?
  │    ├─ 否 → setup() 没执行
  │    │    ├─ 你在用 VS Code 吗? → VS Code 4.0.x 不支持 plugin（bootstrap 缺失）
  │    │    ├─ 你在用 CLI 吗? → 检查插件安装路径
  │    │    └─ 插件在 ~/.cline/plugins/installed/local/governance/ 吗?
  │    │         ├─ 否 → 运行 sync-governance-plugin.ps1
  │    │         └─ 是 → 检查 package.json 有 cline 字段
  │    │
  │    └─ 是 → setup() 执行了，问题在后面
  │
  ├─ setup() 执行了但 registerRule 没调用?
  │    → 检查 setup() 是否在 registerRule 之前抛异常
  │    → 检查 loadConfig() 是否正确读取 config.json
  │
  └─ registerRule 调用了但模型不服从?
       → 见 §5.3 Rule 不生效
```

**VS Code 不可用原因**：VS Code extension 4.0.0 的 esbuild pipeline 没有把 `plugin-sandbox-bootstrap.js` 输出为独立文件。sandbox 子进程无法启动 → 4 秒超时 → setup() 永不执行。官方文档已标注"This feature is not applicable on VSCode and JetBrains Extension for now."

> VS Code workaround 脚本见本仓库 `scripts/patch-vscode-plugin-support.ps1`。

### 5.2 setup() 执行两次

**症状**：marker 文件时间戳有两个、console.log 输出两次

**原因**：CLI 3.0.34+ 每次 `cline -i` 启动时 setup() 被调用两次，间隔 300-500ms。第一条 workspace=unknown，第二条 workspace=实际路径。

**处理**：注册逻辑必须能承受双调用。`api.registerMessageBuilder()` / `api.registerTool()` / `api.registerRule()` 已验证可承受双调用。不要在 setup 里做"只执行一次"的假设。

### 5.3 Rule 不生效

**症状**：模型不遵循注入的 rule，仍然调用工具读文件

**诊断决策树**（详见 [设计思考 §2.4](design-thinking.md#24-rule-失效-6-场景)）：

```
"rule 不生效"
  │
  ├─ rule 是否出现在 system prompt 中?
  │    ├─ 否 → 检查: disabled? 解析失败? 目录未加载? 同名覆盖?
  │    └─ 是 ↓
  │
  ├─ rule 是否与 base prompt 指令冲突?
  │    ├─ 否 → rule 应生效，检查模型能力
  │    └─ 是 ↓
  │
  ├─ 冲突类型?
  │    ├─ 指令方向相反 → 根因: 位置+服从惯性
  │    │    → 解法: 用协同前缀（事实陈述+否定祈使，不可拆分）
  │    │       详见 design-thinking.md §3
  │    │
  │    ├─ 指令范围重叠 → 删除冗余 rule
  │    │
  │    └─ 优先级不明 → 用 MUST/SHALL 提升优先级
  │
  └─ 以上都不是 → 检查: 模型能力? token 预算? API 截断?
```

**最常见的真实根因**：场景 ⑥（位置+服从惯性）。模型对 base prompt section 2 "Always gather all necessary context" 形成强服从惯性，忽略末尾的 "DO NOT RE-READ FILES"。

**解法**：使用协同前缀（事实陈述 + 否定祈使组合）。详见 [设计思考 §3.6](design-thinking.md#36-当前生产配置)。

### 5.4 Codec Bug

**症状**：`n.content.map is not a function` 崩溃

**根因**：Cline `agentMessagesToMessages` 函数无 `Array.isArray` 守卫，当 content 为 string 时 `n.content.map()` 必崩。

**两条触发路径**：

| 路径 | 触发条件 | 状态 |
|------|----------|------|
| A (MCP tool_result) | content 经 JSON.stringify 有损转换变非数组 | Hypothetical |
| B (beforeModel 注入) | beforeModel 返回 content 为 string 类型 | ✅ Verified |

**解法**：所有 hook / messageBuilder 返回的 messages 必须用 `ContentBlock[]` 格式：

```typescript
// ✅ 正确
return [{
  role: "user",
  content: [{ type: "text", text: "..." }],  // ContentBlock[]
}];

// ❌ 错误——会触发 codec bug
return [{
  role: "user",
  content: "...",  // string
}];
```

**beforeModel 返回 undefined**：如果不需要修改 messages，`beforeModel` 返回 `undefined`（不是 `null`，不是空对象）。

### 5.5 工具名不匹配

**症状**：beforeTool guard 不触发，模型成功调用了应该被拦截的工具

**原因**：CLI 3.0.37 重命名了全部工具（见 §1.7）。如果 guard 代码用旧名 `write_to_file`，但 CLI 实际调用 `editor`，guard 不匹配。

**解法**：工具名 Set 同时覆盖新旧名：

```typescript
const WRITE_TOOL_NAMES = new Set([
  // 旧名（≤3.0.34）
  "write_to_file", "replace_in_file", "execute_command",
  "insert_content", "search_and_replace",
  // 新名（3.0.37+）
  "editor", "applyPatch", "run_commands", "bash",
  "write", "edit", "multi_edit",
]);
```

**验证方法**：`cline -i` 跑一次，看实际 `toolCall.toolName`。

### 5.6 git status 超时

**症状**：git-checker 不触发，或会话卡顿

**原因**：`execSync("git status --porcelain")` 在大型仓库可能超过 5 秒

**解法**：
- `execSync` 必须 `{ timeout: 5000 }`
- 超时后 catch 返回 `pass`（不阻断）
- `excludePatterns` 排除 `node_modules/` / `dist/` 等大目录

### 5.7 CLI 集成测试

S1-S6 测试计划：

| 测试 | 验证内容 | 方法 | 状态 |
|------|---------|------|------|
| S1 | Plugin 发现 | 检查 `plugin-loaded.marker` | ✅ PASS |
| S2 | Rule 注入 | 问模型 "constitution §1 标题是什么"，不调工具直接回答 | ✅ PASS |
| S3 | Git-checker 阻断 | N 个未 commit 文件时 `editor` 被 skip | ✅ PASS |
| S4 | 只读不阻断 | `readFile` 在文件堆积时正常工作 | ✅ PASS |
| S5 | Codec 安全 | 多轮对话（read+write）无崩溃 | ✅ PASS |
| S6 | Compaction | 长对话 ≥180K tokens 后 snapshot 写入 | 🔴 阻塞（BL-2）|

---

## 6. 已知局限与路线图

### 6.1 已知局限

| 局限 | 影响 | 缓解 |
|------|------|------|
| 仅在 cline-plus 一个项目 dogfood 过 | 通用性未验证 | `examples/` 示例包降低自建门槛 |
| VS Code 端 Hook 全部阻塞 | VS Code 用户无法用 plugin | CLI 端先跑通，VS Code 恢复后即插即用 |
| 仅 deepseek-v4-flash 验证 | 协同前缀跨模型通用性未知 | 等多模型验证 |
| Compaction 实测阻塞 | snapshot 写入未端到端验证 | 等 BL-2 PR 合并 |
| hooks/ + capabilities/ 部分为设计文档 | 非全部可跑代码 | CLI 端可跑部分；完整实现等阻塞解除 |
| registerRule 求值一次 | 不能做动态 per-turn 注入 | 动态内容走 messageBuilder（服从度不足）|
| Rule 按 name 字母序排列 | 无法控制 rule 顺序 | 用 namespace 前缀影响排序 |

### 6.2 阻塞项

| ID | 环境 | 状态 | 恢复条件 |
|----|------|------|---------|
| BL-1 | VS Code 4.0.x plugin 系统 | 不可用 | SDK 迁移重新合入稳定版（issue #11944，无进展）|
| BL-2 | CLI 3.0.34 codec bug | 部分受限 | PR #12032 合并 + CLI release tag |

**BL-2 影响范围**：

| 范围 | 状态 | 说明 |
|------|------|------|
| snapshot 写入实测 | 🔴 搁置 | 需 180K tokens 长对话，正是 bug 触发场景 |
| Loop Guard 注入 | 🟢 可用 | V6 路径绕过 codec（messageBuilder + ContentBlock[]）|
| setup marker / rules 注入 | 🟢 可用 | 短交互，不触发长对话路径 |

**workaround ≠ 环境可用**：workaround 期间实测结果仅证明"避开 bug 的路径可用"，不证明"环境完整可用"。

### 6.3 路线图

| 优先级 | 任务 | 依赖 | 说明 |
|--------|------|------|------|
| 🟡 中 | S6 compaction 测试 | BL-2 PR 合并 | snapshot 写入端到端验证 |
| 🟡 中 | multi-model verify | 无 | 在 Claude/GPT 上验证协同前缀通用性 |
| 🟢 低 | VS Code 监控 | BL-1 | 关键词 Plugins / registerMessageBuilder |
| 🟢 低 | PR #12032 监控 | 无 | 合并后跑回归测试 |
| 🟢 低 | H2/H3 补证 | 无 | image 分支 + 下游守卫 |

### 6.4 Capability 实现状态

| Capability | 设计 | 实现 | 阻塞 |
|-----------|:---:|:---:|------|
| git-checker | ✅ | ✅ tsc 通过 | VS Code 端（BL-1）|
| snapshot-writer | ✅ | ✅ tsc 通过 | CLI 长对话实测（BL-2）|
| handoff-provider | ✅ | ✅ tsc 通过 | 无 |
| rule-appender | ✅ | ✅ 33 测试过 | 无 |

**Plugin 运行时**：`.governance/plugin/index.ts` — 配置驱动 + Capability 静态导入 + Hook 分发

---

## 引用

- [设计思考与实验发现](design-thinking.md) — "为什么这么设计"
- [Cline Plugin Architecture Atlas](cline-plugin-architecture-atlas.md) — 逐层函数级架构地图
- cline-plus 仓库 `docs/decisions/delivery-framework-design.md` — 框架目录契约
- cline-plus 仓库 `.governance/capabilities/SOP.md` — Capability 开发 7 步清单
- cline-plus 仓库 `.governance/capabilities/README.md` — Capability 接口设计
- cline-plus 仓库 `docs/plugin/runtime-test-plan.md` — CLI 集成测试计划

---

*本文档基于 Cline CLI 3.0.37 + SDK v0.0.56 + Windows 11 实测。跨平台/跨模型适用性待验证。*
