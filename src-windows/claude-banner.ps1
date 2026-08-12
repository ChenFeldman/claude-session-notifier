<#
.SYNOPSIS
  A borderless, click-through HUD that appears in the top-right corner and fades out.

.DESCRIPTION
  Deliberately NOT a Windows toast notification. Toasts require an AUMID (app user
  model ID) registration to appear from a console process, and without one they fail
  silently — the same class of quiet failure that the macOS osascript path has. Focus
  Assist can also suppress toasts with no error. Drawing our own WPF window sidesteps
  both: nothing to register, nothing to authorize.

  Uses only what ships with Windows PowerShell 5.1 (WPF via PresentationFramework),
  so there is no dependency to install.

.PARAMETER Message
  Text to display.

.PARAMETER Duration
  Seconds to stay on screen before fading.

.PARAMETER Slot
  0 is the top-right corner; each further slot stacks one banner lower, so two
  sessions finishing at once don't draw on top of each other.
#>
param(
    [string]$Message  = "Claude Code",
    [double]$Duration = 5,
    [int]   $Slot     = 0
)

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

# Click-through: the Win32 equivalent of AppKit's ignoresMouseEvents. Without this the
# banner would swallow a click meant for whatever is underneath it.
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class ClickThrough {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
    public const int GWL_EXSTYLE     = -20;
    public const int WS_EX_TRANSPARENT = 0x20;
    public const int WS_EX_TOOLWINDOW  = 0x80;   // keep it out of Alt-Tab
}
"@

$width  = 380.0
$height = 92.0
$margin = 16.0

$window = New-Object System.Windows.Window
$window.WindowStyle        = 'None'
$window.AllowsTransparency = $true
$window.Background         = [System.Windows.Media.Brushes]::Transparent
$window.Topmost            = $true
$window.ShowInTaskbar      = $false
$window.ResizeMode         = 'NoResize'
$window.Width              = $width
$window.Height             = $height
$window.Opacity            = 0

# Position against the working area so we never cover the taskbar.
$area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$window.Left = $area.Right - $width - $margin
$window.Top  = $area.Top + $margin + ($Slot * ($height + 10))

$border = New-Object System.Windows.Controls.Border
$border.CornerRadius = New-Object System.Windows.CornerRadius 16
$border.Background   = New-Object System.Windows.Media.SolidColorBrush(
                         [System.Windows.Media.Color]::FromArgb(235, 32, 32, 34))
$border.BorderBrush  = New-Object System.Windows.Media.SolidColorBrush(
                         [System.Windows.Media.Color]::FromArgb(40, 255, 255, 255))
$border.BorderThickness = New-Object System.Windows.Thickness 1

$stack = New-Object System.Windows.Controls.StackPanel
$stack.Margin = New-Object System.Windows.Thickness(18, 14, 18, 14)

$title = New-Object System.Windows.Controls.TextBlock
$title.Text       = "Claude Code"
$title.FontSize   = 12
$title.FontWeight = [System.Windows.FontWeights]::SemiBold
$title.Foreground = New-Object System.Windows.Media.SolidColorBrush(
                      [System.Windows.Media.Color]::FromRgb(160, 160, 168))

$body = New-Object System.Windows.Controls.TextBlock
$body.Text         = $Message
$body.FontSize     = 13
$body.Margin       = New-Object System.Windows.Thickness(0, 6, 0, 0)
$body.TextWrapping = 'Wrap'
$body.Foreground   = [System.Windows.Media.Brushes]::White

$stack.Children.Add($title) | Out-Null
$stack.Children.Add($body)  | Out-Null
$border.Child = $stack
$window.Content = $border

$window.Add_SourceInitialized({
    $handle = (New-Object System.Windows.Interop.WindowInteropHelper $window).Handle
    $ex = [ClickThrough]::GetWindowLong($handle, [ClickThrough]::GWL_EXSTYLE)
    [ClickThrough]::SetWindowLong($handle, [ClickThrough]::GWL_EXSTYLE,
        $ex -bor [ClickThrough]::WS_EX_TRANSPARENT -bor [ClickThrough]::WS_EX_TOOLWINDOW) | Out-Null
})

$window.Add_Loaded({
    $fadeIn = New-Object System.Windows.Media.Animation.DoubleAnimation(
        0, 1, [System.Windows.Duration](New-TimeSpan -Milliseconds 220))
    $window.BeginAnimation([System.Windows.Window]::OpacityProperty, $fadeIn)

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromSeconds($Duration)
    $timer.Add_Tick({
        $timer.Stop()
        $fadeOut = New-Object System.Windows.Media.Animation.DoubleAnimation(
            1, 0, [System.Windows.Duration](New-TimeSpan -Milliseconds 450))
        $fadeOut.Add_Completed({ $window.Close() })
        $window.BeginAnimation([System.Windows.Window]::OpacityProperty, $fadeOut)
    })
    $timer.Start()
})

$window.ShowDialog() | Out-Null
