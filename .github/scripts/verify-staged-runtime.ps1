[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ArtifactDirectory,
    [Parameter(Mandatory = $true)][string]$ReportDirectory,
    [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$ExpectedCommit,
    [ValidateSet(10)][int]$SampleIntervalSeconds = 10,
    [ValidateSet(18)][int]$SampleCount = 18
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$allowedPayload = @('WinMemoryCleaner.exe', 'nunit.framework.dll', 'WinMemoryCleaner.exe.config', 'LICENSE', 'BUILD-INFO.txt', 'SHA256SUMS.txt')
$requiredPayload = @('WinMemoryCleaner.exe', 'nunit.framework.dll', 'LICENSE', 'BUILD-INFO.txt', 'SHA256SUMS.txt')
$settingsPath = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WinMemoryCleaner'
$legacyUserSettingsPath = 'Registry::HKEY_CURRENT_USER\SOFTWARE\WinMemoryCleaner'
$legacyRunPath = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
$ownedSettings = [ordered]@{
    AutoOptimizationInterval = 0; AutoOptimizationMemoryUsage = 0; MemoryAreas = 0
    RunOnStartup = 0; CreateStartMenuShortcut = 0; StartMinimized = 0
    CloseToTheNotificationArea = 0; CloseAfterOptimization = 0
    TrayIconOptimizeOnMiddleMouseClick = 0; UseHotkey = 0; AutoUpdate = 0; RunOnPriority = 0
}
$script:logLines = [System.Collections.Generic.List[string]]::new()
$script:ownedSettingsCreated = $false
$script:startedPid = $null
$script:mainProcessStartTime = $null
$script:appStartedAt = $null
$script:childObservation = $null
$script:exitCode = 1
$script:failure = $null
$report = [ordered]@{
    SchemaVersion = 1
    StartedUtc = (Get-Date).ToUniversalTime().ToString('o')
    ExpectedCommit = $ExpectedCommit.ToLowerInvariant()
    Artifact = [ordered]@{ Status = 'NotValidated'; Directory = $ArtifactDirectory; Files = @() }
    Defender = [ordered]@{ Status = 'NotScanned'; Reason = $null; ScanJobState = $null; Detections = @(); Capability = @{} }
    Runtime = [ordered]@{
        Status = 'NotRun'; Reason = $null; Pid = $null; LogicalProcessorCount = [Environment]::ProcessorCount
        Samples = @(); Events = @(); EventDiagnostics = [ordered]@{ Status = 'NotCollected'; Reason = $null }
        ForcedStop = $false; ChildPidsRemaining = @(); ChildProcessInspection = [ordered]@{ Status = 'NotAttempted'; Reason = $null; UnverifiedPids = @() }
    }
    Overall = 'Fail'
    Failure = $null
}

function Write-Log([string]$Message) {
    $line = '{0} {1}' -f (Get-Date).ToUniversalTime().ToString('o'), $Message
    $script:logLines.Add($line)
    Write-Host $line
}

function Set-RuntimeFailure([string]$Reason) {
    if (-not $script:failure) {
        $script:failure = $Reason
        $report.Runtime.Reason = $Reason
    }
    else {
        Write-Log "Additional runtime/cleanup failure (primary failure preserved): $Reason"
    }
    $report.Runtime.Status = 'Fail'
    $script:exitCode = 1
}

function Get-ArtifactMetadata {
    param([string]$Directory)
    $resolved = (Resolve-Path -LiteralPath $Directory -ErrorAction Stop).Path
    $root = Get-Item -LiteralPath $resolved -Force -ErrorAction Stop
    if (-not $root.PSIsContainer -or ($root.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'ArtifactDirectory must be a non-reparse-point directory.'
    }
    $items = @(Get-ChildItem -LiteralPath $resolved -Force -ErrorAction Stop)
    foreach ($item in $items) {
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Artifact contains a directory or reparse point: $($item.Name)"
        }
        if ($item.Name -notin $allowedPayload) { throw "Artifact contains an unexpected file: $($item.Name)" }
    }
    $names = @($items.Name)
    $missing = @($requiredPayload | Where-Object { $_ -notin $names })
    if ($missing.Count) { throw "Artifact is missing required files: $($missing -join ', ')" }

    $buildInfo = Get-Content -LiteralPath (Join-Path $resolved 'BUILD-INFO.txt') -Raw -ErrorAction Stop
    $commitMatches = [regex]::Matches($buildInfo, "(?m)^Commit:\s*$([regex]::Escape($ExpectedCommit))\s*$")
    if ($commitMatches.Count -ne 1) { throw 'BUILD-INFO.txt does not contain exactly the expected commit.' }

    $checksums = @{}
    foreach ($line in (Get-Content -LiteralPath (Join-Path $resolved 'SHA256SUMS.txt') -ErrorAction Stop)) {
        $match = [regex]::Match($line, '^([0-9a-fA-F]{64}) \*([^\\/]+)$')
        if (-not $match.Success -or $match.Groups[2].Value -notin $allowedPayload -or $match.Groups[2].Value -eq 'SHA256SUMS.txt' -or $checksums.ContainsKey($match.Groups[2].Value)) {
            throw "SHA256SUMS.txt contains an invalid entry: $line"
        }
        $checksums[$match.Groups[2].Value] = $match.Groups[1].Value.ToLowerInvariant()
    }
    $payloadNames = @($names | Where-Object { $_ -ne 'SHA256SUMS.txt' })
    if ($checksums.Count -ne $payloadNames.Count -or @($payloadNames | Where-Object { -not $checksums.ContainsKey($_) }).Count) {
        throw 'SHA256SUMS.txt does not describe exactly the staged payload.'
    }

    $metadata = @()
    foreach ($name in ($payloadNames | Sort-Object)) {
        $file = Get-Item -LiteralPath (Join-Path $resolved $name) -Force -ErrorAction Stop
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        if ($hash -ne $checksums[$name]) { throw "Digest mismatch for $name" }
        $metadata += [pscustomobject]@{ Name = $name; Length = $file.Length; Sha256 = $hash }
    }
    return [pscustomobject]@{ Directory = $resolved; Files = $metadata }
}

function Test-FreshState {
    if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Runtime validation requires an elevated Windows runner.'
    }
    if (-not [Environment]::UserInteractive) { throw 'Desktop unavailable: the runner is not interactive; runtime validation is not a pass.' }

    $shortcut = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::Programs)) 'Windows Memory Cleaner.lnk'
    $tempPath = [IO.Path]::GetTempPath()
    $migratorOrphans = @(
        Get-ChildItem -Path (Join-Path $tempPath 'WinMemoryCleaner.exe.*.new') -File -ErrorAction Stop
        Get-ChildItem -Path (Join-Path $tempPath 'WinMemoryCleaner.exe.*.download') -File -ErrorAction Stop
    )
    $state = @(
        @{ Name = 'HKLM settings'; Exists = (Test-Path -LiteralPath $settingsPath) },
        @{ Name = 'HKCU legacy settings'; Exists = (Test-Path -LiteralPath $legacyUserSettingsPath) },
        @{ Name = 'Start Menu shortcut'; Exists = (Test-Path -LiteralPath $shortcut) },
        @{ Name = 'WinMemoryCleaner service'; Exists = ($null -ne (Get-Service -Name 'WinMemoryCleaner' -ErrorAction SilentlyContinue)) },
        @{ Name = 'Windows Memory Cleaner task'; Exists = ($null -ne (Get-ScheduledTask -TaskName 'Windows Memory Cleaner' -ErrorAction SilentlyContinue)) },
        @{ Name = 'legacy Run value'; Exists = ($null -ne (Get-ItemProperty -LiteralPath $legacyRunPath -Name 'Windows Memory Cleaner' -ErrorAction SilentlyContinue)) },
        @{ Name = 'Migrator update orphan'; Exists = ($migratorOrphans.Count -gt 0) }
    )
    $existing = @($state | Where-Object { $_.Exists } | ForEach-Object { $_.Name })
    if ($existing.Count) { throw "Runner is not fresh; refusing to overwrite or delete existing state: $($existing -join ', ')" }
    $existingProcess = @(Get-Process -Name 'WinMemoryCleaner' -ErrorAction SilentlyContinue)
    if ($existingProcess.Count) { throw "Runner is not fresh; WinMemoryCleaner is already running (PIDs: $($existingProcess.Id -join ', '))." }
}

function Set-OwnedSettings {
    New-Item -Path $settingsPath -ErrorAction Stop | Out-Null
    $script:ownedSettingsCreated = $true
    foreach ($entry in $ownedSettings.GetEnumerator()) {
        New-ItemProperty -LiteralPath $settingsPath -Name $entry.Key -Value ([int]$entry.Value) -PropertyType DWord -Force -ErrorAction Stop | Out-Null
    }
}

function Get-DefenderResult([string]$Directory) {
    $result = $report.Defender
    try {
        $service = Get-Service -Name 'WinDefend' -ErrorAction Stop
        $status = Get-MpComputerStatus -ErrorAction Stop
        $preference = Get-MpPreference -ErrorAction Stop
        $result.Capability = [ordered]@{
            ServiceStatus = [string]$service.Status
            AMServiceEnabled = $status.AMServiceEnabled
            AntivirusEnabled = $status.AntivirusEnabled
            RealTimeProtectionEnabled = $status.RealTimeProtectionEnabled
            AMProductVersion = $status.AMProductVersion
            AMEngineVersion = $status.AMEngineVersion
            AntivirusSignatureVersion = $status.AntivirusSignatureVersion
            AntivirusSignatureLastUpdated = $status.AntivirusSignatureLastUpdated
            SignatureAgeDays = if ($status.AntivirusSignatureLastUpdated) { [math]::Round(((Get-Date) - $status.AntivirusSignatureLastUpdated).TotalDays, 2) } else { $null }
            SubmitSamplesConsent = $preference.SubmitSamplesConsent
            StartMpScanAvailable = ($null -ne (Get-Command Start-MpScan -ErrorAction SilentlyContinue))
        }
        if ($service.Status -ne 'Running' -or -not $status.AMServiceEnabled -or -not $status.AntivirusEnabled -or -not $result.Capability.StartMpScanAvailable) {
            $result.Status = 'Unavailable'; $result.Reason = 'Defender local scanning is not operational on this runner.'; return
        }
        if ([int]$preference.SubmitSamplesConsent -ne 2) {
            $result.Status = 'Unavailable'; $result.Reason = 'Privacy precondition not met: SubmitSamplesConsent is not NeverSend (2); settings were not changed.'; return
        }
    }
    catch {
        $result.Status = 'Unavailable'; $result.Reason = "Defender capability or privacy query failed without changing settings: $($_.Exception.Message)"; return
    }

    $job = $null
    $scanAttempted = $false
    try {
        $scanStarted = Get-Date
        $scanAttempted = $true
        $job = Start-MpScan -ScanType CustomScan -ScanPath $Directory -AsJob -ErrorAction Stop
        $completed = Wait-Job -Job $job -Timeout 120 -ErrorAction Stop
        $result.ScanJobState = [string]$job.State
        if ($null -eq $completed -or $job.State -ne 'Completed') {
            throw 'Defender custom scan timed out or did not complete.'
        }
        $jobOutput = @(Receive-Job -Job $job -ErrorAction Stop | Out-String)
        if ($job.ChildJobs | Where-Object { $_.JobStateInfo.State -eq 'Failed' -or $_.JobStateInfo.Reason }) {
            throw "Defender custom scan failed: $($jobOutput -join ' ')"
        }
        $detections = @(Get-MpThreatDetection -ErrorAction Stop | Where-Object {
            $_.InitialDetectionTime -ge $scanStarted -and (($_.Resources -join '|') -like "*$Directory*")
        })
        $result.Detections = @($detections | Select-Object ThreatName, InitialDetectionTime, Resources)
        if ($detections.Count) { $result.Status = 'Detected'; $result.Reason = 'Defender reported a new detection for the staged payload.'; return }
        $result.Status = 'Pass'; $result.Reason = 'Completed a local-only custom scan with no matching new detections.'
    }
    catch {
        $result.Status = 'Error'
        $prefix = if ($scanAttempted) { 'Defender scan, wait, or evidence query failed after scan attempt' } else { 'Defender scan could not be started' }
        $result.Reason = "$prefix: $($_.Exception.Message)"
    }
    finally {
        if ($job) {
            $result.ScanJobState = [string]$job.State
            if ($job.State -notin @('Completed', 'Failed', 'Stopped')) {
                try { Stop-Job -Job $job -ErrorAction Stop } catch { Write-Log "Owned Defender job stop failed: $($_.Exception.Message)" }
            }
            try { Remove-Job -Job $job -Force -ErrorAction Stop } catch { Write-Log "Owned Defender job removal failed: $($_.Exception.Message)" }
        }
    }
}

function Test-Window([IntPtr]$Handle) {
    $reply = [IntPtr]::Zero
    return ([RuntimeProbe.Native]::IsWindow($Handle) -and [RuntimeProbe.Native]::SendMessageTimeout($Handle, 0, [IntPtr]::Zero, [IntPtr]::Zero, 2, 2000, [ref]$reply) -ne [IntPtr]::Zero)
}

function Get-AppEvents([datetime]$StartTime, [int]$ProcessId) {
    try {
        $pidPattern = "(?<!\d)$([regex]::Escape([string]$ProcessId))(?!\d)"
        $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = $StartTime } -MaxEvents 100 -ErrorAction Stop |
            Where-Object {
                $isError = $_.LevelDisplayName -in @('Error', 'Critical')
                $isAppNamed = $_.ProviderName -in @('Windows Memory Cleaner', 'WinMemoryCleaner') -or ([string]$_.Message -match '(?i)\bWinMemoryCleaner(?:\.exe)?\b')
                $isOwnedPid = ([string]$_.Message -match $pidPattern)
                $isError -and ($isAppNamed -or $isOwnedPid)
            } |
            Select-Object -First 50 TimeCreated, Id, LevelDisplayName, ProviderName, Message)
        $reason = if ($events.Count) { "Application event query completed; found $($events.Count) related error event(s)." } else { 'Application event query completed; no related error events found.' }
        return [pscustomobject]@{ Status = 'Pass'; Reason = $reason; Events = $events }
    }
    catch {
        return [pscustomobject]@{ Status = 'Unavailable'; Reason = "Application event collection unavailable: $($_.Exception.Message)"; Events = @() }
    }
}

function Get-PotentialChildren([int]$ParentPid, [datetime]$NotBefore) {
    try {
        $owned = @()
        $unverified = @()
        foreach ($candidate in @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $ParentPid" -ErrorAction Stop)) {
            try {
                $created = ([datetime]$candidate.CreationDate).ToUniversalTime()
                if ($created -ge $NotBefore.ToUniversalTime()) { $owned += [int]$candidate.ProcessId }
                else { $unverified += [int]$candidate.ProcessId }
            }
            catch { $unverified += [int]$candidate.ProcessId }
        }
        return [pscustomobject]@{ Status = 'Pass'; Reason = 'Child-process inspection completed.'; OwnedPids = $owned; UnverifiedPids = $unverified }
    }
    catch {
        return [pscustomobject]@{ Status = 'Unavailable'; Reason = "Child-process inspection unavailable: $($_.Exception.Message)"; OwnedPids = @(); UnverifiedPids = @() }
    }
}

function Test-OwnedProcessIdentity([System.Diagnostics.Process]$Process) {
    if (-not $script:mainProcessStartTime) { return $false }
    try {
        return $Process.StartTime.ToUniversalTime().ToFileTimeUtc() -eq $script:mainProcessStartTime.ToFileTimeUtc()
    }
    catch { return $false }
}

try {
    New-Item -ItemType Directory -Path $ReportDirectory -Force -ErrorAction Stop | Out-Null
    $artifact = Get-ArtifactMetadata -Directory $ArtifactDirectory
    $report.Artifact.Status = 'Pass'; $report.Artifact.Directory = $artifact.Directory; $report.Artifact.Files = $artifact.Files
    Test-FreshState
    Set-OwnedSettings

    Get-DefenderResult -Directory $artifact.Directory
    if ($report.Defender.Status -in @('Detected', 'Error')) { throw "Defender $($report.Defender.Status): $($report.Defender.Reason)" }
    try {
        $afterScan = Get-ArtifactMetadata -Directory $artifact.Directory
        if ((@($artifact.Files | ConvertTo-Json -Compress) -join '') -ne (@($afterScan.Files | ConvertTo-Json -Compress) -join '')) {
            throw 'Staged payload changed after Defender processing.'
        }
    }
    catch {
        $report.Defender.Status = 'Error'; $report.Defender.Reason = "Post-scan payload verification failed: $($_.Exception.Message)"
        throw $report.Defender.Reason
    }

    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace RuntimeProbe {
  public static class Native {
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  }
}
'@ -ErrorAction Stop

    $script:appStartedAt = Get-Date
    $process = Start-Process -FilePath (Join-Path $artifact.Directory 'WinMemoryCleaner.exe') -WorkingDirectory $artifact.Directory -PassThru -ErrorAction Stop
    $script:startedPid = $process.Id; $report.Runtime.Pid = $process.Id
    try { $script:mainProcessStartTime = $process.StartTime.ToUniversalTime() } catch { throw "Unable to establish the launched process identity: $($_.Exception.Message)" }

    $deadline = (Get-Date).AddSeconds(30); $window = [IntPtr]::Zero
    do {
        Start-Sleep -Milliseconds 500
        $process.Refresh()
        if ($process.HasExited) { throw "Application exited before presenting a main window (exit $($process.ExitCode))." }
        $window = $process.MainWindowHandle
    } while ($window -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline)
    if ($window -eq [IntPtr]::Zero) { throw 'Desktop/window unavailable: application did not expose a non-zero MainWindowHandle within 30 seconds; runtime validation is not a pass.' }
    if (-not (Test-Window $window)) { throw 'The initial application window is not responsive.' }
    [RuntimeProbe.Native]::ShowWindow($window, 6) | Out-Null

    $initialCpu = $process.CPU; $initialTime = Get-Date
    $previousCpu = $initialCpu; $previousTime = $initialTime; $consecutiveHotSamples = 0
    for ($sample = 1; $sample -le $SampleCount; $sample++) {
        Start-Sleep -Seconds $SampleIntervalSeconds
        $process.Refresh()
        if ($process.HasExited) { throw "Application exited during background sampling (exit $($process.ExitCode))." }
        if (-not (Test-Window $window)) { throw "Application window stopped responding during sample $sample." }
        $currentTime = Get-Date; $currentCpu = $process.CPU
        $intervalSeconds = ($currentTime - $previousTime).TotalSeconds
        $intervalCpuSeconds = [math]::Max(0, $currentCpu - $previousCpu)
        $intervalOneCorePercent = if ($intervalSeconds -gt 0) { [math]::Round(100 * $intervalCpuSeconds / $intervalSeconds, 2) } else { 0 }
        $cumulativeElapsedSeconds = ($currentTime - $initialTime).TotalSeconds
        $cumulativeCpuSeconds = [math]::Max(0, $currentCpu - $initialCpu)
        if ($intervalOneCorePercent -gt 50) { $consecutiveHotSamples++ } else { $consecutiveHotSamples = 0 }
        $report.Runtime.Samples += [pscustomobject]@{
            Sample = $sample; IntervalSeconds = [math]::Round($intervalSeconds, 2); IntervalCpuSeconds = [math]::Round($intervalCpuSeconds, 2)
            IntervalOneCorePercent = $intervalOneCorePercent; CumulativeElapsedSeconds = [math]::Round($cumulativeElapsedSeconds, 2)
            CumulativeCpuSeconds = [math]::Round($cumulativeCpuSeconds, 2); WorkingSetBytes = $process.WorkingSet64; PrivateMemoryBytes = $process.PrivateMemorySize64
        }
        if ($consecutiveHotSamples -ge 2) { throw 'CPU exceeded 50% of one logical core for two consecutive sampling intervals (empirical threshold, not a proof).' }
        $previousCpu = $currentCpu; $previousTime = $currentTime
    }
    if (($process.CPU - $initialCpu) -gt 30) { throw 'CPU exceeded 30 cumulative CPU seconds during the three-minute background sample (empirical threshold, not a proof).' }

    [RuntimeProbe.Native]::ShowWindow($window, 9) | Out-Null
    if (-not (Test-Window $window)) { throw 'Application window did not respond after restore.' }
    $script:childObservation = Get-PotentialChildren -ParentPid $script:startedPid -NotBefore $script:appStartedAt
    $report.Runtime.ChildProcessInspection = [ordered]@{
        Status = $script:childObservation.Status; Reason = $script:childObservation.Reason; UnverifiedPids = @($script:childObservation.UnverifiedPids)
    }
    if ($script:childObservation.Status -eq 'Unavailable') { Write-Log $script:childObservation.Reason }
    $closeRequested = $process.CloseMainWindow()
    if (-not $process.WaitForExit(15000)) {
        $report.Runtime.ForcedStop = $true
        $current = Get-Process -Id $script:startedPid -ErrorAction SilentlyContinue
        if (-not $current -or -not (Test-OwnedProcessIdentity -Process $current)) { throw 'Application close timed out and process identity could not be confirmed; no PID was terminated.' }
        Stop-Process -InputObject $current -Force -ErrorAction Stop
        throw 'Application did not exit within 15 seconds after CloseMainWindow; owned PID was force-stopped.'
    }
    if (-not $closeRequested) { throw 'CloseMainWindow did not send a graceful close request.' }
    $report.Runtime.Status = 'Pass'; $report.Runtime.Reason = 'Responsive during the bounded three-minute background sample and exited gracefully.'
    $script:exitCode = 0
}
catch {
    $message = $_.Exception.Message
    if (-not $script:failure) { $script:failure = $message }
    if ($script:startedPid -or $report.Runtime.Status -ne 'NotRun') {
        $report.Runtime.Status = 'Fail'; $report.Runtime.Reason = $script:failure
    }
    Write-Log "Validation failed: $message"
}
finally {
    if ($script:appStartedAt -and $script:startedPid) {
        $eventResult = Get-AppEvents -StartTime $script:appStartedAt -ProcessId $script:startedPid
        $report.Runtime.Events = $eventResult.Events
        $report.Runtime.EventDiagnostics = [ordered]@{ Status = $eventResult.Status; Reason = $eventResult.Reason }
        if ($eventResult.Status -eq 'Unavailable') {
            Write-Log $eventResult.Reason
        }
        elseif (@($eventResult.Events).Count) {
            Set-RuntimeFailure "Related application error events were recorded after launch (count: $(@($eventResult.Events).Count))."
        }
    }

    $mainExited = $true
    $childrenExited = $true
    if ($script:startedPid) {
        $finalChildResult = Get-PotentialChildren -ParentPid $script:startedPid -NotBefore $script:appStartedAt
        $childResults = @($finalChildResult)
        if ($script:childObservation) { $childResults += $script:childObservation }
        $ownedChildPids = @($childResults | ForEach-Object { $_.OwnedPids } | Select-Object -Unique)
        $unverifiedChildPids = @($childResults | ForEach-Object { $_.UnverifiedPids } | Select-Object -Unique)
        $childInspectionStatus = $finalChildResult.Status
        $childInspectionReasons = @($childResults | Where-Object { $_.Status -ne 'Pass' } | ForEach-Object { $_.Reason })
        $childInspectionReason = if ($childInspectionReasons.Count) { "Child-process inspection completed with limitations: $($childInspectionReasons -join '; ')" } else { 'Child-process inspection completed.' }
        $report.Runtime.ChildProcessInspection = [ordered]@{ Status = $childInspectionStatus; Reason = $childInspectionReason; UnverifiedPids = $unverifiedChildPids }
        if ($finalChildResult.Status -eq 'Unavailable') {
            $childrenExited = $false
            Set-RuntimeFailure $finalChildResult.Reason
        }
        if ($unverifiedChildPids.Count) {
            $childrenExited = $false
            $report.Runtime.ChildPidsRemaining = $unverifiedChildPids
            Set-RuntimeFailure "Child processes could not be safely attributed to the launched PID: $($unverifiedChildPids -join ', ')."
        }
        # Do not terminate descendants from cached PIDs; disposable-runner teardown contains failures.
        $ownedChildrenRemaining = @($ownedChildPids | Where-Object { $null -ne (Get-Process -Id $_ -ErrorAction SilentlyContinue) })
        if ($ownedChildrenRemaining.Count) {
            $childrenExited = $false
            $report.Runtime.ChildPidsRemaining = @($report.Runtime.ChildPidsRemaining + $ownedChildrenRemaining | Select-Object -Unique)
            Set-RuntimeFailure "Owned child processes remained after cleanup: $($ownedChildrenRemaining -join ', ')."
        }

        $left = Get-Process -Id $script:startedPid -ErrorAction SilentlyContinue
        if ($left) {
            $mainExited = $false
            if (Test-OwnedProcessIdentity -Process $left) {
                try {
                    Stop-Process -InputObject $left -Force -ErrorAction Stop
                    $report.Runtime.ForcedStop = $true
                }
                catch { Write-Log "Owned PID cleanup failed: $($_.Exception.Message)" }
                $mainExited = $null -eq (Get-Process -Id $script:startedPid -ErrorAction SilentlyContinue)
                if (-not $mainExited) { Set-RuntimeFailure 'Owned application PID remained after forced cleanup.' }
            }
            else {
                Set-RuntimeFailure 'A process with the launched PID remains, but its identity cannot be safely proven; it was not terminated.'
            }
        }
    }

    if ($script:ownedSettingsCreated) {
        if ($mainExited -and $childrenExited) {
            try { Remove-Item -LiteralPath $settingsPath -Recurse -Force -ErrorAction Stop; Write-Log 'Removed only the settings key created for this validation after main PID exit was confirmed.' }
            catch { Set-RuntimeFailure "Owned registry cleanup failed: $($_.Exception.Message)" }
        }
        else {
            Set-RuntimeFailure 'Owned settings were retained because application or descendant exit could not be confirmed; runner teardown provides final containment.'
        }
    }

    $report.FinishedUtc = (Get-Date).ToUniversalTime().ToString('o')
    $report.Failure = $script:failure
    $report.Overall = if ($script:exitCode -eq 0 -and $report.Defender.Status -eq 'Pass' -and $report.Runtime.Status -eq 'Pass') {
        'Pass'
    }
    elseif ($script:exitCode -eq 0 -and $report.Defender.Status -eq 'Unavailable' -and $report.Runtime.Status -eq 'Pass') {
        'RuntimePassedAntivirusUnverified'
    }
    else {
        'Fail'
    }
    $jsonPath = Join-Path $ReportDirectory 'verify-staged-runtime.json'
    $csvPath = Join-Path $ReportDirectory 'verify-staged-runtime-samples.csv'
    $logPath = Join-Path $ReportDirectory 'verify-staged-runtime.log'
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
    if (@($report.Runtime.Samples).Count) {
        @($report.Runtime.Samples) | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
    }
    else {
        'Sample,IntervalSeconds,IntervalCpuSeconds,IntervalOneCorePercent,CumulativeElapsedSeconds,CumulativeCpuSeconds,WorkingSetBytes,PrivateMemoryBytes' | Set-Content -LiteralPath $csvPath -Encoding UTF8
    }
    $script:logLines | Set-Content -LiteralPath $logPath -Encoding UTF8
    if ($env:GITHUB_STEP_SUMMARY) {
        @(
            '## Staged runtime and Defender validation'
            "- Runtime: **$($report.Runtime.Status)** — $($report.Runtime.Reason)"
            "- Defender: **$($report.Defender.Status)** — $($report.Defender.Reason)"
            "- Application-event diagnostics: **$($report.Runtime.EventDiagnostics.Status)** — $($report.Runtime.EventDiagnostics.Reason)"
            "- Child-process diagnostics: **$($report.Runtime.ChildProcessInspection.Status)** — $($report.Runtime.ChildProcessInspection.Reason)"
            "- Overall: **$($report.Overall)**"
            '- This is Windows Server 2022, not Windows 11.'
            '- No aggressive cleanup was triggered, so cleanup-triggered freezes are not reproduced.'
            '- This is not a security certification; Defender Unavailable permits runtime validation but produces RuntimePassedAntivirusUnverified, never a scan pass.'
        ) | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Encoding UTF8
    }
}
exit $script:exitCode
