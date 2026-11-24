#requires -version 5.1
[CmdletBinding()]
param(
    [string]$Executable,
    [string]$Models,
    [string]$Fixture,
    [string]$Output,
    [int]$IdleSeconds = 3,
    [switch]$Baseline
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($PSVersionTable.PSEdition -ne 'Desktop' -or [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    throw 'Use Windows PowerShell 5.1 in STA mode: powershell.exe -NoProfile -STA -File.'
}

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class WfIdleQa {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr FindWindow(string className, string title);
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll")]
    public static extern uint GetClipboardSequenceNumber();
}
'@

$project = Split-Path -Parent $PSScriptRoot
if (-not $Executable) { $Executable = Join-Path $project 'target\release\wf-zi-ui-bp.exe' }
if (-not $Models) { $Models = Join-Path $project 'models' }
if (-not $Fixture) { $Fixture = Join-Path $project 'verification\fixtures\compact.png' }
$Executable = (Resolve-Path -LiteralPath $Executable).Path
$Models = (Resolve-Path -LiteralPath $Models).Path
$Fixture = (Resolve-Path -LiteralPath $Fixture).Path
$outputFile = if ($Output) { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Output) } else { $null }

$script:Checks = New-Object 'System.Collections.Generic.List[object]'
$script:ClipboardBackup = $null
$script:ClipboardSaved = $false
$script:OwnedClipboardSequence = $null

function Add-Check([string]$Name, $Detail) {
    $script:Checks.Add([ordered]@{ name = $Name; detail = $Detail })
}

function Get-ControlOwner {
    $window = [WfIdleQa]::FindWindow('WfZiUiBp_Desktop', 'WfZiUiBp_Desktop')
    [uint32]$owner = 0
    if ($window -ne [IntPtr]::Zero) {
        [void][WfIdleQa]::GetWindowThreadProcessId($window, [ref]$owner)
    }
    return $owner
}

function Save-Clipboard {
    try {
        $data = [System.Windows.Forms.Clipboard]::GetDataObject()
        if ($null -ne $data) {
            $formats = $data.GetFormats()
            $saved = @{}
            foreach ($fmt in $formats) {
                try {
                    $val = $data.GetData($fmt)
                    if ($null -ne $val) { $saved[$fmt] = $val }
                } catch {}
            }
            if ($saved.Count -gt 0) {
                $script:ClipboardBackup = $saved
            }
        }
        $script:ClipboardSaved = $true
    } catch {
        $script:ClipboardSaved = $false
    }
}

function Restore-Clipboard {
    if (-not $script:ClipboardSaved) { return }
    if ($null -ne $script:OwnedClipboardSequence -and [WfIdleQa]::GetClipboardSequenceNumber() -ne $script:OwnedClipboardSequence) {
        return
    }
    try {
        if ($null -eq $script:ClipboardBackup) {
            [System.Windows.Forms.Clipboard]::Clear()
        } else {
            $obj = New-Object System.Windows.Forms.DataObject
            foreach ($key in $script:ClipboardBackup.Keys) {
                try { $obj.SetData($key, $script:ClipboardBackup[$key]) } catch {}
            }
            [System.Windows.Forms.Clipboard]::SetDataObject($obj, $true)
        }
    } catch {}
}

function Set-ClipboardImageFromFile([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $ms = New-Object IO.MemoryStream(,$bytes)
    try {
        $img = [System.Drawing.Image]::FromStream($ms)
        try {
            $bmp = New-Object System.Drawing.Bitmap($img)
            try {
                [System.Windows.Forms.Clipboard]::SetImage($bmp)
                $script:OwnedClipboardSequence = [WfIdleQa]::GetClipboardSequenceNumber()
            } finally { $bmp.Dispose() }
        } finally { $img.Dispose() }
    } finally { $ms.Dispose() }
}

function Start-App([string[]]$Arguments) {
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $Executable
    $info.WorkingDirectory = Split-Path -Parent $Executable
    $info.Arguments = ($Arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    return [System.Diagnostics.Process]::Start($info)
}

function Send-Command([int]$OwnerPid, [string[]]$Arguments) {
    if ((Get-ControlOwner) -ne $OwnerPid) {
        throw "Control window does not belong to PID $OwnerPid."
    }
    $client = Start-App $Arguments
    try {
        if (-not $client.WaitForExit(5000)) { $client.Kill(); throw 'CLI command timed out.' }
        if ($client.ExitCode -ne 0) { throw "CLI command failed with exit code $($client.ExitCode)." }
    } finally { $client.Dispose() }
}

function Get-ChildWorkers([int]$ParentPid) {
    $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $ParentPid" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*--ocr-worker*' })
    return ,$children
}

function Measure-Tree([int]$ParentPid) {
    $parent = Get-Process -Id $ParentPid -ErrorAction Stop
    $parent.Refresh()
    $children = Get-ChildWorkers $ParentPid
    $childList = @()
    $childWs = [int64]0
    $childPm = [int64]0
    foreach ($c in $children) {
        try {
            $cp = Get-Process -Id ([int]$c.ProcessId) -ErrorAction Stop
            $cp.Refresh()
            $childWs += $cp.WorkingSet64
            $childPm += $cp.PrivateMemorySize64
            $childList += [ordered]@{
                pid = [int]$c.ProcessId
                working_set_mib = [math]::Round($cp.WorkingSet64 / 1MB, 2)
                private_mib = [math]::Round($cp.PrivateMemorySize64 / 1MB, 2)
            }
        } catch {}
    }
    return [ordered]@{
        parent_pid = $ParentPid
        parent_working_set_mib = [math]::Round($parent.WorkingSet64 / 1MB, 2)
        parent_private_mib = [math]::Round($parent.PrivateMemorySize64 / 1MB, 2)
        worker_count = $childList.Count
        workers = $childList
        total_working_set_mib = [math]::Round(($parent.WorkingSet64 + $childWs) / 1MB, 2)
        total_private_mib = [math]::Round(($parent.PrivateMemorySize64 + $childPm) / 1MB, 2)
    }
}

function Wait-ClipboardText([uint32]$BeforeSeq, [int]$TimeoutMs = 15000) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if ([WfIdleQa]::GetClipboardSequenceNumber() -ne $BeforeSeq) {
            try {
                if ([System.Windows.Forms.Clipboard]::ContainsText()) {
                    $text = [System.Windows.Forms.Clipboard]::GetText()
                    if ($text -and $text.Trim().Length -gt 0) {
                        $script:OwnedClipboardSequence = [WfIdleQa]::GetClipboardSequenceNumber()
                        return $text
                    }
                }
            } catch {}
        }
        Start-Sleep -Milliseconds 50
    }
    throw 'Timed out waiting for OCR clipboard text.'
}

function Reserve-Port {
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    $listener.Stop()
    return $port
}

$report = [ordered]@{
    executable = $Executable
    executable_sha256 = (Get-FileHash -LiteralPath $Executable -Algorithm SHA256).Hash.ToLowerInvariant()
    fixture_sha256 = (Get-FileHash -LiteralPath $Fixture -Algorithm SHA256).Hash.ToLowerInvariant()
    baseline = [bool]$Baseline
    idle_seconds = $IdleSeconds
    checks = $script:Checks
    success = $false
}

$tempDir = Join-Path ([IO.Path]::GetTempPath()) ('wf-idle-qa-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $tempDir -Force
$profilePath = Join-Path $tempDir 'settings.json'
Save-Clipboard

$desktopProc = $null
$serverProc = $null
try {
    if ((Get-ControlOwner) -ne 0) {
        throw 'Another WfZiUiBp desktop instance is already running. Exit it before running this test.'
    }

    # --- Part 1: Desktop tray mode ---
    $desktopArgs = @('--hide', '--no-hotkey', '--profile', $profilePath, '--models', $Models)
    if (-not $Baseline) {
        $desktopArgs += @('--idle-seconds', "$IdleSeconds")
    }
    $desktopProc = Start-App $desktopArgs
    $waitSw = [Diagnostics.Stopwatch]::StartNew()
    while ((Get-ControlOwner) -ne $desktopProc.Id) {
        if ($desktopProc.HasExited) { throw 'Desktop process exited during startup.' }
        if ($waitSw.ElapsedMilliseconds -gt 10000) { throw 'Timed out waiting for desktop control window.' }
        Start-Sleep -Milliseconds 50
    }
    Start-Sleep -Milliseconds 400
    $trayBefore = Measure-Tree $desktopProc.Id
    Add-Check 'tray_before_ocr' $trayBefore

    Set-ClipboardImageFromFile $Fixture
    $seq1 = [WfIdleQa]::GetClipboardSequenceNumber()
    Send-Command $desktopProc.Id @('--clipboard')
    $text1 = Wait-ClipboardText $seq1
    if ($text1 -notmatch '测试|识别|OCR|2026|文字|compact|Hello|Windows' -and $text1.Trim().Length -lt 2) {
        throw "Unexpected first OCR text: $text1"
    }
    Start-Sleep -Milliseconds 200
    $trayActive = Measure-Tree $desktopProc.Id
    if (-not $Baseline -and $trayActive.worker_count -ne 1) {
        throw "Expected 1 active OCR worker subprocess after first OCR, found $($trayActive.worker_count)."
    }
    Add-Check 'tray_after_first_ocr' ([ordered]@{
        text_length = $text1.Length
        sample = $text1.Substring(0, [math]::Min(40, $text1.Length))
        memory = $trayActive
    })

    Start-Sleep -Seconds ($IdleSeconds + 3)
    $trayAfterIdle = Measure-Tree $desktopProc.Id
    if (-not $Baseline) {
        if ($trayAfterIdle.worker_count -ne 0) {
            throw "OCR worker subprocess did not exit after idle timeout (worker_count=$($trayAfterIdle.worker_count))."
        }
        if ($trayAfterIdle.total_working_set_mib -gt 35) {
            throw "Total working set after idle unload remained too high: $($trayAfterIdle.total_working_set_mib) MiB."
        }
        if ($trayAfterIdle.total_private_mib -gt 35) {
            throw "Total private memory after idle unload remained too high: $($trayAfterIdle.total_private_mib) MiB."
        }
    }
    Add-Check 'tray_after_idle_unload' $trayAfterIdle

    # Sample 3 seconds of idle CPU after unload
    $desktopProc.Refresh()
    $cpuStart = $desktopProc.TotalProcessorTime
    $cpuSw = [Diagnostics.Stopwatch]::StartNew()
    Start-Sleep -Seconds 3
    $cpuSw.Stop()
    $desktopProc.Refresh()
    $cpuDeltaMs = [math]::Round(($desktopProc.TotalProcessorTime - $cpuStart).TotalMilliseconds, 3)
    Add-Check 'tray_idle_cpu_after_unload' ([ordered]@{
        wall_ms = [math]::Round($cpuSw.Elapsed.TotalMilliseconds, 3)
        cpu_ms = $cpuDeltaMs
    })

    # Second OCR after unload verifies seamless worker respawn
    Set-ClipboardImageFromFile $Fixture
    $seq2 = [WfIdleQa]::GetClipboardSequenceNumber()
    Send-Command $desktopProc.Id @('--clipboard')
    $text2 = Wait-ClipboardText $seq2
    if ($text2 -ne $text1) {
        throw "OCR result after respawn differed from first run."
    }
    Start-Sleep -Milliseconds 200
    $trayRespawn = Measure-Tree $desktopProc.Id
    if (-not $Baseline -and $trayRespawn.worker_count -ne 1) {
        throw "Expected 1 respawned OCR worker subprocess after second OCR, found $($trayRespawn.worker_count)."
    }
    Add-Check 'tray_after_respawn_ocr' ([ordered]@{
        matches_first = ($text2 -eq $text1)
        memory = $trayRespawn
    })

    # Clean exit closes both parent and worker
    $workerPidBeforeQuit = if ($trayRespawn.worker_count -gt 0) { $trayRespawn.workers[0].pid } else { 0 }
    Send-Command $desktopProc.Id @('--quit')
    if (-not $desktopProc.WaitForExit(8000)) {
        throw 'Desktop process did not exit on --quit.'
    }
    Start-Sleep -Milliseconds 300
    $workerAliveAfterQuit = $false
    if ($workerPidBeforeQuit -gt 0) {
        $workerAliveAfterQuit = $null -ne (Get-Process -Id $workerPidBeforeQuit -ErrorAction SilentlyContinue)
        if ($workerAliveAfterQuit) {
            throw "OCR worker PID $workerPidBeforeQuit remained alive after parent --quit."
        }
    }
    Add-Check 'tray_clean_exit' ([ordered]@{
        parent_exit_code = $desktopProc.ExitCode
        worker_pid_before_quit = $workerPidBeforeQuit
        worker_alive_after_quit = $workerAliveAfterQuit
    })
    $desktopProc = $null

    # --- Part 2: HTTP server mode ---
    $port = Reserve-Port
    $serveArgs = @('--serve', '--no-hotkey', '--port', "$port", '--models', $Models)
    if (-not $Baseline) {
        $serveArgs += @('--idle-seconds', "$IdleSeconds")
    }
    $serverProc = Start-App $serveArgs
    $readySw = [Diagnostics.Stopwatch]::StartNew()
    $ready = $false
    while ($readySw.ElapsedMilliseconds -lt 10000) {
        if ($serverProc.HasExited) { throw 'HTTP server exited during startup.' }
        try {
            $resp = Invoke-RestMethod -Uri "http://127.0.0.1:$port/" -TimeoutSec 2
            if ($resp) { $ready = $true; break }
        } catch {}
        Start-Sleep -Milliseconds 100
    }
    if (-not $ready) { throw 'HTTP server did not become ready.' }

    $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($Fixture))
    $payload = @{ base64 = $b64; options = @{ 'data.format' = 'text' } } | ConvertTo-Json -Compress
    $http1 = Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$port/api/ocr" -Body $payload -ContentType 'application/json' -TimeoutSec 20
    if ($http1.code -ne 100) { throw "HTTP OCR failed: $($http1 | ConvertTo-Json -Compress)" }
    Start-Sleep -Milliseconds 200
    $httpActive = Measure-Tree $serverProc.Id
    if (-not $Baseline -and $httpActive.worker_count -ne 1) {
        throw "Expected 1 active OCR worker under HTTP server, found $($httpActive.worker_count)."
    }
    Add-Check 'http_after_first_ocr' ([ordered]@{
        code = $http1.code
        memory = $httpActive
    })

    Start-Sleep -Seconds ($IdleSeconds + 3)
    $httpAfterIdle = Measure-Tree $serverProc.Id
    if (-not $Baseline) {
        if ($httpAfterIdle.worker_count -ne 0) {
            throw "HTTP OCR worker did not exit after idle timeout."
        }
        if ($httpAfterIdle.total_working_set_mib -gt 35) {
            throw "HTTP server working set after idle unload remained too high: $($httpAfterIdle.total_working_set_mib) MiB."
        }
    }
    Add-Check 'http_after_idle_unload' $httpAfterIdle

    $http2 = Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$port/api/ocr" -Body $payload -ContentType 'application/json' -TimeoutSec 20
    if ($http2.code -ne 100 -or $http2.data -ne $http1.data) {
        throw 'HTTP OCR after respawn did not match first result.'
    }
    Start-Sleep -Milliseconds 200
    $httpRespawn = Measure-Tree $serverProc.Id
    $httpWorkerPid = if ($httpRespawn.worker_count -gt 0) { $httpRespawn.workers[0].pid } else { 0 }
    Add-Check 'http_after_respawn_ocr' ([ordered]@{
        matches_first = ($http2.data -eq $http1.data)
        memory = $httpRespawn
    })

    # Hard-kill parent while worker is active to verify Job Object kills child with zero orphans
    $serverProc.Kill()
    $serverProc.WaitForExit(5000) | Out-Null
    $serverProc = $null
    Start-Sleep -Milliseconds 500
    $orphanAlive = $false
    if ($httpWorkerPid -gt 0) {
        $orphanAlive = $null -ne (Get-Process -Id $httpWorkerPid -ErrorAction SilentlyContinue)
        if ($orphanAlive) {
            try { Stop-Process -Id $httpWorkerPid -Force -ErrorAction SilentlyContinue } catch {}
            throw "Orphan OCR worker PID $httpWorkerPid survived parent hard-kill."
        }
    }
    Add-Check 'http_parent_kill_no_orphan' ([ordered]@{
        worker_pid_before_kill = $httpWorkerPid
        worker_alive_after_kill = $orphanAlive
    })

    $report.success = $true
} finally {
    if ($null -ne $desktopProc) {
        try { if (-not $desktopProc.HasExited) { $desktopProc.Kill(); $desktopProc.WaitForExit(3000) | Out-Null } } catch {}
    }
    if ($null -ne $serverProc) {
        try { if (-not $serverProc.HasExited) { $serverProc.Kill(); $serverProc.WaitForExit(3000) | Out-Null } } catch {}
    }
    Restore-Clipboard
    try { Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    $json = $report | ConvertTo-Json -Depth 8
    if ($outputFile) {
        $parent = Split-Path -Parent $outputFile
        if ($parent) { $null = New-Item -ItemType Directory -Path $parent -Force }
        [IO.File]::WriteAllText($outputFile, $json + "`r`n", [Text.UTF8Encoding]::new($false))
    }
    Write-Output $json
}
