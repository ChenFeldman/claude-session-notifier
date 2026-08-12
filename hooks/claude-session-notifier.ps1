<#
  Claude Code Stop hook (Windows) — announce which session just finished a turn.

  Registered in %USERPROFILE%\.claude\settings.json by install.ps1, so it covers every
  project and worktree. Claude Code sends the hook a JSON payload on stdin; `cwd` is
  what tells us WHICH session finished.

  Configure with environment variables:
    CLAUDE_BANNER_SOUND     path to a .wav, or "none" to stay silent
    CLAUDE_BANNER_DURATION  seconds the banner stays on screen (default 5)
    CLAUDE_BANNER_TEXT      message template; {0} is replaced with the folder name
#>

$ErrorActionPreference = 'Continue'

$sound    = if ($env:CLAUDE_BANNER_SOUND)    { $env:CLAUDE_BANNER_SOUND }    else { "$env:WINDIR\Media\Windows Notify System Generic.wav" }
$duration = if ($env:CLAUDE_BANNER_DURATION) { [double]$env:CLAUDE_BANNER_DURATION } else { 5 }
$template = if ($env:CLAUDE_BANNER_TEXT)     { $env:CLAUDE_BANNER_TEXT }     else { "{0} finished" }

$bannerScript = Join-Path $env:USERPROFILE '.claude\hooks\claude-banner.ps1'

# `cwd` arrives as JSON on stdin. We use it rather than $env:CLAUDE_PROJECT_DIR, which
# is not reliably set for Stop hooks. ConvertFrom-Json is built in — no jq needed here.
$name = 'claude'
try {
    $payload = [Console]::In.ReadToEnd()
    if ($payload) {
        $cwd = ($payload | ConvertFrom-Json).cwd
        if ($cwd) { $name = Split-Path $cwd -Leaf }
    }
} catch {
    # Malformed or absent payload: still notify, just without a specific name.
}

# The folder name is untrusted input: it can come from a branch name (via
# `git worktree add`), and branch names can come from a pull request. Strip control
# characters and cap the length, but keep Unicode — folder names in Hebrew, Japanese,
# or with emoji are legitimate, and replacing them with underscores would make the
# banner useless for anyone not working in ASCII. Injection is handled where it
# actually matters: the argument string built for Start-Process below is escaped at
# the point of use.
$name = ($name -replace '[\x00-\x1F]', '')
if ($name.Length -gt 64) { $name = $name.Substring(0, 64) }
if ([string]::IsNullOrWhiteSpace($name) -or $name -eq '.') { $name = 'claude' }

# Plain replacement rather than -f: the template is user-supplied, and treating it as
# a .NET format string turns a stray brace into a runtime error.
$message = $template.Replace('{0}', $name)

# Audible signal first: it needs no permission, so it works even if the visual path
# is broken.
if ($sound -ne 'none' -and (Test-Path $sound)) {
    try {
        (New-Object System.Media.SoundPlayer $sound).Play()
    } catch { }
}

if (Test-Path $bannerScript) {
    # Stack below any banner already on screen so parallel sessions don't overlap.
    # Known limitation: slots are not reclaimed as banners fade — see README.
    $slot = 0
    try {
        $running = @(Get-CimInstance Win32_Process -Filter "Name like '%powershell%'" -ErrorAction Stop |
                     Where-Object { $_.CommandLine -like '*claude-banner.ps1*' })
        $slot = $running.Count
    } catch { }

    # SECURITY: -ArgumentList is a string handed to a command-line parser, so a quote
    # inside $message would end the argument and let the rest be read as further
    # arguments. Escape it here, at the point of use. Backslash first, then quote —
    # reversing the order would double-escape.
    $safe = $message -replace '\\', '\\\\'
    $safe = $safe -replace '"', '\"'

    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$bannerScript`"",
        '-Message', "`"$safe`"", '-Duration', $duration, '-Slot', $slot
    )
} else {
    # Fallback: a message box is ugly and modal, but it is at least visible. Toasts are
    # deliberately not used here — without an AUMID registration they fail silently.
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show($message, 'Claude Code') | Out-Null
}
