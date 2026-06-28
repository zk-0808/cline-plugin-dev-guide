# Cline Plugin Architecture Atlas

> **⚠️ Unofficial Guide**
>
> This document is an independent technical reference based on source code inspection and runtime experiments. It is **not affiliated** with the Cline project. The details described here were verified on specific versions (see "Verified On" below) and may differ from newer releases.

> **Verified On**
> - Cline CLI 3.0.31
> - VS Code Extension 4.0.0
> - SDK v0.0.51
> - Date: 2026-06-28

> **Purpose**: A navigational map of the Cline Plugin subsystem. When you encounter a plugin issue, start here — locate the lifecycle stage, then the file, then the function.

---

## 1. Repository Map (Plugin Subsystem)

```
sdk/packages/
├── shared/src/storage/
│   └── paths.ts                      # Discovery — plugin path resolution
├── core/src/
│   ├── services/
│   │   └── plugin-install.ts         # Install — 5 source types → _installed/
│   └── extensions/plugin/
│       ├── plugin-loader.ts          # Loader — in-process import + setup
│       ├── plugin-sandbox.ts         # Sandbox (host side) — spawn + proxy
│       ├── plugin-sandbox-bootstrap.ts  # Sandbox (child side) — IPC dispatch
│       └── plugin-module-import.ts   # Module Import — jiti transpilation
│   └── runtime/tools/
│       └── subprocess-sandbox.ts     # IPC Transport — child_process.spawn
```

> 中文注：这 7 个文件就是整个 Plugin 子系统的全部。不需要读其他文件就能理解 Plugin 如何被发现、加载、运行。

---

## 2. Plugin Lifecycle (7 Layers)

Every plugin passes through these layers in order. A bug at any layer stops the chain.

```
Layer 1: Discovery     →  paths.ts
   ↓ (array of file paths)
Layer 2: Install       →  plugin-install.ts
   ↓ (installed plugin directory)
Layer 3: Load          →  plugin-loader.ts  OR  plugin-sandbox.ts
   ↓ (import + setup)
Layer 4: Module Import →  plugin-module-import.ts
   ↓ (jiti transpilation)
Layer 5: Sandbox       →  plugin-sandbox-bootstrap.ts
   ↓ (IPC message handling)
Layer 6: Runtime       →  subprocess-sandbox.ts
   ↓ (child_process IPC)
Layer 7: Registry      →  plugin-sandbox.ts (host side)
   ↓ (proxy extensions registered on agent)
```

### Layer 1: Discovery (`paths.ts`, 605 lines)

**Responsibility**: Find plugin files on disk.

| Function | What it does |
|----------|-------------|
| `resolvePluginConfigSearchPaths(workspacePath?)` | Returns 3 search roots: workspace `.cline/plugins`, global `~/.cline/plugins`, `~/Documents/Cline/Plugins` |
| `discoverPluginModulePaths(directoryPath)` | Recursive DFS walker: finds `.js`/`.ts` entry files, reads `package.json` manifests |
| `resolvePluginModuleEntries(directoryPath)` | Resolves one directory to entry files via manifest or `index.ts`/`index.js` fallback |
| `resolveConfiguredPluginModulePaths(pluginPaths, cwd)` | Resolves user-configured paths to absolute file paths (throws on invalid) |

**Output**: `string[]` — absolute paths to plugin entry files.
**Error mode**: Returns empty arrays on failure (silent). Does NOT throw (except `resolveConfiguredPluginModulePaths`).

### Layer 2: Install (`plugin-install.ts`, 1218 lines)

**Responsibility**: Download/clone → stage → strip SDK deps → write wrapper `package.json` → atomic move to `_installed/`.

| Source Type | Handler |
|------------|---------|
| npm | `installNpmPackage` |
| git | `installGitPackage` |
| Official registry | `installOfficialPlugin` |
| Remote URL | `installRemoteFile` (30s timeout, 10MB cap) |
| Local path | `installLocalPackage` |

**Key behavior**: Strips `@cline/*` from `package.json` dependencies and `node_modules/@cline/` to prevent version conflicts with host runtime.

**Install path**: `<pluginRoot>/_installed/<type>/<name>-<hash>/`

**Error mode**: Staging directory cleaned up on failure. `replaceInstallPath` uses backup-rename strategy (rename old → rename new → rollback on failure).

### Layer 3: Load (`plugin-loader.ts`, 214 lines / `plugin-sandbox.ts`, 648 lines)

Two loading strategies — callers choose one:

| Strategy | File | When used |
|----------|------|-----------|
| In-process | `plugin-loader.ts` | CLI (direct) |
| Sandboxed | `plugin-sandbox.ts` | CLI + VS Code (default) |

**In-process** (`plugin-loader.ts`):
- `loadAgentPluginFromPath(pluginPath, options?)` — import → validate → wrap `setup` with context → return `AgentExtension`
- `loadAgentPluginsFromPathsWithDiagnostics(...)` — batch load with `PluginInitializationFailure[]` and `PluginInitializationWarning[]`

**Sandboxed** (`plugin-sandbox.ts`):
- `loadSandboxedPlugins(options)` — spawn subprocess → send `initialize` RPC → receive descriptors → build proxy `AgentExtension` objects
- `resolveBootstrap()` — searches 5 candidate paths for `plugin-sandbox-bootstrap.js`, falls back to jiti-based `node -e` script
- Each proxy's tools/commands/builders/hooks are thin wrappers that forward to `sandbox.call(method, args)` via IPC

> 中文注：VS Code 扩展 4.0.0 的问题出在这一层——`resolveBootstrap()` 的 5 个候选路径全部找不到文件，因为 esbuild 没有把 `plugin-sandbox-bootstrap.js` 输出到 `dist/`。

### Layer 4: Module Import (`plugin-module-import.ts`, 682 lines)

**Responsibility**: Import a `.ts` or `.js` plugin file using jiti (real-time TS→JS transpilation).

| Function | What it does |
|----------|-------------|
| `importPluginModule(pluginPath, options?)` | Main entry. Resolves aliases → creates jiti → imports plugin |
| `assertPluginDependenciesInstalled(pluginPath, preferHost)` | Regex-scans source for `import`/`require`, verifies each bare specifier resolves |
| `collectPluginImportAliases(pluginPath, preferHost)` | Builds alias map: workspace sources for SDK packages + host-runtime resolutions |

**Key detail**: `tryNative: false` on jiti instance — forces jiti to handle all imports (critical for Bun compatibility).

**SDK isolation**: `@cline/*` specifiers are aliased to host runtime copies, preventing version skew.

### Layer 5: Sandbox Bootstrap (`plugin-sandbox-bootstrap.ts`, 799 lines)

**Responsibility**: The script that runs **inside** the child process. Dispatches IPC messages to RPC methods.

| RPC Method | What it does |
|-----------|-------------|
| `initialize(args)` | Import plugins → call `setup(api, ctx)` → capture registrations → return descriptors |
| `buildMessages(args)` | Call registered messageBuilder's `build(messages)` |
| `executeTool(args)` | Call registered tool's `execute` handler |
| `executeCommand(args)` | Call registered command's handler |
| `invokeHook(args)` | Call registered hook function |
| `resolveRuleContent(args)` | Call registered rule content function |

**During `initialize`**: Creates a `PluginApi` that captures `registerTool/registerCommand/registerMessageBuilder/...` calls into descriptor arrays. After `setup()` returns, descriptors are serialized and sent back to the host.

### Layer 6: IPC Transport (`subprocess-sandbox.ts`, 335 lines)

**Responsibility**: Generic subprocess IPC transport. Spawns child, sends JSON-RPC calls, correlates responses.

| Method | What it does |
|--------|-------------|
| `start()` | Spawns `child_process.spawn("node", [bootstrapFile])` with `stdio: ["ignore", "ignore", "pipe", "ipc"]` |
| `call(method, args, options?)` | Sends `{type: "call", id, method, args}`, returns `Promise<TResult>` with timeout |
| `shutdown()` | SIGTERM → 300ms grace → SIGKILL. Rejects all pending requests |

**IPC Protocol**:
- Host → Child: `{type: "call", id: number, method: string, args: object}`
- Child → Host: `{type: "response", id: number, ok: boolean, result?: any, error?: {message, stack}}`
- Child → Host (events): `{type: "event", name: string, payload?: any}`

### Layer 7: Registry / Proxy (`plugin-sandbox.ts`, host side)

**Responsibility**: Convert sandbox descriptors into `AgentExtension` objects registered on the agent.

Each contribution type gets a proxy wrapper:
- `registerTools` → proxy `execute` → `sandbox.call("executeTool", ...)`
- `registerCommands` → proxy handler → `sandbox.call("executeCommand", ...)`
- `registerMessageBuilders` → proxy `build` → `sandbox.call("buildMessages", ...)`
- `registerSimpleContributions` → rules, providers, automation events
- `createSandboxRuntimeHooks` → lifecycle hooks (e.g., `onSessionStart`)

**Re-initialization**: On `"Unknown sandbox plugin id:"` error → guarded concurrent-safe `reinitialize()` → re-sends full `initialize` RPC to fresh child process. Deduplication promise prevents thundering-herd.

---

## 3. Data Flow: Message Pipeline

```
User Input
    ↓
Context Assembly
    ↓
┌─ MessageBuilder.build(messages) ──── Plugin can inspect/modify messages
│   ↓
│  Security Layer (rules filtering)
│   ↓
│  Provider (LLM API call)
│   ↓
│  Model Response
│   ↓
│  Tool Execution (if tool_use in response)
│   ↓
│  Loop or Final Response
└───────────────────────────────────────
```

> 中文注：`build()` 在每次 turn 准备时都被调用，不只是 compact 时。这是很多开发者会误解的地方。Plugin 的 `build()` 必须快（< 100ms），重量级操作要加条件门控。

---

## 4. Extension Points (Stable API)

These are the functions plugin developers should call in `setup(api, ctx)`:

| API Method | Capability | Sync/Async |
|-----------|-----------|------------|
| `api.registerTool(tool)` | `tools` | async `execute` |
| `api.registerCommand(command)` | `commands` | sync or async |
| `api.registerRule(rule)` | `rules` | sync or async |
| `api.registerMessageBuilder({ name, build })` | `messageBuilders` | **sync** `build` |
| `api.registerProvider(provider)` | `providers` | — |
| `api.registerAutomationEventType()` | `automationEvents` | — |
| `api.registerMcpServer(server)` | `mcpServers` | — |

**Stability**: These APIs are stable across CLI / VS Code / JetBrains. The loading mechanism differs (in-process vs sandbox), but the API surface is identical.

---

## 5. Diagnostic Flowchart

When a plugin doesn't work, follow this flowchart. Do NOT grep randomly.

```
Plugin not visible in Customize panel?
  → Layer 1: Discovery
  → Check: is plugin in ~/.cline/plugins/ with valid package.json?
  → File: paths.ts → discoverPluginModulePaths()

Plugin visible but setup() never runs?
  → Layer 3-6: Load → Sandbox
  → Check: does plugin-sandbox-bootstrap.js exist in extension dist/?
  → File: plugin-sandbox.ts → resolveBootstrap()
  → Known issue: VS Code 4.0.0 missing bootstrap → apply patch

setup() runs but registerMessageBuilder not called?
  → Layer 5: Bootstrap
  → Check: is setup() throwing before reaching registerMessageBuilder?
  → File: plugin-sandbox-bootstrap.ts → initialize() → loadPluginDescriptor()

registerMessageBuilder called but build() never invoked?
  → Layer 7: Registry
  → Check: is the builder name in the returned descriptors?
  → File: plugin-sandbox.ts → registerMessageBuilders()

build() invoked but output is wrong?
  → Plugin code logic issue
  → Check: messages array structure, shouldCompact threshold
  → File: your plugin's src/index.ts

Plugin times out on Windows?
  → Layer 6: IPC Transport
  → Check: CLINE_PLUGIN_IMPORT_TIMEOUT_MS (default 4000ms)
  → File: subprocess-sandbox.ts → call() timeout
  → Fix: set CLINE_PLUGIN_IMPORT_TIMEOUT_MS=30000
```

> 中文注：这个流程图是最重要的部分。以后遇到任何 Plugin 问题，第一步是定位到生命周期哪一层，然后再去看对应的源码文件。

---

## 6. Cross-Cutting Concerns

### Timeout Strategy

| Layer | Default | Override |
|-------|---------|----------|
| Discovery | none (sync FS) | — |
| Install (remote) | 30s | — |
| Module Import | 4000ms | `CLINE_PLUGIN_IMPORT_TIMEOUT_MS` |
| Hook calls | 3000ms | — |
| Tool/Command/Builder calls | 60000ms | — |

### SDK Dependency Isolation

Two-stage isolation prevents plugin SDK dependencies from conflicting with host:
1. **Install time** (`plugin-install.ts`): Strips `@cline/*` from `package.json` and `node_modules/`
2. **Import time** (`plugin-module-import.ts`): Aliases `@cline/*` specifiers to host runtime copies

### Re-initialization Pattern

When sandbox child process crashes:
1. Next IPC call fails with `"Unknown sandbox plugin id:"` error
2. `plugin-sandbox.ts` detects this specific error message
3. Guarded `reinitialize()` is triggered (deduplication promise prevents thundering-herd)
4. Full `initialize` RPC re-sent to fresh child process
5. Original call is retried once

### Console.log Behavior

Plugin `console.log()` writes to the sandbox subprocess stdout, which is configured as `"ignore"` in `SubprocessSandbox`. It does **NOT** appear in VS Code DevTools Console.

Alternatives:
- `ctx.logger.log()` → appears in Cline output channel
- File-based markers → most reliable for debugging

---

## 7. Quick Reference: File → Function → Line

| File (relative to `sdk/packages/`) | Key Functions | Lines |
|------|-------------|------|
| `shared/src/storage/paths.ts` | `discoverPluginModulePaths`, `resolvePluginConfigSearchPaths` | 605 |
| `core/src/services/plugin-install.ts` | `installPlugin`, `parsePluginSource`, `replaceInstallPath` | 1218 |
| `core/src/extensions/plugin/plugin-loader.ts` | `loadAgentPluginFromPath`, `loadAgentPluginsFromPathsWithDiagnostics` | 214 |
| `core/src/extensions/plugin/plugin-sandbox.ts` | `loadSandboxedPlugins`, `resolveBootstrap`, `registerMessageBuilders` | 648 |
| `core/src/extensions/plugin/plugin-sandbox-bootstrap.ts` | `initialize`, `buildMessages`, `executeTool`, `loadPluginDescriptor` | 799 |
| `core/src/extensions/plugin/plugin-module-import.ts` | `importPluginModule`, `assertPluginDependenciesInstalled` | 682 |
| `core/src/runtime/tools/subprocess-sandbox.ts` | `SubprocessSandbox.start`, `.call`, `.shutdown` | 335 |

---

*Generated from Cline SDK source analysis, 2026-06-28. Verified against CLI 3.0.31 and VS Code extension 4.0.0.*
