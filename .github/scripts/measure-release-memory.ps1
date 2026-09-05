[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TestAssembly,

    [Parameter(Mandatory = $true)]
    [string]$TestRunner,

    [Parameter(Mandatory = $true)]
    [string]$OutputDirectory,

    [int]$Blocks = 3,
    [int]$Samples = 10,
    [int]$Seed = 20240517,
    [int]$ChildTimeoutSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$variants = @(
    [pscustomobject]@{ Name = 'None'; Test = 'WinMemoryCleaner.MemoryBenchmarks.ReleaseMemoryBenchmarkTests.None' },
    [pscustomobject]@{ Name = 'GCOnly'; Test = 'WinMemoryCleaner.MemoryBenchmarks.ReleaseMemoryBenchmarkTests.GCOnly' },
    [pscustomobject]@{ Name = 'TrimOnly'; Test = 'WinMemoryCleaner.MemoryBenchmarks.ReleaseMemoryBenchmarkTests.TrimOnly' },
    [pscustomobject]@{ Name = 'Combined'; Test = 'WinMemoryCleaner.MemoryBenchmarks.ReleaseMemoryBenchmarkTests.Combined' }
)
$expectedHeader = 'variant,iteration,pid,bitness,clrVersion,serverGC,operationMs,processCpuDeltaMs,workingSetBeforeBytes,workingSetAfterBytes,workingSetRecoveryBytes,privateBytesAfterBytes,gc0Delta,gc1Delta,gc2Delta,recoveryMs'
$durationColumns = @('operationMs', 'processCpuDeltaMs', 'recoveryMs')
$byteColumns = @('workingSetBeforeBytes', 'workingSetAfterBytes', 'workingSetRecoveryBytes', 'privateBytesAfterBytes')
$gcCountColumns = @('gc0Delta', 'gc1Delta', 'gc2Delta')
$metricColumns = @($durationColumns + $byteColumns + $gcCountColumns)

if ($Blocks -lt 1 -or $Blocks -gt 10) { throw 'Blocks must be from 1 through 10.' }
if ($Samples -lt 1 -or $Samples -gt 100) { throw 'Samples must be from 1 through 100.' }
if ($ChildTimeoutSeconds -lt 1 -or $ChildTimeoutSeconds -gt 600) { throw 'ChildTimeoutSeconds must be from 1 through 600.' }
if (-not (Test-Path -LiteralPath $TestAssembly -PathType Leaf)) { throw "Test assembly was not found: $TestAssembly" }
if (-not (Test-Path -LiteralPath $TestRunner -PathType Leaf)) { throw "NUnit runner was not found: $TestRunner" }

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$csvPath = Join-Path $OutputDirectory 'release-memory-raw.csv'
$random = New-Object System.Random($Seed)

function Get-ShuffledVariants {
    $ordered = New-Object System.Collections.ArrayList
    foreach ($variant in $variants) { [void]$ordered.Add($variant) }

    for ($index = $ordered.Count - 1; $index -gt 0; $index--) {
        $swapIndex = $random.Next($index + 1)
        $temporary = $ordered[$index]
        $ordered[$index] = $ordered[$swapIndex]
        $ordered[$swapIndex] = $temporary
    }

    return $ordered.ToArray()
}

function Invoke-BenchmarkTest {
    param(
        [pscustomobject]$Variant,
        [int]$Block
    )

    [int]$rowsBeforeInvocation = 0
    if (Test-Path -LiteralPath $csvPath -PathType Leaf) { $rowsBeforeInvocation = @(Import-Csv -LiteralPath $csvPath).Count }

    $resultsPath = Join-Path $OutputDirectory ("{0}-block-{1}-results.xml" -f $Variant.Name, $Block)
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $TestRunner
    $startInfo.Arguments = ('"{0}" /run:"{1}" /xml:"{2}" /noshadow' -f $TestAssembly, $Variant.Test, $resultsPath)
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.EnvironmentVariables['WIN_MEMORY_CLEANER_RELEASE_MEMORY_BENCHMARK'] = '1'
    $startInfo.EnvironmentVariables['WIN_MEMORY_CLEANER_RELEASE_MEMORY_BENCHMARK_CSV'] = $csvPath
    $startInfo.EnvironmentVariables['WIN_MEMORY_CLEANER_RELEASE_MEMORY_BENCHMARK_SAMPLES'] = [string]$Samples

    $child = New-Object System.Diagnostics.Process
    $child.StartInfo = $startInfo
    [void]$child.Start()

    if (-not $child.WaitForExit($ChildTimeoutSeconds * 1000)) {
        & taskkill.exe /PID $child.Id /T /F | Out-Null
        $taskKillExitCode = $LASTEXITCODE
            if ($taskKillExitCode -ne 0) { throw "Timed out waiting for spawned benchmark child $($child.Id), and taskkill failed with $taskKillExitCode." }
        if (-not $child.WaitForExit(10000)) { throw "Timed out waiting for spawned benchmark child tree $($child.Id), and taskkill did not terminate it within 10 seconds." }
        if ($taskKillExitCode -ne 0) { throw "Timed out waiting for spawned benchmark child $($child.Id), and taskkill failed with $taskKillExitCode." }
        throw "Timed out waiting for spawned benchmark child tree $($child.Id)."
    }

    if (-not (Test-Path -LiteralPath $resultsPath -PathType Leaf)) { throw "NUnit did not write $resultsPath." }
    [xml]$results = Get-Content -LiteralPath $resultsPath -Raw
    $testCases = @($results.SelectNodes('//test-case'))
    if ($testCases.Count -ne 1) { throw "Expected exactly one test case for $($Variant.Test), found $($testCases.Count)." }

    $testCase = $testCases[0]
    if ($testCase.name -ne $Variant.Test) { throw "NUnit executed $($testCase.name), not $($Variant.Test)." }
    if ($testCase.executed -ne 'True' -or $testCase.result -ne 'Success' -or $testCase.success -ne 'True') {
        throw "Benchmark test did not pass: $($Variant.Test)."
    }
    if ($child.ExitCode -ne 0) { throw "NUnit exited with $($child.ExitCode) for $($Variant.Test)." }
    return $rowsBeforeInvocation
}

function Assert-CsvState {
    param(
        [int]$CompletedRuns,
        [int]$RowsBeforeInvocation,
        [pscustomobject]$InvocationVariant
    )

    if (-not (Test-Path -LiteralPath $csvPath -PathType Leaf)) { throw "Benchmark CSV was not written: $csvPath" }
    $header = (Get-Content -LiteralPath $csvPath -TotalCount 1).TrimStart([char]0xfeff)
    if ($header -ne $expectedHeader) { throw 'Benchmark CSV header did not match the invariant schema.' }

    $rows = @(Import-Csv -LiteralPath $csvPath)
    $expectedRows = $CompletedRuns * $Samples
    if ($rows.Count -ne $expectedRows) { throw "Expected $expectedRows CSV rows, found $($rows.Count)." }

    foreach ($row in $rows) {
        if ($variants.Name -notcontains $row.variant) { throw "Unexpected CSV variant: $($row.variant)." }
        foreach ($metric in $durationColumns) {
            [double]$value = 0
            if (-not [double]::TryParse([string]$row.$metric, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$value) -or [double]::IsNaN($value) -or [double]::IsInfinity($value) -or $value -lt 0 -or $value -gt ($ChildTimeoutSeconds * 1000)) {
                throw "CSV duration $metric is not a reasonable nonnegative value for $($row.variant) iteration $($row.iteration)."
            }
        }
        foreach ($metric in $byteColumns) {
            [long]$value = 0
            if (-not [long]::TryParse([string]$row.$metric, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$value) -or $value -lt 0) {
                throw "CSV byte count $metric is not a nonnegative integer for $($row.variant) iteration $($row.iteration)."
            }
        }
        foreach ($metric in $gcCountColumns) {
            [int]$value = 0
            if (-not [int]::TryParse([string]$row.$metric, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$value) -or $value -lt 0) {
                throw "CSV GC count $metric is not a nonnegative integer for $($row.variant) iteration $($row.iteration)."
            }
        }
    }

    $batchStart = $expectedRows - $Samples
    if ($RowsBeforeInvocation -ne $batchStart) { throw "Expected $batchStart CSV rows before the latest invocation, found $RowsBeforeInvocation." }
    if (($rows.Count - $RowsBeforeInvocation) -ne $Samples) { throw "Expected the latest invocation to add $Samples CSV rows, found $($rows.Count - $RowsBeforeInvocation)." }
    $batchRows = @($rows | Select-Object -Skip $RowsBeforeInvocation -First $Samples)
    if ($batchRows.Count -ne $Samples) { throw "Expected $Samples rows in the latest invocation batch, found $($batchRows.Count)." }

    $seenIterations = New-Object 'System.Collections.Generic.HashSet[int]'
    [long]$batchPid = 0
    [int]$batchBitness = 0
    [string]$batchClrVersion = $null
    [bool]$batchServerGc = $false
    $hasBatchMetadata = $false
    foreach ($row in $batchRows) {
        if ($row.variant -ne $InvocationVariant.Name) { throw "Latest invocation wrote $($row.variant), not $($InvocationVariant.Name)." }

        [int]$iteration = 0
        if (-not [int]::TryParse([string]$row.iteration, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$iteration) -or $iteration -lt 1 -or $iteration -gt $Samples -or -not $seenIterations.Add($iteration)) {
            throw "CSV iteration must occur exactly once from 1 through $Samples for $($InvocationVariant.Name)."
        }

        [long]$sampleProcessId = 0
        if (-not [long]::TryParse([string]$row.pid, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$sampleProcessId) -or $sampleProcessId -le 0) {
            throw "CSV PID is not a positive integer for $($InvocationVariant.Name) iteration $iteration."
        }

        [int]$bitness = 0
        [Version]$clrVersion = $null
        [bool]$serverGc = $false
        if (-not [int]::TryParse([string]$row.bitness, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$bitness) -or ($bitness -ne 32 -and $bitness -ne 64)) {
            throw "CSV bitness is not 32 or 64 for $($InvocationVariant.Name) iteration $iteration."
        }
        if (-not [Version]::TryParse([string]$row.clrVersion, [ref]$clrVersion)) { throw "CSV CLR version is invalid for $($InvocationVariant.Name) iteration $iteration." }
        if (-not [bool]::TryParse([string]$row.serverGC, [ref]$serverGc)) { throw "CSV serverGC is invalid for $($InvocationVariant.Name) iteration $iteration." }

        if (-not $hasBatchMetadata) {
            $batchPid = $sampleProcessId
            $batchBitness = $bitness
            $batchClrVersion = $clrVersion.ToString()
            $batchServerGc = $serverGc
            $hasBatchMetadata = $true
        }
        elseif ($sampleProcessId -ne $batchPid -or $bitness -ne $batchBitness -or $clrVersion.ToString() -ne $batchClrVersion -or $serverGc -ne $batchServerGc) {
            throw "CSV process metadata is inconsistent within the $($InvocationVariant.Name) invocation."
        }
    }
    if ($seenIterations.Count -ne $Samples) { throw "CSV iterations did not cover 1 through $Samples for $($InvocationVariant.Name)." }

    foreach ($variant in $variants) {
        $expectedVariantRows = $runCounts[$variant.Name] * $Samples
        $actualVariantRows = @($rows | Where-Object { $_.variant -eq $variant.Name }).Count
        if ($actualVariantRows -ne $expectedVariantRows) {
            throw "Expected $expectedVariantRows CSV rows for $($variant.Name), found $actualVariantRows."
        }
    }
}

$completedRuns = 0
$runCounts = @{}
foreach ($variant in $variants) { $runCounts[$variant.Name] = 0 }
for ($block = 1; $block -le $Blocks; $block++) {
    foreach ($variant in Get-ShuffledVariants) {
        $rowsBeforeInvocation = Invoke-BenchmarkTest -Variant $variant -Block $block
        $runCounts[$variant.Name]++
        $completedRuns++
        Assert-CsvState -CompletedRuns $completedRuns -RowsBeforeInvocation $rowsBeforeInvocation -InvocationVariant $variant
    }
}

$rows = @(Import-Csv -LiteralPath $csvPath)
$summaryVariants = [ordered]@{}
foreach ($variant in $variants) {
    $variantRows = @($rows | Where-Object { $_.variant -eq $variant.Name })
    if ($variantRows.Count -ne ($Blocks * $Samples)) { throw "Expected $($Blocks * $Samples) rows for $($variant.Name), found $($variantRows.Count)." }

    $medians = [ordered]@{}
    foreach ($metric in $metricColumns) {
        [double[]]$values = @($variantRows | ForEach-Object { [double]::Parse([string]$_.$metric, [Globalization.CultureInfo]::InvariantCulture) } | Sort-Object)
        $middle = [int][Math]::Floor($values.Length / 2.0)
        $medians[$metric] = if (($values.Length % 2) -eq 0) { ($values[$middle - 1] + $values[$middle]) / 2 } else { $values[$middle] }
    }
    $summaryVariants[$variant.Name] = $medians
}

$summary = [ordered]@{
    metadata = [ordered]@{
        commit = $env:GITHUB_SHA
        runnerOs = $env:RUNNER_OS
        imageOs = $env:ImageOS
        workflow = $env:GITHUB_WORKFLOW
        seed = $Seed
        blocks = $Blocks
        samplesPerInvocation = $Samples
        samplesPerVariant = $Blocks * $Samples
    }
    medians = $summaryVariants
}
$summaryPath = Join-Path $OutputDirectory 'release-memory-summary.json'
$summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $summaryPath -Encoding UTF8

Write-Host "Release-memory benchmark complete. Seed: $Seed. Raw CSV: $csvPath. Summary: $summaryPath"
