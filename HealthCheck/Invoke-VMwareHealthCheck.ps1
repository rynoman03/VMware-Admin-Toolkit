<#
.SYNOPSIS
    Read-only health check & compliance report for a vCenter environment.

.DESCRIPTION
    Connects to one or more vCenter Servers and evaluates four areas:
        1. Host health     - connection state, NTP, syslog, uptime, datastore connectivity
        2. VM compliance   - VMware Tools, VM hardware version, mounted ISOs, floppy drives, snapshot age
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
    Snapshots older than this (days) are flagged. Default 3.

.PARAMETER DatastoreFreeWarnPercent
    Datastores below this free % are WARN. Default 20.

.PARAMETER DatastoreFreeCritPercent
    Datastores below this free % are FAIL. Default 10.

.PARAMETER ClusterUsageWarnPercent
    Cluster CPU/RAM usage above this % is WARN. Default 80.

.PARAMETER OSDriveFreeWarnGB
    Guest OS system drive (C:\ on Windows, / on Linux) with less than this many GB
    free is flagged. Requires VMware Tools running in the guest. Default 20.

.PARAMETER DataDriveFreeWarnGB
    Any other guest drive (non-OS volume) with less than this many GB free is
    flagged. Requires VMware Tools running in the guest. Default 10.

.EXAMPLE
    .\Invoke-VMwareHealthCheck.ps1 -VCenter vcenter01.corp.local

.EXAMPLE
    $cred = Get-Credential
    .\Invoke-VMwareHealthCheck.ps1 -VCenter vc1,vc2 -Credential $cred -ReportPath C:\Reports

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
    [int] $DataDriveFreeWarnGB      = 10
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

# Don't prompt about the CEIP / invalid certs interactively during an unattended run
Set-PowerCLIConfiguration -Scope Session -InvalidCertificateAction Ignore -ParticipateInCeip $false -Confirm:$false | Out-Null

#endregion

#region --- Connect -----------------------------------------------------------

Write-Host "`nConnecting to vCenter(s): $($VCenter -join ', ')" -ForegroundColor Cyan
$connections = @()
foreach ($vc in $VCenter) {
    try {
        $params = @{ Server = $vc; ErrorAction = 'Stop' }
        if ($Credential) { $params.Credential = $Credential }
        $connections += Connect-VIServer @params
        Write-Host "  Connected to $vc" -ForegroundColor Green
    } catch {
        Write-Host "  FAILED to connect to $vc : $($_.Exception.Message)" -ForegroundColor Red
    }
}
if (-not $connections) { throw "No vCenter connections established. Aborting." }

#endregion

try {
    #region --- 1. Host health -----------------------------------------------
    Write-Host "`n=== Host Health ===" -ForegroundColor Cyan
    $vmHosts = Get-VMHost

    foreach ($h in $vmHosts) {
        # Connection / power state
        if ($h.ConnectionState -ne 'Connected') {
            Add-Result 'HostHealth' $h.Name 'ConnectionState' 'FAIL' "State is $($h.ConnectionState)"
        } else {
            Add-Result 'HostHealth' $h.Name 'ConnectionState' 'PASS' 'Connected'
        }

        # NTP - configured and the daemon running
        $ntpServers = ($h | Get-VMHostNtpServer)
        $ntpSvc     = $h | Get-VMHostService | Where-Object { $_.Key -eq 'ntpd' }
        if (-not $ntpServers) {
            Add-Result 'HostHealth' $h.Name 'NTP' 'FAIL' 'No NTP servers configured'
        } elseif (-not $ntpSvc.Running) {
            Add-Result 'HostHealth' $h.Name 'NTP' 'WARN' "Configured ($($ntpServers -join ',')) but ntpd not running"
        } else {
            Add-Result 'HostHealth' $h.Name 'NTP' 'PASS' "Running; servers: $($ntpServers -join ',')"
        }

        # Syslog - remote target configured
        $syslog = ($h | Get-VMHostSysLogServer)
        if (-not $syslog) {
            Add-Result 'HostHealth' $h.Name 'Syslog' 'WARN' 'No remote syslog target configured'
        } else {
            Add-Result 'HostHealth' $h.Name 'Syslog' 'PASS' "Target: $(($syslog | ForEach-Object { "$($_.Host):$($_.Port)" }) -join ',')"
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
    }
    #endregion

    #region --- 2. VM compliance ---------------------------------------------
    Write-Host "`n=== VM Compliance ===" -ForegroundColor Cyan
    $vms = Get-VM

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
        Write-Host "  Pre-fetching snapshots and media for $($vms.Count) VM(s)..." -ForegroundColor DarkGray
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
        if ($hwNum -gt 0 -and $hwNum -lt 13) {
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
    foreach ($ds in (Get-Datastore)) {
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
    foreach ($cl in (Get-Cluster)) {
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
    foreach ($cl in (Get-Cluster)) {
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
        $hostCount = ($cl | Get-VMHost).Count
        if ($cl.HAEnabled -and $hostCount -lt 2) {
            Add-Result 'ClusterConfig' $cl.Name 'HostCount' 'WARN' "Only $hostCount host(s) - HA cannot fail over"
        }
        $evc = $cl.ExtensionData.Summary.CurrentEVCModeKey
        Add-Result 'ClusterConfig' $cl.Name 'EVC' 'INFO' ($(if ($evc) { $evc } else { 'Not configured' }))
    }
    #endregion
}
finally {
    #region --- Report + disconnect ------------------------------------------
    $summary = $script:Results | Group-Object Status | ForEach-Object { "$($_.Name)=$($_.Count)" }
    Write-Host "`n=== Summary: $($summary -join '  ') ===" -ForegroundColor Cyan

    if (-not (Test-Path $ReportPath)) { New-Item -ItemType Directory -Path $ReportPath -Force | Out-Null }
    $stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'
    $htmlFile  = Join-Path $ReportPath "VMwareHealthCheck-$stamp.html"

    $style = @"
<style>
 body { font-family: Segoe UI, Arial, sans-serif; margin: 20px; background: #ffffff; color: #1a1a1a; }
 h1 { color: #333; }
 h2 { color: #2d3e50; margin-top: 30px; border-bottom: 2px solid #e1e4e8; padding-bottom: 4px; }
 table { border-collapse: collapse; width: 100%; margin-top: 6px; }
 th, td { border: 1px solid #ddd; padding: 6px 10px; text-align: left; font-size: 13px; }
 th { background: #2d3e50; color: #fff; }
 tr:nth-child(even) { background: #f6f8fa; }
 .PASS { color: #1a7f37; font-weight: bold; }
 .WARN { color: #b88600; font-weight: bold; }
 .FAIL { color: #cf222e; font-weight: bold; }
 .INFO { color: #57606a; }
 .filters { margin: 16px 0; }
 .filters button { font: inherit; font-size: 13px; padding: 6px 12px; margin: 0 6px 6px 0; border: 1px solid #ccc; border-radius: 4px; background: #fff; cursor: pointer; }
 .filters button:hover { border-color: #2d3e50; }
 .filters button.active { background: #2d3e50; color: #fff; border-color: #2d3e50; }
 tr.hidden, h2.hidden, table.hidden { display: none; }
 #emptyNote { color: #57606a; font-style: italic; margin: 12px 0; display: none; }
 .sumlink { cursor: pointer; text-decoration: underline; }
 .toc { background: #f6f8fa; border: 1px solid #e1e4e8; border-radius: 6px; padding: 12px 18px; margin: 16px 0; }
 .toc h3 { margin: 0 0 8px; color: #2d3e50; font-size: 15px; }
 .toc-cat { margin: 8px 0; }
 .toc-cat-name { font-weight: bold; color: #555; }
 .toc ul { margin: 4px 0 0; padding-left: 18px; columns: 2; }
 .toc li { margin: 2px 0; list-style: square; }
 .toc a { color: #0969da; text-decoration: none; cursor: pointer; }
 .toc a:hover { text-decoration: underline; }
 .b { font-size: 11px; font-weight: bold; padding: 0 5px; border-radius: 8px; margin-left: 4px; }
 .bFAIL { background: #ffebe9; color: #cf222e; }
 .bWARN { background: #fff8c5; color: #7d4e00; }
 .muted { color: #8b949e; font-size: 12px; }
 .seccount { color: #8b949e; font-weight: normal; font-size: 13px; }
 .backtop { font-size: 12px; margin-left: 10px; font-weight: normal; }
</style>
"@

    # Per-status counts for the filter buttons. @() guards the PowerShell
    # quirk where a single matching object has no usable .Count.
    $cFail = @($script:Results | Where-Object { $_.Status -eq 'FAIL' }).Count
    $cWarn = @($script:Results | Where-Object { $_.Status -eq 'WARN' }).Count
    $cInfo = @($script:Results | Where-Object { $_.Status -eq 'INFO' }).Count
    $cPass = @($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count
    $cAttn = $cFail + $cWarn
    $cAll  = @($script:Results).Count

    # Clickable, color-coded summary tokens (e.g. FAIL=57) wired to the same filter
    $summaryHtml = (($script:Results | Group-Object Status | ForEach-Object {
        "<span class='sumlink $($_.Name)' data-filter='$($_.Name)'>$($_.Name)=$($_.Count)</span>"
    }) -join ' &nbsp; ')

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
            "<td class='$($_.Status)'>$($_.Status)</td><td>$([System.Net.WebUtility]::HtmlEncode([string]$_.Detail))</td></tr>"
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
<a id="top"></a>
<h1>VMware Health &amp; Compliance Report</h1>
<p>Generated: $(Get-Date)<br>vCenter(s): $($VCenter -join ', ')<br>
Summary: $summaryHtml &nbsp; <span style='color:#57606a'>(click a number or button to filter)</span></p>
<div class="filters">
 <button data-filter="attention" class="active">Needs attention &mdash; FAIL + WARN ($cAttn)</button>
 <button data-filter="FAIL">FAIL ($cFail)</button>
 <button data-filter="WARN">WARN ($cWarn)</button>
 <button data-filter="INFO">INFO ($cInfo)</button>
 <button data-filter="PASS">PASS ($cPass)</button>
 <button data-filter="all">All ($cAll)</button>
</div>
<div class="toc">
 <h3>Contents &mdash; jump to a section</h3>
 $tocHtml
</div>
<p id="emptyNote">Nothing matches this filter.</p>
$bodyHtml
<script>
(function(){
 var buttons = document.querySelectorAll('.filters button');
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
  refreshSections();
  note.style.display = visible ? 'none' : 'block';
 }
 buttons.forEach(function(b){ b.addEventListener('click', function(){ apply(b.getAttribute('data-filter')); }); });
 document.querySelectorAll('.sumlink').forEach(function(s){ s.addEventListener('click', function(){ apply(s.getAttribute('data-filter')); }); });
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
