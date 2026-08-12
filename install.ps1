<#
.SYNOPSIS
  Install the Claude Code session-end banner (Windows).

.EXAMPLE
  .\install.ps1
.EXAMPLE
  .\install.ps1 -DryRun
#>
[CmdletBinding()]
param([switch]$DryRun)

$ErrorActionPreference = 'Stop'

$RepoDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$ClaudeDir  = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
$HooksDir   = Join-Path $ClaudeDir 'hooks'
$Settings   = Join-Path $ClaudeDir 'settings.json'
$HookDest   = Join-Path $HooksDir 'claude-session-notifier.ps1'
$BannerDest = Join-Path $HooksDir 'claude-banner.ps1'
$Marker     = 'claude-session-notifier'

function Ok   ($m) { Write-Host "  [ok] $m"   -ForegroundColor Green }
function Info ($m) { Write-Host "   .  $m" }
function Fail ($m) { Write-Host "`n  [x] $m`n" -ForegroundColor Red; exit 1 }

Write-Host "`nClaude Code session banner (Windows)`n"

# ── Preflight ────────────────────────────────────────────────────────────────
# Fail loudly here. A missing prerequisite that only shows up at runtime produces a
# hook that silently does nothing, which is painful to debug.

if (-not $IsWindows -and $PSVersionTable.PSVersion.Major -ge 6) {
    Fail "Windows only. On macOS use ./install.sh instead."
}
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Fail "PowerShell 5.1 or newer is required (found $($PSVersionTable.PSVersion))."
}
try {
    Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
} catch {
    Fail "WPF (PresentationFramework) is unavailable. This needs Windows PowerShell 5.1, or PowerShell 7 on Windows."
}
if (-not (Test-Path $ClaudeDir)) {
    Fail "$ClaudeDir not found. Install Claude Code first: https://claude.com/claude-code"
}

Ok "PowerShell $($PSVersionTable.PSVersion)"
Ok "WPF available"
Ok "found $ClaudeDir"

if ($DryRun) {
    Write-Host "`n  Dry run - would then:"
    Info "copy   $RepoDir\src-windows\claude-banner.ps1  ->  $BannerDest"
    Info "copy   $HookDest"
    Info "register a Stop hook in $Settings (backing it up first)"
    Write-Host ""
    exit 0
}

# ── Install files ────────────────────────────────────────────────────────────

New-Item -ItemType Directory -Force -Path $HooksDir | Out-Null
Copy-Item (Join-Path $RepoDir 'src-windows\claude-banner.ps1')         $BannerDest -Force
Ok "installed $BannerDest"
Copy-Item (Join-Path $RepoDir 'hooks\claude-session-notifier.ps1')     $HookDest   -Force
Ok "installed $HookDest"

# ── Register the hook ────────────────────────────────────────────────────────
# Merge, never overwrite: you may already have Stop hooks, and clobbering someone's
# settings.json is unforgivable. Any previous entry of OURS is dropped first, so
# re-running updates in place instead of registering a duplicate.

if (-not (Test-Path $Settings)) { '{}' | Set-Content $Settings -Encoding UTF8 }

try {
    $json = Get-Content $Settings -Raw | ConvertFrom-Json
} catch {
    Fail "$Settings is not valid JSON. Fix or move it first - refusing to touch it."
}
if ($null -eq $json) { $json = [PSCustomObject]@{} }

$backup = "$Settings.backup.$(Get-Date -Format 'yyyyMMddHHmmss')"
Copy-Item $Settings $backup -Force
Ok "backed up settings to $(Split-Path $backup -Leaf)"

if (-not $json.PSObject.Properties.Name.Contains('hooks') -or $null -eq $json.hooks) {
    $json | Add-Member -NotePropertyName 'hooks' -NotePropertyValue ([PSCustomObject]@{}) -Force
}

$existing = @()
if ($json.hooks.PSObject.Properties.Name -contains 'Stop' -and $json.hooks.Stop) {
    $existing = @($json.hooks.Stop | Where-Object {
        $commands = @($_.hooks | ForEach-Object { $_.command })
        -not ($commands -match [regex]::Escape($Marker))
    })
}

$command = 'powershell -NoProfile -ExecutionPolicy Bypass -File "' + $HookDest + '"'
$entry = [PSCustomObject]@{
    hooks = @([PSCustomObject]@{
        type    = 'command'
        command = $command
        shell   = 'powershell'
        async   = $true
    })
}

$json.hooks | Add-Member -NotePropertyName 'Stop' -NotePropertyValue (@($existing) + $entry) -Force

# -Depth matters: ConvertTo-Json defaults to 2 and would silently mangle nested hooks.
$json | ConvertTo-Json -Depth 100 | Set-Content $Settings -Encoding UTF8
Ok "registered Stop hook in settings.json"

# ── Verify ───────────────────────────────────────────────────────────────────
# End on proof, not a promise. If no banner appears, you find out now.

Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$BannerDest`"",
    '-Message', '"install test - if you can read this, it works"', '-Duration', 5, '-Slot', 0
)

Write-Host @"

  Done. A test banner should have appeared in your top-right corner.

  If you saw it, you're set: every Claude Code session on this PC will now
  announce itself when it finishes a turn, labelled with its folder name.

  If you did NOT see it, run .\doctor.ps1 - it will tell you which stage failed.

  Restart any Claude Code sessions that are already running, or open /hooks
  once, so they pick up the new configuration.

"@
