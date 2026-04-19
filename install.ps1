# claude-statusline installer for Windows PowerShell
# Copies statusline.sh to ~/.claude/ and configures settings.json
#
# Requirements: Git Bash (bash.exe in PATH) + jq
# Run:  powershell -ExecutionPolicy Bypass -File install.ps1

#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Write-Info($msg)  { Write-Host "[OK] $msg"      -ForegroundColor Green  }
function Write-Warn($msg)  { Write-Host "[!]  $msg"      -ForegroundColor Yellow }
function Write-Err ($msg)  { Write-Host "[X]  $msg"      -ForegroundColor Red; exit 1 }

$ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$ClaudeDir    = Join-Path $env:USERPROFILE '.claude'
$SettingsFile = Join-Path $ClaudeDir 'settings.json'
$Target       = Join-Path $ClaudeDir 'statusline.sh'
$Source       = Join-Path $ScriptDir 'statusline.sh'

Write-Host ""
Write-Host "claude-statusline installer (Windows)" -ForegroundColor Cyan
Write-Host "─────────────────────────────────────"
Write-Host ""

# 1. Dependencies
$bash = Get-Command bash -ErrorAction SilentlyContinue
if (-not $bash) {
    Write-Err "bash.exe not found in PATH. Install Git for Windows: https://git-scm.com/download/win"
}
Write-Info "bash found: $($bash.Source)"

$jq = Get-Command jq -ErrorAction SilentlyContinue
if (-not $jq) {
    Write-Err "jq not found. Install: 'winget install jqlang.jq'  or  'choco install jq'"
}
Write-Info "jq found: $($jq.Source)"

if (-not (Get-Command curl -ErrorAction SilentlyContinue)) {
    Write-Warn "curl not found — usage limits feature will be disabled"
}

if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Warn "Claude Code CLI not found in PATH (needed at runtime)"
}

# 2. Ensure ~/.claude exists
if (-not (Test-Path $ClaudeDir)) {
    New-Item -ItemType Directory -Path $ClaudeDir | Out-Null
    Write-Info "Created $ClaudeDir"
}

# 3. Copy statusline.sh
if (-not (Test-Path $Source)) {
    Write-Err "statusline.sh not found next to installer: $Source"
}

if ((Test-Path $Target) -and -not $Force) {
    $answer = Read-Host "Existing statusline.sh at $Target — overwrite? [y/N]"
    if ($answer -notmatch '^[Yy]') {
        Write-Host "Aborted."
        exit 0
    }
}
Copy-Item -Path $Source -Destination $Target -Force
Write-Info "Installed statusline.sh -> $Target"

# 4. Configure settings.json
if (-not (Test-Path $SettingsFile)) {
    '{}' | Set-Content -Path $SettingsFile -Encoding UTF8
    Write-Info "Created $SettingsFile"
}

# Convert Windows path to a bash-friendly forward-slash path
$BashTarget = $Target -replace '\\', '/'
$Command    = "bash '$BashTarget'"

try {
    $json = Get-Content $SettingsFile -Raw | ConvertFrom-Json
} catch {
    Write-Err "Failed to parse $SettingsFile : $($_.Exception.Message)"
}

$current = $null
if ($json.PSObject.Properties.Name -contains 'statusLine') {
    $current = $json.statusLine.command
}

if ($current -eq $Command) {
    Write-Info "settings.json already configured"
} else {
    if ($current) {
        Write-Warn "statusLine already set to: $current"
        $answer = Read-Host "  Replace with '$Command'? [y/N]"
        if ($answer -notmatch '^[Yy]') {
            Write-Host "Skipped settings.json update."
            $Command = $null
        }
    }
    if ($Command) {
        $newStatus = [ordered]@{
            type    = 'command'
            command = $Command
            padding = 2
        }
        $json | Add-Member -MemberType NoteProperty -Name 'statusLine' -Value $newStatus -Force
        $json | ConvertTo-Json -Depth 10 | Set-Content -Path $SettingsFile -Encoding UTF8
        Write-Info "Updated statusLine in settings.json"
    }
}

# 5. Platform tips
Write-Host ""
Write-Warn "Usage limits will read ~/.claude/.credentials.json (Claude Code stores OAuth token there)."
Write-Host  "     For toast notifications, optional: Install-Module BurntToast -Scope CurrentUser"
Write-Host ""
Write-Info "Installation complete! Restart Claude Code to see the status line."
Write-Host ""
Write-Host "  Configuration in ~/.claude/settings.json:"
Write-Host "    `"statusLine`": {"
Write-Host "      `"type`": `"command`","
Write-Host "      `"command`": `"bash '$BashTarget'`","
Write-Host "      `"padding`": 2"
Write-Host "    }"
Write-Host ""
