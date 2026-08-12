<#
.SYNOPSIS
  Remove the Claude Code session-end banner (Windows). Leaves the rest of
  settings.json alone.
#>
$ErrorActionPreference = 'Stop'

$ClaudeDir  = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
$Settings   = Join-Path $ClaudeDir 'settings.json'
$HookDest   = Join-Path $ClaudeDir 'hooks\claude-session-notifier.ps1'
$BannerDest = Join-Path $ClaudeDir 'hooks\claude-banner.ps1'
$Marker     = 'claude-session-notifier'

function Ok   ($m) { Write-Host "  [ok] $m" -ForegroundColor Green }
function Fail ($m) { Write-Host "`n  [x] $m`n" -ForegroundColor Red; exit 1 }

Write-Host "`nRemoving claude-session-notifier`n"

if (Test-Path $Settings) {
    try {
        $json = Get-Content $Settings -Raw | ConvertFrom-Json
    } catch {
        Fail "$Settings is not valid JSON - refusing to touch it."
    }

    $backup = "$Settings.backup.$(Get-Date -Format 'yyyyMMddHHmmss')"
    Copy-Item $Settings $backup -Force
    Ok "backed up settings to $(Split-Path $backup -Leaf)"

    if ($json.hooks -and ($json.hooks.PSObject.Properties.Name -contains 'Stop')) {
        # Drop only our own entries, then tidy up empty containers we may have created.
        $kept = @($json.hooks.Stop | Where-Object {
            $commands = @($_.hooks | ForEach-Object { $_.command })
            -not ($commands -match [regex]::Escape($Marker))
        })

        if ($kept.Count -eq 0) {
            $json.hooks.PSObject.Properties.Remove('Stop')
        } else {
            $json.hooks | Add-Member -NotePropertyName 'Stop' -NotePropertyValue $kept -Force
        }

        if ($json.hooks.PSObject.Properties.Name.Count -eq 0) {
            $json.PSObject.Properties.Remove('hooks')
        }

        $json | ConvertTo-Json -Depth 100 | Set-Content $Settings -Encoding UTF8
        Ok "removed Stop hook from settings.json"
    }
}

foreach ($f in @($HookDest, $BannerDest)) {
    if (Test-Path $f) { Remove-Item $f -Force; Ok "removed $f" }
}

Write-Host "`n  Done. Restart running Claude Code sessions to drop the hook.`n"
