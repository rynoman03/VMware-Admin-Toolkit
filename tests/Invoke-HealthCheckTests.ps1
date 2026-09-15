<#
.SYNOPSIS
    Runs Invoke-VMwareHealthCheck.ps1 end to end against the PowerCLI test
    stub and asserts the results.

.DESCRIPTION
    Puts tests/Stubs on PSModulePath so the health check's module detection
    finds the stub VCF.PowerCLI module, then runs the script in a child
    process once per scenario and checks the exit code and the rows in the
    CSV report.

    The assertions are regression tests: each one covers a check that once
    reported the wrong result. They are written against the CSV rather than
    the console output so they test what a consumer of the report sees.

    No vCenter is contacted. The script does attempt a TLS handshake against
    the -VCenter name to read its certificate; the fixture uses a .invalid
    name so that fails fast and lands as a WARN row.

.PARAMETER ScriptPath
    The health check script under test. Defaults to the copy in this repo.

.PARAMETER WorkPath
    Where reports and logs are written. Defaults to a temp folder, removed
    on completion unless -KeepOutput is passed.

.PARAMETER KeepOutput
    Keep the generated reports and logs for inspection.

.EXAMPLE
    pwsh -File tests/Invoke-HealthCheckTests.ps1

.NOTES
    Exits 0 when every assertion passes, 1 otherwise, so it can gate a commit
    or a CI job.
#>
[CmdletBinding()]
param(
    [string] $ScriptPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'HealthCheck/Invoke-VMwareHealthCheck.ps1'),
    [string] $WorkPath   = (Join-Path ([System.IO.Path]::GetTempPath()) "vmware-healthcheck-tests-$PID"),
    [switch] $KeepOutput
)

$ErrorActionPreference = 'Stop'

# Two scenarios expect the health check to exit non-zero. Where PowerShell is
# configured to treat a non-zero native exit code as a terminating error
# (PSNativeCommandUseErrorActionPreference, combined with the Stop preference
# above), that would throw inside the runner instead of being asserted on.
if (Test-Path -LiteralPath 'variable:PSNativeCommandUseErrorActionPreference') {
    $PSNativeCommandUseErrorActionPreference = $false
}

$stubRoot   = Join-Path $PSScriptRoot 'Stubs'
$vcName     = 'vcenter.fixture.invalid'
$pwshExe    = (Get-Process -Id $PID).Path

if (-not (Test-Path -LiteralPath $ScriptPath)) { throw "Script under test not found: $ScriptPath" }
if (-not $pwshExe) { throw 'Could not determine the PowerShell executable for this session.' }

$script:Checks   = 0
$script:Failures = 0

function Assert-That {
    param([string] $Name, [bool] $Condition, [string] $Detail = '')
    $script:Checks++
    if ($Condition) {
        Write-Host "  PASS  $Name" -ForegroundColor Green
    } else {
        $script:Failures++
        Write-Host "  FAIL  $Name" -ForegroundColor Red
        if ($Detail) { Write-Host "        $Detail" -ForegroundColor DarkGray }
    }
}

function Get-ResultRow {
    param($Rows, [string] $Object, [string] $Check)
    # The leading comma matters. Returning @(...) from a function unrolls a
    # single-element array back to a scalar, and in Windows PowerShell 5.1 a
    # lone [pscustomobject] has no .Count - every "exactly one row" assertion
    # below would compare $null against 1 and fail. Wrapping keeps it an array.
    , @($Rows | Where-Object { $_.Object -eq $Object -and $_.Check -eq $Check })
}

function Invoke-Scenario {
    param([string] $Scenario, [string[]] $VCenter = @($vcName))

    $dir = Join-Path $WorkPath $Scenario
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $log = Join-Path $dir 'console.log'

    $savedModulePath = $env:PSModulePath
    $savedEap        = $ErrorActionPreference
    $env:PSModulePath = $stubRoot + [System.IO.Path]::PathSeparator + $savedModulePath
    $env:HEALTHCHECK_FIXTURE_SCENARIO = $Scenario
    # Windows PowerShell turns anything a native command writes to stderr into
    # an error record, which the Stop preference above makes terminating. The
    # ConnectFail scenario writes to stderr by design, so that would abort the
    # runner instead of letting the scenario's exit code be asserted on.
    $ErrorActionPreference = 'Continue'
    try {
        if ($VCenter.Count -gt 1) {
            # -File passes arguments as plain strings, so a list has to go
            # through -Command, which in turn does not propagate a script's
            # exit code on its own. Both halves of the trade-off the health
            # check's .NOTES describes get exercised across these scenarios.
            $literal = ($VCenter | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ','
            & $pwshExe -NoProfile -Command `
                "& '$ScriptPath' -VCenter $literal -ReportPath '$dir'; exit `$LASTEXITCODE" *> $log
        } else {
            & $pwshExe -NoProfile -File $ScriptPath -VCenter $VCenter[0] -ReportPath $dir *> $log
        }
        $code = $LASTEXITCODE
    } finally {
        $env:PSModulePath      = $savedModulePath
        $ErrorActionPreference = $savedEap
        Remove-Item Env:\HEALTHCHECK_FIXTURE_SCENARIO -ErrorAction SilentlyContinue
    }

    $csv  = Get-ChildItem -Path $dir -Filter '*.csv'  -ErrorAction SilentlyContinue | Select-Object -First 1
    $html = Get-ChildItem -Path $dir -Filter '*.html' -ErrorAction SilentlyContinue | Select-Object -First 1

    [pscustomobject]@{
        Scenario = $Scenario
        ExitCode = $code
        Rows     = if ($csv) { @(Import-Csv -Path $csv.FullName) } else { @() }
        Csv      = $csv
        Html     = $html
        Log      = $log
    }
}

Write-Host "Health check under test: $ScriptPath"
Write-Host "PowerShell: $pwshExe ($($PSVersionTable.PSVersion))"
Write-Host "Output: $WorkPath`n"

try {
    # --- Healthy ------------------------------------------------------------
    Write-Host 'Scenario: Healthy' -ForegroundColor Cyan
    $r = Invoke-Scenario 'Healthy'
    Assert-That 'exits 0 when nothing FAILs' ($r.ExitCode -eq 0) "exit code was $($r.ExitCode)"
    Assert-That 'writes an HTML report' ($null -ne $r.Html)
    Assert-That 'writes a CSV report'   ($null -ne $r.Csv)
    Assert-That 'no FAIL rows' (@($r.Rows | Where-Object { $_.Status -eq 'FAIL' }).Count -eq 0) `
        (($r.Rows | Where-Object { $_.Status -eq 'FAIL' } | ForEach-Object { "$($_.Object)/$($_.Check)" }) -join ', ')

    # Config.Certificate is a byte[] of PEM; reading .NotAfter off it directly
    # always yielded null and every host reported INFO.
    $cert = Get-ResultRow $r.Rows 'esx01.fixture.local' 'CertificateExpiry'
    Assert-That 'host certificate expiry is evaluated, not reported as unavailable' `
        ($cert.Count -eq 1 -and $cert[0].Status -eq 'PASS') "got $($cert.Count) row(s): $($cert.Status) - $($cert.Detail)"

    # The managing vCenter used to be parsed out of the host Uid, which breaks
    # for an administrator@vsphere.local style login.
    $ver = Get-ResultRow $r.Rows 'esx01.fixture.local' 'VersionVsVCenter'
    Assert-That 'host is matched to its managing vCenter' `
        ($ver.Count -eq 1 -and $ver[0].Status -eq 'PASS') "got: $($ver.Status) - $($ver.Detail)"

    # A stale IsoPath on a disconnected drive blocks nothing.
    $media = Get-ResultRow $r.Rows 'app01' 'MountedMedia'
    Assert-That 'disconnected CD drive with a stale ISO is not flagged' ($media.Count -eq 0) `
        "got: $($media.Detail)"

    # Reads MemoryTotalGB/MemoryUsageGB; a missing property makes the row vanish.
    Assert-That 'cluster RAM row is present' ((Get-ResultRow $r.Rows 'CL-FIXTURE' 'ClusterRAM').Count -eq 1)
    Assert-That 'storage paths are walked' `
        ((Get-ResultRow $r.Rows 'esx01.fixture.local' 'PathState')[0].Status -eq 'PASS')

    # --- HostDown -----------------------------------------------------------
    Write-Host "`nScenario: HostDown" -ForegroundColor Cyan
    $r = Invoke-Scenario 'HostDown'
    Assert-That 'exits 2 when a check FAILs' ($r.ExitCode -eq 2) "exit code was $($r.ExitCode)"

    # An unreachable host used to run every remaining check, emitting raw
    # cmdlet errors that never reached the report.
    $downRows = @($r.Rows | Where-Object { $_.Object -eq 'esx02.fixture.local' })
    Assert-That 'unreachable host produces exactly one row' ($downRows.Count -eq 1) `
        "got $($downRows.Count): $(($downRows | ForEach-Object { $_.Check }) -join ', ')"
    Assert-That 'that row is a ConnectionState FAIL' `
        ($downRows.Count -eq 1 -and $downRows[0].Check -eq 'ConnectionState' -and $downRows[0].Status -eq 'FAIL')
    Assert-That 'the reachable host is still fully checked' `
        (@($r.Rows | Where-Object { $_.Object -eq 'esx01.fixture.local' }).Count -gt 1)

    # --- Degraded -----------------------------------------------------------
    Write-Host "`nScenario: Degraded" -ForegroundColor Cyan
    $r = Invoke-Scenario 'Degraded'
    Assert-That 'exits 0 when only WARN/INFO are present' ($r.ExitCode -eq 0) "exit code was $($r.ExitCode)"

    # Exactly HostVersionSkewFailMajors behind is the documented WARN boundary,
    # not FAIL (-lt, not -le).
    $ver = Get-ResultRow $r.Rows 'esx01.fixture.local' 'VersionVsVCenter'
    Assert-That 'host exactly N majors behind vCenter is WARN, not FAIL' `
        ($ver.Count -eq 1 -and $ver[0].Status -eq 'WARN') "got: $($ver.Status) - $($ver.Detail)"

    # An unparsable value used to fall through to PASS.
    $hw = Get-ResultRow $r.Rows 'app01' 'HardwareVersion'
    Assert-That 'unparsable hardware version is INFO, not PASS' `
        ($hw.Count -eq 1 -and $hw[0].Status -eq 'INFO') "got: $($hw.Status) - $($hw.Detail)"

    # A failed LUN query used to be reported as "NFS-only host" - a false all-clear.
    $path = Get-ResultRow $r.Rows 'esx01.fixture.local' 'PathState'
    Assert-That 'failed LUN query is WARN, not a no-block-storage all-clear' `
        ($path.Count -eq 1 -and $path[0].Status -eq 'WARN' -and $path[0].Detail -notmatch 'NFS-only') `
        "got: $($path.Status) - $($path.Detail)"

    # An absent advanced setting used to read as "password aging disabled".
    $pw = Get-ResultRow $r.Rows 'esx01.fixture.local' 'PasswordExpirationPolicy'
    Assert-That 'absent password setting is INFO, not a false "disabled" WARN' `
        ($pw.Count -eq 1 -and $pw[0].Status -eq 'INFO') "got: $($pw.Status) - $($pw.Detail)"

    $cert = Get-ResultRow $r.Rows 'esx01.fixture.local' 'CertificateExpiry'
    Assert-That 'certificate inside the warning window is WARN' `
        ($cert.Count -eq 1 -and $cert[0].Status -eq 'WARN') "got: $($cert.Status) - $($cert.Detail)"

    # --- MultiVCenter -------------------------------------------------------
    Write-Host "`nScenario: MultiVCenter" -ForegroundColor Cyan
    # Two vCenters on different versions, each with its own host. The managing
    # vCenter used to be parsed out of the host's Uid, which captures the SSO
    # domain for an administrator@vsphere.local login; the lookup then missed
    # and, with more than one connection, there was no single-connection
    # fallback - every host reported "could not determine ... skipped". A host
    # paired with the wrong vCenter would report a version mismatch instead.
    $r = Invoke-Scenario 'MultiVCenter' -VCenter @('vcenter-a.fixture.invalid', 'vcenter-b.fixture.invalid')
    Assert-That 'exits 0' ($r.ExitCode -eq 0) "exit code was $($r.ExitCode)"

    foreach ($pair in @(
        @{ Host = 'vcenter-a-esx01.fixture.local'; VC = '8.0.2' }
        @{ Host = 'vcenter-b-esx01.fixture.local'; VC = '7.0.3' }
    )) {
        $ver = Get-ResultRow $r.Rows $pair.Host 'VersionVsVCenter'
        Assert-That "$($pair.Host) is paired with its own vCenter ($($pair.VC))" `
            ($ver.Count -eq 1 -and $ver[0].Status -eq 'PASS' -and $ver[0].Detail -match [regex]::Escape($pair.VC)) `
            "got: $($ver.Status) - $($ver.Detail)"
    }

    Assert-That 'no host is reported as unmatched to a vCenter' `
        (@($r.Rows | Where-Object { $_.Check -eq 'VersionVsVCenter' -and $_.Status -eq 'INFO' }).Count -eq 0) `
        (($r.Rows | Where-Object { $_.Check -eq 'VersionVsVCenter' -and $_.Status -eq 'INFO' } | ForEach-Object { $_.Detail }) -join '; ')

    # --- ConnectFail --------------------------------------------------------
    Write-Host "`nScenario: ConnectFail" -ForegroundColor Cyan
    $r = Invoke-Scenario 'ConnectFail'
    Assert-That 'exits 1 when the run itself errors' ($r.ExitCode -eq 1) "exit code was $($r.ExitCode)"
    # The reports are written from the finally block, so a failed run still
    # produces them.
    Assert-That 'still writes an HTML report' ($null -ne $r.Html)
    Assert-That 'still writes a CSV report'   ($null -ne $r.Csv)
    Assert-That 'records the connection failure' `
        (@($r.Rows | Where-Object { $_.Category -eq 'Connection' -and $_.Status -eq 'FAIL' }).Count -ge 1)
}
finally {
    if ($KeepOutput) {
        Write-Host "`nOutput kept at: $WorkPath"
    } elseif (Test-Path -LiteralPath $WorkPath) {
        Remove-Item -LiteralPath $WorkPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
if ($script:Failures -gt 0) {
    Write-Host "$($script:Failures) of $($script:Checks) assertions FAILED" -ForegroundColor Red
    exit 1
}
Write-Host "All $($script:Checks) assertions passed" -ForegroundColor Green
exit 0
