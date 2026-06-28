# Unofficial Cline Plugin Development Guide

> **⚠️ Community Guide**
>
> This is an independent community-maintained guide based on:
> - Source code inspection (SDK v0.0.51)
> - Runtime experiments (CLI 3.0.31 / VS Code Extension 4.0.0)
> - Plugin development experience (handoff-plugin)
>
> It is **not affiliated** with the Cline project. Details were verified on specific versions and may differ from newer releases.

---

## Highlights

| Area | Rating | Description |
|------|--------|-------------|
| **Architecture Atlas** | ⭐⭐⭐⭐⭐ | 7-layer Plugin lifecycle map — from discovery to registry |
| **Sandbox Internals** | ⭐⭐⭐⭐⭐ | How the subprocess sandbox works (and doesn't work) |
| **Debug Flow** | ⭐⭐⭐⭐⭐ | Step-by-step troubleshooting for common plugin issues |
| **VS Code Workaround** | ⭐⭐ | Temporary — likely obsolete in 4.0.1+ |

---

## What's Inside

```
📦 cline-plugin-dev-guide
 ┣ 📄 README.md                          ← This file — overview + quick start
 ┣ 📄 cline-plugin-architecture-atlas.md  ← ★★★★★ Architecture Atlas (core value)
 ┗ 📁 scripts/
    ┣ 📄 patch-vscode-plugin-support.ps1  ← Windows: copy bootstrap to VS Code
    ┗ 📄 patch-vscode-plugin-support.sh   ← macOS/Linux: same workaround
```

### Architecture Atlas (core value)

The [`cline-plugin-architecture-atlas.md`](cline-plugin-architecture-atlas.md) is a navigational map of the Cline Plugin subsystem. It covers:

- **Repository Map** — 7 source files that comprise the entire plugin subsystem
- **7-Layer Plugin Lifecycle** — Discovery → Install → Load → Module Import → Sandbox → Runtime → Registry
- **Per-Layer API Reference** — key functions, signatures, error modes
- **Quick Debug Flow** — "Plugin not loading?" → where to look, what file, what function
- **Cross-Cutting Concerns** — timeout strategy, SDK dependency isolation, crash recovery
- **File → Function → Line Quick Reference**

This content is stable across Cline versions and will remain valuable long-term.

### VS Code Workaround (temporary)

The scripts in `scripts/` address a known limitation in VS Code Extension 4.0.0:

| Observation | Confidence | Evidence |
|-------------|-----------|----------|
| Bootstrap file `plugin-sandbox-bootstrap.js` absent from extension `dist/` | High | Filesystem search — zero hits |
| Build tooling does not emit bootstrap as standalone file | High | CLI build includes it; bundle contains loading code |
| Workaround verified | High | 7 real compaction events tested |

**If you're on VS Code Extension 4.0.0**:

```bash
# 1. Install Cline CLI (needed as bootstrap source)
npm install -g cline

# 2. Run the patch script
# Windows:
.\scripts\patch-vscode-plugin-support.ps1

# macOS/Linux:
chmod +x scripts/patch-vscode-plugin-support.sh
./scripts/patch-vscode-plugin-support.sh

# 3. Reload VS Code
# Ctrl+Shift+P → "Developer: Reload Window"
```

> **Note**: This workaround is version-specific. If you're on 4.0.1+, first check whether `plugin-sandbox-bootstrap.js` exists in the extension directory before applying it.

---

## How This Investigation Was Done

Many developers have asked: *"How did you figure this out?"*

The methodology used in this guide is reusable for any AI Agent codebase:

```
1. Read the SDK examples
   → Start with official plugin examples (custom-compaction.ts is a goldmine)

2. Trace the plugin lifecycle
   → Follow the code: discoverPluginModulePaths → loadSandboxedPlugins → resolveBootstrap → importPluginModule

3. Compare CLI vs VS Code builds
   → Same SDK, different packaging — the diff reveals the root cause

4. Design a runtime experiment
   → Write a marker file in setup(); if it appears, the plugin loaded

5. Formulate and test a hypothesis
   → "Missing bootstrap file" → copy it from CLI → verify setup() executes

6. Verify with real workload
   → 7 compaction events with handoff.md + index.jsonl written correctly
```

This method — **SDK → Lifecycle Trace → Cross-Build Comparison → Experiment → Hypothesis → Verification** — can be applied to any large AI Agent codebase (Cline, Claude Code, OpenHands, Continue, Cursor).

---

## Verified On

| Component | Version | Status |
|-----------|---------|--------|
| Cline CLI | 3.0.31 | ✅ Plugins work natively |
| VS Code Extension | 4.0.0 | ✅ With workaround (scripts/) |
| SDK | v0.0.51 | Reference for source analysis |
| OS | Windows / macOS / Linux | Scripts provided for all three |
| Date | 2026-06-28 | — |

---

## Quick Start for Plugin Developers

```bash
# Create a minimal plugin
mkdir my-plugin && cd my-plugin
npm init -y
# Add "cline" field to package.json (see atlas for schema)
mkdir src && echo 'export default { name: "my-plugin", setup(api) { console.log("loaded!"); } }' > src/index.ts

# Install and test in CLI
cline plugin install . --cwd .
cline -i "hello"  # Verify plugin loads

# If targeting VS Code 4.0.0:
.\scripts\patch-vscode-plugin-support.ps1  # or the .sh equivalent
```

---

## Related Resources

- [Cline Official Plugin Docs](https://docs.cline.bot/customization/plugins)
- [Cline SDK Examples](https://github.com/cline/cline/tree/main/sdk/examples/plugins)
- [Cline Plugin Architecture Atlas (detailed)](cline-plugin-architecture-atlas.md)

---

## License

Apache-2.0 (same as the Cline SDK examples this work is based on).
