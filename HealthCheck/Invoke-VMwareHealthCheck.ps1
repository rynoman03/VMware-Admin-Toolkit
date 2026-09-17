<#
.SYNOPSIS
    Read-only health check & compliance report for a vCenter environment.

.DESCRIPTION
    Connects to one or more vCenter Servers and evaluates four areas:
        1. Host health     - connection state, NTP, syslog, uptime, datastore connectivity, storage path state, TLS certificate expiry (hosts + vCenter), local account password expiration policy, ESXi build vs vCenter build, lockdown mode, SSH service state
        2. VM compliance   - connection state (orphaned/inaccessible VMs), disk consolidation needed, VMware Tools, VM hardware version, mounted ISOs, floppy drives, snapshot age
        3. Capacity        - datastore free space, cluster CPU/RAM utilization
        4. Cluster config  - HA / DRS / admission control

    Every check is READ-ONLY. The script never changes configuration.
    Results are written to the console (color-coded) and an HTML report.

.PARAMETER VCenter
    One or more vCenter Server FQDNs/IPs to connect to.

.PARAMETER Credential
    PSCredential for vCenter. If omitted, you are prompted (or pass-through/SSO is used).

.PARAMETER ReportPath
    Folder for the HTML report. Defaults to the current directory.

.PARAMETER SnapshotAgeWarningDays
    Snapshots at least this many days old are flagged. Default 3.

.PARAMETER DatastoreFreeWarnPercent
    Datastores below this free % are WARN. Default 20.

.PARAMETER DatastoreFreeCritPercent
    Datastores below this free % are FAIL. Default 10.

.PARAMETER ClusterUsageWarnPercent
    Cluster CPU/RAM usage at or above this % is WARN. Default 80.

.PARAMETER OSDriveFreeWarnGB
    Guest OS system drive (C:\ on Windows, / on Linux) with less than this many GB
    free is flagged. Requires VMware Tools running in the guest. Default 20.

.PARAMETER DataDriveFreeWarnGB
    Any other guest drive (non-OS volume) with less than this many GB free is
    flagged. Requires VMware Tools running in the guest. Default 10.

.PARAMETER CertExpiryWarnDays
    ESXi host and vCenter TLS certificates expiring within this many days are
    WARN. Default 30.

.PARAMETER CertExpiryCritDays
    ESXi host and vCenter TLS certificates expiring within this many days (or
    already expired) are FAIL. Default 7.

.PARAMETER HardwareVersionWarnNum
    VM hardware versions below this number (vmx-NN) are flagged as old. Default 13.

.PARAMETER HostVersionSkewFailMajors
    An ESXi host running more than this many major versions behind its
    vCenter is FAIL (outside VMware's supported interop range). A host
    newer than vCenter is always FAIL regardless of this value, since that's
    unsupported outright. Default 2.

.PARAMETER ExpectedSyslogServer
    Optional baseline of the remote syslog target(s) every host is supposed to
    be pointing at, e.g. -ExpectedSyslogServer 'udp://loghost01.corp.local:514'.
    When supplied, the Syslog check compares each host's configured targets
    against this list in BOTH directions and WARNs on any divergence: an
    expected collector that is missing, or a configured collector that is not
    in the baseline (the stale/decommissioned-collector case). Omit it and the
    check behaves as before - it only verifies that some remote target is set.

    Matching ignores a 'udp://' / 'tcp://' / 'ssl://' scheme prefix and is
    case-insensitive, so 'udp://loghost:514', 'loghost:514' and 'LOGHOST:514'
    all compare equal. Leave the ':port' off an expected entry to accept any
    port on that host.

.PARAMETER ExpectedNtpServer
    Optional baseline of the NTP server(s) every host is supposed to be using,
    e.g. -ExpectedNtpServer 10.10.0.10,10.10.0.11. Compared exactly like
    -ExpectedSyslogServer (both directions, WARN on divergence) on top of the
    existing "servers configured and ntpd running" checks. Omit it and the
    check behaves as before.

.PARAMETER TrustAllCertificates
    Whether to ignore untrusted/self-signed vCenter TLS certificates when
    connecting (PowerCLI's InvalidCertificateAction). Default $true, since
    many vCenters run on internal or self-signed certs. Pass
    -TrustAllCertificates:$false to require a valid chain instead.

    Use the colon form. Whether it survives the command line depends on how
    the script is launched, because -File does not parse its arguments as
    PowerShell:

      - From a PowerShell session, or via `pwsh -File`: works. PowerShell 7
        converts a literal $true/$false in a -File argument.
      - Via `powershell.exe -File` (Windows PowerShell 5.1): does NOT work.
        5.1 passes it as the literal string "$false", which a [bool]
        rejects, and the run stops with a parameter binding error. That
        fails safe - it does not quietly fall back to $true - but to
        actually turn the setting off from a 5.1 scheduled task, use
        -Command and propagate the exit code yourself:

          powershell -Command "& .\<script>.ps1 -VCenter vc1 -TrustAllCertificates:$false; exit $LASTEXITCODE"

    The space-separated -TrustAllCertificates $false is rejected under
    -File on both editions, for the same reason.

    Deliberately a [bool] and not a [switch]: a switch that defaults to
    $true cannot be turned off by its bare form, so -TrustAllCertificates
    on its own would be a no-op and only the :$false form would do
    anything. As a [bool] the parameter requires a value, which is the
    behaviour the name implies.

.EXAMPLE
    .\Invoke-VMwareHealthCheck.ps1 -VCenter vcenter01.corp.local

.EXAMPLE
    $cred = Get-Credential
    .\Invoke-VMwareHealthCheck.ps1 -VCenter vc1,vc2 -Credential $cred -ReportPath C:\Reports

.EXAMPLE
    # Flag any host whose syslog/NTP settings have drifted from the standard build
    .\Invoke-VMwareHealthCheck.ps1 -VCenter vcenter01.corp.local `
        -ExpectedSyslogServer 'udp://loghost01.corp.local:514' `
        -ExpectedNtpServer 10.10.0.10,10.10.0.11

.NOTES
    Requires PowerCLI. Install with:  Install-Module VCF.PowerCLI -Scope CurrentUser
    (older releases use the VMware.PowerCLI module name; both are supported)

    Runtime: scales with total inventory across all connected vCenters,
    since checks run per-host and per-VM (each a round-trip to vCenter).
    Rough estimates:
      ~25 VMs / 2-3 hosts ....... under a minute
      ~150 VMs .................. a few minutes
      500+ VMs .................. 10+ minutes
    Add ~10-30s for the initial PowerCLI module import. Multiple vCenters
    add their inventories together. As long as [PASS]/[WARN] lines keep
    printing it is working, not hung.

    Output: every result shown on the console is also written to two
    timestamped files in -ReportPath (default: current directory):
      VMwareHealthCheck-<yyyyMMdd-HHmmss>.html  (styled table)
      VMwareHealthCheck-<yyyyMMdd-HHmmss>.csv   (same rows, for Excel)
    Both share the columns Category, Object, Check, Status, Detail, and
    are written in a finally block so they are produced even if the run
    errors partway through. Pass -ReportPath to control where they land.

    Setting the syslog / NTP baselines (-ExpectedSyslogServer,
    -ExpectedNtpServer). Both are optional: leave them off and those two
    checks only ask "is anything configured at all?", exactly as before.
    Supply them and each host is also compared against the baseline, so a
    host still pointing at a retired collector or time source is flagged.

    Step 1 - find out what your hosts actually have, rather than guessing.
    Sorting by the value groups them, so the odd ones out are obvious:

      Connect-VIServer vcenter01.corp.local
      Get-VMHost | ForEach-Object {
          [pscustomobject]@{
              Host   = $_.Name
              Syslog = ($_ | Get-VMHostSysLogServer |
                          ForEach-Object { "$($_.Host):$($_.Port)" }) -join ', '
              NTP    = ($_ | Get-VMHostNtpServer) -join ', '
          }
      } | Sort-Object Syslog | Format-Table -AutoSize

    Whatever your build standard uses becomes the baseline. Everything that
    disagrees with it is what these parameters are meant to surface.

    Step 2 - pass it on the command line:

      .\Invoke-VMwareHealthCheck.ps1 -VCenter vcenter01.corp.local `
          -ExpectedSyslogServer 'udp://loghost01.corp.local:514' `
          -ExpectedNtpServer 10.10.0.10,10.10.0.11

    Quote a syslog value (it contains '://'); NTP servers need no quotes.
    Pass several by comma-separating them.

    Step 3 (optional) - if you always check the same environment, give the
    parameters a default in the param() block below instead of typing them
    every run:

      [string[]] $ExpectedSyslogServer = 'udp://loghost01.corp.local:514',
      [string[]] $ExpectedNtpServer    = @('10.10.0.10','10.10.0.11'),

    Two consequences worth knowing before you do: the checks stop being
    opt-in, so a run against a DIFFERENT vCenter with its own collector
    will WARN on every host; and to switch the comparison off for a single
    run you then have to pass an empty array, -ExpectedSyslogServer @().
    If you point this at more than one environment, leaving the defaults
    empty and passing the value per run stays cleaner.

    Matching is deliberately forgiving so equivalent spellings don't read as
    drift: a udp:// / tcp:// / ssl:// prefix is ignored, comparison is
    case-insensitive, a trailing dot on an FQDN is ignored, IPv6 literals
    compare bracketed or not, and order does not matter. Leave the ':port'
    off an expected syslog entry to accept that host on any port.

    Exit codes, so a scheduler or monitoring wrapper can act on the outcome
    without parsing the report:
      0  run completed, no FAIL results
      2  run completed, one or more FAIL results
      1  the script itself errored (PowerShell's own exit code for a
         terminating error under `pwsh -File` / `powershell -File`)
    WARN and INFO results do not affect the exit code. 1 is kept distinct
    from 2 on purpose: "the health check found problems" and "the health
    check could not run" usually need different responses. The reports are
    written before the exit code is set, so they exist in every case.

    Getting these codes out of a scheduled run depends on how you invoke it,
    and the two options trade off against each other:

      -File     propagates the exit code, but passes arguments as plain
                strings rather than parsing them as PowerShell, so it cannot
                take a list. -VCenter vc1,vc2 arrives as one server literally
                named "vc1,vc2", and -VCenter vc1 vc2 silently drops vc2.
                Use it for a single vCenter:
                  pwsh -File .\Invoke-VMwareHealthCheck.ps1 -VCenter vcenter01

      -Command  parses its argument as PowerShell, so a list works, but it
                collapses any non-zero script exit to 1 unless you propagate
                $LASTEXITCODE yourself. Use it for more than one vCenter:
                  pwsh -Command "& .\Invoke-VMwareHealthCheck.ps1 -VCenter vc1,vc2; exit $LASTEXITCODE\"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string[]] $VCenter,

    [System.Management.Automation.PSCredential] $Credential,

    [string] $ReportPath = (Get-Location).Path,

    [int] $SnapshotAgeWarningDays   = 3,
    [int] $DatastoreFreeWarnPercent = 20,
    [int] $DatastoreFreeCritPercent = 10,
    [int] $ClusterUsageWarnPercent  = 80,
    [int] $OSDriveFreeWarnGB        = 20,
    [int] $DataDriveFreeWarnGB      = 10,
    [int] $HardwareVersionWarnNum   = 13,
    [int] $CertExpiryWarnDays       = 30,
    [int] $CertExpiryCritDays       = 7,
    [int] $HostVersionSkewFailMajors = 2,
    # Optional baselines. Absent = the Syslog/NTP checks behave as they always
    # have (is anything configured at all?); supplied = each host's configured
    # targets are also compared against the list, in both directions.
    # To always compare against the same baseline, give these a default here,
    # e.g.  [string[]] $ExpectedSyslogServer = 'udp://loghost01.corp.local:514',
    # See "Setting the syslog / NTP baselines" in .NOTES above for how to find
    # the right value, and for what setting a default changes.
    [string[]] $ExpectedSyslogServer,
    [string[]] $ExpectedNtpServer,

    [bool] $TrustAllCertificates    = $true
)

#region --- Setup -------------------------------------------------------------

# Collected results. Each row: Category, Object, Check, Status (PASS/WARN/FAIL/INFO), Detail
$script:Results = New-Object System.Collections.Generic.List[object]

function Add-Result {
    param(
        [string] $Category,
        [string] $Object,
        [string] $Check,
        [ValidateSet('PASS','WARN','FAIL','INFO')] [string] $Status,
        [string] $Detail
    )
    $script:Results.Add([pscustomobject]@{
        Category = $Category
        Object   = $Object
        Check    = $Check
        Status   = $Status
        Detail   = $Detail
    })
    $color = switch ($Status) {
        'PASS' { 'Green' }
        'WARN' { 'Yellow' }
        'FAIL' { 'Red' }
        default { 'Gray' }
    }
    Write-Host ("[{0,-4}] {1,-12} {2,-28} {3} - {4}" -f $Status, $Category, $Object, $Check, $Detail) -ForegroundColor $color
}

# Normalizes one syslog/NTP target into a comparable host + port pair.
# ESXi stores syslog targets in several equivalent spellings - 'udp://host:514',
# 'host:514', a bare 'host' - and NTP servers as a bare host or IP. Comparing the
# raw strings would report drift that isn't there, so both sides of the baseline
# comparison go through here first.
function ConvertTo-LogTargetKey {
    param([string] $Target)

    $t = "$Target".Trim()
    if (-not $t) { return $null }

    $t = $t -replace '^[a-zA-Z][a-zA-Z0-9+.-]*://', ''   # drop udp:// tcp:// ssl://
    # Also strip it from inside brackets, so a value that was bracketed by
    # mistake still normalizes to the same host rather than to garbage.
    $t = $t -replace '^\[[a-zA-Z][a-zA-Z0-9+.-]*://', '['
    $t = $t -replace '/.*$', ''                          # drop any trailing path

    $hostPart = $t
    $portPart = $null
    if ($t -match '^\[(?<h>.+)\](?::(?<p>\d+))?$') {      # [IPv6] or [IPv6]:port
        $hostPart = $Matches['h']
        if ($Matches['p']) { $portPart = $Matches['p'] }
    } elseif ($t -match '^(?<h>[^:]+):(?<p>\d+)$') {      # host:port
        $hostPart = $Matches['h']
        $portPart = $Matches['p']
    }
    # Anything else (a bare hostname, or an unbracketed IPv6 literal) is all host.

    [pscustomobject]@{
        Host     = $hostPart.TrimEnd('.').ToLowerInvariant()
        Port     = $portPart
        Original = $Target
    }
}

# Compares a host's configured targets against an expected baseline in BOTH
# directions: what the baseline says should be there but isn't (Missing), and
# what is configured but isn't in the baseline (Unexpected - the stale or
# decommissioned collector a rebuilt/older host is still pointing at).
# An expected entry with no port matches that host on any port.
function Compare-TargetBaseline {
    param(
        [object[]] $Actual,
        [string[]] $Expected
    )

    $actualKeys   = @(@($Actual)   | ForEach-Object { ConvertTo-LogTargetKey $_ } | Where-Object { $_ })
    $expectedKeys = @(@($Expected) | ForEach-Object { ConvertTo-LogTargetKey $_ } | Where-Object { $_ })

    # Explicit nested loops rather than Where-Object inside Where-Object, which
    # would shadow $_ and silently compare the wrong side.
    $missing    = New-Object System.Collections.Generic.List[object]
    $unexpected = New-Object System.Collections.Generic.List[object]

    foreach ($exp in $expectedKeys) {
        $found = $false
        foreach ($act in $actualKeys) {
            if ($act.Host -eq $exp.Host -and ($null -eq $exp.Port -or $act.Port -eq $exp.Port)) {
                $found = $true
                break
            }
        }
        if (-not $found) { $missing.Add($exp.Original) }
    }
    foreach ($act in $actualKeys) {
        $found = $false
        foreach ($exp in $expectedKeys) {
            if ($act.Host -eq $exp.Host -and ($null -eq $exp.Port -or $act.Port -eq $exp.Port)) {
                $found = $true
                break
            }
        }
        if (-not $found) { $unexpected.Add($act.Original) }
    }

    [pscustomobject]@{ Missing = $missing; Unexpected = $unexpected }
}

function Get-MaxHardwareVersion {
    # Highest VM hardware version the VM's host/cluster can actually run, asked
    # of the compute resource's EnvironmentBrowser rather than inferred from a
    # hardcoded ESXi-version table (which goes stale every release). For a
    # cluster this is already the common denominator across its hosts, so a
    # recommendation based on it stays vMotion-safe.
    # Returns $null if it can't be determined; cached per host name since the
    # answer is identical for every VM on the same host.
    param(
        [object]    $VMHost,
        [hashtable] $Cache
    )
    # A VM's host reference can be a non-null object whose .Name is itself
    # null or empty - e.g. an orphaned/inaccessible VM whose host relationship
    # is broken - which $Cache.ContainsKey(...) throws on ("Value cannot be
    # null. (Parameter 'key')") rather than returning $false. Guard both.
    if (-not $VMHost -or [string]::IsNullOrEmpty($VMHost.Name)) { return $null }
    if ($Cache.ContainsKey($VMHost.Name)) { return $Cache[$VMHost.Name] }

    $max = $null
    try {
        $computeResource = Get-View -Id $VMHost.ExtensionData.Parent -Property EnvironmentBrowser -ErrorAction Stop
        $envBrowser      = Get-View -Id $computeResource.EnvironmentBrowser -ErrorAction Stop
        foreach ($descriptor in @($envBrowser.QueryConfigOptionDescriptor())) {
            if ($descriptor.Key -match 'vmx-(\d+)') {
                $n = [int]$Matches[1]
                if ($null -eq $max -or $n -gt $max) { $max = $n }
            }
        }
    } catch {
        $max = $null
    }
    $Cache[$VMHost.Name] = $max
    return $max
}

function Format-LunList {
    # LUN canonical names are long (naa.60014...), so show a handful and count
    # the rest rather than printing dozens of them into one report cell.
    param(
        [object] $Names,
        [int]    $MaxShown = 4
    )
    # Read .Count directly and enumerate through the pipeline: $Names is a
    # List[object], and wrapping it as @($Names) throws "Argument types do not
    # match" (same quirk noted on $script:Results below).
    $shown = @($Names | Select-Object -First $MaxShown)
    $extra = $Names.Count - $shown.Count
    if ($extra -gt 0) { "$($shown -join ', ') +$extra more" } else { $shown -join ', ' }
}

# Ensure PowerCLI is present. Broadcom renamed the meta-module from
# VMware.PowerCLI to VCF.PowerCLI in PowerCLI 13.x, so accept either.
$pcliModule = @('VCF.PowerCLI','VMware.PowerCLI') |
    Where-Object { Get-Module -ListAvailable -Name $_ } |
    Select-Object -First 1
if (-not $pcliModule) {
    $hint = if ($PSVersionTable.PSEdition -eq 'Desktop') {
        " You're running Windows PowerShell 5.1 (Desktop). If you installed PowerCLI under PowerShell 7, relaunch with: pwsh -File <script>"
    } else { "" }
    throw "PowerCLI (VCF.PowerCLI or VMware.PowerCLI) is not installed for this PowerShell edition ($($PSVersionTable.PSEdition)).$hint Run: Install-Module VCF.PowerCLI -Scope CurrentUser"
}
Import-Module $pcliModule -ErrorAction Stop | Out-Null

# Don't prompt about the CEIP / invalid certs interactively during an unattended run.
# -TrustAllCertificates (default on) ignores untrusted/self-signed vCenter certs;
# pass -TrustAllCertificates:$false to require a valid chain instead.
$certAction = if ($TrustAllCertificates) { 'Ignore' } else { 'Fail' }
Set-PowerCLIConfiguration -Scope Session -InvalidCertificateAction $certAction -ParticipateInCeip $false -Confirm:$false | Out-Null

# Create and resolve the report folder up front. The finally block writes into
# it at the end of what can be a 10+ minute run; a bad path or a permissions
# problem discovered there loses every result, and the New-Item failure inside
# finally would also mask the original error. Fail here instead, before any work.
if (-not (Test-Path -LiteralPath $ReportPath)) {
    New-Item -ItemType Directory -Path $ReportPath -Force -ErrorAction Stop | Out-Null
}
$ReportPath = (Resolve-Path -LiteralPath $ReportPath).Path

#endregion

$connections = @()

try {
    #region --- Connect -------------------------------------------------------
    # Kept inside the try so a connection failure still lands in the HTML/CSV
    # report (via Add-Result below) instead of only the console, and so the
    # finally block still runs (and produces a report) even if every
    # connection fails.
    Write-Host "`nConnecting to vCenter(s): $($VCenter -join ', ')" -ForegroundColor Cyan
    foreach ($vc in $VCenter) {
        try {
            $params = @{ Server = $vc; ErrorAction = 'Stop' }
            if ($Credential) { $params.Credential = $Credential }
            $connections += Connect-VIServer @params
            Write-Host "  Connected to $vc" -ForegroundColor Green
        } catch {
            Write-Host "  FAILED to connect to $vc : $($_.Exception.Message)" -ForegroundColor Red
            Add-Result 'Connection' $vc 'Connect' 'FAIL' "Could not connect: $($_.Exception.Message)"
        }
    }
    if (-not $connections) { throw "No vCenter connections established. Aborting." }
    #endregion

    #region --- 1. Host health -----------------------------------------------
    Write-Host "`n=== Host Health ===" -ForegroundColor Cyan

    # vCenter's own presented TLS certificate - independent of ESXi host certs,
    # fetched via a raw TLS handshake so it doesn't depend on a particular
    # vSphere API version or SSO/VECS cmdlet being available.
    foreach ($vc in $VCenter) {
        $tcpClient = $null
        $sslStream = $null
        try {
            $tcpClient = New-Object System.Net.Sockets.TcpClient
            # Connect with an explicit timeout. The blocking Connect() overload
            # waits on the OS TCP timeout (~21s on Windows) for an unreachable
            # vCenter, stalling an unattended run once per bad -VCenter entry.
            if (-not $tcpClient.ConnectAsync($vc, 443).Wait(5000)) {
                throw "Timed out connecting to ${vc}:443 after 5s"
            }
            $validation = { param($tlsSender, $tlsCertificate, $tlsChain, $tlsPolicyErrors) $true }
            $sslStream = New-Object System.Net.Security.SslStream($tcpClient.GetStream(), $false, $validation)
            $sslStream.AuthenticateAsClient($vc)
            $vcCert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($sslStream.RemoteCertificate)

            $daysLeft = [math]::Round((New-TimeSpan -Start (Get-Date) -End $vcCert.NotAfter).TotalDays, 1)
            if ($daysLeft -lt 0) {
                Add-Result 'HostHealth' $vc 'CertificateExpiry' 'FAIL' "Expired $([math]::Abs($daysLeft)) day(s) ago (NotAfter: $($vcCert.NotAfter))"
            } elseif ($daysLeft -le $CertExpiryCritDays) {
                Add-Result 'HostHealth' $vc 'CertificateExpiry' 'FAIL' "Expires in $daysLeft day(s) (NotAfter: $($vcCert.NotAfter))"
            } elseif ($daysLeft -le $CertExpiryWarnDays) {
                Add-Result 'HostHealth' $vc 'CertificateExpiry' 'WARN' "Expires in $daysLeft day(s) (NotAfter: $($vcCert.NotAfter))"
            } else {
                Add-Result 'HostHealth' $vc 'CertificateExpiry' 'PASS' "Valid until $($vcCert.NotAfter) ($daysLeft days)"
            }
        } catch {
            Add-Result 'HostHealth' $vc 'CertificateExpiry' 'WARN' "Could not retrieve vCenter certificate: $($_.Exception.Message)"
        } finally {
            # Close(), not Dispose(): on .NET Framework (Windows PowerShell 5.1)
            # these types implement IDisposable explicitly, so a .Dispose() call
            # from PowerShell fails with a method-not-found error.
            if ($sslStream) { $sslStream.Close() }
            if ($tcpClient) { $tcpClient.Close() }
        }
    }

    # Enumerate hosts one connection at a time, rather than handing every
    # connection to a single Get-VMHost, so each host is paired with the
    # vCenter that manages it by construction. Deriving that from the host's
    # .Uid is unreliable: an SSO login such as administrator@vsphere.local puts
    # a second '@' in the Uid, so the managing server can't be picked out of it
    # with a simple match. Connect-VIServer's connection object already carries
    # .Version/.Build, so the comparison below needs no extra API call.
    $hostEntries = New-Object System.Collections.Generic.List[object]
    foreach ($conn in $connections) {
        foreach ($h in (Get-VMHost -Server $conn)) {
            $hostEntries.Add([pscustomobject]@{ VMHost = $h; VCenter = $conn })
        }
    }

    foreach ($entry in $hostEntries) {
        $h      = $entry.VMHost
        $vcConn = $entry.VCenter

        # Connection / power state
        if ($h.ConnectionState -ne 'Connected') {
            # Every check below queries the host itself, which vCenter can't
            # reach in this state: the cmdlets emit raw errors that never reach
            # the report, and properties such as Runtime.BootTime come back
            # null. Record the state and move on to the next host.
            Add-Result 'HostHealth' $h.Name 'ConnectionState' 'FAIL' "State is $($h.ConnectionState) - remaining host checks skipped"
            continue
        }
        Add-Result 'HostHealth' $h.Name 'ConnectionState' 'PASS' 'Connected'

        # ESXi build vs vCenter build. VMware only supports ESXi hosts within
        # roughly N-2 major versions of vCenter, and a host *newer* than
        # vCenter is unsupported outright and can break management features.
        # $vcConn came from the enumeration above, so it is always the vCenter
        # this host is actually registered to.
        $hostMajor = 0; $hostMinor = 0
        if ($h.Version -match '^(\d+)\.(\d+)') { $hostMajor = [int]$Matches[1]; $hostMinor = [int]$Matches[2] }
        $vcMajor = 0; $vcMinor = 0
        if ($vcConn.Version -match '^(\d+)\.(\d+)') { $vcMajor = [int]$Matches[1]; $vcMinor = [int]$Matches[2] }

        if ($hostMajor -eq 0 -or $vcMajor -eq 0) {
            Add-Result 'HostHealth' $h.Name 'VersionVsVCenter' 'INFO' "Could not parse version (host $($h.Version)/$($h.Build), vCenter $($vcConn.Version)/$($vcConn.Build))"
        } elseif ($hostMajor -gt $vcMajor -or ($hostMajor -eq $vcMajor -and $hostMinor -gt $vcMinor)) {
            Add-Result 'HostHealth' $h.Name 'VersionVsVCenter' 'FAIL' "ESXi $($h.Version) build $($h.Build) is NEWER than vCenter $($vcConn.Version) build $($vcConn.Build) - unsupported, management features may break"
        } elseif ($hostMajor -lt ($vcMajor - $HostVersionSkewFailMajors)) {
            # -lt, not -le: the parameter is documented as "*more than* this
            # many major versions behind", so a host exactly N behind is the
            # WARN case, not FAIL.
            Add-Result 'HostHealth' $h.Name 'VersionVsVCenter' 'FAIL' "ESXi $($h.Version) is $($vcMajor - $hostMajor) major version(s) behind vCenter $($vcConn.Version) - outside VMware's supported interop range"
        } elseif ($h.Version -ne $vcConn.Version) {
            Add-Result 'HostHealth' $h.Name 'VersionVsVCenter' 'WARN' "ESXi $($h.Version) build $($h.Build) differs from vCenter $($vcConn.Version) build $($vcConn.Build)"
        } else {
            Add-Result 'HostHealth' $h.Name 'VersionVsVCenter' 'PASS' "ESXi $($h.Version) build $($h.Build) matches vCenter $($vcConn.Version) build $($vcConn.Build)"
        }

        # Host services, fetched once and shared with the SSH check below.
        $hostServices = @($h | Get-VMHostService)

        # NTP - servers configured, daemon running, and (optionally) the
        # configured servers matching the -ExpectedNtpServer baseline.
        $ntpServers = @($h | Get-VMHostNtpServer)
        $ntpSvc     = $hostServices | Where-Object { $_.Key -eq 'ntpd' }
        if ($ntpServers.Count -eq 0) {
            $detail = 'No NTP servers configured'
            if ($ExpectedNtpServer) { $detail += " - expected: $($ExpectedNtpServer -join ', ')" }
            Add-Result 'HostHealth' $h.Name 'NTP' 'FAIL' $detail
        } else {
            $ntpIssues = New-Object System.Collections.Generic.List[object]
            if ($null -eq $ntpSvc) {
                $ntpIssues.Add('ntpd service not present on this host - time will drift')
            } elseif (-not $ntpSvc.Running) {
                $ntpIssues.Add('ntpd service not running - the configured servers are not being used')
            }
            if ($ExpectedNtpServer) {
                $ntpCmp = Compare-TargetBaseline -Actual $ntpServers -Expected $ExpectedNtpServer
                if ($ntpCmp.Missing.Count -gt 0) {
                    $ntpIssues.Add("missing expected server(s): $($ntpCmp.Missing -join ', ')")
                }
                if ($ntpCmp.Unexpected.Count -gt 0) {
                    $ntpIssues.Add("server(s) not in the baseline: $($ntpCmp.Unexpected -join ', ') - possibly an older build still pointing at a retired time source")
                }
            }

            if ($ntpIssues.Count -gt 0) {
                $detail = "Configured: $($ntpServers -join ', ') | $($ntpIssues -join ' | ')"
                if ($ExpectedNtpServer) { $detail += " | Expected: $($ExpectedNtpServer -join ', ')" }
                Add-Result 'HostHealth' $h.Name 'NTP' 'WARN' $detail
            } elseif ($ExpectedNtpServer) {
                Add-Result 'HostHealth' $h.Name 'NTP' 'PASS' "Running; servers: $($ntpServers -join ', ') (matches expected baseline)"
            } else {
                Add-Result 'HostHealth' $h.Name 'NTP' 'PASS' "Running; servers: $($ntpServers -join ', ')"
            }
        }

        # Syslog - remote target configured, and (optionally) matching the
        # -ExpectedSyslogServer baseline.
        $syslog       = @($h | Get-VMHostSysLogServer)
        $syslogActual = @($syslog | ForEach-Object {
            # Bracket a bare IPv6 literal before appending the port, or
            # 'fd00::10' + ':514' reads back as one unparseable host. Only a
            # BARE literal: ESXi often reports Host with the scheme already on
            # it ('udp://loghost:514'), and that contains a colon too -
            # bracketing it produced '[udp://loghost]:514', which parses back
            # as the host '[udp:' and can never match a baseline.
            $sysHost = "$($_.Host)"
            if ($sysHost -like '*:*' -and $sysHost -notlike '*/*' -and $sysHost -notlike '`[*') {
                $sysHost = "[$sysHost]"
            }
            # Don't append a port the host string already carries.
            if ($_.Port -and $sysHost -notmatch ':\d+$') { "${sysHost}:$($_.Port)" } else { $sysHost }
        })
        if ($syslogActual.Count -eq 0) {
            if ($ExpectedSyslogServer) {
                # A baseline was supplied, so a remote collector is required here -
                # nothing configured means the requirement is entirely unmet.
                Add-Result 'HostHealth' $h.Name 'Syslog' 'FAIL' "No remote syslog target configured - expected: $($ExpectedSyslogServer -join ', ')"
            } else {
                Add-Result 'HostHealth' $h.Name 'Syslog' 'WARN' 'No remote syslog target configured'
            }
        } elseif (-not $ExpectedSyslogServer) {
            Add-Result 'HostHealth' $h.Name 'Syslog' 'PASS' "Target: $($syslogActual -join ', ')"
        } else {
            $sysCmp    = Compare-TargetBaseline -Actual $syslogActual -Expected $ExpectedSyslogServer
            $sysIssues = New-Object System.Collections.Generic.List[object]
            if ($sysCmp.Missing.Count -gt 0) {
                $sysIssues.Add("missing expected target(s): $($sysCmp.Missing -join ', ')")
            }
            if ($sysCmp.Unexpected.Count -gt 0) {
                $sysIssues.Add("target(s) not in the baseline: $($sysCmp.Unexpected -join ', ') - possibly an older build still shipping logs to a retired collector")
            }

            if ($sysIssues.Count -gt 0) {
                Add-Result 'HostHealth' $h.Name 'Syslog' 'WARN' "Configured: $($syslogActual -join ', ') | $($sysIssues -join ' | ') | Expected: $($ExpectedSyslogServer -join ', ')"
            } else {
                Add-Result 'HostHealth' $h.Name 'Syslog' 'PASS' "Target: $($syslogActual -join ', ') (matches expected baseline)"
            }
        }

        # Uptime (informational; very long uptime can mean missed patching)
        $uptimeDays = [math]::Round((New-TimeSpan -Start $h.ExtensionData.Summary.Runtime.BootTime -End (Get-Date)).TotalDays, 1)
        Add-Result 'HostHealth' $h.Name 'Uptime' 'INFO' "$uptimeDays days"

        # Datastore connectivity - any datastore not accessible from this host
        $inaccessible = $h | Get-Datastore | Where-Object { -not $_.ExtensionData.Summary.Accessible }
        if ($inaccessible) {
            Add-Result 'HostHealth' $h.Name 'DatastoreConnectivity' 'FAIL' "Inaccessible: $(($inaccessible.Name) -join ',')"
        } else {
            Add-Result 'HostHealth' $h.Name 'DatastoreConnectivity' 'PASS' 'All datastores accessible'
        }

        # Storage path state - a LUN can still show as "accessible" on remaining
        # paths while one or more of its FC/iSCSI paths are dead, silently
        # running with reduced (or zero) redundancy. DatastoreConnectivity
        # above won't catch that; this walks the actual multipathing state.
        # A dead HBA or fabric takes the same path off every LUN at once, so
        # LUNs are grouped by how much redundancy each has LEFT (what you'd
        # actually act on) rather than emitting one near-identical line per
        # LUN, which turns into an unreadable wall of text on a host with
        # dozens of LUNs.
        $lunQueryError = $null
        $luns = @($h | Get-ScsiLun -LunType disk -ErrorAction SilentlyContinue -ErrorVariable lunQueryError)
        $pathIssues  = New-Object System.Collections.Generic.List[object]
        $totalPaths  = 0
        $offlineLuns = New-Object System.Collections.Generic.List[object]
        $degraded    = @{}   # "N of M paths active" -> list of LUN names
        foreach ($lun in $luns) {
            $paths = @(Get-ScsiLunPath -ScsiLun $lun -ErrorAction SilentlyContinue)
            if ($paths.Count -eq 0) {
                # Don't let a LUN whose paths can't be read count as healthy.
                $pathIssues.Add($lun.CanonicalName)
                continue
            }
            $totalPaths += $paths.Count
            $dead = @($paths | Where-Object { $_.State -in @('Dead','Disabled') })
            if ($dead.Count -eq 0) { continue }

            $activeCount = $paths.Count - $dead.Count
            if ($activeCount -le 0) {
                $offlineLuns.Add($lun.CanonicalName)
            } else {
                $key = "$activeCount of $($paths.Count) paths active"
                if (-not $degraded.ContainsKey($key)) {
                    $degraded[$key] = New-Object System.Collections.Generic.List[object]
                }
                $degraded[$key].Add($lun.CanonicalName)
            }
        }
        $degradedCount = 0
        foreach ($k in $degraded.Keys) { $degradedCount += $degraded[$k].Count }

        if ($offlineLuns.Count -gt 0 -or $degradedCount -gt 0 -or $pathIssues.Count -gt 0) {
            # Headline counts first, then one grouped line per redundancy level,
            # worst first. E.g.:
            #   40 LUN(s): 2 offline, 12 degraded | OFFLINE - no active paths:
            #   naa.aaa, naa.bbb | 3 of 4 paths active (12): naa.ccc, ... +8 more
            $counts = New-Object System.Collections.Generic.List[object]
            if ($offlineLuns.Count -gt 0) { $counts.Add("$($offlineLuns.Count) offline") }
            if ($degradedCount -gt 0)     { $counts.Add("$degradedCount degraded") }
            if ($pathIssues.Count -gt 0)  { $counts.Add("$($pathIssues.Count) unreadable") }

            $parts = New-Object System.Collections.Generic.List[object]
            $parts.Add("$($luns.Count) LUN(s): $($counts -join ', ')")
            if ($offlineLuns.Count -gt 0) {
                $parts.Add("OFFLINE - no active paths: $(Format-LunList $offlineLuns)")
            }
            # Sort by the leading active-path count in the key, fewest first.
            foreach ($key in ($degraded.Keys | Sort-Object { [int]($_ -split ' ')[0] })) {
                $parts.Add("$key ($($degraded[$key].Count)): $(Format-LunList $degraded[$key])")
            }

            if ($pathIssues.Count -gt 0) {
                $parts.Add("path state could not be read ($($pathIssues.Count)): $(Format-LunList $pathIssues)")
            }

            $severity = if ($offlineLuns.Count -gt 0) { 'FAIL' } else { 'WARN' }
            Add-Result 'HostHealth' $h.Name 'PathState' $severity ($parts -join ' | ')
        } elseif ($luns.Count -gt 0) {
            Add-Result 'HostHealth' $h.Name 'PathState' 'PASS' "$totalPaths path(s) across $($luns.Count) LUN(s), all active"
        } elseif ($lunQueryError) {
            # An empty result because the query failed is not the same as a host
            # with no block storage; saying "NFS-only" here would be a false all-clear.
            Add-Result 'HostHealth' $h.Name 'PathState' 'WARN' "Could not enumerate block storage LUNs: $($lunQueryError[0].Exception.Message)"
        } else {
            Add-Result 'HostHealth' $h.Name 'PathState' 'INFO' 'No block storage LUNs found (e.g. NFS-only host)'
        }

        # ESXi host TLS certificate expiry. Config.Certificate is a byte[] of
        # the PEM-encoded certificate, not a certificate object, so reading
        # .NotAfter off it directly always yields $null - it has to be decoded
        # first. X509Certificate2 accepts PEM bytes only on .NET 5+ (PowerShell
        # 7), so pull the base64 body out and hand it DER, which Windows
        # PowerShell 5.1 accepts too.
        $hostCert  = $null
        $certError = $null
        try {
            $certBytes = $h.ExtensionData.Config.Certificate
            if ($certBytes) {
                $certText = [System.Text.Encoding]::ASCII.GetString([byte[]]$certBytes)
                # Declared [byte[]] deliberately: assigning from an if/else
                # expression unrolls the array into object[], and the ctor then
                # binds to the (string fileName) overload instead of (byte[]).
                [byte[]] $der = $null
                if ($certText -match '(?s)-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----') {
                    $der = [System.Convert]::FromBase64String(($Matches[1] -replace '\s', ''))
                } else {
                    $der = [byte[]]$certBytes   # already DER
                }
                $hostCert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($der)
            }
        } catch {
            $certError = $_.Exception.Message
        }
        if ($hostCert -and $hostCert.NotAfter) {
            $daysLeft = [math]::Round((New-TimeSpan -Start (Get-Date) -End $hostCert.NotAfter).TotalDays, 1)
            if ($daysLeft -lt 0) {
                Add-Result 'HostHealth' $h.Name 'CertificateExpiry' 'FAIL' "Expired $([math]::Abs($daysLeft)) day(s) ago (NotAfter: $($hostCert.NotAfter))"
            } elseif ($daysLeft -le $CertExpiryCritDays) {
                Add-Result 'HostHealth' $h.Name 'CertificateExpiry' 'FAIL' "Expires in $daysLeft day(s) (NotAfter: $($hostCert.NotAfter))"
            } elseif ($daysLeft -le $CertExpiryWarnDays) {
                Add-Result 'HostHealth' $h.Name 'CertificateExpiry' 'WARN' "Expires in $daysLeft day(s) (NotAfter: $($hostCert.NotAfter))"
            } else {
                Add-Result 'HostHealth' $h.Name 'CertificateExpiry' 'PASS' "Valid until $($hostCert.NotAfter) ($daysLeft days)"
            }
        } elseif ($certError) {
            Add-Result 'HostHealth' $h.Name 'CertificateExpiry' 'WARN' "Could not read host certificate: $certError"
        } else {
            Add-Result 'HostHealth' $h.Name 'CertificateExpiry' 'INFO' 'Certificate info not available from vCenter'
        }

        # Local account password expiration policy (root included). vCenter's API
        # doesn't expose a specific account's actual days-until-expiry - that lives
        # only in the host's local shadow file and would require SSH + `chage -l
        # root` to read. This checks whether password aging is enabled at all.
        try {
            # A name that doesn't exist comes back as no output (or a null)
            # rather than an error, and [int]$null is 0 - which would be
            # reported below as "aging disabled" for a host we actually know
            # nothing about. Filter the nulls out before counting: @($null)
            # still has a Count of 1.
            $pwExpSetting = @($h | Get-AdvancedSetting -Name 'Security.PasswordExpirationInDays' -ErrorAction Stop |
                              Where-Object { $null -ne $_ -and $null -ne $_.Value })
            if ($pwExpSetting.Count -ne 1) {
                Add-Result 'HostHealth' $h.Name 'PasswordExpirationPolicy' 'INFO' 'Security.PasswordExpirationInDays not reported by this host'
            } else {
                $pwExpDays = [int]$pwExpSetting[0].Value
                if ($pwExpDays -le 0) {
                    Add-Result 'HostHealth' $h.Name 'PasswordExpirationPolicy' 'WARN' 'Security.PasswordExpirationInDays is 0 (disabled) - local account passwords, including root, never expire'
                } else {
                    Add-Result 'HostHealth' $h.Name 'PasswordExpirationPolicy' 'PASS' "Security.PasswordExpirationInDays = $pwExpDays (root's actual remaining days isn't exposed by the vCenter API; requires SSH to check directly)"
                }
            }
        } catch {
            Add-Result 'HostHealth' $h.Name 'PasswordExpirationPolicy' 'INFO' "Could not read Security.PasswordExpirationInDays: $($_.Exception.Message)"
        }

        # Lockdown mode - Disabled means direct root/local logins to the host
        # bypass vCenter entirely, reducing auditability. Security hardening
        # guides recommend Normal or Strict for production hosts.
        $lockdown = $h.ExtensionData.Config.LockdownMode
        switch ($lockdown) {
            'lockdownDisabled' { Add-Result 'HostHealth' $h.Name 'LockdownMode' 'WARN' 'Disabled - direct root/local logins to this host bypass vCenter, reducing auditability; consider Normal or Strict lockdown' }
            'lockdownNormal'   { Add-Result 'HostHealth' $h.Name 'LockdownMode' 'PASS' 'Normal' }
            'lockdownStrict'   { Add-Result 'HostHealth' $h.Name 'LockdownMode' 'PASS' 'Strict' }
            default            { Add-Result 'HostHealth' $h.Name 'LockdownMode' 'INFO' "Could not read lockdown mode ($lockdown)" }
        }

        # SSH (TSM-SSH) service - often enabled temporarily for troubleshooting
        # and then forgotten; left running long-term it's extra attack surface.
        $sshSvc = $hostServices | Where-Object { $_.Key -eq 'TSM-SSH' }
        if (-not $sshSvc) {
            Add-Result 'HostHealth' $h.Name 'SSHEnabled' 'INFO' 'Could not read SSH (TSM-SSH) service state'
        } elseif ($sshSvc.Running) {
            Add-Result 'HostHealth' $h.Name 'SSHEnabled' 'WARN' 'SSH service is running - confirm this is intentional; leaving it enabled long-term increases attack surface'
        } else {
            Add-Result 'HostHealth' $h.Name 'SSHEnabled' 'PASS' 'SSH service not running'
        }
    }
    #endregion

    #region --- 2. VM compliance ---------------------------------------------
    Write-Host "`n=== VM Compliance ===" -ForegroundColor Cyan
    $vms = Get-VM -Server $connections

    # Pre-fetch snapshots, CD drives and floppy drives for ALL VMs in one
    # round-trip each, rather than calling Get-Snapshot / Get-CDDrive /
    # Get-FloppyDrive once per VM inside the loop. On large or multi-vCenter
    # inventories this is the single biggest speed-up. Key by .Uid
    # (server-qualified) so VMs from different vCenters with the same internal
    # MoRef Id don't collide.
    $snapsByVm  = @{}
    $cdByVm     = @{}
    $floppyByVm = @{}
    # Highest hardware version each host/cluster supports, filled in on first
    # use by Get-MaxHardwareVersion so only hosts with an out-of-date VM on
    # them cost an extra round-trip.
    $maxHwCache = @{}
    if ($vms) {
        Write-Host "  Pre-fetching snapshots and media for $(@($vms).Count) VM(s)..." -ForegroundColor DarkGray
        foreach ($s in (Get-Snapshot -VM $vms)) {
            $key = $s.VM.Uid
            if (-not $snapsByVm.ContainsKey($key)) { $snapsByVm[$key] = [System.Collections.Generic.List[object]]::new() }
            $snapsByVm[$key].Add($s)
        }
        foreach ($c in (Get-CDDrive -VM $vms)) {
            $key = $c.Parent.Uid
            if (-not $cdByVm.ContainsKey($key)) { $cdByVm[$key] = [System.Collections.Generic.List[object]]::new() }
            $cdByVm[$key].Add($c)
        }
        foreach ($fd in (Get-FloppyDrive -VM $vms)) {
            $key = $fd.Parent.Uid
            if (-not $floppyByVm.ContainsKey($key)) { $floppyByVm[$key] = [System.Collections.Generic.List[object]]::new() }
            $floppyByVm[$key].Add($fd)
        }
    }

    foreach ($vm in $vms) {
        # Runtime.ConnectionState / Runtime.ConsolidationNeeded aren't always
        # populated on the cached view Get-VM hands back (PowerCLI retrieves a
        # filtered property set), which reads as $null rather than as an error.
        # Refresh just those two properties when either is missing, so only the
        # affected VMs pay a round-trip.
        $connState     = $vm.ExtensionData.Runtime.ConnectionState
        $consolidation = $vm.ExtensionData.Runtime.ConsolidationNeeded
        if ($null -eq $connState -or $null -eq $consolidation) {
            try {
                $vm.ExtensionData.UpdateViewData('Runtime.ConnectionState', 'Runtime.ConsolidationNeeded')
                $connState     = $vm.ExtensionData.Runtime.ConnectionState
                $consolidation = $vm.ExtensionData.Runtime.ConsolidationNeeded
            } catch {
                # Leave both $null; reported as INFO below rather than guessed at.
            }
        }

        # Connection state - orphaned/inaccessible/invalid is vCenter's
        # inventory losing track of the VM (the "question mark" icon in the
        # vSphere Client). Runs regardless of power state and is easy to miss
        # since it doesn't show up in any other check here. Only the known-bad
        # states FAIL: an unreadable state is reported as INFO, never as a
        # failure, so a healthy VM is never flagged just because vCenter didn't
        # hand back the property.
        switch ([string]$connState) {
            'connected'    { Add-Result 'VMCompliance' $vm.Name 'ConnectionState' 'PASS' "Connected to vCenter ($($vm.PowerState))" }
            'disconnected' { Add-Result 'VMCompliance' $vm.Name 'ConnectionState' 'WARN' 'Disconnected - the host running this VM is currently unreachable from vCenter' }
            'orphaned'     { Add-Result 'VMCompliance' $vm.Name 'ConnectionState' 'FAIL' 'Orphaned - vCenter has an inventory entry but the host does not report this VM (shows as a question mark in the vSphere Client)' }
            'inaccessible' { Add-Result 'VMCompliance' $vm.Name 'ConnectionState' 'FAIL' 'Inaccessible - the VM config file (.vmx) cannot be read, usually a datastore or storage problem' }
            'invalid'      { Add-Result 'VMCompliance' $vm.Name 'ConnectionState' 'FAIL' 'Invalid - vCenter considers this VM unusable, usually a corrupt or unreadable .vmx' }
            ''             { Add-Result 'VMCompliance' $vm.Name 'ConnectionState' 'INFO' "Connection state not reported by vCenter for this VM; VM is $($vm.PowerState)" }
            default        { Add-Result 'VMCompliance' $vm.Name 'ConnectionState' 'INFO' "Unrecognized connection state '$connState'; VM is $($vm.PowerState)" }
        }

        # Disk consolidation needed - leftover snapshot delta disks, often
        # left behind by backup software that didn't clean up after itself,
        # that silently consume growing datastore space until consolidated.
        # $null (property unavailable) is distinct from $false here: reporting
        # it as PASS would silently claim a clean result that was never checked.
        if ($null -eq $consolidation) {
            Add-Result 'VMCompliance' $vm.Name 'DiskConsolidation' 'INFO' 'Consolidation state not reported by vCenter for this VM'
        } elseif ($consolidation) {
            Add-Result 'VMCompliance' $vm.Name 'DiskConsolidation' 'WARN' 'Disk consolidation needed - leftover snapshot delta disk(s) present; consolidate from the vSphere Client (Snapshots > Consolidate)'
        } else {
            Add-Result 'VMCompliance' $vm.Name 'DiskConsolidation' 'PASS' 'No consolidation needed'
        }

        # VMware Tools status (only meaningful when powered on)
        if ($vm.PowerState -eq 'PoweredOn') {
            $toolsStatus = $vm.ExtensionData.Guest.ToolsStatus
            switch ($toolsStatus) {
                'toolsOk'        { Add-Result 'VMCompliance' $vm.Name 'VMwareTools' 'PASS' 'toolsOk' }
                'toolsOld'       { Add-Result 'VMCompliance' $vm.Name 'VMwareTools' 'WARN' 'Tools out of date' }
                'toolsNotRunning'{ Add-Result 'VMCompliance' $vm.Name 'VMwareTools' 'WARN' 'Tools not running' }
                'toolsNotInstalled'{ Add-Result 'VMCompliance' $vm.Name 'VMwareTools' 'FAIL' 'Tools not installed' }
                default          { Add-Result 'VMCompliance' $vm.Name 'VMwareTools' 'INFO' "$toolsStatus" }
            }

            # OS system drive free space (C:\ on Windows, / on Linux).
            # Guest disk data is only populated when VMware Tools is running.
            $guestDisks = $vm.ExtensionData.Guest.Disk
            if ($guestDisks) {
                $osDrive = $guestDisks | Where-Object { $_.DiskPath -eq 'C:\' -or $_.DiskPath -eq '/' } | Select-Object -First 1
                if ($osDrive) {
                    $freeGB  = [math]::Round($osDrive.FreeSpace / 1GB, 1)
                    $totalGB = [math]::Round($osDrive.Capacity / 1GB, 1)
                    $detail  = "$($osDrive.DiskPath) ${freeGB}GB free of ${totalGB}GB"
                    if ($freeGB -lt $OSDriveFreeWarnGB) {
                        Add-Result 'VMCompliance' $vm.Name 'OSDriveFree' 'WARN' "$detail (< ${OSDriveFreeWarnGB}GB)"
                    } else {
                        Add-Result 'VMCompliance' $vm.Name 'OSDriveFree' 'PASS' $detail
                    }
                } else {
                    Add-Result 'VMCompliance' $vm.Name 'OSDriveFree' 'INFO' 'No C:\ or / drive reported by Tools'
                }

                # All other guest drives (data/secondary volumes) below threshold.
                $osPath = if ($osDrive) { $osDrive.DiskPath } else { $null }
                foreach ($disk in ($guestDisks | Where-Object { $_.DiskPath -ne $osPath })) {
                    $freeGB  = [math]::Round($disk.FreeSpace / 1GB, 1)
                    $totalGB = [math]::Round($disk.Capacity / 1GB, 1)
                    $detail  = "$($disk.DiskPath) ${freeGB}GB free of ${totalGB}GB"
                    if ($freeGB -lt $DataDriveFreeWarnGB) {
                        Add-Result 'VMCompliance' $vm.Name 'DataDriveFree' 'WARN' "$detail (< ${DataDriveFreeWarnGB}GB)"
                    } else {
                        Add-Result 'VMCompliance' $vm.Name 'DataDriveFree' 'PASS' $detail
                    }
                }
            }
        }

        # VM hardware version (vmx-NN). Flag noticeably old ones, and name a
        # concrete target rather than a bare "consider upgrading" - the ceiling
        # is whatever the host/cluster supports, and the guest OS has to be
        # supported on that version too, which only the admin can confirm
        # against VMware's compatibility guide.
        # PowerCLI has reported this property as both 'vmx-19' and a bare '19'
        # across releases, so accept either, and report a value matching neither
        # as INFO rather than letting it fall through to PASS unexamined.
        $hwVersion = $vm.HardwareVersion
        $hwNum = 0
        if ($hwVersion -match '(?:vmx-)?(\d+)$') { $hwNum = [int]$Matches[1] }
        if ($hwNum -le 0) {
            Add-Result 'VMCompliance' $vm.Name 'HardwareVersion' 'INFO' "Could not parse hardware version '$hwVersion'"
        } elseif ($hwNum -lt $HardwareVersionWarnNum) {
            $maxHw = Get-MaxHardwareVersion -VMHost $vm.VMHost -Cache $maxHwCache
            $guestOs = $vm.ExtensionData.Config.GuestFullName
            $guestClause = if ($guestOs) {
                "Confirm '$guestOs' is supported on the target version"
            } else {
                'Confirm the guest OS is supported on the target version'
            }

            $advice = if ($null -eq $maxHw) {
                "Could not determine the highest version its host/cluster supports - check that before upgrading."
            } elseif ($maxHw -le $hwNum) {
                "Its host/cluster supports no higher than vmx-$maxHw, so it cannot be upgraded where it runs today - move it to a newer host first."
            } else {
                "Host/cluster supports up to vmx-$maxHw."
            }
            Add-Result 'VMCompliance' $vm.Name 'HardwareVersion' 'WARN' "$hwVersion is below the vmx-$HardwareVersionWarnNum baseline. $advice $guestClause before upgrading; it requires a power-off and cannot be rolled back."
        } else {
            Add-Result 'VMCompliance' $vm.Name 'HardwareVersion' 'PASS' "$hwVersion (at or above the vmx-$HardwareVersionWarnNum baseline)"
        }

        # Mounted ISO / connected CD-ROM (blocks vMotion, often left behind).
        # Only a connected drive (or one set to connect at power-on) matters: a
        # stale IsoPath on a disconnected drive blocks nothing, and flagging it
        # buries the report in noise anywhere VMs are deployed from ISO. Same
        # test as the floppy check below.
        $mounted = $cdByVm[$vm.Uid] | Where-Object {
            ($_.IsoPath -or $_.HostDevice -or $_.RemoteDevice) -and
            ($_.ConnectionState.Connected -or $_.ConnectionState.StartConnected)
        }
        if ($mounted) {
            $what = ($mounted | ForEach-Object { if ($_.IsoPath) { $_.IsoPath } else { 'host/remote device' } }) -join ','
            Add-Result 'VMCompliance' $vm.Name 'MountedMedia' 'WARN' "Connected media: $what"
        }

        # Floppy drives - legacy hardware. A connected floppy blocks vMotion;
        # any floppy at all is usually unnecessary on a modern VM.
        $floppies = $floppyByVm[$vm.Uid]
        if ($floppies) {
            $connected = $floppies | Where-Object { $_.ConnectionState.Connected -or $_.ConnectionState.StartConnected }
            if ($connected) {
                $what = ($connected | ForEach-Object { if ($_.FloppyImagePath) { $_.FloppyImagePath } else { 'device' } }) -join ','
                Add-Result 'VMCompliance' $vm.Name 'FloppyDrive' 'WARN' "Connected floppy drive ($what) - disconnect/remove (legacy, blocks vMotion)"
            } else {
                Add-Result 'VMCompliance' $vm.Name 'FloppyDrive' 'INFO' "Floppy drive present but disconnected - consider removing (legacy device)"
            }
        }

        # Snapshot age
        $snaps = $snapsByVm[$vm.Uid]
        foreach ($s in $snaps) {
            $ageDays = [math]::Round((New-TimeSpan -Start $s.Created -End (Get-Date)).TotalDays, 1)
            $sizeGB  = [math]::Round($s.SizeGB, 1)
            if ($ageDays -ge $SnapshotAgeWarningDays) {
                Add-Result 'VMCompliance' $vm.Name 'Snapshot' 'WARN' "'$($s.Name)' age ${ageDays}d, ${sizeGB}GB"
            } else {
                Add-Result 'VMCompliance' $vm.Name 'Snapshot' 'INFO' "'$($s.Name)' age ${ageDays}d, ${sizeGB}GB"
            }
        }
    }
    #endregion

    #region --- 3. Capacity ---------------------------------------------------
    Write-Host "`n=== Capacity ===" -ForegroundColor Cyan

    # Datastore free space
    foreach ($ds in (Get-Datastore -Server $connections)) {
        if ($ds.CapacityGB -le 0) { continue }
        $freePct = [math]::Round(($ds.FreeSpaceGB / $ds.CapacityGB) * 100, 1)
        $detail  = "$freePct% free ($([math]::Round($ds.FreeSpaceGB))GB / $([math]::Round($ds.CapacityGB))GB)"
        if ($freePct -lt $DatastoreFreeCritPercent) {
            Add-Result 'Capacity' $ds.Name 'DatastoreFree' 'FAIL' $detail
        } elseif ($freePct -lt $DatastoreFreeWarnPercent) {
            Add-Result 'Capacity' $ds.Name 'DatastoreFree' 'WARN' $detail
        } else {
            Add-Result 'Capacity' $ds.Name 'DatastoreFree' 'PASS' $detail
        }
    }

    # Cluster CPU / RAM utilization
    foreach ($cl in (Get-Cluster -Server $connections)) {
        $hostsInCl = $cl | Get-VMHost
        $totalCpuMhz = ($hostsInCl | Measure-Object -Property CpuTotalMhz -Sum).Sum
        $usedCpuMhz  = ($hostsInCl | Measure-Object -Property CpuUsageMhz -Sum).Sum
        # The GB properties are the current ones on VMHost; the MB pair is
        # legacy and, where it is absent, Measure-Object returns a null Sum and
        # the ClusterRAM row silently vanishes from the report instead of erroring.
        $totalMemGB  = ($hostsInCl | Measure-Object -Property MemoryTotalGB -Sum).Sum
        $usedMemGB   = ($hostsInCl | Measure-Object -Property MemoryUsageGB -Sum).Sum

        if ($totalCpuMhz -gt 0) {
            $cpuPct = [math]::Round(($usedCpuMhz / $totalCpuMhz) * 100, 1)
            $status = if ($cpuPct -ge $ClusterUsageWarnPercent) { 'WARN' } else { 'PASS' }
            Add-Result 'Capacity' $cl.Name 'ClusterCPU' $status "$cpuPct% used"
        }
        if ($totalMemGB -gt 0) {
            $memPct = [math]::Round(($usedMemGB / $totalMemGB) * 100, 1)
            $status = if ($memPct -ge $ClusterUsageWarnPercent) { 'WARN' } else { 'PASS' }
            Add-Result 'Capacity' $cl.Name 'ClusterRAM' $status "$memPct% used"
        }
    }
    #endregion

    #region --- 4. Cluster config --------------------------------------------
    Write-Host "`n=== Cluster Config ===" -ForegroundColor Cyan
    foreach ($cl in (Get-Cluster -Server $connections)) {
        # HA
        if ($cl.HAEnabled) {
            Add-Result 'ClusterConfig' $cl.Name 'HA' 'PASS' 'High Availability enabled (restarts VMs on the surviving hosts if a host fails)'
        } else {
            Add-Result 'ClusterConfig' $cl.Name 'HA' 'WARN' 'High Availability disabled - if a host fails, the VMs it was running will stay down until someone restarts them by hand'
        }

        # Admission control (only relevant when HA is on)
        if ($cl.HAEnabled) {
            $ac = $cl.ExtensionData.Configuration.DasConfig.AdmissionControlEnabled
            if ($ac) {
                Add-Result 'ClusterConfig' $cl.Name 'AdmissionControl' 'PASS' 'Enabled - HA holds back enough spare capacity to restart the VMs from a failed host, and blocks power-ons that would eat into that reserve'
            } else {
                Add-Result 'ClusterConfig' $cl.Name 'AdmissionControl' 'WARN' 'Disabled - HA reserves no spare capacity, so VMs from a failed host may fail to restart if the remaining hosts are already committed'
            }
        }

        # DRS
        if ($cl.DrsEnabled) {
            Add-Result 'ClusterConfig' $cl.Name 'DRS' 'PASS' "Distributed Resource Scheduler enabled, $($cl.DrsAutomationLevel) (balances VM load across hosts using vMotion)"
            if ($cl.DrsAutomationLevel -ne 'FullyAutomated') {
                Add-Result 'ClusterConfig' $cl.Name 'DRSAutomation' 'WARN' "DRS is set to $($cl.DrsAutomationLevel), not FullyAutomated - it only recommends migrations instead of performing them, so rebalancing waits on someone approving them"
            }
        } else {
            Add-Result 'ClusterConfig' $cl.Name 'DRS' 'WARN' 'Distributed Resource Scheduler disabled - VM load is not balanced across hosts automatically'
        }

        # Host count / EVC sanity
        $hostCount = @($cl | Get-VMHost).Count
        if ($cl.HAEnabled -and $hostCount -lt 2) {
            Add-Result 'ClusterConfig' $cl.Name 'HostCount' 'WARN' "Only $hostCount host(s) - HA cannot fail over"
        }
        # EVC masks host CPUs to a common baseline so a running VM can vMotion
        # between different CPU generations without the guest seeing the CPU
        # change mid-flight. We can't tell from vCenter alone whether this
        # cluster's hosts actually span multiple CPU generations, so flag
        # "not configured" as WARN (consistent with the other cluster-config
        # checks below, which also flag things that may be intentional) rather
        # than staying silent - it's generally recommended as a hedge even for
        # same-generation clusters, in case a differing host is added later.
        $evc = $cl.ExtensionData.Summary.CurrentEVCModeKey
        if ($evc) {
            Add-Result 'ClusterConfig' $cl.Name 'EVC' 'PASS' "Enhanced vMotion Compatibility enabled, baseline '$evc' (masks host CPUs to a common instruction set so running VMs can vMotion between hosts with different CPU generations)"
        } else {
            Add-Result 'ClusterConfig' $cl.Name 'EVC' 'WARN' 'Enhanced vMotion Compatibility (masks host CPUs to a common instruction set so running VMs can vMotion between hosts with different CPU generations) is not configured - if hosts have mixed CPU generations, or a differing one is added later, vMotion may fail; consider enabling EVC as a hedge'
        }
    }
    #endregion
}
catch {
    # Log a clean one-line message, then rethrow so the run still surfaces as
    # a failure to the caller/scheduler. The finally block below still runs
    # first and writes whatever results were collected before the error.
    Write-Host "`nRun failed: $($_.Exception.Message)" -ForegroundColor Red
    throw
}
finally {
    #region --- Report + disconnect ------------------------------------------
    $summary = $script:Results | Group-Object Status | ForEach-Object { "$($_.Name)=$($_.Count)" }
    Write-Host "`n=== Summary: $($summary -join '  ') ===" -ForegroundColor Cyan

    # $ReportPath was created and resolved during setup, before the run started.
    $stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'
    $htmlFile  = Join-Path $ReportPath "VMwareHealthCheck-$stamp.html"

    # Styled after a Dell iDRAC-style dashboard: dark navy header/sidebar, a
    # blue accent, status pill badges, and a stat-tile summary row instead of
    # a plain text line.
    $style = @"
<style>
 :root {
  /* Every blue in the report is one of the two stops of the iDRAC 10
     banner gradient, so nothing reads as a second, unrelated blue.
     --brand (the top stop) is reserved for the banner itself: at 4.14:1 on
     the page background it is too light for body-size text. --brand-2 (the
     bottom stop) carries everything else - sidebar, table headers, links,
     borders - and clears AA on light and dark alike. */
  --brand: #0076ce; --brand-2: #0062ad; --brand-3: #00559a;
  --accent: #0062ad;
  --bg: #eef1f5; --surface: #ffffff; --border: #dbe1e8;
  --text: #1c2733; --muted: #64748b;
  --ok: #1e7c34; --ok-bg: #e6f4ea;
  --warn: #96650b; --warn-bg: #fff4e0;
  --crit: #a61b1b; --crit-bg: #fdeaea;
  --info: #51606f; --info-bg: #eef1f4;
 }
 * { box-sizing: border-box; }
 body { font-family: Segoe UI, Arial, sans-serif; margin: 0; background: var(--bg); color: var(--text); }
 a { color: var(--accent); }
 .topbar { background: linear-gradient(180deg, var(--brand) 0%, var(--brand-2) 100%); color: #fff; padding: 14px 24px; display: flex; align-items: center; justify-content: space-between; flex-wrap: wrap; gap: 8px; }
 .topbar-brand { display: flex; align-items: center; gap: 12px; }
 .brand-badge { display: inline-flex; align-items: center; justify-content: center; width: 34px; height: 34px; border-radius: 6px; background: rgba(255,255,255,.18); border: 1px solid rgba(255,255,255,.35); color: #fff; font-weight: 700; font-size: 13px; letter-spacing: .5px; flex: none; }
 .brand-title { font-size: 18px; font-weight: 600; }
 .topbar-meta { font-size: 12px; color: #c7d2df; }
 .layout { display: flex; align-items: flex-start; }
 .sidebar { width: 270px; flex: 0 0 270px; background: var(--brand-2); color: #eaf3fb; padding: 18px 0; position: sticky; top: 0; align-self: flex-start; max-height: 100vh; overflow-y: auto; }
 .sidebar h3 { margin: 0 18px 10px; font-size: 12px; text-transform: uppercase; letter-spacing: .08em; color: #8fa3ba; }
 .sidebar .toc-cat { margin: 0 0 14px; }
 .sidebar .toc-cat-name { display: block; padding: 6px 18px; font-weight: 600; font-size: 12px; color: #a9bdd2; text-transform: uppercase; letter-spacing: .04em; }
 .sidebar ul { list-style: none; margin: 4px 0 0; padding: 0; }
 .sidebar li { margin: 0; }
 .sidebar a { display: flex; align-items: center; justify-content: space-between; gap: 6px; padding: 6px 18px; font-size: 13px; color: #eaf3fb; text-decoration: none; border-left: 3px solid transparent; cursor: pointer; }
 .sidebar a:hover { background: var(--brand-3); border-left-color: #9fd4f7; }
 .sidebar .toc-name { min-width: 0; overflow-wrap: anywhere; }
 .sidebar .toc-meta { display: inline-flex; align-items: center; flex: none; }
 .sidebar .muted { color: #cfe0ee; font-size: 11px; }
 .content { flex: 1; min-width: 0; padding: 24px; }
 .meta-line { color: var(--muted); font-size: 13px; margin: 0 0 16px; }
 .stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 12px;
          /* Frozen like a spreadsheet header row: the tiles double as the severity
             filter, so keeping them on screen keeps the filter reachable from
             anywhere in a long report. Negative margin + matching padding bleeds
             the background across .content's 24px gutters, so rows scrolling
             underneath don't show through at the edges. */
          position: sticky; top: 0; z-index: 20; background: var(--bg);
          margin: 0 -24px 18px; padding: 12px 24px 14px;
          box-shadow: 0 1px 0 var(--border), 0 4px 10px -6px rgba(16,24,40,.28); }
 .stat-tile { background: var(--surface); border: 1px solid var(--border); border-left: 4px solid var(--muted); border-radius: 8px; padding: 14px 16px; cursor: pointer; text-align: left; font: inherit; }
 .stat-tile .stat-num { display: block; font-size: 26px; font-weight: 700; line-height: 1.1; }
 .stat-tile .stat-label { display: block; font-size: 12px; color: var(--muted); text-transform: uppercase; letter-spacing: .04em; margin-top: 2px; }
 .stat-tile.stat-FAIL { border-left-color: var(--crit); }
 .stat-tile.stat-FAIL .stat-num { color: var(--crit); }
 .stat-tile.stat-WARN { border-left-color: var(--warn); }
 .stat-tile.stat-WARN .stat-num { color: var(--warn); }
 .stat-tile.stat-INFO { border-left-color: var(--info); }
 .stat-tile.stat-INFO .stat-num { color: var(--info); }
 .stat-tile.stat-PASS { border-left-color: var(--ok); }
 .stat-tile.stat-PASS .stat-num { color: var(--ok); }
 .stat-tile.active { box-shadow: 0 0 0 2px var(--accent) inset; }
 .filters { display: flex; flex-wrap: wrap; gap: 8px; margin: 0 0 20px; }
 .filters button { font: inherit; font-size: 13px; padding: 7px 14px; border: 1px solid var(--border); border-radius: 999px; background: var(--surface); color: var(--text); cursor: pointer; }
 .filters button:hover { border-color: var(--accent); color: var(--accent); }
 .filters button.active { background: var(--accent); color: #fff; border-color: var(--accent); }
 h2 { color: var(--brand-2); margin: 28px 0 4px; padding-left: 10px; border-left: 4px solid var(--accent); font-size: 16px; scroll-margin-top: 118px; }
 table { border-collapse: collapse; width: 100%; margin-top: 6px; background: var(--surface); border-radius: 6px; overflow: hidden; box-shadow: 0 1px 2px rgba(16,24,40,.05); }
 th, td { border-bottom: 1px solid var(--border); padding: 8px 12px; text-align: left; font-size: 13px; }
 th { background: var(--brand-2); color: #fff; font-weight: 600; }
 tr:hover td { background: #f5f8fb; }
 .badge { display: inline-block; padding: 2px 9px; border-radius: 999px; font-size: 11px; font-weight: 700; letter-spacing: .03em; }
 .badge-PASS { background: var(--ok-bg); color: var(--ok); }
 .badge-WARN { background: var(--warn-bg); color: var(--warn); }
 .badge-FAIL { background: var(--crit-bg); color: var(--crit); }
 .badge-INFO { background: var(--info-bg); color: var(--info); }
 tr.hidden, h2.hidden, table.hidden { display: none; }
 #emptyNote { color: var(--muted); font-style: italic; margin: 12px 0; display: none; }
 .b { font-size: 11px; font-weight: bold; padding: 0 5px; border-radius: 8px; margin-left: 4px; }
 .bFAIL { background: var(--crit-bg); color: var(--crit); }
 .bWARN { background: var(--warn-bg); color: var(--warn); }
 .seccount { color: var(--muted); font-weight: normal; font-size: 13px; }
 .backtop { font-size: 12px; margin-left: 10px; font-weight: normal; color: var(--accent); text-decoration: none; }
 @media (max-width: 820px) {
  .layout { flex-direction: column; }
  .sidebar { width: 100%; flex-basis: auto; position: static; max-height: none; }
  .stats { position: static; margin: 0 0 18px; padding: 0; box-shadow: none; }
  h2 { scroll-margin-top: 8px; }
 }
</style>
"@

    # Per-status counts for the stat tiles and filter buttons. @() guards the
    # PowerShell quirk where a single matching object has no usable .Count.
    $cFail = @($script:Results | Where-Object { $_.Status -eq 'FAIL' }).Count
    $cWarn = @($script:Results | Where-Object { $_.Status -eq 'WARN' }).Count
    $cInfo = @($script:Results | Where-Object { $_.Status -eq 'INFO' }).Count
    $cPass = @($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count
    $cAttn = $cFail + $cWarn
    # $script:Results is a List[object]; read .Count directly. Wrapping it as
    # @($script:Results).Count throws "Argument types do not match" in WinPS 5.1.
    $cAll  = $script:Results.Count

    # Group results into per-check sections (Category + Check), preserving
    # first-seen order. Each becomes its own anchored table, navigable from the
    # contents/appendix at the top of the report.
    $sections = New-Object System.Collections.Generic.List[object]
    $secIndex = @{}
    foreach ($r in $script:Results) {
        $key = "$($r.Category)|$($r.Check)"
        if (-not $secIndex.ContainsKey($key)) {
            $secIndex[$key] = $sections.Count
            $sections.Add([pscustomobject]@{
                Cat   = $r.Category
                Check = $r.Check
                Id    = 'sec-' + (($key -replace '[^A-Za-z0-9]+', '-').Trim('-'))
                Rows  = (New-Object System.Collections.Generic.List[object])
            })
        }
        $sections[$secIndex[$key]].Rows.Add($r)
    }

    # Contents/appendix, grouped by category
    $tocHtml = foreach ($catGrp in ($sections | Group-Object Cat)) {
        $items = foreach ($sec in $catGrp.Group) {
            $f = @($sec.Rows | Where-Object { $_.Status -eq 'FAIL' }).Count
            $w = @($sec.Rows | Where-Object { $_.Status -eq 'WARN' }).Count
            $badges = ''
            if ($f -gt 0) { $badges += "<span class='b bFAIL'>$f FAIL</span>" }
            if ($w -gt 0) { $badges += "<span class='b bWARN'>$w WARN</span>" }
            "<li><a data-jump='$($sec.Id)' href='#$($sec.Id)'><span class='toc-name'>$($sec.Check)</span><span class='toc-meta'><span class='muted'>($($sec.Rows.Count))</span>$badges</span></a></li>"
        }
        "<div class='toc-cat'><span class='toc-cat-name'>$($catGrp.Name)</span><ul>$($items -join '')</ul></div>"
    }
    $tocHtml = $tocHtml -join "`n"

    # One anchored section + table per Check (Object / Status / Detail columns;
    # Category and Check live in the heading)
    $bodyHtml = foreach ($sec in $sections) {
        $secRows = ($sec.Rows | ForEach-Object {
            "<tr data-status='$($_.Status)'><td>$([System.Net.WebUtility]::HtmlEncode([string]$_.Object))</td>" +
            "<td><span class='badge badge-$($_.Status)'>$($_.Status)</span></td><td>$([System.Net.WebUtility]::HtmlEncode([string]$_.Detail))</td></tr>"
        }) -join "`n"
        @"
<h2 id="$($sec.Id)" data-section="$($sec.Id)">$($sec.Cat) &rsaquo; $($sec.Check) <span class="seccount">($($sec.Rows.Count))</span> <a class="backtop" href="#top">&uarr; top</a></h2>
<table data-section-table="$($sec.Id)"><tr><th>Object</th><th>Status</th><th>Detail</th></tr>
$secRows
</table>
"@
    }
    $bodyHtml = $bodyHtml -join "`n"

    $html = @"
<!DOCTYPE html><html><head><meta charset='utf-8'>$style
<title>VMware Health Check $stamp</title></head><body>
<header class="topbar">
 <div class="topbar-brand"><span class="brand-badge">HC</span><span class="brand-title">VMware Health &amp; Compliance Report</span></div>
 <div class="topbar-meta">Generated $(Get-Date) &nbsp;&bull;&nbsp; vCenter(s): $([System.Net.WebUtility]::HtmlEncode($VCenter -join ', '))</div>
</header>
<div class="layout">
 <nav class="sidebar">
  <h3>Contents</h3>
  $tocHtml
 </nav>
 <main class="content">
  <a id="top"></a>
  <div class="stats">
   <button class="stat-tile stat-FAIL" data-filter="FAIL"><span class="stat-num">$cFail</span><span class="stat-label">Fail</span></button>
   <button class="stat-tile stat-WARN" data-filter="WARN"><span class="stat-num">$cWarn</span><span class="stat-label">Warn</span></button>
   <button class="stat-tile stat-INFO" data-filter="INFO"><span class="stat-num">$cInfo</span><span class="stat-label">Info</span></button>
   <button class="stat-tile stat-PASS" data-filter="PASS"><span class="stat-num">$cPass</span><span class="stat-label">Pass</span></button>
  </div>
  <div class="filters">
   <button data-filter="attention" class="active">Needs attention &mdash; FAIL + WARN ($cAttn)</button>
   <button data-filter="FAIL">FAIL ($cFail)</button>
   <button data-filter="WARN">WARN ($cWarn)</button>
   <button data-filter="INFO">INFO ($cInfo)</button>
   <button data-filter="PASS">PASS ($cPass)</button>
   <button data-filter="all">All ($cAll)</button>
  </div>
  <p id="emptyNote">Nothing matches this filter.</p>
  $bodyHtml
 </main>
</div>
<script>
(function(){
 var buttons = document.querySelectorAll('.filters button');
 var tiles = document.querySelectorAll('.stat-tile');
 var rows = document.querySelectorAll('table tr[data-status]');
 var note = document.getElementById('emptyNote');
 var tables = document.querySelectorAll('[data-section-table]');
 function refreshSections(){
  tables.forEach(function(tbl){
   var id = tbl.getAttribute('data-section-table');
   var vis = tbl.querySelectorAll('tr[data-status]:not(.hidden)').length;
   var head = document.querySelector('[data-section="' + id + '"]');
   tbl.classList.toggle('hidden', vis === 0);
   if (head) head.classList.toggle('hidden', vis === 0);
  });
 }
 function apply(filter){
  var visible = 0;
  rows.forEach(function(r){
   var s = r.getAttribute('data-status');
   var show = (filter === 'all') || (filter === 'attention' ? (s === 'FAIL' || s === 'WARN') : (s === filter));
   r.classList.toggle('hidden', !show);
   if (show) visible++;
  });
  buttons.forEach(function(b){ b.classList.toggle('active', b.getAttribute('data-filter') === filter); });
  tiles.forEach(function(t){ t.classList.toggle('active', t.getAttribute('data-filter') === filter); });
  refreshSections();
  note.style.display = visible ? 'none' : 'block';
 }
 buttons.forEach(function(b){ b.addEventListener('click', function(){ apply(b.getAttribute('data-filter')); }); });
 tiles.forEach(function(t){ t.addEventListener('click', function(){ apply(t.getAttribute('data-filter')); }); });
 document.querySelectorAll('[data-jump]').forEach(function(a){
  a.addEventListener('click', function(e){
   e.preventDefault();
   apply('all');
   var el = document.getElementById(a.getAttribute('data-jump'));
   if (el) el.scrollIntoView({ behavior: 'smooth', block: 'start' });
  });
 });
 apply('attention');
})();
</script>
</body></html>
"@
    $html | Out-File -FilePath $htmlFile -Encoding utf8
    Write-Host "HTML report written to: $htmlFile" -ForegroundColor Green

    # Also drop a CSV next to it for spreadsheet / trending use
    $csvFile = Join-Path $ReportPath "VMwareHealthCheck-$stamp.csv"
    $script:Results | Export-Csv -Path $csvFile -NoTypeInformation -Encoding utf8
    Write-Host "CSV report written to:  $csvFile" -ForegroundColor Green

    if ($connections) { Disconnect-VIServer -Server $connections -Confirm:$false -ErrorAction SilentlyContinue }
    #endregion
}

#region --- Exit code ---------------------------------------------------------
# Runs only on a completed run: the catch block above rethrows, so a failed run
# never reaches here and PowerShell sets exit code 1 for the terminating error.
# The finally block has already written the HTML and CSV reports by this point.
# See .NOTES for the full table.
$failCount = @($script:Results | Where-Object { $_.Status -eq 'FAIL' }).Count
if ($failCount -gt 0) {
    Write-Host "Exiting with code 2 - $failCount FAIL result(s)." -ForegroundColor Red
    exit 2
}
exit 0
#endregion
