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

    # The report has to say which version of the script produced it. Without
    # that, a stale copy on a jump box is indistinguishable from the current
    # one - a report showing findings that were already fixed reads as a
    # regression rather than as an out-of-date script. Matched from the script
    # itself so the assertion cannot drift from the value it is checking.
    $declared = (Select-String -Path $ScriptPath -Pattern "^\`$script:ScriptVersion\s*=\s*'([^']+)'" |
                    Select-Object -First 1).Matches[0].Groups[1].Value
    Assert-That 'the script declares a version' `
        (-not [string]::IsNullOrWhiteSpace($declared)) "got: '$declared'"
    $htmlText = Get-Content -LiteralPath $r.Html.FullName -Raw
    Assert-That 'the HTML report stamps the script version in its header' `
        ($htmlText -match ([regex]::Escape("v$declared"))) "version '$declared' not found in the report header"
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

    # Snapshot SIZE needs PowerCLI objects, but only for the VMs that actually
    # have a snapshot - which the VM views already state. Asking Get-VM for the
    # whole inventory to size a handful of snapshots was a full extra
    # retrieval of every VM on every run.
    Assert-That 'snapshot sizing never retrieves the whole VM inventory' `
        (@($r.Calls | Where-Object { $_ -like 'Get-VM:all*' }).Count -eq 0) `
        "got: $($r.Calls -join ', ')"
    $scoped = @($r.Calls | Where-Object { $_ -like 'Get-VM:scoped:*' })
    Assert-That 'snapshot sizing asks only about the VMs holding snapshots' `
        ($scoped.Count -eq 1 -and $scoped[0] -like 'Get-VM:scoped:1:*') `
        "got: $($r.Calls -join ', ')"
    # A MoRef is unique only within one vCenter, so the lookup must name the
    # server it belongs to or it can match another vCenter's VM of the same id.
    Assert-That 'snapshot sizing is bound to the VM own vCenter' `
        ($scoped.Count -eq 1 -and $scoped[0] -like '*:server') `
        "got: $($r.Calls -join ', ')"

    # The snapshot tree is walked recursively, so a snapshot nested under
    # another is reported rather than only the root.
    $snapRows = @($r.Rows | Where-Object { $_.Object -eq 'snapvm01' -and $_.Check -eq 'Snapshot' })
    Assert-That 'every snapshot in the tree is reported, roots and children' `
        ($snapRows.Count -eq 3) "got $($snapRows.Count) row(s): $($snapRows.Detail -join ' | ')"
    # Two of the three carry a size. A stub or a lookup that collapses the
    # result set into one row would size at most one of them.
    Assert-That 'each snapshot gets its own size, not the first one repeated' `
        (@($snapRows | Where-Object { $_.Detail -match '12\.5GB' }).Count -eq 1 -and
         @($snapRows | Where-Object { $_.Detail -match '3\.5GB' }).Count -eq 1) `
        "got: $(($snapRows | ForEach-Object { $_.Detail }) -join ' | ')"
    $oldSnap = @($snapRows | Where-Object { $_.Detail -match 'before-patching' })
    Assert-That 'a snapshot past the age threshold is WARN and carries its size' `
        ($oldSnap.Count -eq 1 -and $oldSnap[0].Status -eq 'WARN' -and $oldSnap[0].Detail -match '45d, 12\.5GB') `
        "got: $($oldSnap.Status) - $($oldSnap.Detail)"
    $newSnap = @($snapRows | Where-Object { $_.Detail -match 'after-patching' })
    Assert-That 'a recent snapshot with no resolvable size is still reported' `
        ($newSnap.Count -eq 1 -and $newSnap[0].Status -eq 'INFO' -and $newSnap[0].Detail -match 'age 1d') `
        "got: $($newSnap.Status) - $($newSnap.Detail)"

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

    # VMware Tools severity. On a real estate this was 155 of 177 FAIL rows -
    # the single most common finding there is - which meant the critical count
    # was dominated by a hygiene item and the handful of genuinely broken
    # things were buried underneath it.
    $noTools = Get-ResultRow $r.Rows 'notools01' 'VMwareTools'
    Assert-That 'a VM with no Tools is WARN, not FAIL' `
        ($noTools.Count -eq 1 -and $noTools[0].Status -eq 'WARN') "got: $($noTools.Status) - $($noTools.Detail)"
    Assert-That 'and the detail says what is actually lost' `
        ($noTools.Count -eq 1 -and $noTools[0].Detail -match 'gracefully' -and $noTools[0].Detail -match 'quiesced') `
        "got: $($noTools.Detail)"
    $toolsOff = Get-ResultRow $r.Rows 'toolsoff01' 'VMwareTools'
    Assert-That 'Tools installed but stopped is WARN' `
        ($toolsOff.Count -eq 1 -and $toolsOff[0].Status -eq 'WARN') "got: $($toolsOff.Status)"
    $toolsOld = Get-ResultRow $r.Rows 'toolsold01' 'VMwareTools'
    Assert-That 'out-of-date Tools is WARN' `
        ($toolsOld.Count -eq 1 -and $toolsOld[0].Status -eq 'WARN') "got: $($toolsOld.Status)"
    # The consequence that matters: missing Tools must not make the run look
    # like an outage to whatever is reading the exit code.
    Assert-That 'Tools findings alone do not raise the failure exit code' `
        (@($r.Rows | Where-Object { $_.Check -eq 'VMwareTools' -and $_.Status -eq 'FAIL' }).Count -eq 0) `
        "got: $(($r.Rows | Where-Object { $_.Check -eq 'VMwareTools' } | ForEach-Object { $_.Status }) -join ', ')"

    # A host whose connection state vCenter never reported. '' is not
    # 'connected', so a bare -ne test called a running host FAIL and printed
    # "State is  -" with a hole in it. The VM-side check was fixed for exactly
    # this; the host-side one still had it.
    $blind = Get-ResultRow $r.Rows 'esx-blindstate.fixture.local' 'ConnectionState'
    Assert-That 'an unreported host connection state is INFO, not FAIL' `
        ($blind.Count -eq 1 -and $blind[0].Status -eq 'INFO') "got: $($blind.Status) - $($blind.Detail)"
    Assert-That 'and it never prints a blank state' `
        ($blind.Count -eq 1 -and $blind[0].Detail -notmatch 'State is\s*-') "got: $($blind.Detail)"

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

    # No VM in this scenario has a snapshot, so the other half of the sizing
    # contract holds: the PowerCLI retrieval is skipped entirely rather than
    # run over the whole inventory to discover there was nothing to size.
    Assert-That 'no snapshots anywhere means no sizing calls at all' `
        (@($r.Calls | Where-Object { $_ -like 'Get-VM*' -or $_ -eq 'Get-Snapshot' }).Count -eq 0) `
        "got: $($r.Calls -join ', ')"

    # --- DeadSwitch ---------------------------------------------------------
    # A switch with every uplink down is the most urgent networking finding
    # the script produces, and it used to be the least actionable: the FAIL
    # branch printed the switch and a count while the WARN branch below it
    # named the actual NICs. Whoever picked it up had to log into the host to
    # learn which cable to look at.
    Write-Host "`nScenario: DeadSwitch" -ForegroundColor Cyan
    $r = Invoke-Scenario 'DeadSwitch'
    Assert-That 'exits 2 when a switch has no uplinks left' ($r.ExitCode -eq 2) "exit code was $($r.ExitCode)"
    $nic = Get-ResultRow $r.Rows 'esx01.fixture.local' 'NicLinkState'
    Assert-That 'a switch with every uplink down is FAIL' `
        ($nic.Count -eq 1 -and $nic[0].Status -eq 'FAIL') "got: $($nic.Status) - $($nic.Detail)"
    Assert-That 'and names the switch' `
        ($nic.Count -eq 1 -and $nic[0].Detail -match 'vSwitch1') "got: $($nic.Detail)"
    Assert-That 'and names every NIC that lost link, not just a count' `
        ($nic.Count -eq 1 -and $nic[0].Detail -match 'vmnic4' -and $nic[0].Detail -match 'vmnic5') `
        "got: $($nic.Detail)"
    # The spare NIC rule still holds: an unassigned NIC with no cable is
    # normal and must not be dragged into the finding.
    Assert-That 'the unassigned spare NIC is still not reported' `
        ($nic.Count -eq 1 -and $nic[0].Detail -notmatch 'vmnic7') "got: $($nic.Detail)"
    # The healthy switch on the same host must not appear in the finding.
    Assert-That 'the switch that still has link is not named as down' `
        ($nic.Count -eq 1 -and $nic[0].Detail -notmatch 'vSwitch0') "got: $($nic.Detail)"

    # The first column of each section should say what it lists. 'Object' is
    # the CSV's column name, not a word anyone scans a page of hosts for.
    $htmlText = Get-Content -LiteralPath $r.Html.FullName -Raw
    Assert-That 'host sections head their first column Host, not Object' `
        ($htmlText -match '<table data-section-table="sec-HostHealth[^"]*"><tr><th>Host</th>') `
        'no host section table headed "Host"'
    Assert-That 'VM sections head theirs VM' `
        ($htmlText -match '<table data-section-table="sec-VMCompliance[^"]*"><tr><th>VM</th>') `
        'no VM section table headed "VM"'

    # --- UnresolvedUplink ---------------------------------------------------
    # A switch whose uplink key has no matching physical NIC in
    # Config.Network.Pnic. The uplink was skipped silently, which left the
    # "any uplink up?" counter at zero - and that was read as "every uplink is
    # down" and reported FAIL. The giveaway in production was a FAIL detail
    # reading "0 of 1 uplink(s) up" with no NIC named in it: nothing had been
    # resolved, so there was nothing to name.
    Write-Host "`nScenario: UnresolvedUplink" -ForegroundColor Cyan
    $r = Invoke-Scenario 'UnresolvedUplink'
    $nic = Get-ResultRow $r.Rows 'esx01.fixture.local' 'NicLinkState'
    Assert-That 'an unreadable uplink is not reported as a dead switch' `
        ($nic.Count -eq 1 -and $nic[0].Status -ne 'FAIL') "got: $($nic.Status) - $($nic.Detail)"
    Assert-That 'and the row says the state is unknown, not healthy' `
        ($nic.Count -eq 1 -and $nic[0].Detail -match 'could not be read') "got: $($nic.Detail)"
    Assert-That 'and names the switch it could not read' `
        ($nic.Count -eq 1 -and $nic[0].Detail -match 'DSwitch-Prod') "got: $($nic.Detail)"
    # The readable switch on the same host is healthy, so the run must not
    # fail - but the unreadable one must not be swallowed by that all-clear.
    Assert-That 'an unreadable uplink alone does not fail the run' `
        ($r.ExitCode -eq 0) "exit code was $($r.ExitCode)"
    $red = Get-ResultRow $r.Rows 'esx01.fixture.local' 'UplinkRedundancy'
    Assert-That 'redundancy is not claimed for a switch that was never read' `
        ($red.Count -eq 1 -and $red[0].Detail -notmatch 'Every switch') "got: $($red.Status) - $($red.Detail)"

    # --- Updates ------------------------------------------------------------
    # "Is an update available" has no single source of truth in the vSphere
    # API, so the section has to be explicit about which source produced each
    # verdict - and must never imply an authority it doesn't have.
    Write-Host "`nScenario: Updates (no vLCM, no expected builds)" -ForegroundColor Cyan
    $r = Invoke-Scenario 'Healthy' -Label 'UpdatesBare'
    Assert-That 'exits 0' ($r.ExitCode -eq 0) "exit code was $($r.ExitCode)"
    $vcRow = @($r.Rows | Where-Object { $_.Check -eq 'VCenterBuild' })
    Assert-That 'vCenter build is reported even with nothing to compare against' `
        ($vcRow.Count -eq 1 -and $vcRow[0].Status -eq 'INFO' -and $vcRow[0].Detail -match 'build 22617221') `
        "got: $($vcRow.Status) - $($vcRow.Detail)"
    $esxRows = @($r.Rows | Where-Object { $_.Check -eq 'EsxiPatchLevel' })
    Assert-That 'every host reports a build' ($esxRows.Count -eq 2) "got $($esxRows.Count)"
    # An unjudged build must never read as an up-to-date one.
    Assert-That 'an uncompared build is INFO, never a false NORMAL' `
        (@($esxRows | Where-Object { $_.Status -ne 'INFO' }).Count -eq 0) `
        "got: $(($esxRows | ForEach-Object { $_.Status }) -join ', ')"
    Assert-That 'and says why it was not compared' `
        ($esxRows[0].Detail -match 'not been compared against anything') "got: $($esxRows[0].Detail)"
    Assert-That 'no Lifecycle Manager call when the module is absent' `
        (@($r.Calls | Where-Object { $_ -eq 'Get-Compliance' }).Count -eq 0) `
        "got: $($r.Calls -join ', ')"

    Write-Host "`nScenario: Updates (expected builds supplied)" -ForegroundColor Cyan
    $r = Invoke-Scenario 'Healthy' -Label 'UpdatesBuilds' `
        -ExtraArgs @('-ExpectedEsxiBuild', '24859861', '-ExpectedVCenterBuild', '24322831')
    $vcRow = @($r.Rows | Where-Object { $_.Check -eq 'VCenterBuild' })
    Assert-That 'vCenter behind the expected build is WARN' `
        ($vcRow.Count -eq 1 -and $vcRow[0].Status -eq 'WARN') "got: $($vcRow.Status) - $($vcRow.Detail)"
    $esxRows = @($r.Rows | Where-Object { $_.Check -eq 'EsxiPatchLevel' })
    Assert-That 'hosts behind the expected build are WARN' `
        (@($esxRows | Where-Object { $_.Status -eq 'WARN' }).Count -eq 2) `
        "got: $(($esxRows | ForEach-Object { $_.Status }) -join ', ')"

    # A host AHEAD of the standard is worth knowing about, but it is not a
    # missing update - reporting it as one would put a permanent WARN on every
    # host that got patched early.
    Write-Host "`nScenario: Updates (host ahead of the expected build)" -ForegroundColor Cyan
    $r = Invoke-Scenario 'Healthy' -Label 'UpdatesAhead' -ExtraArgs @('-ExpectedEsxiBuild', '1000')
    $esxRows = @($r.Rows | Where-Object { $_.Check -eq 'EsxiPatchLevel' })
    Assert-That 'a host newer than the expected build is INFO, not WARN' `
        (@($esxRows | Where-Object { $_.Status -eq 'INFO' -and $_.Detail -match 'NEWER' }).Count -eq 2) `
        "got: $(($esxRows | ForEach-Object { "$($_.Status) $($_.Detail)" }) -join ' | ')"
    # 22380479 vs 1000 compares the wrong way round as text.
    Assert-That 'builds are compared as numbers, not as strings' `
        (@($esxRows | Where-Object { $_.Status -eq 'WARN' }).Count -eq 0) `
        "got: $(($esxRows | ForEach-Object { $_.Status }) -join ', ')"

    # Where baselines exist they ARE the answer, and -ExpectedEsxiBuild must
    # not override them: the baseline is what this organisation decided
    # 'current' means, and it stays right with nobody editing the script.
    Write-Host "`nScenario: Updates (vLCM baselines attached)" -ForegroundColor Cyan
    $r = Invoke-Scenario 'VlcmBaselines' -ExtraArgs @('-ExpectedEsxiBuild', '22380479')
    Assert-That 'Lifecycle Manager is asked once for every host, not once per host' `
        (@($r.Calls | Where-Object { $_ -eq 'Get-Compliance' }).Count -eq 1) `
        "got: $($r.Calls -join ', ')"
    $nonComp = Get-ResultRow $r.Rows 'esx01.fixture.local' 'EsxiPatchLevel'
    Assert-That 'a host failing a baseline is WARN and names the baseline' `
        ($nonComp.Count -eq 1 -and $nonComp[0].Status -eq 'WARN' -and $nonComp[0].Detail -match 'Critical Host Patches') `
        "got: $($nonComp.Status) - $($nonComp.Detail)"
    $comp = Get-ResultRow $r.Rows 'esx02.fixture.local' 'EsxiPatchLevel'
    Assert-That 'a host compliant with every baseline is NORMAL' `
        ($comp.Count -eq 1 -and $comp[0].Status -eq 'NORMAL') "got: $($comp.Status) - $($comp.Detail)"
    $unscanned = Get-ResultRow $r.Rows 'esx03.fixture.local' 'EsxiPatchLevel'
    Assert-That 'baselines attached but never scanned is INFO, not a false NORMAL' `
        ($unscanned.Count -eq 1 -and $unscanned[0].Status -eq 'INFO' -and $unscanned[0].Detail -match 'not been scanned') `
        "got: $($unscanned.Status) - $($unscanned.Detail)"
    # esx01 matches -ExpectedEsxiBuild exactly, so a build comparison would
    # have called it NORMAL. The baseline says otherwise and must win.
    Assert-That 'the baseline verdict beats a matching -ExpectedEsxiBuild' `
        ($nonComp.Count -eq 1 -and $nonComp[0].Detail -notmatch 'expected build') `
        "got: $($nonComp.Detail)"

    # --- StaleToolsBundle ---------------------------------------------------
    # VMware Tools runs in the guest, so a host has no Tools version of its
    # own to be behind - but it does ship the package its VMs install from,
    # and when that is stale every VM on the host reports toolsOld at once.
    # The per-VM rows cannot show that pattern on a page of 155 of them.
    Write-Host "`nScenario: StaleToolsBundle" -ForegroundColor Cyan
    $r = Invoke-Scenario 'StaleToolsBundle'
    $bk = Get-ResultRow $r.Rows 'esx01.fixture.local' 'VMToolsBacklog'
    Assert-That 'a host whose VMs are mostly on old Tools is WARN' `
        ($bk.Count -eq 1 -and $bk[0].Status -eq 'WARN') "got: $($bk.Status) - $($bk.Detail)"
    Assert-That 'and points at the host bundle as the fix, not the VMs' `
        ($bk.Count -eq 1 -and $bk[0].Detail -match 'bundled Tools package') "got: $($bk.Detail)"
    Assert-That 'and counts them' `
        ($bk.Count -eq 1 -and $bk[0].Detail -match '4 of 6') "got: $($bk.Detail)"
    # A host carrying no powered-on VMs must not read as a clean Tools estate.
    $idle = Get-ResultRow $r.Rows 'esx02.fixture.local' 'VMToolsBacklog'
    Assert-That 'a host with no powered-on VMs says so rather than NORMAL' `
        ($idle.Count -eq 1 -and $idle[0].Status -eq 'INFO' -and $idle[0].Detail -match 'No powered-on VMs') `
        "got: $($idle.Status) - $($idle.Detail)"
    # Scattered Tools work is per-VM and already listed; repeating it here as
    # a finding would double-count the same backlog into the attention view.
    Assert-That 'the host rollup never raises the failure exit code' `
        (@($r.Rows | Where-Object { $_.Check -eq 'VMToolsBacklog' -and $_.Status -eq 'FAIL' }).Count -eq 0) `
        "got: $(($r.Rows | Where-Object { $_.Check -eq 'VMToolsBacklog' } | ForEach-Object { $_.Status }) -join ', ')"

    # --- ToolsVibVersion ----------------------------------------------------
    # The Tools package a host ships its VMs. Not in the vSphere API, so this
    # is the one check that costs a round trip per host - which is why it is
    # opt-in, and why the default run must not make those calls at all.
    Write-Host "`nScenario: ToolsVibVersion (switch off)" -ForegroundColor Cyan
    $r = Invoke-Scenario 'VlcmBaselines' -Label 'VibOff'
    Assert-That 'no esxcli calls when the switch is not passed' `
        (@($r.Calls | Where-Object { $_ -like 'Get-EsxCli*' }).Count -eq 0) `
        "got: $($r.Calls -join ', ')"
    Assert-That 'and no Tools package rows' `
        (@($r.Rows | Where-Object { $_.Check -eq 'ToolsVibVersion' }).Count -eq 0)

    Write-Host "`nScenario: ToolsVibVersion (switch on)" -ForegroundColor Cyan
    $r = Invoke-Scenario 'VlcmBaselines' -Label 'VibOn' -ExtraArgs @('-IncludeToolsVibVersion')
    # Exactly one esxcli call per host: the cost is already the objection to
    # this check, so a second call per host would matter.
    $esx = @($r.Calls | Where-Object { $_ -like 'Get-EsxCli*' })
    Assert-That 'exactly one esxcli call per connected host' `
        ($esx.Count -eq 3 -and (@($esx | Sort-Object -Unique).Count -eq 3)) `
        "got: $($esx -join ', ')"
    # Host objects come in one bulk call, not one per host.
    Assert-That 'host objects are fetched in bulk, not per host' `
        (@($r.Calls | Where-Object { $_ -like 'Get-VMHost:scoped:*' }).Count -eq 1) `
        "got: $($r.Calls -join ', ')"

    $behind = Get-ResultRow $r.Rows 'esx02.fixture.local' 'ToolsVibVersion'
    Assert-That 'a host on an older Tools package is WARN' `
        ($behind.Count -eq 1 -and $behind[0].Status -eq 'WARN') "got: $($behind.Status) - $($behind.Detail)"
    Assert-That 'and names both versions so the gap is visible' `
        ($behind.Count -eq 1 -and $behind[0].Detail -match '12\.3\.0' -and $behind[0].Detail -match '12\.4\.5') `
        "got: $($behind.Detail)"
    $level = Get-ResultRow $r.Rows 'esx01.fixture.local' 'ToolsVibVersion'
    Assert-That 'a host on the newest package is NORMAL' `
        ($level.Count -eq 1 -and $level[0].Status -eq 'NORMAL') "got: $($level.Status) - $($level.Detail)"
    # esx03 is on build 9999999, which is numerically older than esx01's
    # 23787635 but sorts after it as text. Compared as strings, esx03 would be
    # crowned the newest and esx01 reported as behind it - the finding exactly
    # inverted on the host that is actually current.
    $trap = Get-ResultRow $r.Rows 'esx03.fixture.local' 'ToolsVibVersion'
    Assert-That 'version builds compare as numbers, not as text' `
        ($trap.Count -eq 1 -and $trap[0].Status -eq 'WARN' -and $trap[0].Detail -match '9999999 is older') `
        "got: $($trap.Status) - $($trap.Detail)"
    # Being behind the estate is a consistency finding, not an outage.
    Assert-That 'the Tools package check never raises the failure exit code' `
        (@($r.Rows | Where-Object { $_.Check -eq 'ToolsVibVersion' -and $_.Status -eq 'FAIL' }).Count -eq 0)

    # esxcli needs the host reachable and the account privileged. Failing to
    # ask is not evidence the host is behind.
    Write-Host "`nScenario: ToolsVibUnreadable" -ForegroundColor Cyan
    $r = Invoke-Scenario 'ToolsVibUnreadable' -ExtraArgs @('-IncludeToolsVibVersion')
    $denied = @($r.Rows | Where-Object { $_.Check -eq 'ToolsVibVersion' })
    Assert-That 'an esxcli failure is INFO, never a false "behind"' `
        ($denied.Count -gt 0 -and @($denied | Where-Object { $_.Status -ne 'INFO' }).Count -eq 0) `
        "got: $(($denied | ForEach-Object { $_.Status }) -join ', ')"
    Assert-That 'and says why it could not be read' `
        ($denied.Count -gt 0 -and $denied[0].Detail -match 'esxcli') "got: $($denied[0].Detail)"
    Assert-That 'an unreadable Tools package does not fail the run' `
        ($r.ExitCode -eq 0) "exit code was $($r.ExitCode)"

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
