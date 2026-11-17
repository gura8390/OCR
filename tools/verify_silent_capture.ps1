#requires -version 5.1
[CmdletBinding()]
param(
    [string]$Executable,
    [string]$Output,
    [string]$Fixture
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($PSVersionTable.PSEdition -ne 'Desktop' -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    throw 'Use Windows PowerShell 5.1 in STA mode: powershell.exe -NoProfile -STA -File.'
}
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms, System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class WfSilentQa {
    private delegate bool EnumProc(IntPtr window, IntPtr parameter);
    private delegate void WinEventProc(IntPtr hook, uint eventId, IntPtr window, int objectId, int childId, uint threadId, uint time);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string className, string title);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc callback, IntPtr parameter);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetWindowText(IntPtr window, StringBuilder text, int capacity);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetClassName(IntPtr window, StringBuilder text, int capacity);
    [DllImport("user32.dll", SetLastError=true)] private static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr module, WinEventProc callback, uint process, uint thread, uint flags);
    [DllImport("user32.dll")] private static extern bool UnhookWinEvent(IntPtr hook);
    private static readonly WinEventProc recorder = Record;
    private static IntPtr hook;
    private static int target;
    private static readonly List<uint> shows = new List<uint>();
    private static bool IsMain(IntPtr window) {
        uint process; GetWindowThreadProcessId(window, out process);
        if (process != target) return false;
        var type = new StringBuilder(128); GetClassName(window, type, type.Capacity);
        var title = new StringBuilder(256); GetWindowText(window, title, title.Capacity);
        return type.ToString() == "Window Class" || title.ToString().StartsWith("文字识别");
    }
    private static void Record(IntPtr hook, uint eventId, IntPtr window, int objectId, int childId, uint threadId, uint time) {
        if (eventId == 0x8002 && objectId == 0 && childId == 0 && IsMain(window)) shows.Add(time);
    }
    public static void Start(int process) {
        target = process; shows.Clear();
        hook = SetWinEventHook(0x8002, 0x8002, IntPtr.Zero, recorder, (uint)process, 0, 0);
        if (hook == IntPtr.Zero) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    }
    public static int ShowCount { get { return shows.Count; } }
    public static void ResetShows() { shows.Clear(); }
    public static void Stop() { if (hook != IntPtr.Zero) { UnhookWinEvent(hook); hook = IntPtr.Zero; } }
    public static IntPtr MainWindow() {
        IntPtr result = IntPtr.Zero;
        EnumWindows(delegate(IntPtr window, IntPtr parameter) {
            if (IsMain(window)) { result = window; return false; }
            return true;
        }, IntPtr.Zero);
        return result;
    }
}
'@

$project = Split-Path -Parent $PSScriptRoot
if (-not $Executable) { $Executable = Join-Path $project 'target\release\wf-zi-ui-bp.exe' }
if (-not $Fixture) { $Fixture = Join-Path $project 'verification\fixtures\compact.png' }
$Executable = (Resolve-Path -LiteralPath $Executable).Path
$Fixture = (Resolve-Path -LiteralPath $Fixture).Path
$outputFile = if ($Output) { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Output) } else { $null }
$script:Process = $null
$script:MainWindow = [IntPtr]::Zero
$script:Checks = New-Object 'System.Collections.Generic.List[object]'
$script:OwnedClipboardSequence = $null
$script:ClipboardBackup = $null
$script:ClipboardSaved = $false
$script:Report = [ordered]@{
    executable_sha256 = (Get-FileHash -LiteralPath $Executable -Algorithm SHA256).Hash.ToLowerInvariant()
    fixture_sha256 = (Get-FileHash -LiteralPath $Fixture -Algorithm SHA256).Hash.ToLowerInvariant()
    method = 'Windows UI Automation, native window and WinEvent visibility checks, isolated profile, synthetic clipboard image, shared capture worker'
    capture_entry = 'app --clipboard uses the same background worker and result handler as F4 after image capture'
    checks = $script:Checks
    success = $false
}

function Add-Check([string]$Name, $Detail) { $script:Checks.Add([ordered]@{ name = $Name; detail = $Detail }) }
function Pump { [System.Windows.Forms.Application]::DoEvents() }
function Get-ControlOwner {
    $window = [WfSilentQa]::FindWindow('WfZiUiBp_Desktop', 'WfZiUiBp_Desktop')
    [uint32]$owner = 0
    if ($window -ne [IntPtr]::Zero) { [void][WfSilentQa]::GetWindowThreadProcessId($window, [ref]$owner) }
    return $owner
}
function Start-Tool([string[]]$Arguments) {
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $Executable
    $info.WorkingDirectory = Split-Path -Parent $Executable
    $info.Arguments = ($Arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    return [System.Diagnostics.Process]::Start($info)
}
function Send-Command([string[]]$Arguments) {
    if ((Get-ControlOwner) -ne $script:Process.Id) { throw 'The control window does not belong to the isolated process.' }
    $client = Start-Tool $Arguments
    try {
        if (-not $client.WaitForExit(5000)) { $client.Kill(); throw 'The CLI command timed out.' }
        if ($client.ExitCode -ne 0) { throw 'The CLI command failed.' }
    } finally { $client.Dispose() }
    Pump
}
function Assert-Hidden([switch]$NoMain) {
    Pump
    if ($script:Process.HasExited) { throw 'The isolated process exited during background recognition.' }
    $window = [WfSilentQa]::MainWindow()
    if ($NoMain -and $window -ne [IntPtr]::Zero) { throw 'Cold background recognition created a main window.' }
    if (-not $NoMain -and ($window -ne $script:MainWindow -or -not [WfSilentQa]::IsWindow($window))) { throw 'The original main window was replaced or destroyed.' }
    if ($window -ne [IntPtr]::Zero -and [WfSilentQa]::IsWindowVisible($window)) { throw 'Background recognition displayed the main window.' }
    if ([WfSilentQa]::ShowCount -ne 0) { throw 'WinEvent recorded a main-window show event during background recognition.' }
}
function Wait-For([scriptblock]$Probe, [string]$Description, [int]$Seconds = 20, [switch]$Hidden, [switch]$NoMain) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($clock.Elapsed.TotalSeconds -lt $Seconds) {
        Pump
        if ($script:Process.HasExited) { throw "The isolated process exited while waiting for $Description." }
        if ($Hidden) { Assert-Hidden -NoMain:$NoMain }
        try {
            $value = & $Probe
            if ($value) { return $value }
        } catch [System.Windows.Automation.ElementNotAvailableException] {}
        Start-Sleep -Milliseconds 60
    }
    throw "Timed out waiting for $Description."
}
function Get-AppWindow {
    $window = [WfSilentQa]::MainWindow()
    if ($window -ne [IntPtr]::Zero -and [WfSilentQa]::IsWindowVisible($window)) {
        return [System.Windows.Automation.AutomationElement]::FromHandle($window)
    }
}
function Get-Controls {
    $window = Get-AppWindow
    if ($null -ne $window) { $window.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) }
}
function Get-Pattern($Control, $Pattern) {
    $provider = $null
    if ($Control.TryGetCurrentPattern($Pattern, [ref]$provider)) { return $provider }
}
function Get-ControlName($Control) {
    $name = $Control.Current.Name
    if ($name) { return $name }
    $label = $Control.Current.LabeledBy
    if ($null -ne $label) { return $label.Current.Name }
    return ''
}
function Find-Control([string]$Name, [switch]$Actionable) {
    foreach ($control in Get-Controls) {
        try {
            if ((Get-ControlName $control) -notmatch $Name -or $control.Current.IsOffscreen) { continue }
            if (-not $Actionable) { return $control }
            if (-not $control.Current.IsEnabled) { continue }
            foreach ($pattern in @([System.Windows.Automation.InvokePattern]::Pattern, [System.Windows.Automation.SelectionItemPattern]::Pattern, [System.Windows.Automation.TogglePattern]::Pattern)) {
                if ($null -ne (Get-Pattern $control $pattern)) { return $control }
            }
        } catch [System.Windows.Automation.ElementNotAvailableException] {}
    }
}
function Invoke-Control([string]$Name) {
    $control = Wait-For { Find-Control $Name -Actionable } "the semantic control $Name"
    $invoke = Get-Pattern $control ([System.Windows.Automation.InvokePattern]::Pattern)
    $select = Get-Pattern $control ([System.Windows.Automation.SelectionItemPattern]::Pattern)
    $toggle = Get-Pattern $control ([System.Windows.Automation.TogglePattern]::Pattern)
    if ($null -ne $invoke) { $invoke.Invoke(); return }
    if ($null -ne $select) { $select.Select(); return }
    if ($null -ne $toggle) { $toggle.Toggle(); return }
    throw 'The control lost its semantic action.'
}
function Find-Result {
    foreach ($control in Get-Controls) {
        try {
            if ($control.Current.ControlType -ne [System.Windows.Automation.ControlType]::Edit -or $control.Current.IsOffscreen) { continue }
            $pattern = Get-Pattern $control ([System.Windows.Automation.TextPattern]::Pattern)
            if ($null -ne $pattern) {
                $text = $pattern.DocumentRange.GetText(-1)
                if (($text -replace '\s', '') -match '离线文字识别') { return $text }
            }
        } catch [System.Windows.Automation.ElementNotAvailableException] {}
    }
}
function Show-App {
    Send-Command @('--show')
    [void](Wait-For { Get-AppWindow } 'the explicitly opened main window')
    $script:MainWindow = [WfSilentQa]::MainWindow()
}
function Show-History {
    Invoke-Control '^截图OCR$'
    Invoke-Control '^记录$'
    return Wait-For { Find-Result } 'the result through UI Automation TextPattern'
}
function Open-GlobalSettings {
    Invoke-Control '^(新标签页|新建标签页（Ctrl\+T）)$'
    [void](Wait-For { Find-Control '^功能页$' } 'the feature chooser')
    Invoke-Control '^全局设置$'
    Invoke-Control '^截图$'
}
function Set-CopyToggle([bool]$Enabled) {
    $control = Wait-For { Find-Control '^识别后复制结果$' -Actionable } 'the copy-result settings toggle' 5
    $toggle = Get-Pattern $control ([System.Windows.Automation.TogglePattern]::Pattern)
    if ($null -eq $toggle) { throw 'The copy-result control does not expose TogglePattern.' }
    if (($toggle.Current.ToggleState -eq [System.Windows.Automation.ToggleState]::On) -ne $Enabled) { $toggle.Toggle() }
    [void](Wait-For {
        $value = Get-Content -LiteralPath $profile -Raw | ConvertFrom-Json
        $value.auto_copy -eq $Enabled
    } 'the copy-result setting persisted in the isolated profile')
    $control = Wait-For { Find-Control '^识别后复制结果$' -Actionable } 'the copy-result toggle readback'
    $toggle = Get-Pattern $control ([System.Windows.Automation.TogglePattern]::Pattern)
    if (($toggle.Current.ToggleState -eq [System.Windows.Automation.ToggleState]::On) -ne $Enabled) { throw 'The copy-result toggle state did not match its saved value.' }
}
function Close-ToTray {
    $window = Get-AppWindow
    $pattern = Get-Pattern $window ([System.Windows.Automation.WindowPattern]::Pattern)
    if ($null -ne $pattern) { $pattern.Close() }
    else { Invoke-Control '^(Close|关闭)$' }
    [void](Wait-For { -not [WfSilentQa]::IsWindowVisible($script:MainWindow) } 'the main window closed to the tray')
    Start-Sleep -Milliseconds 180
    Pump
    [WfSilentQa]::ResetShows()
    Assert-Hidden
}
function Put-FixtureOnClipboard {
    $bitmap = [Drawing.Bitmap]::new($Fixture)
    try { [Windows.Forms.Clipboard]::SetImage($bitmap) } finally { $bitmap.Dispose() }
    $script:OwnedClipboardSequence = [WfSilentQa]::GetClipboardSequenceNumber()
}
function Read-TestClipboard {
    if ([Windows.Forms.Clipboard]::ContainsText()) {
        $text = [Windows.Forms.Clipboard]::GetText()
        if (($text -replace '\s', '') -match '离线文字识别') {
            $script:OwnedClipboardSequence = [WfSilentQa]::GetClipboardSequenceNumber()
            return $text
        }
    }
}
function Recognize-Hidden([string]$Name, [switch]$NoMain) {
    Put-FixtureOnClipboard
    [WfSilentQa]::ResetShows()
    Assert-Hidden -NoMain:$NoMain
    Send-Command @('--clipboard')
    $text = Wait-For { Read-TestClipboard } 'the background OCR clipboard result' 30 -Hidden -NoMain:$NoMain
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($clock.Elapsed.TotalMilliseconds -lt 350) { Assert-Hidden -NoMain:$NoMain; Start-Sleep -Milliseconds 40 }
    Add-Check $Name ([ordered]@{ result = $text; main_window_created = -not $NoMain; show_events = [WfSilentQa]::ShowCount; retained_same_process = (Get-ControlOwner) -eq $script:Process.Id })
}
function Save-Report {
    $json = $script:Report | ConvertTo-Json -Depth 8
    if ($outputFile) {
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($outputFile))
        [IO.File]::WriteAllText($outputFile, "$json`r`n", [Text.UTF8Encoding]::new($false))
    }
    $json
}

$testDir = Join-Path ([IO.Path]::GetTempPath()) ('wfziuibp-silent-' + [guid]::NewGuid().ToString('N'))
try {
    if ((Get-ControlOwner) -ne 0) { throw 'A WfZiUiBp desktop instance is already running. Close it before this isolated test.' }
    $script:ClipboardBackup = [Windows.Forms.Clipboard]::GetDataObject()
    if ($null -ne $script:ClipboardBackup) {
        $saved = [Windows.Forms.DataObject]::new()
        foreach ($format in $script:ClipboardBackup.GetFormats($false)) {
            $data = $script:ClipboardBackup.GetData($format, $false)
            if ($null -ne $data) { $saved.SetData($format, $false, $data) }
        }
        $script:ClipboardBackup = $saved
    }
    $script:ClipboardSaved = $true
    [void][IO.Directory]::CreateDirectory($testDir)
    $profile = Join-Path $testDir 'profile.json'
    [IO.File]::WriteAllText($profile, '{"hotkey":false,"auto_copy":true,"tray":true,"window_top":false,"tabs_locked":false,"startup_hidden":false}')
    $script:Process = Start-Tool @('--hide', '--profile', $profile, '--no-hotkey')
    [void](Wait-For { (Get-ControlOwner) -eq $script:Process.Id } 'the isolated native control window')
    [WfSilentQa]::Start($script:Process.Id)
    Recognize-Hidden 'cold tray recognition copies without creating a main window' -NoMain

    Show-App
    $text = Show-History
    Add-Check 'explicit show exposes cold result through TextPattern' $text
    Open-GlobalSettings
    Set-CopyToggle $false
    Set-CopyToggle $true
    Add-Check 'copy setting supports TogglePattern and persists both values' @($false, $true)
    [void](Show-History)
    Close-ToTray
    Recognize-Hidden 'warm tray recognition copies without showing the same main window'
    Recognize-Hidden 'repeated warm recognition remains hidden'

    Show-App
    [void](Show-History)
    Invoke-Control '^清空记录$'
    [void](Wait-For { Find-Control '^暂无记录$' } 'the cleared history')
    Open-GlobalSettings
    Set-CopyToggle $false
    Invoke-Control '^截图OCR$'
    Close-ToTray
    Send-Command @('--reload')
    Put-FixtureOnClipboard
    Send-Command @('--clipboard')
    [void](Wait-For { Get-AppWindow } 'the result window with automatic copying disabled')
    $text = Wait-For { Find-Result } 'the newly recognized result with automatic copying disabled' 30
    if (-not [Windows.Forms.Clipboard]::ContainsImage() -or [WfSilentQa]::GetClipboardSequenceNumber() -ne $script:OwnedClipboardSequence) { throw 'Disabling automatic copying changed the input clipboard image.' }
    Add-Check 'disabling auto copy shows results and keeps the clipboard image' $text

    Open-GlobalSettings
    Set-CopyToggle $true
    Invoke-Control '^截图OCR$'
    Close-ToTray
    Start-Sleep -Milliseconds 500
    $script:Process.Refresh()
    $startCpu = $script:Process.TotalProcessorTime
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($clock.Elapsed.TotalSeconds -lt 5) { Assert-Hidden; Start-Sleep -Milliseconds 60 }
    $clock.Stop()
    $script:Process.Refresh()
    $cpuMs = ($script:Process.TotalProcessorTime - $startCpu).TotalMilliseconds
    $rate = $cpuMs / $clock.Elapsed.TotalSeconds
    Add-Check 'tray idle CPU after repeated recognition' ([ordered]@{ cpu_ms = $cpuMs; wall_ms = [Math]::Round($clock.Elapsed.TotalMilliseconds, 3); cpu_ms_per_wall_second = [Math]::Round($rate, 3); limit_cpu_ms_per_wall_second = 150; passed = $rate -lt 150; show_events = [WfSilentQa]::ShowCount })
    if ($rate -ge 150) { throw 'Tray idle CPU exceeded 150 CPU milliseconds per wall second.' }
    Show-App
    [void](Show-History)
    Add-Check 'explicit show restores after all hidden operations' 'same native window and same process'
    Send-Command @('--quit')
    if (-not $script:Process.WaitForExit(5000)) { throw 'The app did not exit after the explicit quit command.' }
    Add-Check 'explicit quit exits the isolated process' $true
    $script:Report.success = $true
} catch {
    $script:Report.error = $_.Exception.Message
    try {
        $script:Report.controls = @(Get-Controls | Select-Object -First 180 | ForEach-Object {
            try {
                $label = $_.Current.LabeledBy
                [ordered]@{
                    name = $_.Current.Name
                    labelled_by = if ($null -ne $label) { $label.Current.Name } else { $null }
                    type = $_.Current.ControlType.ProgrammaticName
                    visible = -not $_.Current.IsOffscreen
                    patterns = @($_.GetSupportedPatterns() | ForEach-Object ProgrammaticName)
                }
            } catch [System.Windows.Automation.ElementNotAvailableException] {}
        })
    } catch { $script:Report.control_inventory_error = 'The UI Automation provider was unavailable during diagnostics.' }
    throw
} finally {
    [WfSilentQa]::Stop()
    if ($null -ne $script:Process) {
        try {
            if (-not $script:Process.HasExited -and (Get-ControlOwner) -eq $script:Process.Id) { Send-Command @('--quit') }
        } catch { Write-Warning 'The isolated app could not be closed through its CLI.' }
        if (-not $script:Process.WaitForExit(3000)) { $script:Process.Kill(); [void]$script:Process.WaitForExit(3000) }
        $script:Process.Dispose()
    }
    if ($script:ClipboardSaved -and $null -ne $script:OwnedClipboardSequence) {
        if ([WfSilentQa]::GetClipboardSequenceNumber() -eq $script:OwnedClipboardSequence) {
            try {
                if ($null -eq $script:ClipboardBackup) { [Windows.Forms.Clipboard]::Clear() }
                else { [Windows.Forms.Clipboard]::SetDataObject($script:ClipboardBackup, $true) }
                $script:Report.clipboard_restored = $true
            } catch { $script:Report.clipboard_restored = $false; $script:Report.clipboard_restore_error = 'The clipboard was occupied during restoration.' }
        } else { $script:Report.clipboard_restored = $false; $script:Report.clipboard_restore_reason = 'The clipboard changed after the last test-owned write, so the newer value was preserved.' }
    }
    if (Test-Path -LiteralPath $testDir -PathType Container) {
        foreach ($name in @('profile.json', 'profile.json.tmp')) {
            $file = Join-Path $testDir $name
            if (Test-Path -LiteralPath $file -PathType Leaf) { Remove-Item -LiteralPath $file }
        }
        if (-not (Get-ChildItem -LiteralPath $testDir -Force)) { Remove-Item -LiteralPath $testDir }
    }
    Save-Report
}
