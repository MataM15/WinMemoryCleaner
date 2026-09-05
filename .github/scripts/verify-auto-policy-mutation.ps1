[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Workspace,

    [Parameter(Mandatory = $true)]
    [string]$SolutionPath,

    [Parameter(Mandatory = $true)]
    [string]$TestAssembly,

    [Parameter(Mandatory = $true)]
    [string]$TestRunner
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or $env:RUNNER_OS -ne 'Windows') {
    throw 'Auto optimization policy mutation verification is restricted to GitHub-hosted Windows runners.'
}

$workspacePath = [System.IO.Path]::GetFullPath($Workspace)
$sourcePath = Join-Path $workspacePath 'src\Core\AutoOptimizationPolicy.cs'
$mutationResultsPath = Join-Path $workspacePath 'auto-policy-mutation-results.xml'
$restoredResultsPath = Join-Path $workspacePath 'auto-policy-restored-results.xml'
$fixture = 'WinMemoryCleaner.AutomationTests.AutoOptimizationPolicyTests'
$expectedTests = @(
    "$fixture.DisabledBoth_ReturnsNull",
    "$fixture.Schedule_WhenJustBeforeDue_ReturnsNull",
    "$fixture.Schedule_WhenExactlyDue_ReturnsSchedule",
    "$fixture.LowMemory_WhenFreePercentageIsBelowThreshold_ReturnsLowMemory",
    "$fixture.LowMemory_WhenFreePercentageEqualsThreshold_ReturnsNull",
    "$fixture.LowMemory_WhenCooldownIsJustBeforeDue_ReturnsNull",
    "$fixture.LowMemory_WhenCooldownIsExactlyDue_ReturnsLowMemory",
    "$fixture.Schedule_WhenBothTriggersAreDue_ReturnsSchedule",
    "$fixture.Schedule_WhenNonZeroIntervalCrossesDateBoundary_ReturnsSchedule"
)
$expectedMutationFailures = @{
    "$fixture.LowMemory_WhenFreePercentageIsBelowThreshold_ReturnsLowMemory" = @('Expected: LowMemory', 'But was:.*null')
    "$fixture.LowMemory_WhenFreePercentageEqualsThreshold_ReturnsNull" = @('Expected: null', 'But was:.*LowMemory')
    "$fixture.LowMemory_WhenCooldownIsExactlyDue_ReturnsLowMemory" = @('Expected: LowMemory', 'But was:.*null')
}

foreach ($path in @($SolutionPath, $TestAssembly, $TestRunner, $sourcePath)) {
    $fullPath = [System.IO.Path]::GetFullPath($path)
    if (-not $fullPath.StartsWith($workspacePath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Mutation verification path is outside GITHUB_WORKSPACE: $fullPath"
    }
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
        throw "Mutation verification path does not exist: $fullPath"
    }
}

function Invoke-CiBuild {
    param([string]$Phase)

    & msbuild $SolutionPath /m /p:Configuration=Release /p:Platform="Any CPU" /p:IsCI=true "/p:RestartFlag=$workspacePath\ci-restart-required.flag"
    if ($LASTEXITCODE -ne 0) {
        throw "$Phase build failed. Compiler failure is not valid mutation evidence."
    }
}

function Get-FixtureResults {
    param([string]$ResultsPath)

    if (-not (Test-Path -LiteralPath $ResultsPath -PathType Leaf)) {
        throw "NUnit did not write $ResultsPath"
    }

    [xml]$results = Get-Content -LiteralPath $ResultsPath -Raw
    $testCases = @($results.SelectNodes('//test-case'))
    if ($testCases.Count -ne $expectedTests.Count) {
        throw "Expected $($expectedTests.Count) policy test cases, found $($testCases.Count)"
    }

    $actualNames = @($testCases | ForEach-Object { $_.name })
    if (@(Compare-Object -ReferenceObject $expectedTests -DifferenceObject $actualNames).Count -ne 0) {
        throw 'NUnit XML did not contain exactly the auto optimization policy test allowlist'
    }

    return $testCases
}

function Invoke-PolicyFixture {
    param(
        [string]$ResultsPath,
        [bool]$ExpectMutationFailures
    )

    & $TestRunner $TestAssembly "/fixture:$fixture" "/xml:$ResultsPath" /noshadow
    $testExitCode = $LASTEXITCODE
    $testCases = Get-FixtureResults $ResultsPath

    if ($ExpectMutationFailures) {
        if ($testExitCode -eq 0) {
            throw 'The threshold mutant survived the auto optimization policy fixture.'
        }

        $actualFailures = @($testCases | Where-Object { $_.executed -eq 'True' -and $_.result -eq 'Failure' -and $_.success -eq 'False' })
        $actualFailureNames = @($actualFailures | ForEach-Object { $_.name })
        $expectedFailureNames = @($expectedMutationFailures.Keys)
        if (@(Compare-Object -ReferenceObject $expectedFailureNames -DifferenceObject $actualFailureNames).Count -ne 0) {
            throw "Mutant did not produce exactly the expected assertion failures: $($actualFailureNames -join ', ')"
        }

        foreach ($testCase in $actualFailures) {
            $messageNode = $testCase.SelectSingleNode('failure/message')
            if ($null -eq $messageNode) { throw "Mutation failure lacks an assertion message: $($testCase.name)." }
            $message = $messageNode.InnerText
            foreach ($expectedMessage in $expectedMutationFailures[$testCase.name]) {
                if ($message -notmatch $expectedMessage) {
                    throw "Mutation failure message for $($testCase.name) did not contain '$expectedMessage'."
                }
            }
        }

        $unexpectedNonPassing = @($testCases | Where-Object {
            $expectedFailureNames -notcontains $_.name -and ($_.executed -ne 'True' -or $_.result -ne 'Success' -or $_.success -ne 'True')
        })
        if ($unexpectedNonPassing.Count -ne 0) {
            throw "Mutant caused unexpected non-passing tests: $($unexpectedNonPassing.name -join ', ')"
        }

        return
    }

    $nonPassing = @($testCases | Where-Object { $_.executed -ne 'True' -or $_.result -ne 'Success' -or $_.success -ne 'True' })
    if ($nonPassing.Count -ne 0) {
        throw "Restored policy fixture contains non-passing tests: $($nonPassing.name -join ', ')"
    }
    if ($testExitCode -ne 0) {
        throw "Restored policy fixture exited with $testExitCode."
    }
}

$originalBytes = [System.IO.File]::ReadAllBytes($sourcePath)
$originalHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
$mutationValidated = $false

try {
    $sourceText = [System.Text.Encoding]::UTF8.GetString($originalBytes)
    $originalCondition = 'freePhysicalMemoryPercentage < autoOptimizationMemoryUsage'
    $mutatedCondition = 'freePhysicalMemoryPercentage >= autoOptimizationMemoryUsage'
    $matchCount = [System.Text.RegularExpressions.Regex]::Matches($sourceText, [System.Text.RegularExpressions.Regex]::Escape($originalCondition)).Count
    if ($matchCount -ne 1) {
        throw "Expected exactly one mutable threshold condition, found $matchCount."
    }

    $mutatedText = $sourceText.Replace($originalCondition, $mutatedCondition)
    [System.IO.File]::WriteAllText($sourcePath, $mutatedText, [System.Text.UTF8Encoding]::new($false))

    Invoke-CiBuild 'Mutated'
    Invoke-PolicyFixture $mutationResultsPath $true
    $mutationValidated = $true
}
finally {
    [System.IO.File]::WriteAllBytes($sourcePath, $originalBytes)
    $restoredHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
    if ($restoredHash -ne $originalHash) {
        throw 'Auto optimization policy source hash did not match after restoration.'
    }

    Write-Host "Policy source restored: SHA256 $restoredHash"
    Invoke-CiBuild 'Restored'
    Invoke-PolicyFixture $restoredResultsPath $false
}

if (-not $mutationValidated) {
    throw 'Auto optimization policy mutation verification did not complete.'
}
