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
    [string[]] $ExpectedSyslogServer,
    [string[]] $ExpectedNtpServer,

    [switch] $TrustAllCertificates  = $true
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
            $tcpClient.Connect($vc, 443)
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
            if ($sslStream) { $sslStream.Close() }
            if ($tcpClient) { $tcpClient.Close() }
        }
    }

    # Explicit -Server so this always spans every connected vCenter,
    # regardless of the session's DefaultVIServerMode setting.
    $vmHosts = Get-VMHost -Server $connections

    # vCenter version/build per connection, keyed by server name, for comparing
    # against each host below. Connect-VIServer's connection object already
    # carries .Version/.Build - no extra API call needed.
    $vcInfoByServer = @{}
    foreach ($conn in $connections) { $vcInfoByServer[$conn.Name.ToLowerInvariant()] = $conn }

    foreach ($h in $vmHosts) {
        # Connection / power state
        if ($h.ConnectionState -ne 'Connected') {
            Add-Result 'HostHealth' $h.Name 'ConnectionState' 'FAIL' "State is $($h.ConnectionState)"
        } else {
            Add-Result 'HostHealth' $h.Name 'ConnectionState' 'PASS' 'Connected'
        }

        # ESXi build vs vCenter build. VMware only supports ESXi hosts within
        # roughly N-2 major versions of vCenter, and a host *newer* than
        # vCenter is unsupported outright and can break management features.
        # Match the host to its managing vCenter via its Uid
        # (/VIServer=user@server:port/VMHost=.../), same pattern already used
        # for VM/snapshot matching below; fall back to the sole connection
        # when there's only one, in case Uid parsing ever fails.
        $hostServer = $null
        if ($h.Uid -match '@([^:/]+)') { $hostServer = $Matches[1].ToLowerInvariant() }
        $vcConn = if ($hostServer -and $vcInfoByServer.ContainsKey($hostServer)) {
            $vcInfoByServer[$hostServer]
        } elseif ($connections.Count -eq 1) {
            $connections[0]
        } else {
            $null
        }

        if (-not $vcConn) {
            Add-Result 'HostHealth' $h.Name 'VersionVsVCenter' 'INFO' "Could not determine which connected vCenter manages this host; skipped"
        } else {
            $hostMajor = 0; $hostMinor = 0
            if ($h.Version -match '^(\d+)\.(\d+)') { $hostMajor = [int]$Matches[1]; $hostMinor = [int]$Matches[2] }
            $vcMajor = 0; $vcMinor = 0
            if ($vcConn.Version -match '^(\d+)\.(\d+)') { $vcMajor = [int]$Matches[1]; $vcMinor = [int]$Matches[2] }

            if ($hostMajor -eq 0 -or $vcMajor -eq 0) {
                Add-Result 'HostHealth' $h.Name 'VersionVsVCenter' 'INFO' "Could not parse version (host $($h.Version)/$($h.Build), vCenter $($vcConn.Version)/$($vcConn.Build))"
            } elseif ($hostMajor -gt $vcMajor -or ($hostMajor -eq $vcMajor -and $hostMinor -gt $vcMinor)) {
                Add-Result 'HostHealth' $h.Name 'VersionVsVCenter' 'FAIL' "ESXi $($h.Version) build $($h.Build) is NEWER than vCenter $($vcConn.Version) build $($vcConn.Build) - unsupported, management features may break"
            } elseif ($hostMajor -le ($vcMajor - $HostVersionSkewFailMajors)) {
                Add-Result 'HostHealth' $h.Name 'VersionVsVCenter' 'FAIL' "ESXi $($h.Version) is $($vcMajor - $hostMajor) major version(s) behind vCenter $($vcConn.Version) - outside VMware's supported interop range"
            } elseif ($h.Version -ne $vcConn.Version) {
                Add-Result 'HostHealth' $h.Name 'VersionVsVCenter' 'WARN' "ESXi $($h.Version) build $($h.Build) differs from vCenter $($vcConn.Version) build $($vcConn.Build)"
            } else {
                Add-Result 'HostHealth' $h.Name 'VersionVsVCenter' 'PASS' "ESXi $($h.Version) build $($h.Build) matches vCenter $($vcConn.Version) build $($vcConn.Build)"
            }
        }

        # NTP - servers configured, daemon running, and (optionally) the
        # configured servers matching the -ExpectedNtpServer baseline.
        $ntpServers = @($h | Get-VMHostNtpServer)
        $ntpSvc     = $h | Get-VMHostService | Where-Object { $_.Key -eq 'ntpd' }
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
            # 'fd00::10' + ':514' reads back as one unparseable host.
            $sysHost = "$($_.Host)"
            if ($sysHost -like '*:*' -and $sysHost -notlike '`[*') { $sysHost = "[$sysHost]" }
            if ($_.Port) { "${sysHost}:$($_.Port)" } else { $sysHost }
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
        $luns = @($h | Get-ScsiLun -LunType disk -ErrorAction SilentlyContinue)
        $pathIssues  = New-Object System.Collections.Generic.List[object]
        $totalPaths  = 0
        $anyLunDown  = $false
        foreach ($lun in $luns) {
            $paths  = @(Get-ScsiLunPath -ScsiLun $lun -ErrorAction SilentlyContinue)
            $totalPaths += $paths.Count
            $dead   = @($paths | Where-Object { $_.State -in @('Dead','Disabled') })
            $active = @($paths | Where-Object { $_.State -notin @('Dead','Disabled') })
            if ($dead.Count -eq 0) { continue }
            if ($active.Count -eq 0) {
                $anyLunDown = $true
                $pathIssues.Add("$($lun.CanonicalName): all $($paths.Count) paths down")
            } else {
                $pathIssues.Add("$($lun.CanonicalName): $($dead.Count) of $($paths.Count) paths down")
            }
        }
        if ($pathIssues.Count -gt 0) {
            $severity = if ($anyLunDown) { 'FAIL' } else { 'WARN' }
            Add-Result 'HostHealth' $h.Name 'PathState' $severity ($pathIssues -join '; ')
        } elseif ($luns.Count -gt 0) {
            Add-Result 'HostHealth' $h.Name 'PathState' 'PASS' "$totalPaths path(s) across $($luns.Count) LUN(s), all active"
        } else {
            Add-Result 'HostHealth' $h.Name 'PathState' 'INFO' 'No block storage LUNs found (e.g. NFS-only host)'
        }

        # ESXi host TLS certificate expiry
        $hostCert = $h.ExtensionData.Config.Certificate
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
        } else {
            Add-Result 'HostHealth' $h.Name 'CertificateExpiry' 'INFO' 'Certificate info not available from vCenter'
        }

        # Local account password expiration policy (root included). vCenter's API
        # doesn't expose a specific account's actual days-until-expiry - that lives
        # only in the host's local shadow file and would require SSH + `chage -l
        # root` to read. This checks whether password aging is enabled at all.
        try {
            $pwExpSetting = $h | Get-AdvancedSetting -Name 'Security.PasswordExpirationInDays' -ErrorAction Stop
            $pwExpDays = [int]$pwExpSetting.Value
            if ($pwExpDays -le 0) {
                Add-Result 'HostHealth' $h.Name 'PasswordExpirationPolicy' 'WARN' 'Security.PasswordExpirationInDays is 0 (disabled) - local account passwords, including root, never expire'
            } else {
                Add-Result 'HostHealth' $h.Name 'PasswordExpirationPolicy' 'PASS' "Security.PasswordExpirationInDays = $pwExpDays (root's actual remaining days isn't exposed by the vCenter API; requires SSH to check directly)"
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
        $sshSvc = $h | Get-VMHostService | Where-Object { $_.Key -eq 'TSM-SSH' }
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
        # Connection state - orphaned/inaccessible/invalid is vCenter's
        # inventory losing track of the VM (the "question mark" icon in the
        # vSphere Client). Runs regardless of power state and is easy to miss
        # since it doesn't show up in any other check here.
        $connState = $vm.ExtensionData.Runtime.ConnectionState
        switch ($connState) {
            'connected'    { Add-Result 'VMCompliance' $vm.Name 'ConnectionState' 'PASS' 'Connected' }
            'disconnected' { Add-Result 'VMCompliance' $vm.Name 'ConnectionState' 'WARN' 'Disconnected (host may be unreachable)' }
            default        { Add-Result 'VMCompliance' $vm.Name 'ConnectionState' 'FAIL' "$connState" }
        }

        # Disk consolidation needed - leftover snapshot delta disks, often
        # left behind by backup software that didn't clean up after itself,
        # that silently consume growing datastore space until consolidated.
        if ($vm.ExtensionData.Runtime.ConsolidationNeeded) {
            Add-Result 'VMCompliance' $vm.Name 'DiskConsolidation' 'WARN' 'Disk consolidation needed - leftover snapshot delta disk(s) present'
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

        # VM hardware version (vmx-NN). Flag noticeably old ones.
        $hwVersion = $vm.HardwareVersion
        $hwNum = 0
        if ($hwVersion -match 'vmx-(\d+)') { $hwNum = [int]$Matches[1] }
        if ($hwNum -gt 0 -and $hwNum -lt $HardwareVersionWarnNum) {
            Add-Result 'VMCompliance' $vm.Name 'HardwareVersion' 'WARN' "$hwVersion (consider upgrading)"
        } else {
            Add-Result 'VMCompliance' $vm.Name 'HardwareVersion' 'PASS' "$hwVersion"
        }

        # Mounted ISO / connected CD-ROM (blocks vMotion, often left behind)
        $mounted = $cdByVm[$vm.Uid] | Where-Object { $_.IsoPath -or $_.HostDevice -or $_.RemoteDevice }
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
        $totalMemMB  = ($hostsInCl | Measure-Object -Property MemoryTotalMB -Sum).Sum
        $usedMemMB   = ($hostsInCl | Measure-Object -Property MemoryUsageMB -Sum).Sum

        if ($totalCpuMhz -gt 0) {
            $cpuPct = [math]::Round(($usedCpuMhz / $totalCpuMhz) * 100, 1)
            $status = if ($cpuPct -ge $ClusterUsageWarnPercent) { 'WARN' } else { 'PASS' }
            Add-Result 'Capacity' $cl.Name 'ClusterCPU' $status "$cpuPct% used"
        }
        if ($totalMemMB -gt 0) {
            $memPct = [math]::Round(($usedMemMB / $totalMemMB) * 100, 1)
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
            Add-Result 'ClusterConfig' $cl.Name 'HA' 'PASS' 'HA enabled'
        } else {
            Add-Result 'ClusterConfig' $cl.Name 'HA' 'WARN' 'HA disabled'
        }

        # Admission control (only relevant when HA is on)
        if ($cl.HAEnabled) {
            $ac = $cl.ExtensionData.Configuration.DasConfig.AdmissionControlEnabled
            if ($ac) {
                Add-Result 'ClusterConfig' $cl.Name 'AdmissionControl' 'PASS' 'Enabled'
            } else {
                Add-Result 'ClusterConfig' $cl.Name 'AdmissionControl' 'WARN' 'Disabled (no failover capacity guarantee)'
            }
        }

        # DRS
        if ($cl.DrsEnabled) {
            Add-Result 'ClusterConfig' $cl.Name 'DRS' 'PASS' "Enabled ($($cl.DrsAutomationLevel))"
            if ($cl.DrsAutomationLevel -ne 'FullyAutomated') {
                Add-Result 'ClusterConfig' $cl.Name 'DRSAutomation' 'WARN' "Not FullyAutomated ($($cl.DrsAutomationLevel))"
            }
        } else {
            Add-Result 'ClusterConfig' $cl.Name 'DRS' 'WARN' 'DRS disabled'
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
            Add-Result 'ClusterConfig' $cl.Name 'EVC' 'PASS' $evc
        } else {
            Add-Result 'ClusterConfig' $cl.Name 'EVC' 'WARN' 'Not configured - if hosts have mixed CPU generations, or a differing one is added later, vMotion may fail; consider enabling EVC as a hedge'
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

    if (-not (Test-Path $ReportPath)) { New-Item -ItemType Directory -Path $ReportPath -Force | Out-Null }
    $stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'
    $htmlFile  = Join-Path $ReportPath "VMwareHealthCheck-$stamp.html"

    # Styled after a Dell iDRAC-style dashboard: dark navy header/sidebar, a
    # blue accent, status pill badges, and a stat-tile summary row instead of
    # a plain text line.
    $style = @"
<style>
 :root {
  --navy: #0b1f33; --navy-2: #123252; --accent: #045a9e;
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
 .topbar { background: linear-gradient(180deg, var(--navy) 0%, var(--navy-2) 100%); color: #fff; padding: 14px 24px; display: flex; align-items: center; justify-content: space-between; flex-wrap: wrap; gap: 8px; }
 .topbar-brand { display: flex; align-items: center; gap: 12px; }
 .brand-badge { display: inline-flex; align-items: center; justify-content: center; width: 34px; height: 34px; border-radius: 6px; background: var(--accent); color: #fff; font-weight: 700; font-size: 13px; letter-spacing: .5px; flex: none; }
 .brand-title { font-size: 18px; font-weight: 600; }
 .topbar-meta { font-size: 12px; color: #c7d2df; }
 .layout { display: flex; align-items: flex-start; }
 .sidebar { width: 270px; flex: 0 0 270px; background: var(--navy); color: #dbe6f0; padding: 18px 0; position: sticky; top: 0; align-self: flex-start; max-height: 100vh; overflow-y: auto; }
 .sidebar h3 { margin: 0 18px 10px; font-size: 12px; text-transform: uppercase; letter-spacing: .08em; color: #8fa3ba; }
 .sidebar .toc-cat { margin: 0 0 14px; }
 .sidebar .toc-cat-name { display: block; padding: 6px 18px; font-weight: 600; font-size: 12px; color: #a9bdd2; text-transform: uppercase; letter-spacing: .04em; }
 .sidebar ul { list-style: none; margin: 4px 0 0; padding: 0; }
 .sidebar li { margin: 0; }
 .sidebar a { display: flex; align-items: center; justify-content: space-between; gap: 6px; padding: 6px 18px; font-size: 13px; color: #dbe6f0; text-decoration: none; border-left: 3px solid transparent; cursor: pointer; }
 .sidebar a:hover { background: var(--navy-2); border-left-color: var(--accent); }
 .sidebar .muted { color: #7c93ab; font-size: 11px; }
 .content { flex: 1; min-width: 0; padding: 24px; }
 .meta-line { color: var(--muted); font-size: 13px; margin: 0 0 16px; }
 .stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 12px; margin-bottom: 18px; }
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
 h2 { color: var(--navy); margin: 28px 0 4px; padding-left: 10px; border-left: 4px solid var(--accent); font-size: 16px; }
 table { border-collapse: collapse; width: 100%; margin-top: 6px; background: var(--surface); border-radius: 6px; overflow: hidden; box-shadow: 0 1px 2px rgba(16,24,40,.05); }
 th, td { border-bottom: 1px solid var(--border); padding: 8px 12px; text-align: left; font-size: 13px; }
 th { background: var(--navy); color: #fff; font-weight: 600; }
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
            "<li><a data-jump='$($sec.Id)' href='#$($sec.Id)'>$($sec.Check)</a> <span class='muted'>($($sec.Rows.Count))</span>$badges</li>"
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
 <div class="topbar-meta">Generated $(Get-Date) &nbsp;&bull;&nbsp; vCenter(s): $($VCenter -join ', ')</div>
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
