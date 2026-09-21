<#
.SYNOPSIS
    Read-only health check & compliance report for a vCenter environment.

.DESCRIPTION
    Connects to one or more vCenter Servers and evaluates four areas:
        1. Host health     - connection state, services set to start with the host, NIC link state, uplink redundancy, DNS, NTP, syslog, uptime, datastore connectivity, storage path state, TLS certificate expiry (hosts + vCenter), local account password expiration policy, ESXi build vs vCenter build, lockdown mode, SSH service state
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

.PARAMETER OSDriveFreeWarnPercent
    Guest OS system drive (C:\ on Windows, / on Linux) with less than this
    percentage free is flagged. Requires VMware Tools running in the guest.
    Default 15. A percentage rather than a GB figure because 20GB free is
    comfortable on a 1TB disk and nearly full on a 40GB one.

.PARAMETER DataDriveFreeWarnPercent
    Any other guest drive (non-OS volume) with less than this percentage free
    is flagged. Requires VMware Tools running in the guest. Default 10.

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

.PARAMETER ExpectedEsxiBuild
    The ESXi build number every host is supposed to be running, e.g.
    -ExpectedEsxiBuild 24859861. Hosts on a lower build are WARN, hosts on a
    higher one are INFO (ahead of the standard, which is worth knowing but is
    not a fault). Omit it and the Updates section reports each host's build
    without judging it.

    Only consulted for hosts that vLCM/Update Manager cannot answer for. Where
    a host has a patch baseline attached, that baseline is the answer - it is
    what your own organisation has decided "current" means - and this value is
    not used for that host.

.PARAMETER ExpectedVCenterBuild
    The vCenter build number you expect, e.g. -ExpectedVCenterBuild 24322831.
    Omit it and the Updates section reports vCenter's version and build
    without judging it.

    There is deliberately no query to the appliance management service on port
    5480 here: that is a separate endpoint needing its own credentials and its
    own firewall path, which this script does not ask for and should not need.

.PARAMETER IncludeToolsVibVersion
    Read the VMware Tools package (the 'tools-light' VIB) each ESXi host ships
    to its VMs, and flag hosts whose copy is older than the newest one in the
    estate.

    OFF BY DEFAULT, because it is the one check here that costs a round trip
    PER HOST. Everything else in this script reads from bulk property
    collector calls; this reaches into each host through esxcli, which is the
    only place the VIB list is exposed - it is not in the vSphere API. On a
    large estate expect this to add minutes to the run, so it suits an
    occasional audit rather than a scheduled health check.

    Nothing is hardcoded: each host is compared against the newest tools-light
    version found on any host in this run. A host behind that is WARN and can
    be brought level by patching it. If every host is on the same version they
    are all NORMAL, which is the correct answer even if that version is old -
    this check answers "are my hosts consistent" and vLCM baselines
    (-ExpectedEsxiBuild, or an attached patch baseline) answer "are my hosts
    current".

.PARAMETER ShowAllConsoleOutput
    Echo every NORMAL and INFO row to the console as it is found, the way the
    script used to. Off by default: on a real estate those rows are the large
    majority, writing them is one of the slowest things the script does, and
    they scroll the FAIL and WARN lines - the ones worth watching for - off
    the screen. Everything is in the HTML and CSV reports either way; this
    only controls what the console shows while the run is in progress.

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

.PARAMETER PasswordMaxDaysWarn
    Hosts whose Security.PasswordMaxDays is above this many days are WARN.
    Default 365. VMware ships the setting at 99999, which is the "never
    expires" sentinel rather than a real age limit, and that is always
    flagged regardless of this value.

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
    add their inventories together. As long as [NORMAL]/[WARN] lines keep
    printing it is working, not hung.

    Output: every result shown on the console is also written to two
    timestamped files in -ReportPath (default: current directory):
      VMwareHealthCheck-<yyyyMMdd-HHmmss>.html  (styled table)
      VMwareHealthCheck-<yyyyMMdd-HHmmss>.csv   (same rows, for Excel)
    Both share the columns Category, Object, Check, Status, Detail, and
    are written in a finally block so they are produced even if the run
    errors partway through. Pass -ReportPath to control where they land.

    Checking for available updates (-ExpectedEsxiBuild,
    -ExpectedVCenterBuild). The Updates section answers "is anything behind?"
    from whichever of two sources it can, and always says which one it used.

    Source 1, and the one worth having: vSphere Lifecycle Manager / Update
    Manager baseline compliance. If your hosts have a patch baseline attached,
    nothing needs configuring here - the section reports each host's
    compliance against the baselines your organisation already maintains, and
    stays correct without anyone editing this script. -ExpectedEsxiBuild is
    not consulted for a host that has a baseline.

    Source 2, for estates that don't use baselines: a build number you supply.

      # What your hosts are actually on. Sorting groups them, so the
      # stragglers stand out and the majority build is the obvious standard:
      Connect-VIServer vcenter01.corp.local
      Get-VMHost | Select-Object Name, Version, Build | Sort-Object Build

      # vCenter's own build:
      $global:DefaultVIServer | Select-Object Name, Version, Build

    Then pass whichever you want compared:

      .\Invoke-VMwareHealthCheck.ps1 -VCenter vcenter01.corp.local `
          -ExpectedEsxiBuild 24859861 -ExpectedVCenterBuild 24322831

    Leave them off and the section still lists every build, it just doesn't
    judge them. A host AHEAD of the expected build is INFO, not WARN - worth
    knowing, but not a missing update.

    There is deliberately no hardcoded table of current VMware builds in this
    script. One existed and was removed: it is wrong the day Broadcom ships
    anything, and a stale table reporting "up to date" is worse than reporting
    nothing at all. For the same reason nothing here queries the vCenter
    appliance service on port 5480 - that is a separate endpoint with its own
    credentials and its own firewall path, which this script does not ask for.

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

    Step 3 (optional) - if you always check the same environment and don't
    want to retype the baselines, put them in a WRAPPER script beside this
    one rather than editing the param() block below:

      # Run-SiteHealthCheck.ps1 - this site's settings; edit freely.
      & "$PSScriptRoot\Invoke-VMwareHealthCheck.ps1" `
          -VCenter              vcenter01.corp.local `
          -ExpectedSyslogServer 'udp://loghost01.corp.local:514' `
          -ExpectedNtpServer    10.10.0.10, 10.10.0.11 `
          -ReportPath           C:\Reports `
          @args
      exit $LASTEXITCODE

    Then run .\Run-SiteHealthCheck.ps1, and pass extra arguments straight
    through: .\Run-SiteHealthCheck.ps1 -ShowAllConsoleOutput

    Why a wrapper and not a default in param(): this file gets updated. Local
    edits to it mean every 'git pull' is a merge, and a half-applied merge
    leaves a script that no longer parses - a stray comma in param() is a
    syntax error with no obvious connection to what you actually changed. The
    wrapper is yours, never changes upstream, and 'exit $LASTEXITCODE' keeps
    the exit codes below working for a scheduler.

    If you do set a default in param() anyway, know that the check stops
    being opt-in: a run against a DIFFERENT vCenter with its own collector
    will WARN on every host, and switching the comparison off for one run
    then means passing an empty array, -ExpectedSyslogServer @().

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
    [int] $OSDriveFreeWarnPercent   = 15,
    [int] $DataDriveFreeWarnPercent = 10,
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

    [int] $PasswordMaxDaysWarn      = 365,

    [bool] $TrustAllCertificates    = $true,

    [switch] $ShowAllConsoleOutput,

    # See "Checking for available updates" in .NOTES for how to find these.
    [string] $ExpectedEsxiBuild,
    [string] $ExpectedVCenterBuild,

    [switch] $IncludeToolsVibVersion
)

#region --- Setup -------------------------------------------------------------

# Collected results. Each row: Category, Object, Check, Status (NORMAL/WARN/FAIL/INFO), Detail
# Stamped into the console banner and the report header. A report that cannot
# say which version of the script produced it makes "is this the fixed copy?"
# unanswerable - the script gets copied to jump boxes and scheduled tasks, and
# those copies go stale silently. Bump this whenever a change alters what the
# report says.
$script:ScriptVersion = '1.6.0'

$script:Results = New-Object System.Collections.Generic.List[object]
$script:ShowAllRows = [bool]$ShowAllConsoleOutput
$script:QuietRows   = 0
$script:LastProgressTick = 0
$script:ProgressClock    = $null
$script:HostOptionIndex = @{}   # host MoRef -> (advanced setting name -> value)

# A progress bar for the long loops. Write-Progress updates in place rather
# than scrolling, and is a no-op when output is redirected, so it reassures an
# operator watching a 300-host run without adding a line to any log. Refreshed
# at most every 250ms: redrawing it per object was itself measurable.
function Write-HealthCheckProgress {
    param(
        [string] $Activity,
        [int]    $Current,
        [int]    $Total,
        [string] $Item
    )
    if ($Total -le 0) { return }
    # A Stopwatch rather than [Environment]::TickCount: TickCount wraps to
    # Int32.MinValue after ~24.9 days of uptime, and a negative delta would
    # read as "too soon" and freeze the bar for the rest of the run.
    if ($null -eq $script:ProgressClock) { $script:ProgressClock = [Diagnostics.Stopwatch]::StartNew() }
    $now = $script:ProgressClock.ElapsedMilliseconds
    if ($Current -lt $Total -and ($now - $script:LastProgressTick) -lt 250) { return }
    $script:LastProgressTick = $now
    Write-Progress -Activity $Activity -Status "$Current of $Total - $Item" `
        -PercentComplete ([math]::Min(100, [int](($Current / [double]$Total) * 100)))
    if ($Current -ge $Total) { Write-Progress -Activity $Activity -Completed }
}

function Add-Result {
    param(
        [string] $Category,
        [string] $Object,
        [string] $Check,
        [ValidateSet('NORMAL','WARN','FAIL','INFO')] [string] $Status,
        [string] $Detail
    )
    $script:Results.Add([pscustomobject]@{
        Category = $Category
        Object   = $Object
        Check    = $Check
        Status   = $Status
        Detail   = $Detail
    })
    # FAIL and WARN always print - they are the reason someone is watching the
    # run. NORMAL and INFO are counted instead of printed unless asked for:
    # they are the bulk of the rows, and writing each one to the console is
    # among the most expensive things the script does (console rendering, not
    # the check itself). Nothing is lost - every row is in both reports.
    if ($Status -eq 'FAIL' -or $Status -eq 'WARN' -or $script:ShowAllRows) {
        $color = switch ($Status) {
            'NORMAL' { 'Green' }
            'WARN' { 'Yellow' }
            'FAIL' { 'Red' }
            default { 'Gray' }
        }
        Write-Host ("[{0,-4}] {1,-12} {2,-28} {3} - {4}" -f $Status, $Category, $Object, $Check, $Detail) -ForegroundColor $color
    } else {
        $script:QuietRows++
    }
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
    # Highest VM hardware version a compute resource can run, asked of its
    # EnvironmentBrowser rather than inferred from a hardcoded ESXi-version
    # table (which goes stale every release). For a cluster this is already
    # the common denominator across its hosts, so a recommendation based on
    # it stays vMotion-safe.
    # Keyed on the COMPUTE RESOURCE, not the host: every host in a cluster
    # shares one EnvironmentBrowser, so a per-host cache asked vCenter the
    # same question once per host instead of once per cluster.
    # Returns $null if it can't be determined.
    param(
        [string]    $ComputeResourceMoRef,
        [object]    $EnvironmentBrowser,
        [hashtable] $Cache
    )
    if ([string]::IsNullOrEmpty($ComputeResourceMoRef) -or -not $EnvironmentBrowser) { return $null }
    if ($Cache.ContainsKey($ComputeResourceMoRef)) { return $Cache[$ComputeResourceMoRef] }

    $max = $null
    try {
        $envBrowser = Get-View -Id $EnvironmentBrowser -ErrorAction Stop
        foreach ($descriptor in @($envBrowser.QueryConfigOptionDescriptor())) {
            if ($descriptor.Key -match 'vmx-(\d+)') {
                $n = [int]$Matches[1]
                if ($null -eq $max -or $n -gt $max) { $max = $n }
            }
        }
    } catch {
        Write-Verbose "Could not query EnvironmentBrowser for '$ComputeResourceMoRef': $($_.Exception.Message)"
        $max = $null
    }
    $Cache[$ComputeResourceMoRef] = $max
    return $max
}

# Flattens a VM's snapshot tree - RootSnapshotList plus every
# ChildSnapshotList beneath it - into one list, so nested snapshots are
# reported rather than only the roots.
function Get-SnapshotNode {
    param([object] $Nodes)
    foreach ($n in @($Nodes)) {
        if (-not $n) { continue }
        $n
        if ($n.ChildSnapshotList) { Get-SnapshotNode -Nodes $n.ChildSnapshotList }
    }
}

# Value of one ESXi advanced setting, read from the Config.Option array that
# was fetched with the host view. Replaces a per-host, per-setting
# Get-AdvancedSetting round-trip.
function Get-HostOptionValue {
    param(
        [object] $HostView,
        [string] $Name
    )
    # Config.Option carries every advanced setting on the host - well over a
    # thousand entries on a current ESXi build - so it is indexed once per
    # host and cached against the host's MoRef. Scanning the array per lookup
    # meant a full linear walk for each setting the script asks about.
    if ($null -eq $script:HostOptionIndex) { $script:HostOptionIndex = @{} }
    $moRef = "$($HostView.MoRef)"
    $index = $script:HostOptionIndex[$moRef]
    if ($null -eq $index) {
        $index = @{}
        foreach ($o in @($HostView.Config.Option)) {
            if ($o -and $null -ne $o.Key) { $index[[string]$o.Key] = $o.Value }
        }
        $script:HostOptionIndex[$moRef] = $index
    }
    if ($index.ContainsKey($Name)) { return $index[$Name] }
    return $null
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

# Sidebar label for a check name. Check names are CamelCase identifiers
# ('CertificateExpiry'), which the narrow sidebar has to break mid-word; spacing
# them lets the column wrap at word boundaries instead. Only the sidebar uses
# this - section headings keep the raw name, which matches the CSV.
# What the first column of a section's table is actually listing. Every
# section used to head it 'Object', which is the CSV's column name but not a
# word anyone scans for: on a page of seventeen hosts with a dead uplink, the
# question being asked is "which host?", and the heading should say so. Only
# categories whose rows are all one kind of thing get a specific name;
# Capacity (datastores and clusters) and Updates (vCenter and hosts) stay
# generic rather than mislabel half their rows.
# Orders two VIB version strings such as '12.4.5-23787635' or
# '11.3.5.18557794-20036586'. Split on the punctuation and compare piece by
# piece, numerically where both pieces are numbers - a plain string compare
# puts '9' after '12', which would report the newest host in the estate as the
# one that is behind. Returns -1, 0 or 1.
function Compare-VibVersion {
    param([string] $Left, [string] $Right)
    if ($Left -eq $Right) { return 0 }
    $lp = @($Left  -split '[^0-9A-Za-z]+' | Where-Object { $_ -ne '' })
    $rp = @($Right -split '[^0-9A-Za-z]+' | Where-Object { $_ -ne '' })
    $n  = [math]::Max($lp.Count, $rp.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $a = if ($i -lt $lp.Count) { $lp[$i] } else { '0' }
        $b = if ($i -lt $rp.Count) { $rp[$i] } else { '0' }
        $an = 0; $bn = 0
        if ([int64]::TryParse($a, [ref]$an) -and [int64]::TryParse($b, [ref]$bn)) {
            if ($an -ne $bn) { return $(if ($an -lt $bn) { -1 } else { 1 }) }
        } else {
            $c = [string]::Compare($a, $b, $true)
            if ($c -ne 0) { return $(if ($c -lt 0) { -1 } else { 1 }) }
        }
    }
    return 0
}

function Format-ObjectColumnLabel {
    param([string] $Category)
    switch ($Category) {
        'HostHealth'    { 'Host' }
        'VMCompliance'  { 'VM' }
        'ClusterConfig' { 'Cluster' }
        'Connection'    { 'vCenter' }
        default         { 'Object' }
    }
}

function Format-CheckLabel {
    param([string] $Check)

    # Names the generic rules below get wrong, or that have a house spelling.
    $overrides = @{
        'VersionVsVCenter' = 'Version vs vCenter'
        'VCenterBuild'     = 'vCenter Build'
        'EsxiPatchLevel'   = 'ESXi Patch Level'
        'VMToolsBacklog'   = 'VM Tools Backlog'
        'ToolsVibVersion'  = 'Host Tools Package'
    }
    if ($overrides.ContainsKey($Check)) { return $overrides[$Check] }

    # lowercase/digit followed by a capital: Certificate|Expiry
    $label = $Check -creplace '([a-z0-9])([A-Z])', '$1 $2'
    # end of an acronym run: SSH|Enabled, OS|Drive, DRS|Automation. The {2,} is
    # what keeps 'VMwareTools' from becoming 'V Mware Tools'.
    $label = $label -creplace '([A-Z]{2,})([A-Z][a-z])', '$1 $2'
    return $label
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
    Write-Host "`nVMware Health Check v$($script:ScriptVersion)" -ForegroundColor Cyan
    Write-Host "Connecting to vCenter(s): $($VCenter -join ', ')" -ForegroundColor Cyan
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
                Add-Result 'HostHealth' $vc 'CertificateExpiry' 'NORMAL' "Valid until $($vcCert.NotAfter) ($daysLeft days)"
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

    # ---- Inventory prefetch -------------------------------------------
    # Everything the host checks need is pulled in ONE Get-View per connection
    # instead of a Get-VMHost plus a Get-VMHostService / Get-VMHostNtpServer /
    # Get-VMHostSysLogServer / Get-AdvancedSetting / Get-Datastore / Get-ScsiLun
    # per host, and a Get-ScsiLunPath per LUN. On a host with 40 LUNs that was
    # 45+ round-trips; it is now a share of one.
    # Hosts are still enumerated per connection so each is paired with the
    # vCenter that manages it by construction - deriving that from a .Uid is
    # unreliable, since an SSO login like administrator@vsphere.local puts a
    # second '@' in it.
    $hostProps = @(
        'Name', 'Parent', 'Datastore',
        'Runtime.ConnectionState', 'Runtime.BootTime',
        'Config.Product', 'Config.Certificate', 'Config.LockdownMode',
        'Config.Service.Service', 'Config.DateTimeInfo.NtpConfig.Server',
        'Config.Option', 'Config.StorageDevice.ScsiLun', 'Config.StorageDevice.MultipathInfo',
        'Config.Network',
        'Summary.Hardware', 'Summary.QuickStats'
    )

    $hostEntries    = New-Object System.Collections.Generic.List[object]
    $clusterEntries = New-Object System.Collections.Generic.List[object]
    $dsEntries      = New-Object System.Collections.Generic.List[object]
    $dsByMoRef      = @{}   # datastore MoRef -> view
    $envBrowserByCr = @{}   # compute resource MoRef -> EnvironmentBrowser MoRef
    $hostByMoRef    = @{}   # host MoRef -> view, for pairing VMs to their host

    foreach ($conn in $connections) {
        foreach ($hv in @(Get-View -ViewType HostSystem -Property $hostProps -Server $conn)) {
            $hostEntries.Add([pscustomobject]@{ View = $hv; VCenter = $conn })
            $hostByMoRef[$hv.MoRef.ToString()] = $hv
        }
        # One call covers standalone hosts and clusters alike: ComputeResource
        # is the base type, so this is where every host's EnvironmentBrowser
        # comes from - one per cluster rather than one per host.
        foreach ($cr in @(Get-View -ViewType ComputeResource -Property Name,EnvironmentBrowser -Server $conn)) {
            $envBrowserByCr[$cr.MoRef.ToString()] = $cr.EnvironmentBrowser
        }
        foreach ($cv in @(Get-View -ViewType ClusterComputeResource -Property Name,Host,Summary,Configuration -Server $conn)) {
            $clusterEntries.Add($cv)
        }
        foreach ($dv in @(Get-View -ViewType Datastore -Property Name,Summary,Host -Server $conn)) {
            $dsEntries.Add($dv)
            $dsByMoRef[$dv.MoRef.ToString()] = $dv
        }
    }
    Write-Host ("  Prefetched {0} host(s), {1} cluster(s), {2} datastore(s)." -f `
        $hostEntries.Count, $clusterEntries.Count, $dsEntries.Count) -ForegroundColor DarkGray

    # With NORMAL/INFO rows off the console by default, a big estate would
    # otherwise show nothing between section headers and read as hung. This is
    # a status line, not scrollback, and it costs nothing when the output is
    # redirected to a file or a CI log.
    $hostIdx = 0
    foreach ($entry in $hostEntries) {
        $hv     = $entry.View
        $vcConn = $entry.VCenter
        $hName  = $hv.Name
        $hostIdx++
        Write-HealthCheckProgress -Activity 'Host health' -Current $hostIdx -Total $hostEntries.Count -Item $hName

        # Connection / power state.
        # A $null state is NOT a disconnected host - it is a property vCenter
        # did not return, and reporting it as FAIL produced a red row whose
        # detail read "State is  -" with nothing in it. The VM-side check was
        # fixed for this; the host-side one was not. Either way the remaining
        # checks are skipped, because they read host-side config that cannot be
        # trusted in an unknown state - but the row says which of the two
        # happened.
        $hState = [string]$hv.Runtime.ConnectionState
        if ([string]::IsNullOrWhiteSpace($hState)) {
            Add-Result 'HostHealth' $hName 'ConnectionState' 'INFO' 'Connection state not reported by vCenter for this host - remaining host checks skipped'
            continue
        }
        if ($hState -ne 'connected') {
            # Every check below reads host-side config that vCenter cannot
            # refresh in this state, so the values would be stale or absent.
            Add-Result 'HostHealth' $hName 'ConnectionState' 'FAIL' "State is $hState - remaining host checks skipped"
            continue
        }
        Add-Result 'HostHealth' $hName 'ConnectionState' 'NORMAL' 'Connected'

        # ESXi build vs vCenter build. VMware only supports ESXi hosts within
        # roughly N-2 major versions of vCenter, and a host *newer* than
        # vCenter is unsupported outright and can break management features.
        $hVersion = $hv.Config.Product.Version
        $hBuild   = $hv.Config.Product.Build
        $hostMajor = 0; $hostMinor = 0
        if ($hVersion -match '^(\d+)\.(\d+)') { $hostMajor = [int]$Matches[1]; $hostMinor = [int]$Matches[2] }
        $vcMajor = 0; $vcMinor = 0
        if ($vcConn.Version -match '^(\d+)\.(\d+)') { $vcMajor = [int]$Matches[1]; $vcMinor = [int]$Matches[2] }

        if ($hostMajor -eq 0 -or $vcMajor -eq 0) {
            Add-Result 'HostHealth' $hName 'VersionVsVCenter' 'INFO' "Could not parse version (host $hVersion/$hBuild, vCenter $($vcConn.Version)/$($vcConn.Build))"
        } elseif ($hostMajor -gt $vcMajor -or ($hostMajor -eq $vcMajor -and $hostMinor -gt $vcMinor)) {
            Add-Result 'HostHealth' $hName 'VersionVsVCenter' 'FAIL' "ESXi $hVersion build $hBuild is NEWER than vCenter $($vcConn.Version) build $($vcConn.Build) - unsupported, management features may break"
        } elseif ($hostMajor -lt ($vcMajor - $HostVersionSkewFailMajors)) {
            # -lt, not -le: the parameter is documented as "*more than* this
            # many major versions behind", so a host exactly N behind is the
            # WARN case, not FAIL.
            Add-Result 'HostHealth' $hName 'VersionVsVCenter' 'FAIL' "ESXi $hVersion is $($vcMajor - $hostMajor) major version(s) behind vCenter $($vcConn.Version) - outside VMware's supported interop range"
        } elseif ($hVersion -ne $vcConn.Version) {
            Add-Result 'HostHealth' $hName 'VersionVsVCenter' 'WARN' "ESXi $hVersion build $hBuild differs from vCenter $($vcConn.Version) build $($vcConn.Build)"
        } else {
            Add-Result 'HostHealth' $hName 'VersionVsVCenter' 'NORMAL' "ESXi $hVersion build $hBuild matches vCenter $($vcConn.Version) build $($vcConn.Build)"
        }

        # Host services came with the view; no per-host service query.
        $hostServices = @($hv.Config.Service.Service)

        # NTP - servers configured, daemon running, and (optionally) the
        # configured servers matching the -ExpectedNtpServer baseline.
        $ntpServers = @($hv.Config.DateTimeInfo.NtpConfig.Server)
        $ntpSvc     = $hostServices | Where-Object { $_.Key -eq 'ntpd' }
        if ($ntpServers.Count -eq 0) {
            $detail = 'No NTP servers configured'
            if ($ExpectedNtpServer) { $detail += " - expected: $($ExpectedNtpServer -join ', ')" }
            Add-Result 'HostHealth' $hName 'NTP' 'FAIL' $detail
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
                Add-Result 'HostHealth' $hName 'NTP' 'WARN' $detail
            } elseif ($ExpectedNtpServer) {
                Add-Result 'HostHealth' $hName 'NTP' 'NORMAL' "Running; servers: $($ntpServers -join ', ') (matches expected baseline)"
            } else {
                Add-Result 'HostHealth' $hName 'NTP' 'NORMAL' "Running; servers: $($ntpServers -join ', ')"
            }
        }

        # Syslog - ESXi keeps the remote target(s) in the Syslog.global.logHost
        # advanced setting as a comma-separated list, already in the
        # 'udp://host:514' form the baseline comparison normalizes.
        $syslogActual = @(("$(Get-HostOptionValue -HostView $hv -Name 'Syslog.global.logHost')" -split ',') |
                          ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($syslogActual.Count -eq 0) {
            if ($ExpectedSyslogServer) {
                # A baseline was supplied, so a remote collector is required here -
                # nothing configured means the requirement is entirely unmet.
                Add-Result 'HostHealth' $hName 'Syslog' 'FAIL' "No remote syslog target configured - expected: $($ExpectedSyslogServer -join ', ')"
            } else {
                Add-Result 'HostHealth' $hName 'Syslog' 'WARN' 'No remote syslog target configured'
            }
        } elseif (-not $ExpectedSyslogServer) {
            Add-Result 'HostHealth' $hName 'Syslog' 'NORMAL' "Target: $($syslogActual -join ', ')"
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
                Add-Result 'HostHealth' $hName 'Syslog' 'WARN' "Configured: $($syslogActual -join ', ') | $($sysIssues -join ' | ') | Expected: $($ExpectedSyslogServer -join ', ')"
            } else {
                Add-Result 'HostHealth' $hName 'Syslog' 'NORMAL' "Target: $($syslogActual -join ', ') (matches expected baseline)"
            }
        }

        # Uptime (informational; very long uptime can mean missed patching)
        if ($null -eq $hv.Runtime.BootTime) {
            Add-Result 'HostHealth' $hName 'Uptime' 'INFO' 'Boot time not reported by vCenter for this host'
        } else {
            $uptimeDays = [math]::Round((New-TimeSpan -Start $hv.Runtime.BootTime -End (Get-Date)).TotalDays, 1)
            Add-Result 'HostHealth' $hName 'Uptime' 'INFO' "$uptimeDays days"
        }

        # Datastore connectivity - resolved from the datastore views already
        # fetched, via the MoRefs the host view carries. No per-host query.
        # An unpopulated Summary must not read as "inaccessible", so the three
        # cases are kept apart: definitely inaccessible, definitely fine, unknown.
        $dsList       = @(@($hv.Datastore) | ForEach-Object { $dsByMoRef[$_.ToString()] } | Where-Object { $_ })
        $inaccessible = @($dsList | Where-Object { $null -ne $_.Summary -and -not $_.Summary.Accessible })
        $dsUnknown    = @($dsList | Where-Object { $null -eq $_.Summary })
        if ($inaccessible.Count -gt 0) {
            Add-Result 'HostHealth' $hName 'DatastoreConnectivity' 'FAIL' "Inaccessible: $(($inaccessible.Name) -join ',')"
        } elseif ($dsUnknown.Count -gt 0) {
            # Saying "all accessible" here would be a false all-clear.
            Add-Result 'HostHealth' $hName 'DatastoreConnectivity' 'INFO' "Accessibility not reported by vCenter for $($dsUnknown.Count) of $($dsList.Count) datastore(s): $(($dsUnknown.Name) -join ',')"
        } else {
            Add-Result 'HostHealth' $hName 'DatastoreConnectivity' 'NORMAL' 'All datastores accessible'
        }

        # Storage path state - a LUN can still show as "accessible" on remaining
        # paths while one or more of its FC/iSCSI paths are dead, silently
        # running with reduced (or zero) redundancy. DatastoreConnectivity
        # above won't catch that; this walks the actual multipathing state.
        # Config.StorageDevice came with the host view, so the whole walk -
        # previously one Get-ScsiLunPath per LUN - costs nothing extra.
        # A dead HBA or fabric takes the same path off every LUN at once, so
        # LUNs are grouped by how much redundancy each has LEFT (what you'd
        # actually act on) rather than emitting one near-identical line per
        # LUN, which turns into an unreadable wall of text on a host with
        # dozens of LUNs.
        $diskLuns = @(@($hv.Config.StorageDevice.ScsiLun) | Where-Object { $_ -and $_.DeviceType -eq 'disk' })
        $lunNameByKey = @{}
        foreach ($lun in $diskLuns) { $lunNameByKey[[string]$lun.Key] = $lun.CanonicalName }
        $pathsByLunKey = @{}
        foreach ($mpLun in @($hv.Config.StorageDevice.MultipathInfo.Lun)) {
            if ($mpLun) { $pathsByLunKey[[string]$mpLun.Lun] = @($mpLun.Path) }
        }

        $pathIssues  = New-Object System.Collections.Generic.List[object]
        $totalPaths  = 0
        $offlineLuns = New-Object System.Collections.Generic.List[object]
        $degraded    = @{}   # "N of M paths active" -> list of LUN names
        foreach ($lun in $diskLuns) {
            $paths = @($pathsByLunKey[[string]$lun.Key])
            if ($paths.Count -eq 0) {
                # Don't let a LUN whose paths can't be read count as healthy.
                $pathIssues.Add($lun.CanonicalName)
                continue
            }
            $totalPaths += $paths.Count
            # Counted with a plain loop, not a Where-Object pipeline: this is
            # the innermost loop in the script (every path of every LUN of
            # every host), and the pipeline version also re-allocated the
            # ('dead','disabled') array on each path it tested.
            $deadCount = 0
            foreach ($pth in $paths) {
                $ps = $pth.PathState
                if ($ps -eq 'dead' -or $ps -eq 'disabled') { $deadCount++ }
            }
            if ($deadCount -eq 0) { continue }

            $activeCount = $paths.Count - $deadCount
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
            # worst first.
            $counts = New-Object System.Collections.Generic.List[object]
            if ($offlineLuns.Count -gt 0) { $counts.Add("$($offlineLuns.Count) offline") }
            if ($degradedCount -gt 0)     { $counts.Add("$degradedCount degraded") }
            if ($pathIssues.Count -gt 0)  { $counts.Add("$($pathIssues.Count) unreadable") }

            $parts = New-Object System.Collections.Generic.List[object]
            $parts.Add("$($diskLuns.Count) LUN(s): $($counts -join ', ')")
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
            Add-Result 'HostHealth' $hName 'PathState' $severity ($parts -join ' | ')
        } elseif ($diskLuns.Count -gt 0) {
            Add-Result 'HostHealth' $hName 'PathState' 'NORMAL' "$totalPaths path(s) across $($diskLuns.Count) LUN(s), all active"
        } elseif ($null -eq $hv.Config.StorageDevice) {
            # An empty result because the data never arrived is not the same as
            # a host with no block storage; "NFS-only" here would be a false
            # all-clear.
            Add-Result 'HostHealth' $hName 'PathState' 'WARN' 'Could not enumerate block storage LUNs for this host'
        } else {
            Add-Result 'HostHealth' $hName 'PathState' 'INFO' 'No block storage LUNs found (e.g. NFS-only host)'
        }

        # ---- Network ---------------------------------------------------
        # Config.Network came with the host view, so all of this is free.
        $net = $hv.Config.Network
        if ($null -eq $net) {
            Add-Result 'HostHealth' $hName 'NicLinkState' 'INFO' 'Network configuration not reported by vCenter for this host'
        } else {
            # Map pNIC key -> device name and link state once, then read the
            # switches through it.
            $pnicByKey = @{}
            foreach ($pnic in @($net.Pnic)) {
                if ($pnic) { $pnicByKey[[string]$pnic.Key] = $pnic }
            }

            # Uplinks assigned to a switch, grouped by the switch they serve.
            $switches = New-Object System.Collections.Generic.List[object]
            foreach ($vsw in @($net.Vswitch)) {
                if ($vsw) { $switches.Add([pscustomobject]@{ Name = $vsw.Name; Keys = @($vsw.Pnic) }) }
            }
            foreach ($psw in @($net.ProxySwitch)) {
                if ($psw) { $switches.Add([pscustomobject]@{ Name = $psw.DvsName; Keys = @($psw.Pnic) }) }
            }

            # A pNIC with no LinkSpeed has no link. Only ASSIGNED uplinks are
            # reported: an unused NIC with no cable in it is normal, and
            # flagging every one of those would bury the real finding.
            # Graded the way PathState is: losing an uplink while the switch
            # still has another is a redundancy loss, not an outage. Only a
            # switch with NO uplinks left carrying link is a FAIL - that
            # switch's traffic is actually down.
            $downUplinks   = New-Object System.Collections.Generic.List[object]
            $deadSwitches  = New-Object System.Collections.Generic.List[object]
            $thinSwitches  = New-Object System.Collections.Generic.List[object]
            $unreadable    = New-Object System.Collections.Generic.List[object]
            foreach ($sw in $switches) {
                $swKeys = @($sw.Keys)
                if ($swKeys.Count -eq 0) { continue }
                $up   = 0
                $dead = New-Object System.Collections.Generic.List[object]
                $unresolved = 0
                foreach ($k in $swKeys) {
                    $pnic = $pnicByKey[[string]$k]
                    # An uplink key with no matching entry in Config.Network.Pnic
                    # tells us NOTHING about that uplink's link state. Skipping
                    # it silently left $up at 0, which the test below then read
                    # as "every uplink is down" - a hard FAIL, with no NIC names
                    # in it because none had been resolved to name. That is the
                    # difference between a switch that is down and a switch we
                    # could not read, and they are not the same finding.
                    if ($null -eq $pnic) { $unresolved++; continue }
                    if ($null -eq $pnic.LinkSpeed) { $dead.Add("$($pnic.Device)") } else { $up++ }
                }
                if ($up -eq 0 -and $dead.Count -eq 0) {
                    $unreadable.Add("$($sw.Name) ($unresolved of $($swKeys.Count) uplink(s) not reported by vCenter)")
                    continue
                }
                if ($up -eq 0) {
                    # Name the NICs here too. These were collected and then
                    # thrown away: a fully dead switch took the branch that
                    # prints only the switch and a count, so the FAIL row said
                    # LESS than the WARN row below it, and whoever picked it up
                    # had to log into the host to find out which cable to look
                    # at. The urgent row should be the actionable one.
                    $which = if ($dead.Count -gt 0) { ": $(Format-LunList -Names $dead -MaxShown 6) with no link" } else { '' }
                    $deadSwitches.Add("$($sw.Name)$which (0 of $(@($sw.Keys).Count) uplink(s) up)")
                } else {
                    foreach ($d in $dead) { $downUplinks.Add("$d on $($sw.Name)") }
                    if ($up -lt 2) {
                        $thinSwitches.Add("$($sw.Name) ($up of $(@($sw.Keys).Count) uplink(s) up)")
                    }
                }
            }

            # Never let an unreadable switch hide inside an all-clear: the note
            # rides along with whatever verdict the readable switches produced.
            $unread = if ($unreadable.Count -gt 0) { " Uplink state could not be read for: $($unreadable -join ', ')." } else { '' }
            if ($switches.Count -eq 0) {
                Add-Result 'HostHealth' $hName 'NicLinkState' 'INFO' 'No virtual switches reported for this host'
            } elseif ($deadSwitches.Count -gt 0) {
                $also = if ($downUplinks.Count -gt 0) { " Also down elsewhere: $($downUplinks -join ', ')." } else { '' }
                Add-Result 'HostHealth' $hName 'NicLinkState' 'FAIL' "Switch(es) with no uplink carrying link: $($deadSwitches -join ', ') - that traffic is down; check the cables and physical switch ports.$also$unread"
            } elseif ($downUplinks.Count -gt 0) {
                Add-Result 'HostHealth' $hName 'NicLinkState' 'WARN' "Uplink(s) with no link: $($downUplinks -join ', ') - still carrying traffic on the remaining uplink(s); check the cable and the physical switch port.$unread"
            } elseif ($unreadable.Count -gt 0) {
                Add-Result 'HostHealth' $hName 'NicLinkState' 'INFO' "Uplink state could not be read for: $($unreadable -join ', ') - vCenter listed the switch's uplinks but reported no matching physical NIC, so this host's link state is unknown rather than healthy"
            } else {
                Add-Result 'HostHealth' $hName 'NicLinkState' 'NORMAL' "All assigned uplinks have link across $($switches.Count) switch(es)"
            }

            # Fewer than two live uplinks means one cable, NIC or switch port
            # takes the host's traffic down with it.
            if ($switches.Count -gt 0) {
                if ($thinSwitches.Count -gt 0) {
                    Add-Result 'HostHealth' $hName 'UplinkRedundancy' 'WARN' "No uplink redundancy on: $($thinSwitches -join ', ') - a single cable, NIC or switch port failure takes this traffic down.$unread"
                } elseif ($unreadable.Count -gt 0) {
                    # "Every switch" would be a claim about switches that were
                    # never read.
                    Add-Result 'HostHealth' $hName 'UplinkRedundancy' 'INFO' "Redundancy could not be assessed for: $($unreadable -join ', ')"
                } else {
                    Add-Result 'HostHealth' $hName 'UplinkRedundancy' 'NORMAL' "Every switch has at least two uplinks with link"
                }
            }

            # DNS - a host that can't resolve names fails vCenter operations,
            # NTP by hostname and syslog by hostname in confusing ways.
            $dns = @($net.DnsConfig.Address)
            if ($null -eq $net.DnsConfig) {
                Add-Result 'HostHealth' $hName 'DNS' 'INFO' 'DNS configuration not reported by vCenter for this host'
            } elseif ($dns.Count -eq 0) {
                Add-Result 'HostHealth' $hName 'DNS' 'WARN' 'No DNS servers configured - name resolution failures show up as confusing errors elsewhere'
            } else {
                Add-Result 'HostHealth' $hName 'DNS' 'NORMAL' "Servers: $($dns -join ', ')"
            }
        }

        # ESXi host TLS certificate expiry. Config.Certificate is a byte[] of
        # the PEM-encoded certificate, not a certificate object, so reading
        # .NotAfter off it directly always yields $null - it has to be decoded
        # first. X509Certificate2 accepts PEM bytes only on .NET 5+ (PowerShell
        # 7), so pull the base64 body out and hand it DER, which Windows
        # PowerShell 5.1 accepts too.
        try {
            $certBytes = $hv.Config.Certificate
            if (-not $certBytes) {
                Add-Result 'HostHealth' $hName 'CertificateExpiry' 'INFO' 'Certificate info not available from vCenter'
            } else {
                $pem = [System.Text.Encoding]::ASCII.GetString($certBytes)
                $b64 = ($pem -replace '-----BEGIN CERTIFICATE-----', '' -replace '-----END CERTIFICATE-----', '') -replace '\s', ''
                $der = [Convert]::FromBase64String($b64)
                $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($der)
                $daysLeft = [math]::Round((New-TimeSpan -Start (Get-Date) -End $cert.NotAfter).TotalDays, 1)
                if ($daysLeft -lt 0) {
                    Add-Result 'HostHealth' $hName 'CertificateExpiry' 'FAIL' "Expired $([math]::Abs($daysLeft)) day(s) ago (NotAfter: $($cert.NotAfter))"
                } elseif ($daysLeft -le $CertExpiryCritDays) {
                    Add-Result 'HostHealth' $hName 'CertificateExpiry' 'FAIL' "Expires in $daysLeft day(s) (NotAfter: $($cert.NotAfter))"
                } elseif ($daysLeft -le $CertExpiryWarnDays) {
                    Add-Result 'HostHealth' $hName 'CertificateExpiry' 'WARN' "Expires in $daysLeft day(s) (NotAfter: $($cert.NotAfter))"
                } else {
                    Add-Result 'HostHealth' $hName 'CertificateExpiry' 'NORMAL' "Valid until $($cert.NotAfter) ($daysLeft days)"
                }
            }
        } catch {
            Add-Result 'HostHealth' $hName 'CertificateExpiry' 'INFO' "Could not read host certificate: $($_.Exception.Message)"
        }

        # Local account password expiration policy (root included). vCenter's API
        # doesn't expose a specific account's actual days-until-expiry - that lives
        # only in the host's local shadow file and would require SSH + `chage -l
        # root` to read. Security.PasswordMaxDays is the host-wide maximum age a
        # local password may reach, which is what vCenter does expose. It came
        # with the view in Config.Option, so there is no per-host settings query.
        $pwRaw = Get-HostOptionValue -HostView $hv -Name 'Security.PasswordMaxDays'
        if ($null -eq $pwRaw) {
            Add-Result 'HostHealth' $hName 'PasswordExpirationPolicy' 'INFO' 'Security.PasswordMaxDays not reported by this host'
        } else {
            $pwMaxDays = [int]$pwRaw
            $pwNote    = "root's own remaining days aren't exposed by the vCenter API; that needs SSH and 'chage -l root'"
            if ($pwMaxDays -ge 99999) {
                # 99999 is VMware's shipped default and its "never" sentinel,
                # not an age anyone chose - worth calling out as such.
                Add-Result 'HostHealth' $hName 'PasswordExpirationPolicy' 'WARN' "Security.PasswordMaxDays = $pwMaxDays - VMware's default, meaning local account passwords including root never expire ($pwNote)"
            } elseif ($pwMaxDays -gt $PasswordMaxDaysWarn) {
                Add-Result 'HostHealth' $hName 'PasswordExpirationPolicy' 'WARN' "Security.PasswordMaxDays = $pwMaxDays days, above the $PasswordMaxDaysWarn-day threshold ($pwNote)"
            } else {
                Add-Result 'HostHealth' $hName 'PasswordExpirationPolicy' 'NORMAL' "Security.PasswordMaxDays = $pwMaxDays days ($pwNote)"
            }
        }

        # Lockdown mode - Disabled means direct root/local logins to the host
        # bypass vCenter entirely, reducing auditability. Security hardening
        # guides recommend Normal or Strict for production hosts.
        $lockdown = $hv.Config.LockdownMode
        switch ([string]$lockdown) {
            'lockdownDisabled' { Add-Result 'HostHealth' $hName 'LockdownMode' 'WARN' 'Disabled - direct root/local logins to this host bypass vCenter, reducing auditability; consider Normal or Strict lockdown' }
            'lockdownNormal'   { Add-Result 'HostHealth' $hName 'LockdownMode' 'NORMAL' 'Normal' }
            'lockdownStrict'   { Add-Result 'HostHealth' $hName 'LockdownMode' 'NORMAL' 'Strict' }
            default            { Add-Result 'HostHealth' $hName 'LockdownMode' 'INFO' "Could not read lockdown mode ($lockdown)" }
        }

        # Host services that are set to start with the host but aren't running.
        # Policy is what makes this safe to report: a service with policy
        # 'off' that is stopped was turned off on purpose and is not a
        # finding, so only 'on' (start/stop with host) and 'automatic' count.
        # Without that distinction this would flag every optional daemon on
        # every host.
        # ntpd and TSM-SSH have their own checks, so they are left out here
        # rather than reported twice.
        $svcExcluded = @('ntpd', 'TSM-SSH')
        $svcManaged  = @($hostServices | Where-Object {
            $_ -and $_.Key -notin $svcExcluded -and ([string]$_.Policy -in @('on', 'automatic'))
        })
        $svcDown = @($svcManaged | Where-Object { -not $_.Running })
        if ($hostServices.Count -eq 0) {
            Add-Result 'HostHealth' $hName 'Services' 'INFO' 'Host service list not reported by vCenter for this host'
        } elseif ($svcManaged.Count -eq 0) {
            Add-Result 'HostHealth' $hName 'Services' 'INFO' 'No services are set to start with the host'
        } elseif ($svcDown.Count -gt 0) {
            $svcNames = ($svcDown | ForEach-Object {
                if ($_.Label) { "$($_.Label) ($($_.Key))" } else { "$($_.Key)" }
            }) -join ', '
            Add-Result 'HostHealth' $hName 'Services' 'WARN' "$($svcDown.Count) of $($svcManaged.Count) service(s) set to start with the host are stopped: $svcNames"
        } else {
            Add-Result 'HostHealth' $hName 'Services' 'NORMAL' "All $($svcManaged.Count) service(s) set to start with the host are running"
        }

        # SSH (TSM-SSH) service - often enabled temporarily for troubleshooting
        # and then forgotten; left running long-term it's extra attack surface.
        $sshSvc = $hostServices | Where-Object { $_.Key -eq 'TSM-SSH' }
        if (-not $sshSvc) {
            Add-Result 'HostHealth' $hName 'SSHEnabled' 'INFO' 'Could not read SSH (TSM-SSH) service state'
        } elseif ($sshSvc.Running) {
            Add-Result 'HostHealth' $hName 'SSHEnabled' 'WARN' 'SSH service is running - confirm this is intentional; leaving it enabled long-term increases attack surface'
        } else {
            Add-Result 'HostHealth' $hName 'SSHEnabled' 'NORMAL' 'SSH service not running'
        }
    }
    #endregion

    #region --- 2. VM compliance ---------------------------------------------
    Write-Host "`n=== VM Compliance ===" -ForegroundColor Cyan

    # One Get-View for every VM across every connection, carrying everything
    # the VM checks need - including the devices that used to come from a
    # Get-CDDrive and a Get-FloppyDrive, and the snapshot tree.
    $vmProps = @(
        'Name', 'Runtime.ConnectionState', 'Runtime.ConsolidationNeeded',
        'Runtime.PowerState', 'Runtime.Host',
        'Config.Version', 'Config.GuestFullName', 'Config.Hardware.Device',
        'Guest.ToolsStatus', 'Guest.Disk', 'Snapshot'
    )
    # Each view is kept with the connection it came from, the same way
    # $hostEntries does. A MoRef like 'VirtualMachine-vm-101' is only unique
    # WITHIN one vCenter - two vCenters routinely both have a vm-101 - so any
    # per-VM lookup across a multi-vCenter run has to be qualified by server.
    $vmEntries = New-Object System.Collections.Generic.List[object]
    foreach ($conn in $connections) {
        foreach ($vv in @(Get-View -ViewType VirtualMachine -Property $vmProps -Server $conn)) {
            $vmEntries.Add([pscustomobject]@{ View = $vv; VCenter = $conn })
        }
    }

    # Snapshot SIZE is the one thing the view layout doesn't hand over
    # directly, and it is the part that tells you whether a snapshot is
    # urgent, so it comes from Get-Snapshot - but ONLY for the VMs that
    # actually have one. The views above already say which those are
    # ($vv.Snapshot is $null otherwise), and in a real estate that is a
    # handful of VMs out of thousands. Asking Get-VM / Get-Snapshot about
    # the whole inventory to size a dozen snapshots was the last full-fat
    # retrieval left in the script; when nothing has a snapshot, both calls
    # now disappear entirely.
    $snapsByVm  = @{}   # "<vCenter>|<VM MoRef>" -> list of PowerCLI snapshots
    $maxHwCache = @{}   # compute resource MoRef -> highest supported vmx-NN

    # Grouped by connection so each Get-VM is bound to the vCenter whose
    # MoRefs it is being given. An unqualified Get-VM -Id searches every
    # connected server, so in a two-vCenter run it could match the other
    # vCenter's vm-101 and size the wrong VM's snapshots.
    $snapIdsByConn = @{}
    foreach ($entry in $vmEntries) {
        $vv = $entry.View
        if (-not ($vv.Snapshot -and $vv.Snapshot.RootSnapshotList)) { continue }
        $ck = "$($entry.VCenter)"
        if (-not $snapIdsByConn.ContainsKey($ck)) {
            $snapIdsByConn[$ck] = [pscustomobject]@{
                Conn = $entry.VCenter
                Ids  = (New-Object System.Collections.Generic.List[string])
            }
        }
        $snapIdsByConn[$ck].Ids.Add("$($vv.MoRef)")
    }

    $snapVmTotal = 0
    foreach ($g in $snapIdsByConn.Values) { $snapVmTotal += $g.Ids.Count }
    if ($snapVmTotal -gt 0) {
        Write-Host "  Sizing snapshots on $snapVmTotal VM(s) with snapshots..." -ForegroundColor DarkGray
        foreach ($g in $snapIdsByConn.Values) {
            try {
                # .ToArray() rather than passing the List straight in: binding
                # a generic List to a PowerCLI parameter is the "Argument types
                # do not match" trap that WinPS 5.1 throws on.
                $snapVms = @(Get-VM -Id $g.Ids.ToArray() -Server $g.Conn -ErrorAction Stop)
                foreach ($sn in @(Get-Snapshot -VM $snapVms -ErrorAction Stop)) {
                    $key = "$($g.Conn)|$($sn.VM.ExtensionData.MoRef)"
                    if (-not $snapsByVm.ContainsKey($key)) { $snapsByVm[$key] = [System.Collections.Generic.List[object]]::new() }
                    $snapsByVm[$key].Add($sn)
                }
            } catch {
                # Sizes are a nice-to-have; age is what drives the finding.
                # Losing them must not lose the snapshot rows themselves.
                Write-Warning "Could not read snapshot sizes from $($g.Conn): $($_.Exception.Message). Snapshot age is still reported."
            }
        }
    }

    $vmIdx = 0
    foreach ($vmEntry in $vmEntries) {
        $vv         = $vmEntry.View
        $vmName     = $vv.Name
        $powerState = [string]$vv.Runtime.PowerState
        $vmIdx++
        Write-HealthCheckProgress -Activity 'VM compliance' -Current $vmIdx -Total $vmEntries.Count -Item $vmName

        # Runtime.ConnectionState / ConsolidationNeeded are requested above, so
        # they arrive populated. If vCenter still returns nothing, that is
        # reported as INFO rather than guessed at - a property that could not
        # be read is not a failing VM.
        $connState     = $vv.Runtime.ConnectionState
        $consolidation = $vv.Runtime.ConsolidationNeeded

        # Connection state - orphaned/inaccessible/invalid is vCenter's
        # inventory losing track of the VM (the "question mark" icon in the
        # vSphere Client). Runs regardless of power state and is easy to miss
        # since it doesn't show up in any other check here. Only the known-bad
        # states FAIL: an unreadable state is reported as INFO, never as a
        # failure, so a healthy VM is never flagged just because vCenter didn't
        # hand back the property.
        switch ([string]$connState) {
            'connected'    { Add-Result 'VMCompliance' $vmName 'ConnectionState' 'NORMAL' "Connected to vCenter ($powerState)" }
            'disconnected' { Add-Result 'VMCompliance' $vmName 'ConnectionState' 'WARN' 'Disconnected - the host running this VM is currently unreachable from vCenter' }
            'orphaned'     { Add-Result 'VMCompliance' $vmName 'ConnectionState' 'FAIL' 'Orphaned - vCenter has an inventory entry but the host does not report this VM (shows as a question mark in the vSphere Client)' }
            'inaccessible' { Add-Result 'VMCompliance' $vmName 'ConnectionState' 'FAIL' 'Inaccessible - the VM config file (.vmx) cannot be read, usually a datastore or storage problem' }
            'invalid'      { Add-Result 'VMCompliance' $vmName 'ConnectionState' 'FAIL' 'Invalid - vCenter considers this VM unusable, usually a corrupt or unreadable .vmx' }
            ''             { Add-Result 'VMCompliance' $vmName 'ConnectionState' 'INFO' "Connection state not reported by vCenter for this VM; VM is $powerState" }
            default        { Add-Result 'VMCompliance' $vmName 'ConnectionState' 'INFO' "Unrecognized connection state '$connState'; VM is $powerState" }
        }

        # Disk consolidation needed - leftover snapshot delta disks, often
        # left behind by backup software that didn't clean up after itself,
        # that silently consume growing datastore space until consolidated.
        # $null (property unavailable) is distinct from $false here: reporting
        # it as NORMAL would silently claim a clean result that was never checked.
        if ($null -eq $consolidation) {
            Add-Result 'VMCompliance' $vmName 'DiskConsolidation' 'INFO' 'Consolidation state not reported by vCenter for this VM'
        } elseif ($consolidation) {
            Add-Result 'VMCompliance' $vmName 'DiskConsolidation' 'WARN' 'Disk consolidation needed - leftover snapshot delta disk(s) present; consolidate from the vSphere Client (Snapshots > Consolidate)'
        } else {
            Add-Result 'VMCompliance' $vmName 'DiskConsolidation' 'NORMAL' 'No consolidation needed'
        }

        # VMware Tools status (only meaningful when powered on)
        if ($powerState -eq 'poweredOn') {
            $toolsStatus = [string]$vv.Guest.ToolsStatus
            switch ($toolsStatus) {
                'toolsOk'          { Add-Result 'VMCompliance' $vmName 'VMwareTools' 'NORMAL' 'toolsOk' }
                'toolsOld'         { Add-Result 'VMCompliance' $vmName 'VMwareTools' 'WARN' 'Tools out of date' }
                'toolsNotRunning'  { Add-Result 'VMCompliance' $vmName 'VMwareTools' 'WARN' 'Tools installed but not running - no graceful shutdown, no quiesced backup, and no guest IP or disk data in this report' }
                # WARN, not FAIL. A VM with no Tools is running fine - what is
                # missing is manageability: graceful shutdown, quiesced
                # backups, heartbeat, and the guest disk figures this report
                # would otherwise show. That is a backlog item, not an outage,
                # and grading it FAIL put it in the same bucket as an orphaned
                # VM or a fully offline LUN. On a real estate it is also one of
                # the most common findings there is, so as a FAIL it buried
                # every genuine failure underneath it.
                'toolsNotInstalled'{ Add-Result 'VMCompliance' $vmName 'VMwareTools' 'WARN' 'VMware Tools not installed - the VM runs, but it cannot be shut down gracefully, backed up with a quiesced snapshot, or report its guest IP and disk usage' }
                default            { Add-Result 'VMCompliance' $vmName 'VMwareTools' 'INFO' "$toolsStatus" }
            }

            # Guest disk free space. Reported as a PERCENTAGE of each volume
            # rather than an absolute GB figure: 20GB free is comfortable on a
            # 1TB data disk and nearly full on a 40GB system disk, so a single
            # GB threshold either cried wolf on big disks or stayed silent on
            # small ones.
            $guestDisks = @($vv.Guest.Disk)
            if ($guestDisks.Count -gt 0) {
                $osDrive = $guestDisks | Where-Object { $_.DiskPath -eq 'C:\' -or $_.DiskPath -eq '/' } | Select-Object -First 1
                if ($osDrive -and $osDrive.Capacity -gt 0) {
                    $freePct = [math]::Round(($osDrive.FreeSpace / $osDrive.Capacity) * 100, 1)
                    $freeGB  = [math]::Round($osDrive.FreeSpace / 1GB, 1)
                    $totalGB = [math]::Round($osDrive.Capacity / 1GB, 1)
                    $detail  = "$($osDrive.DiskPath) $freePct% free (${freeGB}GB of ${totalGB}GB)"
                    if ($freePct -lt $OSDriveFreeWarnPercent) {
                        Add-Result 'VMCompliance' $vmName 'OSDriveFree' 'WARN' "$detail (< $OSDriveFreeWarnPercent%)"
                    } else {
                        Add-Result 'VMCompliance' $vmName 'OSDriveFree' 'NORMAL' $detail
                    }
                } else {
                    Add-Result 'VMCompliance' $vmName 'OSDriveFree' 'INFO' 'No C:\ or / drive reported by Tools'
                }

                # All other guest drives (data/secondary volumes) below threshold.
                $osPath = if ($osDrive) { $osDrive.DiskPath } else { $null }
                foreach ($disk in ($guestDisks | Where-Object { $_.DiskPath -ne $osPath })) {
                    if ($disk.Capacity -le 0) { continue }
                    $freePct = [math]::Round(($disk.FreeSpace / $disk.Capacity) * 100, 1)
                    $freeGB  = [math]::Round($disk.FreeSpace / 1GB, 1)
                    $totalGB = [math]::Round($disk.Capacity / 1GB, 1)
                    $detail  = "$($disk.DiskPath) $freePct% free (${freeGB}GB of ${totalGB}GB)"
                    if ($freePct -lt $DataDriveFreeWarnPercent) {
                        Add-Result 'VMCompliance' $vmName 'DataDriveFree' 'WARN' "$detail (< $DataDriveFreeWarnPercent%)"
                    } else {
                        Add-Result 'VMCompliance' $vmName 'DataDriveFree' 'NORMAL' $detail
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
        # as INFO rather than letting it fall through to NORMAL unexamined.
        $hwVersion = $vv.Config.Version
        $hwNum = 0
        if ($hwVersion -match '(?:vmx-)?(\d+)$') { $hwNum = [int]$Matches[1] }
        if ($hwNum -le 0) {
            Add-Result 'VMCompliance' $vmName 'HardwareVersion' 'INFO' "Could not parse hardware version '$hwVersion'"
        } elseif ($hwNum -lt $HardwareVersionWarnNum) {
            # Resolve the VM's host -> compute resource -> EnvironmentBrowser
            # from the prefetched maps, and cache on the COMPUTE RESOURCE so a
            # cluster is asked once, not once per host and not once per VM.
            $maxHw = $null
            $vmHostView = if ($vv.Runtime.Host) { $hostByMoRef["$($vv.Runtime.Host)"] } else { $null }
            if ($vmHostView -and $vmHostView.Parent) {
                $crKey = "$($vmHostView.Parent)"
                $maxHw = Get-MaxHardwareVersion -ComputeResourceMoRef $crKey `
                                                -EnvironmentBrowser $envBrowserByCr[$crKey] `
                                                -Cache $maxHwCache
            }
            $guestOs = $vv.Config.GuestFullName
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
            Add-Result 'VMCompliance' $vmName 'HardwareVersion' 'WARN' "$hwVersion is below the vmx-$HardwareVersionWarnNum baseline. $advice $guestClause before upgrading; it requires a power-off and cannot be rolled back."
        } else {
            Add-Result 'VMCompliance' $vmName 'HardwareVersion' 'NORMAL' "$hwVersion (at or above the vmx-$HardwareVersionWarnNum baseline)"
        }

        # Virtual hardware came with the view, so CD and floppy drives are read
        # straight off Config.Hardware.Device instead of a Get-CDDrive and a
        # Get-FloppyDrive per inventory.
        $devices = @($vv.Config.Hardware.Device)

        # Mounted ISO / connected CD-ROM (blocks vMotion, often left behind).
        # Only a connected drive (or one set to connect at power-on) matters: a
        # stale ISO path on a disconnected drive blocks nothing, and flagging it
        # buries the report in noise anywhere VMs are deployed from ISO.
        $cdDevices = @($devices | Where-Object { $_ -is [VMware.Vim.VirtualCdrom] })
        $mounted   = @($cdDevices | Where-Object {
            $_.Connectable -and ($_.Connectable.Connected -or $_.Connectable.StartConnected)
        })
        if ($mounted.Count -gt 0) {
            $what = ($mounted | ForEach-Object {
                if ($_.Backing -and $_.Backing.FileName) { $_.Backing.FileName } else { 'host/remote device' }
            }) -join ','
            Add-Result 'VMCompliance' $vmName 'MountedMedia' 'WARN' "Connected media: $what"
        }

        # Floppy drives - legacy hardware. A connected floppy blocks vMotion;
        # any floppy at all is usually unnecessary on a modern VM.
        $floppies = @($devices | Where-Object { $_ -is [VMware.Vim.VirtualFloppy] })
        if ($floppies.Count -gt 0) {
            $connected = @($floppies | Where-Object {
                $_.Connectable -and ($_.Connectable.Connected -or $_.Connectable.StartConnected)
            })
            if ($connected.Count -gt 0) {
                $what = ($connected | ForEach-Object {
                    if ($_.Backing -and $_.Backing.FileName) { $_.Backing.FileName } else { 'device' }
                }) -join ','
                Add-Result 'VMCompliance' $vmName 'FloppyDrive' 'WARN' "Connected floppy drive ($what) - disconnect/remove (legacy, blocks vMotion)"
            } else {
                Add-Result 'VMCompliance' $vmName 'FloppyDrive' 'INFO' "Floppy drive present but disconnected - consider removing (legacy device)"
            }
        }

        # Snapshot age, from the view's snapshot tree; size from the bulk
        # Get-Snapshot above, matched by name.
        $snapSizes = @{}
        foreach ($sn in @($snapsByVm["$($vmEntry.VCenter)|$($vv.MoRef)"])) {
            if ($sn) { $snapSizes[[string]$sn.Name] = $sn.SizeGB }
        }
        foreach ($node in (Get-SnapshotNode -Nodes $vv.Snapshot.RootSnapshotList)) {
            $ageDays = [math]::Round((New-TimeSpan -Start $node.CreateTime -End (Get-Date)).TotalDays, 1)
            $sizeTxt = if ($snapSizes.ContainsKey([string]$node.Name)) {
                ", $([math]::Round($snapSizes[[string]$node.Name], 1))GB"
            } else { '' }
            if ($ageDays -ge $SnapshotAgeWarningDays) {
                Add-Result 'VMCompliance' $vmName 'Snapshot' 'WARN' "'$($node.Name)' age ${ageDays}d$sizeTxt"
            } else {
                Add-Result 'VMCompliance' $vmName 'Snapshot' 'INFO' "'$($node.Name)' age ${ageDays}d$sizeTxt"
            }
        }
    }
    #endregion

    #region --- 3. Capacity ---------------------------------------------------
    Write-Host "`n=== Capacity ===" -ForegroundColor Cyan

    # Datastore free space, from the datastore views already prefetched.
    foreach ($dv in $dsEntries) {
        if ($null -eq $dv.Summary -or [double]$dv.Summary.Capacity -le 0) { continue }
        $capGB  = [double]$dv.Summary.Capacity / 1GB
        $freeGB = [double]$dv.Summary.FreeSpace / 1GB
        $freePct = [math]::Round(($freeGB / $capGB) * 100, 1)
        $detail  = "$freePct% free ($([math]::Round($freeGB))GB / $([math]::Round($capGB))GB)"
        if ($freePct -lt $DatastoreFreeCritPercent) {
            Add-Result 'Capacity' $dv.Name 'DatastoreFree' 'FAIL' $detail
        } elseif ($freePct -lt $DatastoreFreeWarnPercent) {
            Add-Result 'Capacity' $dv.Name 'DatastoreFree' 'WARN' $detail
        } else {
            Add-Result 'Capacity' $dv.Name 'DatastoreFree' 'NORMAL' $detail
        }
    }

    # Cluster CPU / RAM utilization, summed from the host views the cluster
    # already points at - no Get-VMHost per cluster.
    foreach ($cv in $clusterEntries) {
        $clHosts = @(@($cv.Host) | ForEach-Object { $hostByMoRef["$_"] } | Where-Object { $_ })
        $totalCpuMhz = 0.0; $usedCpuMhz = 0.0
        $totalMemGB  = 0.0; $usedMemGB  = 0.0
        foreach ($chv in $clHosts) {
            $hw = $chv.Summary.Hardware
            $qs = $chv.Summary.QuickStats
            if ($hw) {
                $totalCpuMhz += ([double]$hw.CpuMhz * [double]$hw.NumCpuCores)
                $totalMemGB  += ([double]$hw.MemorySize / 1GB)
            }
            if ($qs) {
                $usedCpuMhz += [double]$qs.OverallCpuUsage
                # QuickStats reports memory usage in MB.
                $usedMemGB  += ([double]$qs.OverallMemoryUsage / 1024)
            }
        }

        if ($totalCpuMhz -gt 0) {
            $cpuPct = [math]::Round(($usedCpuMhz / $totalCpuMhz) * 100, 1)
            $status = if ($cpuPct -ge $ClusterUsageWarnPercent) { 'WARN' } else { 'NORMAL' }
            Add-Result 'Capacity' $cv.Name 'ClusterCPU' $status "$cpuPct% used"
        }
        if ($totalMemGB -gt 0) {
            $memPct = [math]::Round(($usedMemGB / $totalMemGB) * 100, 1)
            $status = if ($memPct -ge $ClusterUsageWarnPercent) { 'WARN' } else { 'NORMAL' }
            Add-Result 'Capacity' $cv.Name 'ClusterRAM' $status "$memPct% used"
        }
    }
    #endregion

    #region --- 4. Cluster config --------------------------------------------
    Write-Host "`n=== Cluster Config ===" -ForegroundColor Cyan

    foreach ($cv in $clusterEntries) {
        $clName = $cv.Name
        $dasCfg = $cv.Configuration.DasConfig
        $drsCfg = $cv.Configuration.DrsConfig

        # HA
        if ($null -eq $dasCfg) {
            Add-Result 'ClusterConfig' $clName 'HA' 'INFO' 'HA configuration not reported by vCenter for this cluster'
        } elseif ($dasCfg.Enabled) {
            Add-Result 'ClusterConfig' $clName 'HA' 'NORMAL' 'High Availability enabled (restarts VMs on the surviving hosts if a host fails)'
        } else {
            Add-Result 'ClusterConfig' $clName 'HA' 'WARN' 'High Availability disabled - if a host fails, the VMs it was running will stay down until someone restarts them by hand'
        }

        # Admission control (only relevant when HA is on). An unpopulated
        # DasConfig must not be reported as "Disabled" - that is a finding we
        # never established.
        if ($null -eq $dasCfg) {
            Add-Result 'ClusterConfig' $clName 'AdmissionControl' 'INFO' 'Admission control state not reported by vCenter for this cluster'
        } elseif ($dasCfg.Enabled) {
            if ($dasCfg.AdmissionControlEnabled) {
                Add-Result 'ClusterConfig' $clName 'AdmissionControl' 'NORMAL' 'Enabled - HA holds back enough spare capacity to restart the VMs from a failed host, and blocks power-ons that would eat into that reserve'
            } else {
                Add-Result 'ClusterConfig' $clName 'AdmissionControl' 'WARN' 'Disabled - HA reserves no spare capacity, so VMs from a failed host may fail to restart if the remaining hosts are already committed'
            }
        }

        # DRS
        if ($null -eq $drsCfg) {
            Add-Result 'ClusterConfig' $clName 'DRS' 'INFO' 'DRS configuration not reported by vCenter for this cluster'
        } elseif ($drsCfg.Enabled) {
            $drsLevel = [string]$drsCfg.DefaultVmBehavior
            Add-Result 'ClusterConfig' $clName 'DRS' 'NORMAL' "Distributed Resource Scheduler enabled, $drsLevel (balances VM load across hosts using vMotion)"
            if ($drsLevel -ne 'fullyAutomated') {
                Add-Result 'ClusterConfig' $clName 'DRSAutomation' 'WARN' "DRS is set to $drsLevel, not FullyAutomated - it only recommends migrations instead of performing them, so rebalancing waits on someone approving them"
            }
        } else {
            Add-Result 'ClusterConfig' $clName 'DRS' 'WARN' 'Distributed Resource Scheduler disabled - VM load is not balanced across hosts automatically'
        }

        # Host count - straight off the cluster view's own host list.
        $hostCount = @($cv.Host).Count
        if ($dasCfg -and $dasCfg.Enabled -and $hostCount -lt 2) {
            Add-Result 'ClusterConfig' $clName 'HostCount' 'WARN' "Only $hostCount host(s) - HA cannot fail over"
        }

        # EVC masks host CPUs to a common baseline so a running VM can vMotion
        # between different CPU generations without the guest seeing the CPU
        # change mid-flight.
        # Reported as INFO, not WARN, even when it is off: plenty of estates
        # run no EVC by design, and vCenter can't tell us whether this
        # cluster's hosts actually span CPU generations - so "not configured"
        # is context, not a fault. Flagging it put an item on every cluster in
        # the "needs attention" view that nobody was ever going to action.
        # Summary is requested with the view above, so a $null here means
        # vCenter genuinely didn't answer - a different statement from "off",
        # and the detail keeps them apart even though both are INFO.
        if ($null -eq $cv.Summary) {
            Add-Result 'ClusterConfig' $clName 'EVC' 'INFO' 'EVC mode not reported by vCenter for this cluster - could not determine whether it is enabled'
        } elseif ($cv.Summary.CurrentEVCModeKey) {
            Add-Result 'ClusterConfig' $clName 'EVC' 'NORMAL' "Enhanced vMotion Compatibility enabled, baseline '$($cv.Summary.CurrentEVCModeKey)' (masks host CPUs to a common instruction set so running VMs can vMotion between hosts with different CPU generations)"
        } else {
            Add-Result 'ClusterConfig' $clName 'EVC' 'INFO' 'Enhanced vMotion Compatibility (masks host CPUs to a common instruction set so running VMs can vMotion between hosts with different CPU generations) is not configured - fine if every host is the same CPU generation; worth enabling as a hedge before adding a differing host'
        }
    }
    #endregion

    #region --- 5. Updates ----------------------------------------------------
    Write-Host "`n=== Updates ===" -ForegroundColor Cyan

    # "Is an update available" has no single answer in the vSphere API, so this
    # section is explicit about WHERE each verdict came from rather than
    # implying an authority it doesn't have. Two sources, in priority order:
    #
    #   1. vLCM / Update Manager baseline compliance, where a baseline is
    #      attached. This is the real answer: it is what this organisation has
    #      decided "current" means, and it stays right without anyone editing
    #      this script.
    #   2. A build number the admin supplies (-ExpectedEsxiBuild /
    #      -ExpectedVCenterBuild), for estates that don't use baselines.
    #
    # What is deliberately NOT here is a hardcoded table of current VMware
    # builds. One was tried and removed: it is wrong the day Broadcom ships
    # anything, and a stale table reporting "up to date" is worse than
    # reporting nothing.
    foreach ($conn in $connections) {
        $vcName = "$($conn.Name)"
        if ($ExpectedVCenterBuild) {
            $vcBuild = "$($conn.Build)"
            if ([string]::IsNullOrWhiteSpace($vcBuild)) {
                Add-Result 'Updates' $vcName 'VCenterBuild' 'INFO' "vCenter did not report a build number; expected $ExpectedVCenterBuild"
            } elseif ($vcBuild -eq "$ExpectedVCenterBuild") {
                Add-Result 'Updates' $vcName 'VCenterBuild' 'NORMAL' "vCenter $($conn.Version) build $vcBuild matches the expected build"
            } else {
                Add-Result 'Updates' $vcName 'VCenterBuild' 'WARN' "vCenter $($conn.Version) is on build $vcBuild, expected $ExpectedVCenterBuild - an update may be pending"
            }
        } else {
            Add-Result 'Updates' $vcName 'VCenterBuild' 'INFO' "vCenter $($conn.Version) build $($conn.Build) - pass -ExpectedVCenterBuild to have this compared against your standard"
        }
    }

    # One bulk Get-Compliance for every host, not one per host, and only when
    # the Update Manager module is actually loaded - it ships with PowerCLI but
    # is not present in every install, and on estates that don't use vLCM there
    # is nothing for it to read anyway.
    $complianceByHost = @{}
    $vumAvailable = $null -ne (Get-Command -Name 'Get-Compliance' -ErrorAction SilentlyContinue)
    if ($vumAvailable -and $hostEntries.Count -gt 0) {
        try {
            $hostMoRefs = New-Object System.Collections.Generic.List[string]
            foreach ($entry in $hostEntries) { $hostMoRefs.Add("$($entry.View.MoRef)") }
            foreach ($c in @(Get-Compliance -Entity $hostMoRefs.ToArray() -ErrorAction Stop)) {
                $k = "$($c.Entity)"
                if (-not $complianceByHost.ContainsKey($k)) { $complianceByHost[$k] = [System.Collections.Generic.List[object]]::new() }
                $complianceByHost[$k].Add($c)
            }
        } catch {
            # Never fail the run over this: the section still reports build
            # numbers, which is what estates without vLCM had anyway.
            Write-Verbose "Baseline compliance unavailable: $($_.Exception.Message)"
            $complianceByHost = @{}
        }
    }

    foreach ($entry in $hostEntries) {
        $hv    = $entry.View
        $hName = $hv.Name
        if ([string]$hv.Runtime.ConnectionState -ne 'connected') { continue }
        $hBuild = "$($hv.Config.Product.Build)"

        # vLCM first, where it has something to say about this host.
        $rows = @($complianceByHost["$($hv.MoRef)"])
        $rows = @($rows | Where-Object { $_ })
        if ($rows.Count -gt 0) {
            $nonCompliant = @($rows | Where-Object { "$($_.Status)" -eq 'NonCompliant' })
            $incompatible = @($rows | Where-Object { "$($_.Status)" -eq 'Incompatible' })
            $unknown      = @($rows | Where-Object { "$($_.Status)" -eq 'Unknown' })
            if ($nonCompliant.Count -gt 0) {
                $names = Format-LunList -Names @($nonCompliant | ForEach-Object { "$($_.Baseline.Name)" })
                Add-Result 'Updates' $hName 'EsxiPatchLevel' 'WARN' "Build $hBuild is not compliant with $($nonCompliant.Count) attached baseline(s): $names - updates are available through Lifecycle Manager"
            } elseif ($incompatible.Count -gt 0) {
                $names = Format-LunList -Names @($incompatible | ForEach-Object { "$($_.Baseline.Name)" })
                Add-Result 'Updates' $hName 'EsxiPatchLevel' 'WARN' "Build $hBuild is INCOMPATIBLE with $($incompatible.Count) attached baseline(s): $names - the update cannot be applied as-is and needs looking at"
            } elseif ($unknown.Count -eq $rows.Count) {
                Add-Result 'Updates' $hName 'EsxiPatchLevel' 'INFO' "Build $hBuild - baselines are attached but have not been scanned yet, so compliance is unknown (run a scan in Lifecycle Manager)"
            } else {
                Add-Result 'Updates' $hName 'EsxiPatchLevel' 'NORMAL' "Build $hBuild is compliant with all $($rows.Count) attached baseline(s)"
            }
            continue
        }

        # No baseline for this host: fall back to the admin-supplied build.
        if (-not $ExpectedEsxiBuild) {
            $why = if ($vumAvailable) { 'no patch baseline attached' } else { 'Lifecycle Manager not available from this session' }
            Add-Result 'Updates' $hName 'EsxiPatchLevel' 'INFO' "Build $hBuild - $why, and no -ExpectedEsxiBuild given, so this build has not been compared against anything"
            continue
        }
        if ([string]::IsNullOrWhiteSpace($hBuild)) {
            Add-Result 'Updates' $hName 'EsxiPatchLevel' 'INFO' "Host did not report a build number; expected $ExpectedEsxiBuild"
        } elseif ($hBuild -eq "$ExpectedEsxiBuild") {
            Add-Result 'Updates' $hName 'EsxiPatchLevel' 'NORMAL' "Build $hBuild matches the expected build"
        } else {
            # Numeric where both sides parse, so 24859861 vs 9214924 doesn't
            # get compared as text. A host AHEAD of the standard is INFO, not
            # WARN: it is worth knowing, but it is not a missing update.
            $hNum = 0; $eNum = 0
            $parsed = [int64]::TryParse($hBuild, [ref]$hNum) -and [int64]::TryParse("$ExpectedEsxiBuild", [ref]$eNum)
            if ($parsed -and $hNum -gt $eNum) {
                Add-Result 'Updates' $hName 'EsxiPatchLevel' 'INFO' "Build $hBuild is NEWER than the expected build $ExpectedEsxiBuild - ahead of the standard, not behind it"
            } else {
                Add-Result 'Updates' $hName 'EsxiPatchLevel' 'WARN' "Build $hBuild is behind the expected build $ExpectedEsxiBuild - an update is available"
            }
        }
    }

    # VMware Tools backlog, per host.
    #
    # Tools runs in the GUEST, not on the host - ESXi has no "Tools version"
    # of its own to be behind. What a host does have is the Tools package it
    # offers its VMs, and when that package is stale every VM on the host
    # reports toolsOld at once. So the useful host-level question is not "does
    # this host need Tools updated" but "is this host where the backlog
    # lives", which the per-VM rows cannot answer on a page of 155 of them.
    #
    # Runtime.Host came with the VM views, so this is a regroup of data
    # already in memory - no extra calls.
    $toolsByHost = @{}
    foreach ($vmEntry in $vmEntries) {
        $vv = $vmEntry.View
        if ([string]$vv.Runtime.PowerState -ne 'poweredOn') { continue }
        if (-not $vv.Runtime.Host) { continue }
        $hk = "$($vmEntry.VCenter)|$($vv.Runtime.Host)"
        if (-not $toolsByHost.ContainsKey($hk)) {
            $toolsByHost[$hk] = [pscustomobject]@{ Total = 0; Old = 0; NotRunning = 0; NotInstalled = 0 }
        }
        $t = $toolsByHost[$hk]
        $t.Total++
        switch ([string]$vv.Guest.ToolsStatus) {
            'toolsOld'          { $t.Old++ }
            'toolsNotRunning'   { $t.NotRunning++ }
            'toolsNotInstalled' { $t.NotInstalled++ }
        }
    }

    foreach ($entry in $hostEntries) {
        $hv    = $entry.View
        $hName = $hv.Name
        if ([string]$hv.Runtime.ConnectionState -ne 'connected') { continue }
        $t = $toolsByHost["$($entry.VCenter)|$($hv.MoRef)"]
        if ($null -eq $t -or $t.Total -eq 0) {
            Add-Result 'Updates' $hName 'VMToolsBacklog' 'INFO' 'No powered-on VMs on this host'
            continue
        }
        $behind = $t.Old + $t.NotRunning + $t.NotInstalled
        if ($behind -eq 0) {
            Add-Result 'Updates' $hName 'VMToolsBacklog' 'NORMAL' "All $($t.Total) powered-on VM(s) report current, running VMware Tools"
            continue
        }
        $parts = New-Object System.Collections.Generic.List[object]
        if ($t.Old -gt 0)          { $parts.Add("$($t.Old) out of date") }
        if ($t.NotRunning -gt 0)   { $parts.Add("$($t.NotRunning) installed but stopped") }
        if ($t.NotInstalled -gt 0) { $parts.Add("$($t.NotInstalled) not installed") }
        $summary = "$behind of $($t.Total) powered-on VM(s): $($parts -join ', ')"

        # WARN only where updating the HOST is the fix. Out-of-date Tools on
        # most of a host's VMs points at the Tools package the host itself
        # ships; scattered ones are per-VM work that the VMCompliance rows
        # already list, and repeating them here as findings would double-count
        # the same backlog into the attention view twice.
        if ($t.Old -gt 0 -and $t.Old -ge [math]::Ceiling($t.Total / 2.0)) {
            Add-Result 'Updates' $hName 'VMToolsBacklog' 'WARN' "$summary - most of this host's VMs report out-of-date Tools, which usually means the host's own bundled Tools package is behind; patching the host updates them all"
        } else {
            Add-Result 'Updates' $hName 'VMToolsBacklog' 'INFO' "$summary - listed per VM under VM Compliance > VMware Tools"
        }
    }

    # The Tools package each host ships to its VMs ('tools-light'), opt-in.
    #
    # This is the one check in the script that costs a round trip PER HOST.
    # The VIB list is not in the vSphere API at all - esxcli is the only place
    # it is exposed - so there is no bulk form of this and no way to fold it
    # into the property collector calls everything else uses. Hence the
    # switch, and hence the warning about what it costs.
    if ($IncludeToolsVibVersion) {
        $connectedHosts = @($hostEntries | Where-Object { [string]$_.View.Runtime.ConnectionState -eq 'connected' })
        if ($connectedHosts.Count -gt 0) {
            Write-Host "  Reading the Tools package from $($connectedHosts.Count) host(s) over esxcli - this is per-host and slow..." -ForegroundColor DarkGray
        }

        # One bulk Get-VMHost per connection: Get-EsxCli needs PowerCLI host
        # objects, and fetching them one at a time would double the per-host
        # cost this check already carries.
        $pcliHostByMoRef = @{}
        foreach ($conn in $connections) {
            $ids = @($connectedHosts | Where-Object { "$($_.VCenter)" -eq "$conn" } | ForEach-Object { "$($_.View.MoRef)" })
            if ($ids.Count -eq 0) { continue }
            try {
                foreach ($ph in @(Get-VMHost -Id $ids -Server $conn -ErrorAction Stop)) {
                    $pcliHostByMoRef["$conn|$($ph.ExtensionData.MoRef)"] = $ph
                }
            } catch {
                Write-Warning "Could not retrieve host objects from $conn for the Tools package check: $($_.Exception.Message)"
            }
        }

        $vibByHost = @{}    # host name -> version string
        $vibIdx    = 0
        foreach ($entry in $connectedHosts) {
            $hv    = $entry.View
            $hName = $hv.Name
            $vibIdx++
            Write-HealthCheckProgress -Activity 'Host Tools package' -Current $vibIdx -Total $connectedHosts.Count -Item $hName
            $ph = $pcliHostByMoRef["$($entry.VCenter)|$($hv.MoRef)"]
            if ($null -eq $ph) {
                Add-Result 'Updates' $hName 'ToolsVibVersion' 'INFO' 'Could not retrieve a host object to query esxcli with'
                continue
            }
            try {
                $esxcli = Get-EsxCli -VMHost $ph -V2 -ErrorAction Stop
                $vib = @($esxcli.software.vib.list.Invoke() | Where-Object { $_.Name -eq 'tools-light' })
                if ($vib.Count -eq 0) {
                    # Not a finding: some images genuinely carry no
                    # tools-light VIB, and "absent" is not "old".
                    Add-Result 'Updates' $hName 'ToolsVibVersion' 'INFO' "No 'tools-light' VIB present on this host"
                } else {
                    $vibByHost[$hName] = "$($vib[0].Version)"
                }
            } catch {
                # esxcli needs the host reachable and the account privileged.
                # Failing to ask is not evidence the host is behind.
                Add-Result 'Updates' $hName 'ToolsVibVersion' 'INFO' "Could not read the Tools package over esxcli: $($_.Exception.Message)"
            }
        }

        if ($vibByHost.Count -gt 0) {
            # The newest version seen ANYWHERE in this run is the yardstick.
            # Nothing is hardcoded, so there is no table here to go stale -
            # the same reason this script has no list of current ESXi builds.
            $newest = $null
            foreach ($v in $vibByHost.Values) {
                if ($null -eq $newest -or (Compare-VibVersion -Left $v -Right $newest) -gt 0) { $newest = $v }
            }
            foreach ($hName in $vibByHost.Keys) {
                $v = $vibByHost[$hName]
                if ((Compare-VibVersion -Left $v -Right $newest) -lt 0) {
                    Add-Result 'Updates' $hName 'ToolsVibVersion' 'WARN' "Tools package $v is older than $newest, which $(@($vibByHost.Values | Where-Object { $_ -eq $newest }).Count) other host(s) in this run carry - VMs installing Tools from this host get the older build; patch the host to bring it level"
                } else {
                    Add-Result 'Updates' $hName 'ToolsVibVersion' 'NORMAL' "Tools package $v - the newest seen across the $($vibByHost.Count) host(s) read in this run"
                }
            }
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
    # Say plainly that rows were withheld from the console, so a quiet run
    # never reads as a run that found nothing.
    if ($script:QuietRows -gt 0) {
        Write-Host "$($script:QuietRows) NORMAL/INFO row(s) not shown above - all rows are in the reports below (-ShowAllConsoleOutput to see them here)." -ForegroundColor DarkGray
    }

    # $ReportPath was created and resolved during setup, before the run started.
    $stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'
    $htmlFile  = Join-Path $ReportPath "VMwareHealthCheck-$stamp.html"

    # Dashboard-style layout: blue header and sidebar, status pill badges,
    # and two summary rings instead of a plain text line.
    $style = @"
<style>
 :root {
  /* Every blue in the report is one of the two stops of the header
     gradient, so nothing reads as a second, unrelated blue.
     --brand (the top stop) is reserved for the header itself: at 4.14:1 on
     the page background it is too light for body-size text. --brand-2 (the
     bottom stop) carries everything else - sidebar, table headers, links,
     borders - and clears AA on light and dark alike. */
  --brand: #0076ce; --brand-2: #0062ad; --brand-3: #00559a;
  --accent: #0062ad;
  --bg: #eef1f5; --surface: #ffffff; --border: #dbe1e8;
  --text: #1c2733; --muted: #64748b;
  --ok: #1e7c34; --ok-bg: #e6f4ea;
  /* #946600 rather than #96650b: measured against --crit, the old pair sat
     at deltaE 14.9 for normal vision - under the 15 floor, i.e. hard to
     tell apart even with full colour vision, which matters now that the
     two sit next to each other on a ring. This clears it at 15.4 while
     holding badge text contrast at 4.63 (AA), same as before. */
  --warn: #946600; --warn-bg: #fff4e0;
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
 /* The tiles AND the filter buttons freeze together as one toolbar. Freezing
    only the tiles left the FAIL/WARN/INFO/NORMAL buttons - and their counts -
    scrolling away under it. Negative margin + matching padding bleeds the
    background across .content's 24px gutters, so rows scrolling underneath
    don't show through at the edges. */
 .toolbar { position: sticky; top: 0; z-index: 20; background: var(--bg);
            margin: 0 -24px 18px; padding: 12px 24px 12px;
            box-shadow: 0 1px 0 var(--border), 0 4px 10px -6px rgba(16,24,40,.28); }
 /* Two rings: objects rolled up to a health state, and every result by
    severity - the same pair an inventory console shows. Part-to-whole at a
    glance; the legend beside each carries the exact numbers. */
 .summary { display: flex; flex-wrap: wrap; gap: 28px; margin: 0 0 14px; }
 .donut-card { display: flex; align-items: center; gap: 18px; background: var(--surface); border: 1px solid var(--border); border-radius: 8px; padding: 12px 20px 12px 14px; flex: 1 1 320px; min-width: 300px; }
 .donut-wrap { position: relative; flex: none; width: 116px; height: 116px; }
 .donut { display: block; transform: rotate(-90deg); }
 .donut-track { stroke: #e6ebf1; }
 .donut-center { position: absolute; inset: 0; display: flex; flex-direction: column; align-items: center; justify-content: center; pointer-events: none; }
 .donut-num { font-size: 26px; font-weight: 700; line-height: 1; color: var(--text); }
 .donut-cap { font-size: 11px; text-transform: uppercase; letter-spacing: .05em; color: var(--muted); margin-top: 3px; }
 .donut-legend { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
 /* Never colour alone: swatch + count + word on every row. */
 .legend-row { display: flex; align-items: center; gap: 8px; background: none; border: 0; border-radius: 5px; padding: 3px 8px 3px 4px; cursor: pointer; font: inherit; text-align: left; color: var(--text); }
 .legend-row:hover { background: var(--bg); }
 .legend-row.active { background: var(--bg); box-shadow: inset 0 0 0 1px var(--accent); }
 .legend-row.zero { opacity: .45; }
 .legend-dot { width: 10px; height: 10px; border-radius: 2px; flex: none; }
 .legend-count { font-weight: 700; font-size: 14px; min-width: 2.5em; }
 .legend-label { font-size: 13px; color: var(--muted); }
 .filters { display: flex; flex-wrap: wrap; gap: 8px; margin: 0 0 20px; }
 .filters button { font: inherit; font-size: 13px; padding: 7px 14px; border: 1px solid var(--border); border-radius: 999px; background: var(--surface); color: var(--text); cursor: pointer; }
 .filters button:hover { border-color: var(--accent); color: var(--accent); }
 .filters button.active { background: var(--accent); color: #fff; border-color: var(--accent); }
 h2 { color: var(--brand-2); margin: 28px 0 4px; padding-left: 10px; border-left: 4px solid var(--accent); font-size: 16px; scroll-margin-top: 246px; }
 table { border-collapse: collapse; width: 100%; margin-top: 6px; background: var(--surface); border-radius: 6px; overflow: hidden; box-shadow: 0 1px 2px rgba(16,24,40,.05); }
 th, td { border-bottom: 1px solid var(--border); padding: 8px 12px; text-align: left; font-size: 13px; }
 th { background: var(--brand-2); color: #fff; font-weight: 600; }
 tr:hover td { background: #f5f8fb; }
 .badge { display: inline-block; padding: 2px 9px; border-radius: 999px; font-size: 11px; font-weight: 700; letter-spacing: .03em; }
 .badge-NORMAL { background: var(--ok-bg); color: var(--ok); }
 .badge-WARN { background: var(--warn-bg); color: var(--warn); }
 .badge-FAIL { background: var(--crit-bg); color: var(--crit); }
 .badge-INFO { background: var(--info-bg); color: var(--info); }
 tr.hidden, h2.hidden, table.hidden, .sidebar li.hidden, .sidebar .toc-cat.hidden { display: none; }
 #emptyNote { color: var(--muted); font-style: italic; margin: 12px 0; display: none; }
 .b { font-size: 11px; font-weight: bold; padding: 0 5px; border-radius: 8px; margin-left: 4px; }
 .bFAIL { background: var(--crit-bg); color: var(--crit); }
 .bWARN { background: var(--warn-bg); color: var(--warn); }
 .seccount { color: var(--muted); font-weight: normal; font-size: 13px; }
 .backtop { font-size: 12px; margin-left: 10px; font-weight: normal; color: var(--accent); text-decoration: none; }
 @media (max-width: 820px) {
  .layout { flex-direction: column; }
  .sidebar { width: 100%; flex-basis: auto; position: static; max-height: none; }
  .toolbar { position: static; margin: 0 0 18px; padding: 0; box-shadow: none; }
  h2 { scroll-margin-top: 8px; }
 }
</style>
"@

    # Per-status counts, plus the per-object rollup for the Objects ring, in
    # ONE pass over the results. This used to be four separate
    # Where-Object pipelines (four full passes, each invoking a scriptblock
    # per row) plus a fifth pass for the rollup.
    $cFail = 0; $cWarn = 0; $cInfo = 0; $cNormal = 0
    # Object -> worst severity seen (3 FAIL / 2 WARN / 1 otherwise)
    $objState = @{}
    foreach ($r in $script:Results) {
        $rank = 1
        switch ($r.Status) {
            'FAIL'   { $cFail++;   $rank = 3 }
            'WARN'   { $cWarn++;   $rank = 2 }
            'INFO'   { $cInfo++ }
            'NORMAL' { $cNormal++ }
        }
        $cur = $objState[$r.Object]
        if ($null -eq $cur -or $rank -gt $cur) { $objState[$r.Object] = $rank }
    }
    $cAttn = $cFail + $cWarn
    # $script:Results is a List[object]; read .Count directly. Wrapping it as
    # @($script:Results).Count throws "Argument types do not match" in WinPS 5.1.
    $cAll  = $script:Results.Count

    # One ring per summary, drawn as plain SVG so the report stays a single
    # self-contained file with no CDN - these get opened on jump boxes with no
    # internet. Part-to-whole at a glance only: four segments, with the exact
    # numbers in the legend beside it rather than on the ring.
    function Format-DonutSvg {
        param(
            [object[]] $Segments,   # Label / Count / Color, in fixed order
            [int]      $Size = 116
        )
        $live = @($Segments | Where-Object { $_.Count -gt 0 })
        $sum  = 0
        foreach ($sg in $live) { $sum += $sg.Count }

        $svg = New-Object System.Text.StringBuilder
        [void]$svg.Append("<svg class='donut' viewBox='0 0 42 42' width='$Size' height='$Size' aria-hidden='true'>")
        [void]$svg.Append("<circle class='donut-track' cx='21' cy='21' r='15.9155' fill='none' stroke-width='4.2'/>")

        if ($sum -gt 0) {
            # A 2px surface gap between adjacent fills, so segments are
            # separated by geometry and not by hue alone - which is what makes
            # the red/amber pair legible for a deuteranomalous reader. Skipped
            # when one status is everything, where a gap would just be a notch.
            $gap      = if ($live.Count -gt 1) { 1.1 } else { 0 }
            $cumulate = 0.0
            foreach ($sg in $live) {
                $len  = ($sg.Count / [double]$sum) * 100.0
                $draw = [math]::Max($len - $gap, 0.5)
                $off  = 25.0 - $cumulate
                while ($off -lt 0) { $off += 100 }
                [void]$svg.Append(("<circle cx='21' cy='21' r='15.9155' fill='none' stroke='{0}' stroke-width='4.2' stroke-linecap='butt' stroke-dasharray='{1} {2}' stroke-dashoffset='{3}'/>" -f `
                    $sg.Color, [math]::Round($draw,2), [math]::Round(100 - $draw,2), [math]::Round($off,2)))
                $cumulate += $len
            }
        }
        [void]$svg.Append('</svg>')
        $svg.ToString()
    }

    # Each object rolls up to a single health bucket: Critical if anything
    # about it FAILs, Warning if anything WARNs, Normal otherwise. Three
    # buckets, not four - an "Unknown" slice would only ever catch an object
    # whose every row was informational, which is rare enough that it reads as
    # an empty mystery rather than as information. $objState was filled by the
    # single counting pass above.
    $oCrit = 0; $oWarn = 0; $oNorm = 0
    foreach ($v in $objState.Values) {
        switch ($v) { 3 { $oCrit++ } 2 { $oWarn++ } default { $oNorm++ } }
    }
    $oTotal = $objState.Count

    $objSegments = @(
        [pscustomobject]@{ Label = 'Critical'; Count = $oCrit; Color = 'var(--crit)'; Filter = 'FAIL' }
        [pscustomobject]@{ Label = 'Warning';  Count = $oWarn; Color = 'var(--warn)'; Filter = 'WARN' }
        [pscustomobject]@{ Label = 'Normal';   Count = $oNorm; Color = 'var(--ok)';   Filter = 'NORMAL' }
    )
    $resSegments = @(
        [pscustomobject]@{ Label = 'Fail'; Count = $cFail; Color = 'var(--crit)'; Filter = 'FAIL' }
        [pscustomobject]@{ Label = 'Warn'; Count = $cWarn; Color = 'var(--warn)'; Filter = 'WARN' }
        [pscustomobject]@{ Label = 'Info'; Count = $cInfo; Color = 'var(--info)'; Filter = 'INFO' }
        [pscustomobject]@{ Label = 'Normal'; Count = $cNormal; Color = 'var(--ok)';   Filter = 'NORMAL' }
    )

    function Format-DonutLegend {
        param([object[]] $Segments)
        $rows = foreach ($sg in $Segments) {
            # Never colour alone: every row carries a swatch, a count AND a
            # word, so the ring is decoration on top of a readable list.
            # A bucket with nothing in it stays listed - the legend shouldn't
            # reflow between runs - but is muted so it doesn't read as a finding.
            $zero = if ($sg.Count -eq 0) { ' zero' } else { '' }
            "<button class='legend-row$zero' data-filter='$($sg.Filter)'><span class='legend-dot' style='background:$($sg.Color)'></span><span class='legend-count'>$($sg.Count)</span><span class='legend-label'>$($sg.Label)</span></button>"
        }
        $rows -join ''
    }

    $summaryHtml = @"
<div class="summary">
  <div class="donut-card">
    <div class="donut-wrap">$(Format-DonutSvg -Segments $objSegments)<div class="donut-center"><span class="donut-num">$oTotal</span><span class="donut-cap">Objects</span></div></div>
    <div class="donut-legend">$(Format-DonutLegend -Segments $objSegments)</div>
  </div>
  <div class="donut-card">
    <div class="donut-wrap">$(Format-DonutSvg -Segments $resSegments)<div class="donut-center"><span class="donut-num">$cAll</span><span class="donut-cap">Results</span></div></div>
    <div class="donut-legend">$(Format-DonutLegend -Segments $resSegments)</div>
  </div>
</div>
"@

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
                Fail  = 0
                Warn  = 0
            })
        }
        $sec = $sections[$secIndex[$key]]
        $sec.Rows.Add($r)
        # Tallied here rather than re-derived with a Where-Object per section
        # per status when the contents list is built.
        if ($r.Status -eq 'FAIL') { $sec.Fail++ } elseif ($r.Status -eq 'WARN') { $sec.Warn++ }
    }

    # Contents/appendix, grouped by category
    $tocHtml = foreach ($catGrp in ($sections | Group-Object Cat)) {
        $items = foreach ($sec in $catGrp.Group) {
            $f = $sec.Fail
            $w = $sec.Warn
            $badges = ''
            if ($f -gt 0) { $badges += "<span class='b bFAIL'>$f FAIL</span>" }
            if ($w -gt 0) { $badges += "<span class='b bWARN'>$w WARN</span>" }
            "<li><a data-jump='$($sec.Id)' href='#$($sec.Id)'><span class='toc-name'>$(Format-CheckLabel $sec.Check)</span><span class='toc-meta'>$badges</span></a></li>"
        }
        "<div class='toc-cat'><span class='toc-cat-name'>$($catGrp.Name)</span><ul>$($items -join '')</ul></div>"
    }
    $tocHtml = $tocHtml -join "`n"

    # One anchored section + table per Check (Object / Status / Detail columns;
    # Category and Check live in the heading)
    # Built into one StringBuilder rather than accumulating per-row strings
    # through a ForEach-Object pipeline: this is the one loop that runs once
    # per result row, so it is where the report generator actually spends its
    # time on a big estate.
    $sb = New-Object System.Text.StringBuilder
    foreach ($sec in $sections) {
        [void]$sb.Append('<h2 id="').Append($sec.Id).Append('" data-section="').Append($sec.Id).Append('">')
        [void]$sb.Append($sec.Cat).Append(' &rsaquo; ').Append($sec.Check)
        [void]$sb.Append(' <span class="seccount">(').Append($sec.Rows.Count).Append(')</span>')
        [void]$sb.AppendLine(' <a class="backtop" href="#top">&uarr; top</a></h2>')
        [void]$sb.Append('<table data-section-table="').Append($sec.Id).Append('"><tr><th>')
        [void]$sb.Append((Format-ObjectColumnLabel $sec.Cat)).AppendLine('</th><th>Status</th><th>Detail</th></tr>')
        foreach ($row in $sec.Rows) {
            $st = $row.Status
            [void]$sb.Append("<tr data-status='").Append($st).Append("'><td>")
            [void]$sb.Append([System.Net.WebUtility]::HtmlEncode([string]$row.Object))
            [void]$sb.Append("</td><td><span class='badge badge-").Append($st).Append("'>").Append($st).Append('</span></td><td>')
            [void]$sb.Append([System.Net.WebUtility]::HtmlEncode([string]$row.Detail))
            [void]$sb.AppendLine('</td></tr>')
        }
        [void]$sb.AppendLine('</table>')
    }
    $bodyHtml = $sb.ToString()

    $html = @"
<!DOCTYPE html><html><head><meta charset='utf-8'>$style
<title>VMware Health Check $stamp</title></head><body>
<header class="topbar">
 <div class="topbar-brand"><span class="brand-badge">HC</span><span class="brand-title">VMware Health &amp; Compliance Report</span></div>
 <div class="topbar-meta">v$($script:ScriptVersion) &nbsp;&bull;&nbsp; Generated $(Get-Date) &nbsp;&bull;&nbsp; vCenter(s): $([System.Net.WebUtility]::HtmlEncode($VCenter -join ', '))</div>
</header>
<div class="layout">
 <nav class="sidebar">
  <h3>Contents</h3>
  $tocHtml
 </nav>
 <main class="content">
  <a id="top"></a>
  <div class="toolbar">
  $summaryHtml
  <div class="filters">
   <button data-filter="attention" class="active">Needs attention &mdash; FAIL + WARN ($cAttn)</button>
   <button data-filter="FAIL">FAIL ($cFail)</button>
   <button data-filter="WARN">WARN ($cWarn)</button>
   <button data-filter="INFO">INFO ($cInfo)</button>
   <button data-filter="NORMAL">NORMAL ($cNormal)</button>
   <button data-filter="all">All ($cAll)</button>
  </div>
  </div>
  <p id="emptyNote">Nothing matches this filter.</p>
  $bodyHtml
 </main>
</div>
<script>
(function(){
 var buttons = document.querySelectorAll('.filters button');
 var tiles = document.querySelectorAll('.legend-row');
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
   // The sidebar entry follows its section. Under the default
   // "Needs attention" filter that leaves the contents listing showing only
   // what needs attention - INFO/NORMAL-only sections such as Uptime stay out
   // of the way until you click INFO or NORMAL to bring them back.
   var link = document.querySelector('.sidebar [data-jump="' + id + '"]');
   if (link && link.parentElement) { link.parentElement.classList.toggle('hidden', vis === 0); }
  });
  // A category heading with nothing left under it goes too.
  document.querySelectorAll('.sidebar .toc-cat').forEach(function(cat){
   cat.classList.toggle('hidden', cat.querySelectorAll('li:not(.hidden)').length === 0);
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
   var id  = a.getAttribute('data-jump');
   var el  = document.getElementById(id);
   var tbl = document.querySelector('[data-section-table="' + id + '"]');
   // Reveal ONLY the section being jumped to if the current filter hides it.
   // This used to call apply('all'), which dropped the whole report out of
   // "Needs attention" and dumped every row into the main area.
   if (tbl && tbl.querySelectorAll('tr[data-status]:not(.hidden)').length === 0) {
    tbl.querySelectorAll('tr[data-status]').forEach(function(r){ r.classList.remove('hidden'); });
    tbl.classList.remove('hidden');
    if (el) el.classList.remove('hidden');
    note.style.display = 'none';
   }
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
