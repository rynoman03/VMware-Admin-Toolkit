<#
.SYNOPSIS
    Read-only health check & compliance report for a vCenter environment.

.DESCRIPTION
    Connects to one or more vCenter Servers and evaluates four areas:
        1. Host health     - connection state, NTP, syslog, uptime, datastore connectivity
        2. VM compliance   - VMware Tools, VM hardware version, mounted ISOs, snapshot age
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
    Requires VMware.PowerCLI. Install with:  Install-Module VMware.PowerCLI -Scope CurrentUser
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

# Ensure PowerCLI is present
if (-not (Get-Module -ListAvailable -Name VMware.PowerCLI)) {
    throw "VMware.PowerCLI is not installed. Run: Install-Module VMware.PowerCLI -Scope CurrentUser"
}
Import-Module VMware.PowerCLI -ErrorAction Stop | Out-Null

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
        $mounted = $vm | Get-CDDrive | Where-Object { $_.IsoPath -or $_.HostDevice -or $_.RemoteDevice }
        if ($mounted) {
            $what = ($mounted | ForEach-Object { if ($_.IsoPath) { $_.IsoPath } else { 'host/remote device' } }) -join ','
            Add-Result 'VMCompliance' $vm.Name 'MountedMedia' 'WARN' "Connected media: $what"
        }

        # Snapshot age
        $snaps = $vm | Get-Snapshot
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
 body { font-family: Segoe UI, Arial, sans-serif; margin: 20px; }
 h1 { color: #333; } h2 { color: #555; margin-top: 28px; }
 table { border-collapse: collapse; width: 100%; }
 th, td { border: 1px solid #ddd; padding: 6px 10px; text-align: left; font-size: 13px; }
 th { background: #2d3e50; color: #fff; }
 tr:nth-child(even) { background: #f6f8fa; }
 .PASS { color: #1a7f37; font-weight: bold; }
 .WARN { color: #b88600; font-weight: bold; }
 .FAIL { color: #cf222e; font-weight: bold; }
 .INFO { color: #57606a; }
</style>
"@

    $rowsHtml = ($script:Results | ForEach-Object {
        "<tr><td>$($_.Category)</td><td>$($_.Object)</td><td>$($_.Check)</td>" +
        "<td class='$($_.Status)'>$($_.Status)</td><td>$([System.Web.HttpUtility]::HtmlEncode($_.Detail))</td></tr>"
    }) -join "`n"

    Add-Type -AssemblyName System.Web
    $html = @"
<!DOCTYPE html><html><head><meta charset='utf-8'>$style
<title>VMware Health Check $stamp</title></head><body>
<h1>VMware Health &amp; Compliance Report</h1>
<p>Generated: $(Get-Date)<br>vCenter(s): $($VCenter -join ', ')<br>
Summary: $($summary -join ' &nbsp; ')</p>
<table><tr><th>Category</th><th>Object</th><th>Check</th><th>Status</th><th>Detail</th></tr>
$rowsHtml
</table></body></html>
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
