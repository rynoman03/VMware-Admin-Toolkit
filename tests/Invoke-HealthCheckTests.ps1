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
    param(
        [string]   $Scenario,
        [string[]] $VCenter = @($vcName),
        # Extra arguments for the script under test. Only supported on the
        # single-vCenter path, which invokes via -File.
        [string[]] $ExtraArgs = @(),
        # Output folder name, so the same scenario can be run more than once.
        [string]   $Label,
        # How to invoke the script. -File propagates the exit code but passes
        # arguments as plain strings; -Command parses them as PowerShell but
        # needs $LASTEXITCODE propagated by hand. Both are exercised.
        [ValidateSet('File', 'Command')] [string] $Via
    )
    if (-not $Label) { $Label = $Scenario }
    # A list cannot be passed through -File at all, so multiple vCenters always
    # go via -Command.
    if (-not $Via) { $Via = if ($VCenter.Count -gt 1) { 'Command' } else { 'File' } }
    if ($Via -eq 'File' -and $VCenter.Count -gt 1) {
        throw '-File cannot express a vCenter list.'
    }

    $dir = Join-Path $WorkPath $Label
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $log = Join-Path $dir 'console.log'

    $savedModulePath = $env:PSModulePath
    $savedEap        = $ErrorActionPreference
    $env:PSModulePath = $stubRoot + [System.IO.Path]::PathSeparator + $savedModulePath
    $env:HEALTHCHECK_FIXTURE_SCENARIO = $Scenario
    $probe = Join-Path $dir 'powercli-config.txt'
    $env:HEALTHCHECK_FIXTURE_PROBE = $probe
    $callLog = Join-Path $dir 'inventory-calls.txt'
    $env:HEALTHCHECK_FIXTURE_CALLLOG = $callLog
    # Windows PowerShell turns anything a native command writes to stderr into
    # an error record, which the Stop preference above makes terminating. The
    # ConnectFail scenario writes to stderr by design, so that would abort the
    # runner instead of letting the scenario's exit code be asserted on.
    $ErrorActionPreference = 'Continue'
    try {
        if ($Via -eq 'Command') {
            $literal = ($VCenter | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ','
            $extra   = if ($ExtraArgs.Count -gt 0) { ' ' + ($ExtraArgs -join ' ') } else { '' }
            & $pwshExe -NoProfile -Command `
                "& '$ScriptPath' -VCenter $literal -ReportPath '$dir'$extra; exit `$LASTEXITCODE" *> $log
        } else {
            & $pwshExe -NoProfile -File $ScriptPath -VCenter $VCenter[0] -ReportPath $dir @ExtraArgs *> $log
        }
        $code = $LASTEXITCODE
    } finally {
        $env:PSModulePath      = $savedModulePath
        $ErrorActionPreference = $savedEap
        Remove-Item Env:\HEALTHCHECK_FIXTURE_SCENARIO -ErrorAction SilentlyContinue
        Remove-Item Env:\HEALTHCHECK_FIXTURE_PROBE -ErrorAction SilentlyContinue
        Remove-Item Env:\HEALTHCHECK_FIXTURE_CALLLOG -ErrorAction SilentlyContinue
    }

    $csv  = Get-ChildItem -Path $dir -Filter '*.csv'  -ErrorAction SilentlyContinue | Select-Object -First 1
    $html = Get-ChildItem -Path $dir -Filter '*.html' -ErrorAction SilentlyContinue | Select-Object -First 1

    [pscustomobject]@{
        Scenario  = $Scenario
        Calls     = if (Test-Path $callLog) { @(Get-Content -LiteralPath $callLog) } else { @() }
        ExitCode = $code
        Rows     = if ($csv) { @(Import-Csv -Path $csv.FullName) } else { @() }
        Csv      = $csv
        Html     = $html
        Log      = $log
        # The tail of the child's own output. A failure that reproduces only on
        # one PowerShell edition is otherwise invisible without downloading the
        # CI artifact, which is not always reachable.
        LogTail  = if (Test-Path -LiteralPath $log) {
            ((Get-Content -LiteralPath $log |
                Where-Object { $_ -match '\S' } |
                Select-Object -Last 3) -join ' | ')
        } else { '' }
        # What the script asked PowerCLI to do about certificates, or $null.
        CertPolicy = if (Test-Path -LiteralPath $probe) {
            ((Get-Content -LiteralPath $probe -Raw) -replace '(?s)^.*InvalidCertificateAction=', '').Trim()
        } else { $null }
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
        ($cert.Count -eq 1 -and $cert[0].Status -eq 'NORMAL') "got $($cert.Count) row(s): $($cert.Status) - $($cert.Detail)"

    # The managing vCenter used to be parsed out of the host Uid, which breaks
    # for an administrator@vsphere.local style login.
    $ver = Get-ResultRow $r.Rows 'esx01.fixture.local' 'VersionVsVCenter'
    Assert-That 'host is matched to its managing vCenter' `
        ($ver.Count -eq 1 -and $ver[0].Status -eq 'NORMAL') "got: $($ver.Status) - $($ver.Detail)"

    # A stale IsoPath on a disconnected drive blocks nothing.
    $media = Get-ResultRow $r.Rows 'app01' 'MountedMedia'
    Assert-That 'disconnected CD drive with a stale ISO is not flagged' ($media.Count -eq 0) `
        "got: $($media.Detail)"

    # Reads MemoryTotalGB/MemoryUsageGB; a missing property makes the row vanish.
    Assert-That 'cluster RAM row is present' ((Get-ResultRow $r.Rows 'CL-FIXTURE' 'ClusterRAM').Count -eq 1)
    Assert-That 'storage paths are walked' `
        ((Get-ResultRow $r.Rows 'esx01.fixture.local' 'PathState')[0].Status -eq 'NORMAL')

    $svcOk = Get-ResultRow $r.Rows 'esx01.fixture.local' 'Services'
    Assert-That 'all start-with-host services running is NORMAL' `
        ($svcOk.Count -eq 1 -and $svcOk[0].Status -eq 'NORMAL') "got: $($svcOk.Status) - $($svcOk.Detail)"

    $linkOk = Get-ResultRow $r.Rows 'esx01.fixture.local' 'NicLinkState'
    Assert-That 'uplinks with link are NORMAL' `
        ($linkOk.Count -eq 1 -and $linkOk[0].Status -eq 'NORMAL') "got: $($linkOk.Status) - $($linkOk.Detail)"
    Assert-That 'an unassigned NIC with no cable is not reported as down' `
        ($linkOk.Count -eq 1 -and $linkOk[0].Detail -notmatch 'vmnic7') "got: $($linkOk.Detail)"
    $redOk = Get-ResultRow $r.Rows 'esx01.fixture.local' 'UplinkRedundancy'
    Assert-That 'two live uplinks is NORMAL' `
        ($redOk.Count -eq 1 -and $redOk[0].Status -eq 'NORMAL') "got: $($redOk.Status) - $($redOk.Detail)"
    $dnsOk = Get-ResultRow $r.Rows 'esx01.fixture.local' 'DNS'
    Assert-That 'configured DNS servers are NORMAL' `
        ($dnsOk.Count -eq 1 -and $dnsOk[0].Status -eq 'NORMAL') "got: $($dnsOk.Status) - $($dnsOk.Detail)"

    # Inventory is read in bulk, so the number of API calls must depend on the
    # number of CONNECTIONS, not on how many hosts, LUNs or VMs there are.
    # Behavioural assertions alone would not notice a refactor that quietly
    # reintroduced a per-host or per-LUN round-trip, so count them directly.
    # One connection, two hosts, two LUNs each, one VM:
    #   HostSystem, ComputeResource, ClusterComputeResource, Datastore,
    #   VirtualMachine  (5 Get-View) + Get-VM + Get-Snapshot
    Assert-That 'inventory is read in a fixed number of bulk calls' `
        ($r.Calls.Count -le 8) "made $($r.Calls.Count) calls: $($r.Calls -join ', ')"
    Assert-That 'exactly one HostSystem view call for all hosts' `
        (@($r.Calls | Where-Object { $_ -eq 'Get-View:HostSystem' }).Count -eq 1) `
        "got: $($r.Calls -join ', ')"
    Assert-That 'exactly one VirtualMachine view call for all VMs' `
        (@($r.Calls | Where-Object { $_ -eq 'Get-View:VirtualMachine' }).Count -eq 1) `
        "got: $($r.Calls -join ', ')"
    Assert-That 'no per-LUN or per-host storage calls remain' `
        (@($r.Calls | Where-Object { $_ -match 'ScsiLun|VMHostService|AdvancedSetting|CDDrive|FloppyDrive' }).Count -eq 0) `
        "got: $($r.Calls -join ', ')"

    # The EVC detail spells the acronym out; that wording was lost in the same
    # revert that took the ConnectionState fix.
    $evcRow = @($r.Rows | Where-Object { $_.Check -eq 'EVC' })
    Assert-That 'EVC detail explains the acronym' `
        ($evcRow.Count -ge 1 -and $evcRow[0].Detail -match 'Enhanced vMotion Compatibility') `
        "got: $($evcRow.Detail)"

    # The stub only answers for advanced settings that exist on a real ESXi
    # host, so this fails if the check asks for a setting name that doesn't.
    # It shipped asking for 'Security.PasswordExpirationInDays', which isn't
    # one, and every host silently reported INFO instead of a real policy.
    $pwOk = Get-ResultRow $r.Rows 'esx01.fixture.local' 'PasswordExpirationPolicy'
    Assert-That 'password policy resolves a real advanced setting, not INFO' `
        ($pwOk.Count -eq 1 -and $pwOk[0].Status -eq 'NORMAL' -and $pwOk[0].Detail -match 'Security\.PasswordMaxDays') `
        "got: $($pwOk.Status) - $($pwOk.Detail)"

    # -TrustAllCertificates is a [bool] defaulting to $true rather than a
    # [switch], because a switch defaulting to $true cannot be turned off by
    # its bare form. These two assert that the parameter actually reaches
    # PowerCLI, across the -File boundary where only the :$false form binds.
    Assert-That 'certificate errors are ignored by default' `
        ($r.CertPolicy -eq 'Ignore') "InvalidCertificateAction was '$($r.CertPolicy)'"

    # Via -Command, where arguments are parsed as PowerShell. Under -File they
    # are plain strings, and whether a literal "$false" binds to a [bool]
    # there is edition-specific - see the diagnostic below.
    $strict = Invoke-Scenario 'Healthy' -Label 'HealthyStrictCert' -Via Command `
        -ExtraArgs @('-TrustAllCertificates:$false')
    Assert-That '-TrustAllCertificates:$false requires a valid chain' `
        ($strict.CertPolicy -eq 'Fail') `
        "InvalidCertificateAction was '$($strict.CertPolicy)'; exit $($strict.ExitCode); $($strict.LogTail)"
    Assert-That 'the strict run still completes' ($strict.ExitCode -eq 0) `
        "exit code was $($strict.ExitCode); $($strict.LogTail)"

    # The one that pins the [bool]: as a [switch] defaulting to $true, the bare
    # form bound to $true and did nothing, so an operator who wrote
    # -TrustAllCertificates expecting it to mean something got silence. A
    # [bool] requires a value, making that a binding error instead.
    $bare = Invoke-Scenario 'Healthy' -Label 'HealthyBareFlag' -Via File `
        -ExtraArgs @('-TrustAllCertificates')
    Assert-That 'bare -TrustAllCertificates is rejected, not silently ignored' `
        ($bare.ExitCode -ne 0 -and $null -eq $bare.CertPolicy) `
        "exit $($bare.ExitCode), policy '$($bare.CertPolicy)'; $($bare.LogTail)"

    # -File does not parse its arguments as PowerShell, and whether a literal
    # "$false" reaches a [bool] parameter through it is edition-specific. The
    # scripts' help makes a claim about this per edition, so pin it here
    # rather than leaving it as prose that can quietly go stale.
    $viaFile = Invoke-Scenario 'Healthy' -Label 'HealthyStrictCertViaFile' -Via File `
        -ExtraArgs @('-TrustAllCertificates:$false')
    Write-Host ("  NOTE  -File with -TrustAllCertificates:`$false -> exit $($viaFile.ExitCode), policy '$($viaFile.CertPolicy)'") -ForegroundColor DarkGray
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        # Windows PowerShell passes the literal string "$false", which a [bool]
        # rejects. The point worth pinning is that it fails loudly rather than
        # falling back to the trusting default.
        Assert-That '-File rejects the colon form on Windows PowerShell, without trusting' `
            ($viaFile.ExitCode -ne 0 -and $viaFile.CertPolicy -ne 'Ignore') `
            "exit $($viaFile.ExitCode), policy '$($viaFile.CertPolicy)'; $($viaFile.LogTail)"
    } else {
        # PowerShell 7 converts a literal $true/$false in a -File argument.
        Assert-That '-File honours the colon form on PowerShell 7' `
            ($viaFile.CertPolicy -eq 'Fail') `
            "policy '$($viaFile.CertPolicy)'; $($viaFile.LogTail)"
    }

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

    # An unparsable value used to fall through to NORMAL.
    $hw = Get-ResultRow $r.Rows 'app01' 'HardwareVersion'
    Assert-That 'unparsable hardware version is INFO, not NORMAL' `
        ($hw.Count -eq 1 -and $hw[0].Status -eq 'INFO') "got: $($hw.Status) - $($hw.Detail)"

    # A failed LUN query used to be reported as "NFS-only host" - a false all-clear.
    $path = Get-ResultRow $r.Rows 'esx01.fixture.local' 'PathState'
    Assert-That 'failed LUN query is WARN, not a no-block-storage all-clear' `
        ($path.Count -eq 1 -and $path[0].Status -eq 'WARN' -and $path[0].Detail -notmatch 'NFS-only') `
        "got: $($path.Status) - $($path.Detail)"

    # A healthy, powered-on VM whose Runtime.ConnectionState never comes back
    # must be INFO, never FAIL. Reporting running VMs as failed - with a blank
    # Detail, because "$null" stringifies to '' - was the original bug, and it
    # regressed once when a later merge silently reverted the fix, so this is
    # the guard against that happening again.
    $ghost = Get-ResultRow $r.Rows 'ghost01' 'ConnectionState'
    Assert-That 'unreadable connection state is INFO, not FAIL' `
        ($ghost.Count -eq 1 -and $ghost[0].Status -eq 'INFO') `
        "got: $($ghost.Status) - $($ghost.Detail)"
    Assert-That 'unreadable connection state still explains itself' `
        ($ghost.Count -eq 1 -and -not [string]::IsNullOrWhiteSpace($ghost[0].Detail)) `
        "Detail was blank"

    # $null is not $false: claiming NORMAL would report a clean result that was
    # never actually checked.
    $ghostCons = Get-ResultRow $r.Rows 'ghost01' 'DiskConsolidation'
    Assert-That 'unreadable consolidation state is INFO, not a false NORMAL' `
        ($ghostCons.Count -eq 1 -and $ghostCons[0].Status -eq 'INFO') `
        "got: $($ghostCons.Status) - $($ghostCons.Detail)"

    # A cluster whose view never populates Summary/Configuration must not have
    # findings invented for it. Reporting "EVC not configured" or "admission
    # control Disabled" from a $null is claiming an answer that was never
    # obtained - the same shape as the VM connection-state bug.
    $blindEvc = Get-ResultRow $r.Rows 'CL-BLIND' 'EVC'
    Assert-That 'unreadable EVC state says so, rather than "not configured"' `
        ($blindEvc.Count -eq 1 -and $blindEvc[0].Status -eq 'INFO' -and $blindEvc[0].Detail -match 'not reported by vCenter') `
        "got: $($blindEvc.Status) - $($blindEvc.Detail)"

    $blindAc = Get-ResultRow $r.Rows 'CL-BLIND' 'AdmissionControl'
    Assert-That 'unreadable admission control is INFO, not a false "Disabled"' `
        ($blindAc.Count -eq 1 -and $blindAc[0].Status -eq 'INFO') `
        "got: $($blindAc.Status) - $($blindAc.Detail)"

    # ...but a cluster that genuinely has EVC off must still WARN, so the fix
    # above cannot have been made by simply never warning.
    # EVC off is INFO, not a finding - but it must still say it is OFF, not
    # that it could not be read, or the two cases have been conflated.
    $realNoEvc = Get-ResultRow $r.Rows 'CL-NOEVC' 'EVC'
    Assert-That 'EVC genuinely off is INFO and says it is not configured' `
        ($realNoEvc.Count -eq 1 -and $realNoEvc[0].Status -eq 'INFO' -and $realNoEvc[0].Detail -match 'is not configured') `
        "got: $($realNoEvc.Status) - $($realNoEvc.Detail)"

    $realNoAc = Get-ResultRow $r.Rows 'CL-NOEVC' 'AdmissionControl'
    Assert-That 'admission control genuinely off still WARNs' `
        ($realNoAc.Count -eq 1 -and $realNoAc[0].Status -eq 'WARN') `
        "got: $($realNoAc.Status) - $($realNoAc.Detail)"

    # A datastore with no Summary must not be reported as inaccessible, and
    # must not be swept into a "all datastores accessible" all-clear either.
    $dsRow = Get-ResultRow $r.Rows 'esx01.fixture.local' 'DatastoreConnectivity'
    Assert-That 'datastore with unreadable Summary is not a false FAIL' `
        ($dsRow.Count -eq 1 -and $dsRow[0].Status -ne 'FAIL') `
        "got: $($dsRow.Status) - $($dsRow.Detail)"
    Assert-That 'datastore with unreadable Summary is not a false all-clear' `
        ($dsRow.Count -eq 1 -and $dsRow[0].Detail -notmatch 'All datastores accessible') `
        "got: $($dsRow.Status) - $($dsRow.Detail)"

    # A service set to start with the host but stopped is the point of the
    # check; a service with policy 'off' that is stopped was switched off on
    # purpose and must not be reported as down.
    $svc = Get-ResultRow $r.Rows 'esx01.fixture.local' 'Services'
    Assert-That 'a stopped start-with-host service is WARN and named' `
        ($svc.Count -eq 1 -and $svc[0].Status -eq 'WARN' -and $svc[0].Detail -match 'sfcbd-watchdog') `
        "got: $($svc.Status) - $($svc.Detail)"
    Assert-That 'a deliberately disabled service is not reported as down' `
        ($svc.Count -eq 1 -and $svc[0].Detail -notmatch 'snmpd') `
        "got: $($svc.Detail)"
    Assert-That 'services with their own checks are not double-reported' `
        ($svc.Count -eq 1 -and $svc[0].Detail -notmatch 'ntpd|TSM-SSH') `
        "got: $($svc.Detail)"

    # An assigned uplink with no link is a real finding; the spare NIC with no
    # cable in it, on the same host, must stay out of the report.
    $link = Get-ResultRow $r.Rows 'esx01.fixture.local' 'NicLinkState'
    # One of two uplinks down: traffic still flows, so WARN not FAIL - the
    # same grading PathState uses for a degraded-but-serving LUN.
    Assert-That 'an uplink with no link, with one still up, is WARN and names the NIC' `
        ($link.Count -eq 1 -and $link[0].Status -eq 'WARN' -and $link[0].Detail -match 'vmnic1') `
        "got: $($link.Status) - $($link.Detail)"
    Assert-That 'the spare NIC is still not reported' `
        ($link.Count -eq 1 -and $link[0].Detail -notmatch 'vmnic7') "got: $($link.Detail)"

    # Losing one of two uplinks also costs the redundancy.
    $red = Get-ResultRow $r.Rows 'esx01.fixture.local' 'UplinkRedundancy'
    Assert-That 'a switch down to one live uplink WARNs' `
        ($red.Count -eq 1 -and $red[0].Status -eq 'WARN' -and $red[0].Detail -match 'vSwitch0') `
        "got: $($red.Status) - $($red.Detail)"

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
            ($ver.Count -eq 1 -and $ver[0].Status -eq 'NORMAL' -and $ver[0].Detail -match [regex]::Escape($pair.VC)) `
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
