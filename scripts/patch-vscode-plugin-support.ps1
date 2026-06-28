#Requires -Version 5.1
<#
.SYNOPSIS
    Patch VS Code extension 4.x to support Cline Plugin loading.

.DESCRIPTION
    VS Code extension 4.0.0 is missing plugin-sandbox-bootstrap.js in its build output,
    causing plugins to silently fail to load. This script copies the bootstrap file and
    required dependencies from the Cline CLI installation into the extension directory.

    Prerequisites:
    - Cline CLI installed globally (npm install -g cline)
    - VS Code extension "saoudrizwan.claude-dev" installed

.PARAMETER ExtensionDir
    Override auto-detected VS Code extension directory.

.PARAMETER CliDir
    Override auto-detected CLI node_modules directory.

.PARAMETER Timeout
    Plugin import timeout in milliseconds (default: 30000).

.EXAMPLE
    .\patch-vscode-plugin-support.ps1

.EXAMPLE
    .\patch-vscode-plugin-support.ps1 -CliDir "C:\custom\path\node_modules"
#>

param(
    [string]$ExtensionDir = "",
    [string]$CliDir = "",
    [int]$Timeout = 30000
)

$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host "`n>> $Message" -ForegroundColor Cyan
}

function Write-OK {
    param([string]$Message)
    Write-Host "   OK: $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "   WARN: $Message" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Message)
    Write-Host "   FAIL: $Message" -ForegroundColor Red
}

# ── Step 1: Locate VS Code extension ──────────────────────────────────────────

Write-Step "Locating VS Code extension..."

if ($ExtensionDir -eq "") {
    $vscodeExtRoot = Join-Path $env:USERPROFILE ".vscode\extensions"
    $candidates = Get-ChildItem -Path $vscodeExtRoot -Directory -Filter "saoudrizwan.claude-dev-*" -ErrorAction SilentlyContinue |
                  Sort-Object Name -Descending
    if ($candidates.Count -eq 0) {
        Write-Fail "No Cline VS Code extension found in $vscodeExtRoot"
        Write-Host "   Install Cline from the VS Code marketplace first, then re-run this script." -ForegroundColor Yellow
        exit 1
    }
    $ExtensionDir = $candidates[0].FullName
}

if (-not (Test-Path $ExtensionDir)) {
    Write-Fail "Extension directory not found: $ExtensionDir"
    exit 1
}

$extensionVersion = (Split-Path $ExtensionDir -Leaf) -replace "saoudrizwan\.claude-dev-", ""
Write-OK "Found extension v$extensionVersion at $ExtensionDir"

# ── Step 2: Locate CLI installation ──────────────────────────────────────────

Write-Step "Locating Cline CLI installation..."

if ($CliDir -eq "") {
    # Try npm global prefix
    $npmPrefix = ""
    try {
        $npmPrefix = (npm prefix -g 2>$null).Trim()
    } catch {}

    $searchPaths = @()
    if ($npmPrefix) {
        $searchPaths += Join-Path $npmPrefix "node_modules\cline\node_modules"
    }
    $searchPaths += @(
        (Join-Path $env:APPDATA "npm\node_modules\cline\node_modules"),
        (Join-Path $env:USERPROFILE "AppData\Roaming\npm\node_modules\cline\node_modules")
    )

    foreach ($path in $searchPaths) {
        if (Test-Path (Join-Path $path "@cline\core")) {
            $CliDir = $path
            break
        }
    }
}

if ($CliDir -eq "" -or -not (Test-Path $CliDir)) {
    Write-Fail "Cline CLI not found. Install it with: npm install -g cline"
    Write-Host "   Or specify the path: .\patch-vscode-plugin-support.ps1 -CliDir `"path\to\node_modules`"" -ForegroundColor Yellow
    exit 1
}

Write-OK "Found CLI at $CliDir"

# ── Step 3: Verify bootstrap source ──────────────────────────────────────────

Write-Step "Verifying bootstrap file..."

$bootstrapSrc = Join-Path $CliDir "@cline\core\dist\extensions\plugin-sandbox-bootstrap.js"
if (-not (Test-Path $bootstrapSrc)) {
    Write-Fail "Bootstrap file not found at: $bootstrapSrc"
    Write-Host "   Your CLI installation may be incomplete. Try: npm install -g cline" -ForegroundColor Yellow
    exit 1
}

Write-OK "Bootstrap source: $bootstrapSrc"

# ── Step 4: Copy bootstrap ───────────────────────────────────────────────────

Write-Step "Copying bootstrap to extension..."

$bootstrapDst = Join-Path $ExtensionDir "dist\extensions"
if (-not (Test-Path $bootstrapDst)) {
    New-Item -ItemType Directory -Force -Path $bootstrapDst | Out-Null
}

Copy-Item $bootstrapSrc (Join-Path $bootstrapDst "plugin-sandbox-bootstrap.js") -Force
Write-OK "Bootstrap copied to $bootstrapDst"

# ── Step 5: Copy dependencies ────────────────────────────────────────────────

Write-Step "Copying dependencies..."

$nodeModulesDst = Join-Path $ExtensionDir "node_modules"
$clineDst = Join-Path $nodeModulesDst "@cline"

if (-not (Test-Path $clineDst)) {
    New-Item -ItemType Directory -Force -Path $clineDst | Out-Null
}

$depsToCopy = @("@cline\shared", "@cline\core", "jiti")
foreach ($dep in $depsToCopy) {
    $src = Join-Path $CliDir $dep
    if (-not (Test-Path $src)) {
        Write-Warn "Dependency not found: $dep (skipping)"
        continue
    }

    if ($dep -like "@cline\*") {
        $dst = Join-Path $clineDst ($dep -replace "@cline\\", "")
    } else {
        $dst = Join-Path $nodeModulesDst $dep
    }

    if (Test-Path $dst) {
        Remove-Item -Recurse -Force $dst
    }
    Copy-Item -Recurse -Force $src $dst
    Write-OK "Copied $dep"
}

# ── Step 6: Set timeout environment variable ─────────────────────────────────

Write-Step "Setting plugin import timeout..."

$currentTimeout = [Environment]::GetEnvironmentVariable("CLINE_PLUGIN_IMPORT_TIMEOUT_MS", "User")
if ($currentTimeout -ne "$Timeout") {
    [Environment]::SetEnvironmentVariable("CLINE_PLUGIN_IMPORT_TIMEOUT_MS", "$Timeout", "User")
    Write-OK "CLINE_PLUGIN_IMPORT_TIMEOUT_MS set to ${Timeout}ms (user-level)"
} else {
    Write-OK "CLINE_PLUGIN_IMPORT_TIMEOUT_MS already set to ${Timeout}ms"
}

# ── Step 7: Verify ───────────────────────────────────────────────────────────

Write-Step "Verifying patch..."

$checks = @(
    @{ Path = (Join-Path $bootstrapDst "plugin-sandbox-bootstrap.js"); Name = "Bootstrap file" },
    @{ Path = (Join-Path $clineDst "core"); Name = "@cline/core" },
    @{ Path = (Join-Path $clineDst "shared"); Name = "@cline/shared" }
)

$allOK = $true
foreach ($check in $checks) {
    if (Test-Path $check.Path) {
        Write-OK "$($check.Name) present"
    } else {
        Write-Fail "$($check.Name) MISSING"
        $allOK = $false
    }
}

# ── Done ─────────────────────────────────────────────────────────────────────

Write-Host ""
if ($allOK) {
    Write-Host "=== Patch applied successfully ===" -ForegroundColor Green
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor White
    Write-Host "  1. Reload VS Code: Ctrl+Shift+P -> 'Developer: Reload Window'"
    Write-Host "  2. Open Cline sidebar -> Customize (gear icon)"
    Write-Host "  3. Install a plugin to ~/.cline/plugins/installed/local/<name>/"
    Write-Host "  4. Plugin should appear and be functional"
    Write-Host ""
    Write-Host "To undo: Delete the copied files and the environment variable." -ForegroundColor Gray
} else {
    Write-Host "=== Patch incomplete — check errors above ===" -ForegroundColor Red
    exit 1
}
