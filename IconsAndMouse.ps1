param(
    [switch]$Headless,
    [switch]$StartInTray,
    [int]$CursorRecoveryForPid = 0,
    [string]$CursorRecoveryEventName = '',
    [string]$CursorRecoveryReadyEventName = '',
    [switch]$DisableErrorLog
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Must run before any window is created
# Unhandled WinForms exceptions are logged
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::add_ThreadException([System.Threading.ThreadExceptionEventHandler]{
    param($sender, $e)
    Write-AppLog "Unhandled: $($e.Exception.Message)"
})

# Error logging is optional: the -DisableErrorLog switch always wins over the saved setting
$script:writeErrorLog = -not $DisableErrorLog

function Write-AppLog([string]$message) {
    if (-not $script:writeErrorLog) { return }
    try {
        $logPath = Join-Path (Join-Path $env:APPDATA 'DesktopIconsApp') 'errors.log'
        $logDirectory = Split-Path -Parent $logPath
        if (-not (Test-Path -LiteralPath $logDirectory)) {
            New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
        }
        # Keep the log from growing without bound (one rotated copy)
        if ((Test-Path -LiteralPath $logPath) -and (Get-Item -LiteralPath $logPath).Length -gt 512KB) {
            Move-Item -LiteralPath $logPath -Destination ($logPath + '.old') -Force
        }
        Add-Content -LiteralPath $logPath -Value ('{0:u} {1}' -f [DateTime]::Now, $message) -Encoding UTF8
    } catch { }   # logging must never throw
}

if ($CursorRecoveryForPid -eq 0) {
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.ComponentModel;

public static class DesktopIconsAppNative {
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }

    [DllImport("user32.dll", SetLastError = true)]
    static extern bool GetCursorPos(out POINT point);
    [DllImport("user32.dll")]
    static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string className, string windowName);
    [DllImport("user32.dll")]
    static extern bool ShowWindow(IntPtr handle, int command);
    [DllImport("user32.dll")]
    static extern bool IsWindowVisible(IntPtr handle);
    public delegate bool EnumWindowsProc(IntPtr handle, IntPtr parameter);
    [DllImport("user32.dll")]
    static extern bool EnumWindows(EnumWindowsProc callback, IntPtr parameter);
    [DllImport("user32.dll")]
    static extern short GetAsyncKeyState(int virtualKey);
    [DllImport("user32.dll", SetLastError = true)]
    static extern IntPtr CreateCursor(IntPtr instance, int hotX, int hotY, int width, int height, byte[] andPlane, byte[] xorPlane);
    [DllImport("user32.dll", SetLastError = true)]
    static extern bool SetSystemCursor(IntPtr cursor, uint id);
    [DllImport("user32.dll", SetLastError = true)]
    static extern bool SystemParametersInfo(uint action, uint parameter, IntPtr value, uint flags);
    [DllImport("kernel32.dll")]
    static extern IntPtr GetModuleHandle(string moduleName);

    static readonly uint[] CursorIds = {
        32512, 32513, 32514, 32515, 32516, 32642, 32643,
        32644, 32645, 32646, 32648, 32649, 32650
    };

    // Returns null when the cursor position is unavailable (secure desktop: UAC, Ctrl+Alt+Del, lock screen).
    public static POINT? TryCursorPosition() {
        POINT point;
        return GetCursorPos(out point) ? (POINT?)point : null;
    }

    public static int ScreenWidth() { return GetSystemMetrics(0); }
    public static int ScreenHeight() { return GetSystemMetrics(1); }

    public static IntPtr DesktopList() {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr window, IntPtr parameter) {
            IntPtr view = FindWindowEx(window, IntPtr.Zero, "SHELLDLL_DefView", null);
            if (view != IntPtr.Zero) {
                IntPtr list = FindWindowEx(view, IntPtr.Zero, "SysListView32", null);
                if (list != IntPtr.Zero) { found = list; return false; }
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static void SetIconsVisible(bool visible) {
        IntPtr list = DesktopList();
        if (list == IntPtr.Zero) throw new InvalidOperationException("Could not find the Windows desktop icon list.");
        ShowWindow(list, visible ? 5 : 0);
    }

    public static bool AreIconsVisible() {
        IntPtr list = DesktopList();
        if (list == IntPtr.Zero) throw new InvalidOperationException("Could not find the Windows desktop icon list.");
        return IsWindowVisible(list);
    }

    public static bool AnyMouseButtonDown() {
        return (GetAsyncKeyState(1) & 0x8000) != 0
            || (GetAsyncKeyState(2) & 0x8000) != 0
            || (GetAsyncKeyState(4) & 0x8000) != 0;
    }

    public static void HideCursor() {
        byte[] andPlane = new byte[128];
        byte[] xorPlane = new byte[128];
        for (int i = 0; i < andPlane.Length; i++) andPlane[i] = 0xFF;

        foreach (uint id in CursorIds) {
            IntPtr cursor = CreateCursor(GetModuleHandle(null), 0, 0, 32, 32, andPlane, xorPlane);
            if (cursor == IntPtr.Zero || !SetSystemCursor(cursor, id)) {
                RestoreCursor();
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not hide the system cursor.");
            }
        }
    }

    public static void RestoreCursor() {
        if (!SystemParametersInfo(0x0057, 0, IntPtr.Zero, 0))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not restore the system cursors.");
    }
}
"@
}

$script:settingsPath = Join-Path $env:APPDATA 'DesktopIconsApp\settings.json'
if ($CursorRecoveryForPid -gt 0) {
    Add-Type @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class DesktopIconsAppRecoveryNative {
    [DllImport("user32.dll", SetLastError = true)]
    static extern bool SystemParametersInfo(uint action, uint parameter, IntPtr value, uint flags);

    public static void RestoreCursor() {
        if (!SystemParametersInfo(0x0057, 0, IntPtr.Zero, 0))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not restore the system cursors.");
    }
}
"@
    $recoveryEvent = $null
    $readyEvent = $null
    $parentProcess = $null
    try {
        $recoveryEvent = [System.Threading.EventWaitHandle]::OpenExisting($CursorRecoveryEventName)
        $readyEvent = [System.Threading.EventWaitHandle]::OpenExisting($CursorRecoveryReadyEventName)
        $readyEvent.Set() | Out-Null
        try {
            $parentProcess = [System.Diagnostics.Process]::GetProcessById($CursorRecoveryForPid)
        } catch [System.ArgumentException] {
            [DesktopIconsAppRecoveryNative]::RestoreCursor()
            exit 0
        }
        while ($true) {
            if ($recoveryEvent.WaitOne(500)) { break }
            if ($parentProcess.HasExited) {
                [DesktopIconsAppRecoveryNative]::RestoreCursor()
                break
            }
        }
        exit 0
    } catch {
        Write-AppLog "Cursor recovery failed: $($_.Exception.Message)"
        exit 1
    } finally {
        if ($recoveryEvent) { $recoveryEvent.Dispose() }
        if ($readyEvent) { $readyEvent.Dispose() }
        if ($parentProcess) { $parentProcess.Dispose() }
    }
}
$script:startupLink = Join-Path ([Environment]::GetFolderPath('Startup')) 'Desktop Icons App.lnk'
$script:startupLauncherPath = Join-Path $env:APPDATA 'DesktopIconsApp\Startup.vbs'
$script:headlessStopEvent = [System.Threading.EventWaitHandle]::new(
    $false, [System.Threading.EventResetMode]::ManualReset, 'Local\DesktopIconsApp.Stop'
)
$script:showUiEvent = [System.Threading.EventWaitHandle]::new(
    $false, [System.Threading.EventResetMode]::AutoReset, 'Local\DesktopIconsApp.ShowUI'
)
$script:automationMutex = [System.Threading.Mutex]::new($false, 'Local\DesktopIconsApp.Automation')
$script:ownsAutomationMutex = $false
$script:uiMutex = $null
$script:originalIconsVisible = $null
$script:cursorRecoveryEvent = $null
$script:cursorRecoveryReadyEvent = $null
$script:cursorRecoveryProcess = $null
if (-not $Headless) {
    $uiMutexCreated = $false
    $script:uiMutex = [System.Threading.Mutex]::new(
        $true, 'Local\DesktopIconsApp.SettingsUI', [ref]$uiMutexCreated
    )
    if (-not $uiMutexCreated) {
        $script:showUiEvent.Set() | Out-Null
        $script:uiMutex.Dispose()
        $script:automationMutex.Dispose()
        $script:showUiEvent.Dispose()
        $script:headlessStopEvent.Dispose()
        exit 0
    }
}
$script:screenWidth = [DesktopIconsAppNative]::ScreenWidth()
$script:screenHeight = [DesktopIconsAppNative]::ScreenHeight()
$script:zones = @(
    [pscustomobject]@{ X = 0.0; Y = 0.0; Width = 0.13; Height = 0.95 },
    [pscustomobject]@{ X = 0.87; Y = 0.0; Width = 0.13; Height = 0.95 }
)
$script:iconsVisible = $true
$script:cursorHidden = $false
$script:cursorBackoffUntil = 0
$script:leftZoneAt = $null
$script:lastCursorPosition = $null
$script:activityClock = [System.Diagnostics.Stopwatch]::StartNew()
$script:zoneClock = [System.Diagnostics.Stopwatch]::StartNew()
$script:dragStart = $null
$script:dragCurrent = $null
$script:selectedZone = -1
$script:closingForExit = $false
$script:headlessStartFailed = $false
$script:tickFailures = 0
$script:maxTickFailures = 40   # ~10 s of consecutive failed ticks (250 ms each) before giving up

function Show-AppError([string]$message) {
    if ($Headless) {
        Write-AppLog $message
        return
    }
    Write-AppLog $message
    [System.Windows.Forms.MessageBox]::Show(
        $message, 'Desktop Icons App', [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}

function Show-SettingsWindow {
    $script:form.Show()
    $script:form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    $script:form.Activate()
}

# WaitOne(0) that treats an abandoned mutex (previous owner was killed) as acquired
function Try-AcquireAutomationMutex {
    try {
        return $script:automationMutex.WaitOne(0)
    } catch [System.Threading.AbandonedMutexException] {
        return $true
    }
}

function Start-CursorRecoveryWatcher {
    if ($script:cursorRecoveryEvent) { return }

    $eventName = 'Local\DesktopIconsApp.CursorRecovery.{0}.{1}' -f $PID, [Guid]::NewGuid().ToString('N')
    $readyEventName = $eventName + '.Ready'
    $script:cursorRecoveryEvent = [System.Threading.EventWaitHandle]::new(
        $false, [System.Threading.EventResetMode]::ManualReset, $eventName
    )
    $script:cursorRecoveryReadyEvent = [System.Threading.EventWaitHandle]::new(
        $false, [System.Threading.EventResetMode]::ManualReset, $readyEventName
    )
    try {
        $loggingArgument = if ($script:writeErrorLog) { '' } else { ' -DisableErrorLog' }
        $arguments = '-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -CursorRecoveryForPid {1} -CursorRecoveryEventName "{2}" -CursorRecoveryReadyEventName "{3}"{4}' -f $PSCommandPath, $PID, $eventName, $readyEventName, $loggingArgument
        $script:cursorRecoveryProcess = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') `
            -ArgumentList $arguments -WindowStyle Hidden -PassThru
        if (-not $script:cursorRecoveryReadyEvent.WaitOne(30000)) {
            throw 'Cursor recovery helper did not become ready within 30 seconds.'
        }
        $script:cursorRecoveryReadyEvent.Dispose()
        $script:cursorRecoveryReadyEvent = $null
    } catch {
        Stop-CursorRecoveryWatcher
        throw
    }
}

function Stop-CursorRecoveryWatcher {
    if ($script:cursorRecoveryEvent) {
        $script:cursorRecoveryEvent.Set() | Out-Null
        $script:cursorRecoveryEvent.Dispose()
        $script:cursorRecoveryEvent = $null
    }
    if ($script:cursorRecoveryReadyEvent) {
        $script:cursorRecoveryReadyEvent.Dispose()
        $script:cursorRecoveryReadyEvent = $null
    }
    if ($script:cursorRecoveryProcess) {
        $script:cursorRecoveryProcess.Dispose()
        $script:cursorRecoveryProcess = $null
    }
}

# Compares against the real desktop state so a cached value can't desync
# (Explorer restart, resolution change refreshing the desktop, etc)
function Set-IconsVisible([bool]$visible) {
    if ([DesktopIconsAppNative]::AreIconsVisible() -ne $visible) {
        [DesktopIconsAppNative]::SetIconsVisible($visible)
    }
    $script:iconsVisible = $visible
}

function Restore-AppState {
    $restoreErrors = @()
    if ($null -ne $script:originalIconsVisible) {
        try {
            Set-IconsVisible $script:originalIconsVisible
            $script:originalIconsVisible = $null
        } catch {
            $restoreErrors += "Could not restore desktop icon visibility: $($_.Exception.Message)"
        }
    }
    if ($script:cursorHidden) {
        try {
            [DesktopIconsAppNative]::RestoreCursor()
            $script:cursorHidden = $false
            Stop-CursorRecoveryWatcher
        } catch {
            $restoreErrors += "Could not restore system cursors: $($_.Exception.Message)"
        }
    }
    if ($restoreErrors.Count -gt 0) { throw ($restoreErrors -join "`n") }
}

function Release-AutomationMutex {
    if ($script:ownsAutomationMutex) {
        $script:automationMutex.ReleaseMutex()
        $script:ownsAutomationMutex = $false
    }
}

function Save-Settings {
    $directory = Split-Path -Parent $script:settingsPath
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $settings = [ordered]@{
        Zones = @($script:zones | ForEach-Object {
            [ordered]@{ X = $_.X; Y = $_.Y; Width = $_.Width; Height = $_.Height }
        })
        HideIcons = $script:hideIconsCheck.Checked
        HideCursor = $script:hideCursorCheck.Checked
        LogErrors = $script:logErrorsCheck.Checked
        HideDelayMs = [int]$script:hideDelayInput.Value
        IdleHideMs = [int]$script:idleHideInput.Value
    }
    # Atomic write: a crash mid-write can't leave a corrupt settings.json
    $tempPath = $script:settingsPath + '.tmp'
    $settings | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $tempPath -Encoding UTF8
    Move-Item -LiteralPath $tempPath -Destination $script:settingsPath -Force
}

function Load-Settings {
    if (-not (Test-Path -LiteralPath $script:settingsPath)) { return }
    try {
        $settings = Get-Content -LiteralPath $script:settingsPath -Raw | ConvertFrom-Json
    } catch {
        # Corrupt file: set it aside and fall back to defaults instead of failing startup
        Write-AppLog "settings.json is unreadable, using defaults: $($_.Exception.Message)"
        try { Move-Item -LiteralPath $script:settingsPath -Destination ($script:settingsPath + '.corrupt') -Force } catch { }
        return
    }
    if ($null -eq $settings) { return }
    if ($null -ne $settings.Zones) {
        $loadedZones = @()
        foreach ($zone in $settings.Zones) {
            if ($null -ne $zone.X -and $null -ne $zone.Y -and
                $null -ne $zone.Width -and $null -ne $zone.Height -and
                $zone.X -ge 0 -and $zone.Y -ge 0 -and
                $zone.Width -gt 0 -and $zone.Height -gt 0 -and
                ($zone.X + $zone.Width) -le 1 -and ($zone.Y + $zone.Height) -le 1) {
                $loadedZones += [pscustomobject]@{
                    X = [double]$zone.X; Y = [double]$zone.Y
                    Width = [double]$zone.Width; Height = [double]$zone.Height
                }
            }
        }
        $script:zones = @($loadedZones)
    }
    if ($null -ne $settings.HideIcons) { $script:hideIconsCheck.Checked = [bool]$settings.HideIcons }
    if ($null -ne $settings.HideCursor) { $script:hideCursorCheck.Checked = [bool]$settings.HideCursor }
    if ($null -ne $settings.LogErrors) {
        $script:logErrorsCheck.Checked = [bool]$settings.LogErrors
    }
    # The -DisableErrorLog switch always overrides the saved preference
    $script:writeErrorLog = $script:logErrorsCheck.Checked -and -not $DisableErrorLog
    if ($null -ne $settings.HideDelayMs -and
        $settings.HideDelayMs -ge $script:hideDelayInput.Minimum -and
        $settings.HideDelayMs -le $script:hideDelayInput.Maximum) {
        $script:hideDelayInput.Value = [decimal]$settings.HideDelayMs
    }
    if ($null -ne $settings.IdleHideMs -and
        $settings.IdleHideMs -ge $script:idleHideInput.Minimum -and
        $settings.IdleHideMs -le $script:idleHideInput.Maximum) {
        $script:idleHideInput.Value = [decimal]$settings.IdleHideMs
    }
}

function Start-Automation {
    if (-not $script:ownsAutomationMutex) {
        if (-not (Try-AcquireAutomationMutex)) {
            throw 'The desktop effects are already running in another app instance.'
        }
        $script:ownsAutomationMutex = $true
    }
    try {
        $script:originalIconsVisible = [DesktopIconsAppNative]::AreIconsVisible()
        $script:iconsVisible = $script:originalIconsVisible
        $script:headlessStopEvent.Reset()
        Save-Settings
        $script:activityClock.Restart()
        $script:leftZoneAt = $null
        $script:tickFailures = 0
        $script:timer.Start()
        $script:startButton.Enabled = $false
        $script:stopButton.Enabled = $true
        $script:statusLabel.Text = 'Running'
    } catch {
        Release-AutomationMutex
        throw
    }
}

function Get-PreviewBounds {
    $panel = $script:preview
    $scale = [Math]::Min($panel.ClientSize.Width / [double]$script:screenWidth, $panel.ClientSize.Height / [double]$script:screenHeight)
    $width = $script:screenWidth * $scale
    $height = $script:screenHeight * $scale
    return [System.Drawing.RectangleF]::new(
        ($panel.ClientSize.Width - $width) / 2,
        ($panel.ClientSize.Height - $height) / 2,
        $width, $height
    )
}

function Update-Preview {
    $script:preview.Invalidate()
    $script:zoneList.Items.Clear()
    for ($index = 0; $index -lt $script:zones.Count; $index++) {
        $zone = $script:zones[$index]
        [void]$script:zoneList.Items.Add(
            ('Area {0} ({1}%, {2}%)' -f ($index + 1), [Math]::Round($zone.X * 100), [Math]::Round($zone.Y * 100))
        )
    }
    if ($script:selectedZone -ge $script:zones.Count) { $script:selectedZone = -1 }
    $script:zoneList.SelectedIndex = $script:selectedZone
}

function Get-StartupMode {
    if (-not (Test-Path -LiteralPath $script:startupLink)) { return 'None' }
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($script:startupLink)
    if ($shortcut.Arguments -match '(?i)(?:^|\s)-StartInTray(?:\s|$)') { return 'Tray' }
    if ($shortcut.Arguments -match '(?i)Startup\.vbs') {
        if (Test-Path -LiteralPath $script:startupLauncherPath) {
            $launcher = Get-Content -LiteralPath $script:startupLauncherPath -Raw
            if ($launcher -match '(?i)-StartInTray') { return 'Tray' }
        }
        return 'Headless'
    }
    return 'Headless'
}

function Set-StartupShortcut([string]$mode) {
    if ($mode -ne 'None') {
        $launcherDirectory = Split-Path -Parent $script:startupLauncherPath
        if (-not (Test-Path -LiteralPath $launcherDirectory)) {
            New-Item -ItemType Directory -Path $launcherDirectory -Force | Out-Null
        }
        $powershellExe = Join-Path $PSHOME 'powershell.exe'
        $startupModeArgument = if ($mode -eq 'Tray') { '-StartInTray' } else { '-Headless' }
        $powerShellArguments = '-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" ' + $startupModeArgument
        $runCommand = '"' + $powershellExe + '" ' + $powerShellArguments
        $vbScriptCommand = $runCommand.Replace('"', '""')
        @(
            'Set shell = CreateObject("WScript.Shell")'
            ('shell.Run "{0}", 0, False' -f $vbScriptCommand)
        ) | Set-Content -LiteralPath $script:startupLauncherPath -Encoding Unicode

        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($script:startupLink)
        $shortcut.TargetPath = Join-Path ([Environment]::GetFolderPath('System')) 'wscript.exe'
        $shortcut.Arguments = '"' + $script:startupLauncherPath + '"'
        $shortcut.WorkingDirectory = Split-Path -Parent $PSCommandPath
        $shortcut.Description = 'Run Desktop Icons App at sign-in'
        $shortcut.Save()
    }
    elseif (Test-Path -LiteralPath $script:startupLink) {
        Remove-Item -LiteralPath $script:startupLink
        if (Test-Path -LiteralPath $script:startupLauncherPath) {
            Remove-Item -LiteralPath $script:startupLauncherPath
        }
    }
}

$script:form = New-Object System.Windows.Forms.Form
$script:form.Text = 'Desktop Icons App'
$script:form.StartPosition = 'CenterScreen'
$script:form.ClientSize = [System.Drawing.Size]::new(600, 537)
$script:form.MinimumSize = [System.Drawing.Size]::new(616, 576)
$script:form.MaximizeBox = $false
$script:form.ShowInTaskbar = -not $Headless
$script:form.Opacity = if ($Headless) { 0 } else { 1 }

$script:preview = New-Object System.Windows.Forms.Panel
$script:preview.Location = [System.Drawing.Point]::new(18, 52)
$script:preview.Size = [System.Drawing.Size]::new(365, 210)
$script:preview.BackColor = [System.Drawing.Color]::FromArgb(36, 43, 54)
$script:preview.BorderStyle = 'FixedSingle'
$script:form.Controls.Add($script:preview)

$previewTitle = New-Object System.Windows.Forms.Label
$previewTitle.Text = 'Screen preview — drag to add an area'
$previewTitle.Location = [System.Drawing.Point]::new(18, 20)
$previewTitle.AutoSize = $true
$script:form.Controls.Add($previewTitle)

$script:zoneList = New-Object System.Windows.Forms.ListBox
$script:zoneList.Location = [System.Drawing.Point]::new(402, 52)
$script:zoneList.Size = [System.Drawing.Size]::new(178, 170)
$script:form.Controls.Add($script:zoneList)

$removeZone = New-Object System.Windows.Forms.Button
$removeZone.Text = 'Remove selected'
$removeZone.Location = [System.Drawing.Point]::new(402, 231)
$removeZone.Size = [System.Drawing.Size]::new(178, 30)
$script:form.Controls.Add($removeZone)

$script:hideIconsCheck = New-Object System.Windows.Forms.CheckBox
$script:hideIconsCheck.Text = 'Show desktop icons only inside these areas'
$script:hideIconsCheck.Location = [System.Drawing.Point]::new(18, 280)
$script:hideIconsCheck.AutoSize = $true
$script:hideIconsCheck.Checked = $true
$script:form.Controls.Add($script:hideIconsCheck)

$hideDelayLabel = New-Object System.Windows.Forms.Label
$hideDelayLabel.Text = 'Hide icons after leaving area (ms):'
$hideDelayLabel.Location = [System.Drawing.Point]::new(38, 310)
$hideDelayLabel.AutoSize = $true
$script:form.Controls.Add($hideDelayLabel)

$script:hideDelayInput = New-Object System.Windows.Forms.NumericUpDown
$script:hideDelayInput.Location = [System.Drawing.Point]::new(275, 307)
$script:hideDelayInput.Size = [System.Drawing.Size]::new(90, 24)
$script:hideDelayInput.Minimum = 0
$script:hideDelayInput.Maximum = 10000
$script:hideDelayInput.Increment = 100
$script:hideDelayInput.Value = 500
$script:form.Controls.Add($script:hideDelayInput)

$script:hideCursorCheck = New-Object System.Windows.Forms.CheckBox
$script:hideCursorCheck.Text = 'Hide cursor when idle'
$script:hideCursorCheck.Location = [System.Drawing.Point]::new(18, 347)
$script:hideCursorCheck.AutoSize = $true
$script:hideCursorCheck.Checked = $true
$script:form.Controls.Add($script:hideCursorCheck)

$idleHideLabel = New-Object System.Windows.Forms.Label
$idleHideLabel.Text = 'Idle time before hiding cursor (ms):'
$idleHideLabel.Location = [System.Drawing.Point]::new(38, 377)
$idleHideLabel.AutoSize = $true
$script:form.Controls.Add($idleHideLabel)

$script:idleHideInput = New-Object System.Windows.Forms.NumericUpDown
$script:idleHideInput.Location = [System.Drawing.Point]::new(275, 374)
$script:idleHideInput.Size = [System.Drawing.Size]::new(90, 24)
$script:idleHideInput.Minimum = 500
$script:idleHideInput.Maximum = 60000
$script:idleHideInput.Increment = 500
$script:idleHideInput.Value = 3000
$script:form.Controls.Add($script:idleHideInput)

$script:startupTrayCheck = New-Object System.Windows.Forms.CheckBox
$script:startupTrayCheck.Text = 'Start with Windows (with notification-area icon)'
$script:startupTrayCheck.Location = [System.Drawing.Point]::new(18, 407)
$script:startupTrayCheck.AutoSize = $true
$script:form.Controls.Add($script:startupTrayCheck)

$script:startupHeadlessCheck = New-Object System.Windows.Forms.CheckBox
$script:startupHeadlessCheck.Text = 'Start with Windows (no notification-area icon)'
$script:startupHeadlessCheck.Location = [System.Drawing.Point]::new(18, 428)
$script:startupHeadlessCheck.AutoSize = $true
$script:form.Controls.Add($script:startupHeadlessCheck)

$script:logErrorsCheck = New-Object System.Windows.Forms.CheckBox
$script:logErrorsCheck.Text = 'Write errors to errors.log (optional)'
$script:logErrorsCheck.Location = [System.Drawing.Point]::new(18, 449)
$script:logErrorsCheck.AutoSize = $true

# Change to $false if you want logging off until the user enables it
$script:logErrorsCheck.Checked = $true
$script:form.Controls.Add($script:logErrorsCheck)

$script:statusLabel = New-Object System.Windows.Forms.Label
$script:statusLabel.Text = 'Stopped'
$script:statusLabel.Location = [System.Drawing.Point]::new(18, 494)
$script:statusLabel.AutoSize = $true
$script:form.Controls.Add($script:statusLabel)

$script:startButton = New-Object System.Windows.Forms.Button
$script:startButton.Text = 'Start'
$script:startButton.Location = [System.Drawing.Point]::new(306, 482)
$script:startButton.Size = [System.Drawing.Size]::new(86, 34)
$script:form.Controls.Add($script:startButton)

$saveButton = New-Object System.Windows.Forms.Button
$saveButton.Text = 'Save settings'
$saveButton.Location = [System.Drawing.Point]::new(402, 482)
$saveButton.Size = [System.Drawing.Size]::new(86, 34)
$script:form.Controls.Add($saveButton)

$script:stopButton = New-Object System.Windows.Forms.Button
$script:stopButton.Text = 'Stop'
$script:stopButton.Location = [System.Drawing.Point]::new(494, 482)
$script:stopButton.Size = [System.Drawing.Size]::new(86, 34)
$script:stopButton.Enabled = $true
$script:form.Controls.Add($script:stopButton)

$script:notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$script:notifyIcon.Icon = [System.Drawing.SystemIcons]::Application
$script:notifyIcon.Text = 'Desktop Icons App'
$script:notifyIcon.Visible = -not $Headless
$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$showItem = $trayMenu.Items.Add('Open')
$exitItem = $trayMenu.Items.Add('Exit')
$script:notifyIcon.ContextMenuStrip = $trayMenu

$script:timer = New-Object System.Windows.Forms.Timer
$script:timer.Interval = 250
$script:housekeepingTimer = New-Object System.Windows.Forms.Timer
$script:housekeepingTimer.Interval = 150
$script:applicationContext = New-Object System.Windows.Forms.ApplicationContext
$script:housekeepingTimer.Add_Tick({
    try {
        if ($Headless -and $script:headlessStopEvent.WaitOne(0)) {
            try {
                $script:timer.Stop()
                Restore-AppState
                Release-AutomationMutex
                $script:applicationContext.ExitThread()
            } catch {
                Show-AppError "Could not stop headless automation: $($_.Exception.Message)"
                $script:headlessStopEvent.Reset()
            }
        }
        elseif (-not $Headless -and $script:showUiEvent.WaitOne(0)) {
            Show-SettingsWindow
        }
    } catch {
        $script:housekeepingTimer.Stop()
        Show-AppError "Could not process an app instance request: $($_.Exception.Message)"
    }
})

$script:preview.Add_Paint({
    param($sender, $eventArgs)
    $g = $eventArgs.Graphics
    $bounds = Get-PreviewBounds
    $backgroundBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(55, 65, 80))
    $g.FillRectangle($backgroundBrush, $bounds)
    $backgroundBrush.Dispose()
    $g.DrawRectangle([System.Drawing.Pens]::White, $bounds.X, $bounds.Y, $bounds.Width, $bounds.Height)
    for ($i = 0; $i -lt $script:zones.Count; $i++) {
        $zone = $script:zones[$i]
        $rect = [System.Drawing.RectangleF]::new(
            $bounds.X + ($zone.X * $bounds.Width),
            $bounds.Y + ($zone.Y * $bounds.Height),
            $zone.Width * $bounds.Width,
            $zone.Height * $bounds.Height
        )
        $brush = if ($i -eq $script:selectedZone) {
            [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(115, 50, 180, 255))
        } else {
            [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(90, 50, 180, 255))
        }
        $g.FillRectangle($brush, $rect)
        $brush.Dispose()
        $g.DrawRectangle([System.Drawing.Pens]::DeepSkyBlue, $rect.X, $rect.Y, $rect.Width, $rect.Height)
    }
    if ($null -ne $script:dragStart -and $null -ne $script:dragCurrent) {
        $left = [Math]::Min($script:dragStart.X, $script:dragCurrent.X)
        $top = [Math]::Min($script:dragStart.Y, $script:dragCurrent.Y)
        $rect = [System.Drawing.RectangleF]::new(
            $bounds.X + ($left / $script:screenWidth * $bounds.Width),
            $bounds.Y + ($top / $script:screenHeight * $bounds.Height),
            ([Math]::Abs($script:dragCurrent.X - $script:dragStart.X) / $script:screenWidth * $bounds.Width),
            ([Math]::Abs($script:dragCurrent.Y - $script:dragStart.Y) / $script:screenHeight * $bounds.Height)
        )
        $dragBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(80, 255, 200, 70))
        $g.FillRectangle($dragBrush, $rect)
        $dragBrush.Dispose()
        $g.DrawRectangle([System.Drawing.Pens]::Gold, $rect.X, $rect.Y, $rect.Width, $rect.Height)
    }
})

$script:preview.Add_MouseDown({
    param($sender, $eventArgs)
    $bounds = Get-PreviewBounds
    if ($eventArgs.Button -ne [System.Windows.Forms.MouseButtons]::Left -or
        -not $bounds.Contains([single]$eventArgs.X, [single]$eventArgs.Y)) { return }

    $script:dragStart = [System.Drawing.Point]::new(
        [int](($eventArgs.X - $bounds.X) / $bounds.Width * $script:screenWidth),
        [int](($eventArgs.Y - $bounds.Y) / $bounds.Height * $script:screenHeight)
    )
    $script:dragCurrent = $script:dragStart
    $script:preview.Invalidate()
})

$script:preview.Add_MouseMove({
    param($sender, $eventArgs)
    if ($null -eq $script:dragStart) { return }
    $bounds = Get-PreviewBounds
    $script:dragCurrent = [System.Drawing.Point]::new(
        [Math]::Max(0, [Math]::Min($script:screenWidth, [int](($eventArgs.X - $bounds.X) / $bounds.Width * $script:screenWidth))),
        [Math]::Max(0, [Math]::Min($script:screenHeight, [int](($eventArgs.Y - $bounds.Y) / $bounds.Height * $script:screenHeight)))
    )
    $script:preview.Invalidate()
})

$script:preview.Add_MouseUp({
    param($sender, $eventArgs)
    if ($null -eq $script:dragStart) { return }
    $bounds = Get-PreviewBounds
    $script:dragCurrent = [System.Drawing.Point]::new(
        [Math]::Max(0, [Math]::Min($script:screenWidth, [int](($eventArgs.X - $bounds.X) / $bounds.Width * $script:screenWidth))),
        [Math]::Max(0, [Math]::Min($script:screenHeight, [int](($eventArgs.Y - $bounds.Y) / $bounds.Height * $script:screenHeight)))
    )
    $x = [Math]::Min($script:dragStart.X, $script:dragCurrent.X) / [double]$script:screenWidth
    $y = [Math]::Min($script:dragStart.Y, $script:dragCurrent.Y) / [double]$script:screenHeight
    $width = [Math]::Abs($script:dragCurrent.X - $script:dragStart.X) / [double]$script:screenWidth
    $height = [Math]::Abs($script:dragCurrent.Y - $script:dragStart.Y) / [double]$script:screenHeight
    if ($width -ge 0.01 -and $height -ge 0.01) {
        $script:zones += [pscustomobject]@{ X = $x; Y = $y; Width = $width; Height = $height }
        $script:selectedZone = $script:zones.Count - 1
        Update-Preview
    }
    $script:dragStart = $null
    $script:dragCurrent = $null
    $script:preview.Invalidate()
})

$script:zoneList.Add_SelectedIndexChanged({
    $script:selectedZone = $script:zoneList.SelectedIndex
    $script:preview.Invalidate()
})

$removeZone.Add_Click({
    $index = $script:zoneList.SelectedIndex
    if ($index -ge 0) {
        $kept = @()
        for ($i = 0; $i -lt $script:zones.Count; $i++) {
            if ($i -ne $index) { $kept += $script:zones[$i] }
        }
        $script:zones = @($kept)
        $script:selectedZone = -1
        Update-Preview
    }
})

$saveButton.Add_Click({
    try {
        Save-Settings
        $script:statusLabel.Text = if ($script:timer.Enabled) { 'Running — settings saved' } else { 'Settings saved' }
    } catch {
        Show-AppError "Could not save settings: $($_.Exception.Message)"
    }
})

$script:startButton.Add_Click({
    try {
        Start-Automation
    } catch {
        Show-AppError "Could not start: $($_.Exception.Message)"
    }
})

$script:stopButton.Add_Click({
    try {
        $script:headlessStopEvent.Set() | Out-Null
        $script:timer.Stop()
        Restore-AppState
        Release-AutomationMutex
        $script:startButton.Enabled = $true
        $script:stopButton.Enabled = $true
        $script:statusLabel.Text = 'Stopped'
    } catch {
        Show-AppError "Could not restore the desktop state: $($_.Exception.Message)"
    }
})

$script:timer.Add_Tick({
    try {
        # Resolution / display changes are detected by polling (no cross-thread event needed)
        $width = [DesktopIconsAppNative]::ScreenWidth()
        $height = [DesktopIconsAppNative]::ScreenHeight()
        if ($width -gt 0 -and $height -gt 0 -and
            ($width -ne $script:screenWidth -or $height -ne $script:screenHeight)) {
            $script:screenWidth = $width
            $script:screenHeight = $height
            $script:preview.Invalidate()
        }

        # Cursor position is unavailable on the secure desktop: just skip this tick
        $position = [DesktopIconsAppNative]::TryCursorPosition()
        if ($null -eq $position) { return }

        # Re-sync with the real desktop state (Explorer restart, display change)
        $script:iconsVisible = [DesktopIconsAppNative]::AreIconsVisible()

        $x = $position.X / [double]$script:screenWidth
        $y = $position.Y / [double]$script:screenHeight
        $inZone = $false
        if ($script:hideIconsCheck.Checked) {
            foreach ($zone in $script:zones) {
                if ($x -ge $zone.X -and $x -le ($zone.X + $zone.Width) -and
                    $y -ge $zone.Y -and $y -le ($zone.Y + $zone.Height)) {
                    $inZone = $true
                    break
                }
            }
        }

        if (-not $script:hideIconsCheck.Checked -or $script:zones.Count -eq 0) {
            $script:leftZoneAt = $null
            Set-IconsVisible $true
        }
        elseif ($inZone) {
            $script:leftZoneAt = $null
            Set-IconsVisible $true
        }
        elseif ($script:iconsVisible) {
            if ($null -eq $script:leftZoneAt) { $script:leftZoneAt = $script:zoneClock.ElapsedMilliseconds }
            elseif (($script:zoneClock.ElapsedMilliseconds - $script:leftZoneAt) -ge $script:hideDelayInput.Value) {
                Set-IconsVisible $false
            }
        }

        $positionKey = '{0}:{1}' -f $position.X, $position.Y
        if ($positionKey -ne $script:lastCursorPosition -or [DesktopIconsAppNative]::AnyMouseButtonDown()) {
            $script:lastCursorPosition = $positionKey
            $script:activityClock.Restart()
            if ($script:cursorHidden) {
                [DesktopIconsAppNative]::RestoreCursor()
                $script:cursorHidden = $false
                Stop-CursorRecoveryWatcher
            }
        }
        elseif ($script:hideCursorCheck.Checked -and -not $script:cursorHidden -and
            $script:activityClock.ElapsedMilliseconds -ge $script:idleHideInput.Value -and
            $script:zoneClock.ElapsedMilliseconds -ge $script:cursorBackoffUntil) {
            try {
                Start-CursorRecoveryWatcher
                [DesktopIconsAppNative]::HideCursor()
                $script:cursorHidden = $true
            } catch {
                # Don't kill the whole automation over a cursor failure; back off and retry later
                Write-AppLog "Could not hide cursor: $($_.Exception.Message)"
                try { [DesktopIconsAppNative]::RestoreCursor() } catch { }
                $script:cursorHidden = $false
                Stop-CursorRecoveryWatcher
                $script:cursorBackoffUntil = $script:zoneClock.ElapsedMilliseconds + 10000
            }
        }
        elseif (-not $script:hideCursorCheck.Checked -and $script:cursorHidden) {
            [DesktopIconsAppNative]::RestoreCursor()
            $script:cursorHidden = $false
            Stop-CursorRecoveryWatcher
        }

        $script:tickFailures = 0
    } catch {
        # Tolerate transient failures
        $script:tickFailures++
        Write-AppLog "Tick failed ($($script:tickFailures)/$($script:maxTickFailures)): $($_.Exception.Message)"
        if ($script:tickFailures -lt $script:maxTickFailures) { return }

        $script:timer.Stop()
        $message = $_.Exception.Message
        try {
            Restore-AppState
            Release-AutomationMutex
        } catch {
            $message += "`nDesktop restoration also failed: $($_.Exception.Message)"
        }
        $script:startButton.Enabled = $true
        $script:stopButton.Enabled = $true
        $script:statusLabel.Text = 'Error'
        Show-AppError "Automation stopped: $message"
        if ($Headless) { $script:applicationContext.ExitThread() }
    }
})

$showItem.Add_Click({
    Show-SettingsWindow
})

$exitItem.Add_Click({
    $script:headlessStopEvent.Set() | Out-Null
    $script:closingForExit = $true
    $script:form.Close()
})

$script:notifyIcon.Add_DoubleClick({
    Show-SettingsWindow
})

$script:form.Add_Resize({
    if ($script:form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
        $script:form.Hide()
    }
})

$script:form.Add_FormClosing({
    param($sender, $eventArgs)
    # Only intercept the user's own close; never block Windows shutdown / logoff
    if (-not $script:closingForExit -and
        $eventArgs.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
        $eventArgs.Cancel = $true
        $script:form.Hide()
        return
    }
    $script:timer.Stop()
    $script:housekeepingTimer.Stop()
    try {
        Restore-AppState
        Release-AutomationMutex
    } catch {
        if ($eventArgs.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
            $eventArgs.Cancel = $true
            Show-AppError "Could not restore the desktop state: $($_.Exception.Message)"
            return
        }
        # During shutdown/logoff, never block the close
        Write-AppLog "Restore during shutdown failed: $($_.Exception.Message)"
    }
    $script:notifyIcon.Visible = $false
})

$script:form.Add_FormClosed({
    if ($StartInTray) { $script:applicationContext.ExitThread() }
})

$null = $script:form.Handle

# Read the startup mode first so a failure in Load-Settings can never turn into a bogus shortcut
$startupMode = 'None'
$startupModeKnown = $false
try {
    $startupMode = Get-StartupMode
    $startupModeKnown = $true
} catch {
    Write-AppLog "Could not read startup mode: $($_.Exception.Message)"
}
try {
    Load-Settings
    $script:startupTrayCheck.Checked = $startupMode -eq 'Tray'
    $script:startupHeadlessCheck.Checked = $startupMode -eq 'Headless'
    Update-Preview
} catch {
    Show-AppError "Could not load settings: $($_.Exception.Message)"
    if ($Headless -or $StartInTray) { $script:headlessStartFailed = $true }
}
if ($startupModeKnown -and $startupMode -ne 'None') {
    try {
        Set-StartupShortcut $startupMode
    } catch {
        Show-AppError "Could not update the sign-in shortcut for silent startup: $($_.Exception.Message)"
    }
}

$script:updateStartupOptions = {
    if ($script:updatingStartupOptions) { return }
    $mode = if ($script:startupTrayCheck.Checked) { 'Tray' }
        elseif ($script:startupHeadlessCheck.Checked) { 'Headless' }
        else { 'None' }
    $script:updatingStartupOptions = $true
    if ($mode -eq 'Tray') { $script:startupHeadlessCheck.Checked = $false }
    elseif ($mode -eq 'Headless') { $script:startupTrayCheck.Checked = $false }
    $script:updatingStartupOptions = $false
    try {
        Save-Settings
        Set-StartupShortcut $mode
    } catch {
        Show-AppError "Could not update the sign-in shortcut: $($_.Exception.Message)"
        $existingMode = Get-StartupMode
        $script:updatingStartupOptions = $true
        $script:startupTrayCheck.Checked = $existingMode -eq 'Tray'
        $script:startupHeadlessCheck.Checked = $existingMode -eq 'Headless'
        $script:updatingStartupOptions = $false
    }
}
$script:updatingStartupOptions = $false
$script:startupTrayCheck.Add_CheckedChanged($script:updateStartupOptions)
$script:startupHeadlessCheck.Add_CheckedChanged($script:updateStartupOptions)
$script:logErrorsCheck.Add_CheckedChanged({
    $script:writeErrorLog = $script:logErrorsCheck.Checked -and -not $DisableErrorLog
    try {
        Save-Settings
    } catch {
        $script:logErrorsCheck.Checked = -not $script:logErrorsCheck.Checked
        $script:writeErrorLog = $script:logErrorsCheck.Checked -and -not $DisableErrorLog
        Show-AppError "Could not save error-log preference: $($_.Exception.Message)"
    }
})

if ($Headless -or $StartInTray) {
    if (-not $script:headlessStartFailed) {
        try {
            if (-not (Try-AcquireAutomationMutex)) {
                if ($Headless) {
                    $script:closingForExit = $true
                    $script:headlessStopEvent.Dispose()
                    $script:showUiEvent.Dispose()
                    $script:automationMutex.Dispose()
                    exit 0
                }
                throw 'The desktop effects are already running in another app instance.'
            }
            $script:ownsAutomationMutex = $true
            $script:headlessStopEvent.Reset()
            Start-Automation
        } catch {
            Release-AutomationMutex
            Show-AppError "Could not start: $($_.Exception.Message)"
            if ($Headless) { $script:headlessStartFailed = $true }
        }
    }
}

# Needed in every mode: headless instances use it to notice the stop request
# UI instances use it to notice "show settings" requests from a second launch
$script:housekeepingTimer.Start()

try {
    if (-not ($Headless -and $script:headlessStartFailed)) {
        if ($Headless -or $StartInTray) {
            [System.Windows.Forms.Application]::Run($script:applicationContext)
        } else {
            [System.Windows.Forms.Application]::Run($script:form)
        }
    }
} finally {
    if ($script:ownsAutomationMutex) { Release-AutomationMutex }
    if ($script:uiMutex) {
        $script:uiMutex.ReleaseMutex()
        $script:uiMutex.Dispose()
    }
    $script:timer.Dispose()
    $script:housekeepingTimer.Dispose()
    $script:notifyIcon.Visible = $false
    $script:notifyIcon.Dispose()
    $script:form.Dispose()
    $script:applicationContext.Dispose()
    $script:automationMutex.Dispose()
    $script:showUiEvent.Dispose()
    $script:headlessStopEvent.Dispose()
}