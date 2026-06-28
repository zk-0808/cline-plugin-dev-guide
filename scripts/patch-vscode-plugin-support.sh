#!/usr/bin/env bash
#
# patch-vscode-plugin-support.sh
#
# Patch VS Code extension 4.x to support Cline Plugin loading.
#
# VS Code extension 4.0.0 is missing plugin-sandbox-bootstrap.js in its build output,
# causing plugins to silently fail to load. This script copies the bootstrap file and
# required dependencies from the Cline CLI installation into the extension directory.
#
# Prerequisites:
#   - Cline CLI installed globally (npm install -g cline)
#   - VS Code extension "saoudrizwan.claude-dev" installed
#
# Usage:
#   chmod +x patch-vscode-plugin-support.sh
#   ./patch-vscode-plugin-support.sh
#
# Options:
#   --ext-dir <path>    Override auto-detected extension directory
#   --cli-dir <path>    Override auto-detected CLI node_modules directory
#   --timeout <ms>      Plugin import timeout (default: 30000)
#   --uninstall         Remove the patch
#

set -euo pipefail

EXTENSION_DIR=""
CLI_DIR=""
TIMEOUT=30000
UNINSTALL=false

# ── Colors ────────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

step()  { echo -e "\n${CYAN}>> $1${NC}"; }
ok()    { echo -e "   ${GREEN}OK${NC}: $1"; }
warn()  { echo -e "   ${YELLOW}WARN${NC}: $1"; }
fail()  { echo -e "   ${RED}FAIL${NC}: $1"; }

# ── Parse arguments ──────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ext-dir)  EXTENSION_DIR="$2"; shift 2 ;;
        --cli-dir)  CLI_DIR="$2"; shift 2 ;;
        --timeout)  TIMEOUT="$2"; shift 2 ;;
        --uninstall) UNINSTALL=true; shift ;;
        -h|--help)
            echo "Usage: $0 [--ext-dir <path>] [--cli-dir <path>] [--timeout <ms>] [--uninstall]"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ── Step 1: Locate VS Code extension ─────────────────────────────────────────

step "Locating VS Code extension..."

if [[ -z "$EXTENSION_DIR" ]]; then
    VSCODE_EXT_ROOT="$HOME/.vscode/extensions"
    if [[ ! -d "$VSCODE_EXT_ROOT" ]]; then
        fail "VS Code extensions directory not found: $VSCODE_EXT_ROOT"
        exit 1
    fi

    # Find the latest Cline extension directory
    EXTENSION_DIR=$(find "$VSCODE_EXT_ROOT" -maxdepth 1 -type d -name "saoudrizwan.claude-dev-*" | sort -r | head -1)

    if [[ -z "$EXTENSION_DIR" ]]; then
        fail "No Cline VS Code extension found in $VSCODE_EXT_ROOT"
        echo "   Install Cline from the VS Code marketplace first, then re-run this script."
        exit 1
    fi
fi

if [[ ! -d "$EXTENSION_DIR" ]]; then
    fail "Extension directory not found: $EXTENSION_DIR"
    exit 1
fi

EXT_VERSION=$(basename "$EXTENSION_DIR" | sed 's/saoudrizwan\.claude-dev-//')
ok "Found extension v$EXT_VERSION at $EXTENSION_DIR"

# ── Step 2: Locate CLI installation ──────────────────────────────────────────

step "Locating Cline CLI installation..."

if [[ -z "$CLI_DIR" ]]; then
    # Try to find via npm prefix
    NPM_PREFIX=""
    if command -v npm &>/dev/null; then
        NPM_PREFIX=$(npm prefix -g 2>/dev/null || true)
    fi

    SEARCH_PATHS=()
    if [[ -n "$NPM_PREFIX" ]]; then
        SEARCH_PATHS+=("$NPM_PREFIX/lib/node_modules/cline/node_modules")
    fi

    # Common locations
    SEARCH_PATHS+=(
        "/usr/local/lib/node_modules/cline/node_modules"
        "/usr/lib/node_modules/cline/node_modules"
        "$HOME/.npm-global/lib/node_modules/cline/node_modules"
        "$HOME/.local/lib/node_modules/cline/node_modules"
        "$(dirname "$(which cline 2>/dev/null || echo /dev/null)")/../lib/node_modules/cline/node_modules"
    )

    for path in "${SEARCH_PATHS[@]}"; do
        if [[ -d "$path/@cline/core" ]]; then
            CLI_DIR="$path"
            break
        fi
    done
fi

if [[ -z "$CLI_DIR" ]] || [[ ! -d "$CLI_DIR" ]]; then
    fail "Cline CLI not found. Install it with: npm install -g cline"
    echo "   Or specify the path: $0 --cli-dir /path/to/node_modules"
    exit 1
fi

ok "Found CLI at $CLI_DIR"

# ── Uninstall mode ───────────────────────────────────────────────────────────

if [[ "$UNINSTALL" == true ]]; then
    step "Removing patch..."

    rm -f "$EXTENSION_DIR/dist/extensions/plugin-sandbox-bootstrap.js"
    ok "Removed bootstrap file"

    rm -rf "$EXTENSION_DIR/node_modules/@cline/shared"
    rm -rf "$EXTENSION_DIR/node_modules/@cline/core"
    rm -rf "$EXTENSION_DIR/node_modules/jiti"
    ok "Removed dependency copies"

    # Clean up empty directories
    rmdir "$EXTENSION_DIR/dist/extensions" 2>/dev/null || true
    rmdir "$EXTENSION_DIR/node_modules/@cline" 2>/dev/null || true

    echo ""
    echo -e "${GREEN}=== Patch removed ===${NC}"
    echo "   Reload VS Code to apply changes."
    exit 0
fi

# ── Step 3: Verify bootstrap source ──────────────────────────────────────────

step "Verifying bootstrap file..."

BOOTSTRAP_SRC="$CLI_DIR/@cline/core/dist/extensions/plugin-sandbox-bootstrap.js"
if [[ ! -f "$BOOTSTRAP_SRC" ]]; then
    fail "Bootstrap file not found at: $BOOTSTRAP_SRC"
    echo "   Your CLI installation may be incomplete. Try: npm install -g cline"
    exit 1
fi

ok "Bootstrap source: $BOOTSTRAP_SRC"

# ── Step 4: Copy bootstrap ───────────────────────────────────────────────────

step "Copying bootstrap to extension..."

BOOTSTRAP_DST="$EXTENSION_DIR/dist/extensions"
mkdir -p "$BOOTSTRAP_DST"
cp "$BOOTSTRAP_SRC" "$BOOTSTRAP_DST/plugin-sandbox-bootstrap.js"
ok "Bootstrap copied to $BOOTSTRAP_DST"

# ── Step 5: Copy dependencies ────────────────────────────────────────────────

step "Copying dependencies..."

NODE_MODULES_DST="$EXTENSION_DIR/node_modules"
CLINE_DST="$NODE_MODULES_DST/@cline"
mkdir -p "$CLINE_DST"

for dep in "shared" "core"; do
    SRC="$CLI_DIR/@cline/$dep"
    DST="$CLINE_DST/$dep"
    if [[ ! -d "$SRC" ]]; then
        warn "@cline/$dep not found (skipping)"
        continue
    fi
    rm -rf "$DST"
    cp -r "$SRC" "$DST"
    ok "Copied @cline/$dep"
done

JITI_SRC="$CLI_DIR/jiti"
JITI_DST="$NODE_MODULES_DST/jiti"
if [[ -d "$JITI_SRC" ]]; then
    rm -rf "$JITI_DST"
    cp -r "$JITI_SRC" "$JITI_DST"
    ok "Copied jiti"
else
    warn "jiti not found (skipping)"
fi

# ── Step 6: Timeout hint ─────────────────────────────────────────────────────

step "Plugin import timeout..."

# On macOS/Linux, the default 4s timeout is usually sufficient.
# The Windows-specific Issue #11065 may not apply.
echo "   Default timeout is 4000ms."
echo "   If plugins fail to load, set: export CLINE_PLUGIN_IMPORT_TIMEOUT_MS=$TIMEOUT"
echo "   Or add to ~/.bashrc / ~/.zshrc for persistence."

# ── Step 7: Verify ───────────────────────────────────────────────────────────

step "Verifying patch..."

ALL_OK=true
for check in \
    "$BOOTSTRAP_DST/plugin-sandbox-bootstrap.js:Bootstrap file" \
    "$CLINE_DST/core:@cline/core" \
    "$CLINE_DST/shared:@cline/shared"
do
    path="${check%%:*}"
    name="${check##*:}"
    if [[ -e "$path" ]]; then
        ok "$name present"
    else
        fail "$name MISSING"
        ALL_OK=false
    fi
done

# ── Done ─────────────────────────────────────────────────────────────────────

echo ""
if [[ "$ALL_OK" == true ]]; then
    echo -e "${GREEN}=== Patch applied successfully ===${NC}"
    echo ""
    echo "Next steps:"
    echo "  1. Reload VS Code: Cmd+Shift+P → 'Developer: Reload Window'"
    echo "  2. Open Cline sidebar → Customize (gear icon)"
    echo "  3. Install a plugin to ~/.cline/plugins/installed/local/<name>/"
    echo "  4. Plugin should appear and be functional"
    echo ""
    echo -e "${YELLOW}To undo:${NC} $0 --uninstall"
else
    echo -e "${RED}=== Patch incomplete — check errors above ===${NC}"
    exit 1
fi
