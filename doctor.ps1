<#
.SYNOPSIS
  Diagnose a banner that isn't appearing (Windows).

.DESCRIPTION
  The failure modes here are unusually quiet, so this walks the pipeline stage by
  stage and reports where it actually stops.
#>
$ClaudeDir  = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
$Settings   = Join-Path $ClaudeDir 'settings.json'
$HookDest   = Join-Path $ClaudeDir 'hooks\claude-session-notifier.ps1'
$BannerDest = Join-Path $ClaudeDir 'hooks\claude-banner.ps1'

function Pass ($m) { Write-Host "  [ok]   $m" -ForegroundColor Green }
function Warn ($m) { Write-Host "  [warn] $m" -ForegroundColor Yellow }
function Bad  ($m) { Write-Host "  [fail] $m" -ForegroundColor Red }

Write-Host "`nclaude-session-notifier - doctor`n"

# 1. Environment
if ($PSVersionTable.PSVersion.Major -ge 5) { Pass "PowerShell $($PSVersionTable.PSVersion)" }
else { Bad "PowerShell 5.1+ required" }

try { Add-Type -AssemblyName PresentationFramework -ErrorAction Stop; Pass "WPF available" }
catch { Bad "WPF unavailable - the banner cannot draw" }

$policy = Get-ExecutionPolicy
if ($policy -eq 'Restricted') {
    Warn "ExecutionPolicy is Restricted. The hook passes -ExecutionPolicy Bypass so it should still run, but if nothing happens try: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned"
} else {
    Pass "ExecutionPolicy $policy"
}

# 2. Installed files
if (Test-Path $BannerDest) { Pass "banner script installed" } else { Bad "banner missing - run .\install.ps1" }
if (Test-Path $HookDest)   { Pass "hook script installed" }   else { Bad "hook missing - run .\install.ps1" }

# 3. Hook registration
if (Test-Path $Settings) {
    try {
        $json = Get-Content $Settings -Raw | ConvertFrom-Json
        $found = @($json.hooks.Stop | Where-Object {
            @($_.hooks | ForEach-Object { $_.command }) -match 'claude-session-notifier'
        })
        if ($found.Count -ge 1) { Pass "Stop hook registered in settings.json" }
        else { Bad "Stop hook NOT registered - run .\install.ps1" }
        if ($found.Count -gt 1) { Warn "registered $($found.Count) times - you will get duplicate banners" }
    } catch {
        Bad "cannot parse $Settings"
    }
} else {
    Bad "$Settings not found"
}

# 4. Focus Assist - suppresses sound, not our banner
$fa = Get-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\QuietHours' -ErrorAction SilentlyContinue
if ($fa) { Warn "Focus Assist may be configured (can silence the sound; the banner still draws)" }

# 5. Can anything draw at all?
if (Test-Path $BannerDest) {
    Write-Host "`n  Drawing a test banner (top-right, 4s)..."
    & $BannerDest -Message "doctor test - if you can read this, the banner works" -Duration 4
    Write-Host "  Did it appear? If YES, the banner is fine and the problem is upstream"
    Write-Host "  (hook not firing). If NO, please open an issue with your Windows version."
}

Write-Host "`n  Note: the banner does not use Windows toast notifications, so toast"
Write-Host "  registration and Focus Assist settings are irrelevant to it.`n"
