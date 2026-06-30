<#
.SYNOPSIS
    Report (and optionally remediate) VMs whose VMware Tools or VM hardware
    version need updating in a vCenter environment.

.DESCRIPTION
    Connects to one or more vCenter Servers and evaluates every VM for:
        1. VMware Tools   - current / needs upgrade / not installed / unmanaged
        2. Hardware ver.  - VM compatibility (vmx-NN) below a target baseline

    REPORT-ONLY BY DEFAULT. Results go to the console (color-coded) plus HTML
    and CSV reports. Remediation is opt-in and guarded:

        -UpdateTools       Update VMware Tools on flagged, powered-on VMs.
        -UpgradeHardware   Upgrade VM hardware version on flagged VMs (must be
                           powered off; the script SKIPS powered-on VMs).

    Both remediation switches support -WhatIf and -Confirm via ShouldProcess.
    Run with -WhatIf first to preview exactly what would change.

.PARAMETER VCenter
    One or more vCenter Server FQDNs/IPs to connect to.

.PARAMETER Credential
    PSCredential for vCenter. If omitted, you are prompted (or SSO is used).

.PARAMETER ReportPath
    Folder for the HTML/CSV report. Defaults to the current directory.

.PARAMETER TargetHardwareVersion
    Hardware version baseline. VMs below this are flagged. Accepts a number
    (e.g. 19) or full key (e.g. vmx-19). Default 19 (vSphere 7 era).

.PARAMETER UpdateTools
    Remediate: update VMware Tools on powered-on VMs flagged as needing upgrade.
    Honors -WhatIf / -Confirm.

.PARAMETER UpgradeHardware
    Remediate: upgrade VM hardware version to -TargetHardwareVersion on flagged
    VMs. Only acts on POWERED-OFF VMs. Honors -WhatIf / -Confirm.

.PARAMETER NoReboot
    With -UpdateTools, pass through to suppress the automatic guest reboot the
    Tools upgrade may trigger (Windows). Default behavior is VMware's default.

.EXAMPLE
    # Report only
    .\Invoke-VMwareUpdateCompliance.ps1 -VCenter vcenter01.corp.local

.EXAMPLE
    # Preview hardware upgrades to vmx-20 without changing anything
    .\Invoke-VMwareUpdateCompliance.ps1 -VCenter vc1 -TargetHardwareVersion 20 -UpgradeHardware -WhatIf

.EXAMPLE
    # Update Tools on flagged VMs without rebooting the guest
    .\Invoke-VMwareUpdateCompliance.ps1 -VCenter vc1 -UpdateTools -NoReboot

.NOTES
    Requires PowerCLI. Install with:  Install-Module VCF.PowerCLI -Scope CurrentUser
    (older releases use the VMware.PowerCLI module name; both are supported)
    Tools/HW data requires the VM to have run at least once; Tools status is
    only meaningful for powered-on VMs.

    Runtime: scales with total inventory across all connected vCenters,
    since checks run per-VM. Rough estimates:
      ~25 VMs ........ under a minute
      ~150 VMs ....... a few minutes
      500+ VMs ....... 10+ minutes
    Add ~10-30s for the initial PowerCLI module import. Multiple vCenters
    add their inventories together.

    Output: every result shown on the console is also written to two
    timestamped files in -ReportPath (default: current directory):
      VMwareUpdateCompliance-<yyyyMMdd-HHmmss>.html  (styled table)
      VMwareUpdateCompliance-<yyyyMMdd-HHmmss>.csv   (same rows, for Excel)
    Both share the columns Category, Object, Check, Status, Detail, and
    are written in a finally block so they are produced even if the run
    errors partway through. Pass -ReportPath to control where they land.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [string[]] $VCenter,

    [System.Management.Automation.PSCredential] $Credential,

    [string] $ReportPath = (Get-Location).Path,

    [string] $TargetHardwareVersion = '19',

    [switch] $UpdateTools,
    [switch] $UpgradeHardware,
    [switch] $NoReboot
)

#region --- Setup -------------------------------------------------------------

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
    Write-Host ("[{0,-4}] {1,-14} {2,-26} {3} - {4}" -f $Status, $Category, $Object, $Check, $Detail) -ForegroundColor $color
}

# Normalize the target hardware version to an integer (accept 19 or vmx-19)
$targetHwNum = 0
if ($TargetHardwareVersion -match '(\d+)') { $targetHwNum = [int]$Matches[1] }
if ($targetHwNum -le 0) { throw "Invalid -TargetHardwareVersion '$TargetHardwareVersion'. Use a number like 19 or vmx-19." }

# Broadcom renamed the meta-module from VMware.PowerCLI to VCF.PowerCLI
# in PowerCLI 13.x, so accept either.
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

Write-Host ("Mode: {0}   Target HW: vmx-{1}" -f `
    $(if ($UpdateTools -or $UpgradeHardware) { 'REMEDIATE' } else { 'REPORT-ONLY' }), $targetHwNum) -ForegroundColor Cyan

#endregion

try {
    $vms = Get-VM | Sort-Object Name

    # Track which VMs are flagged so remediation only touches those
    $toolsToUpdate = New-Object System.Collections.Generic.List[object]
    $hwToUpgrade   = New-Object System.Collections.Generic.List[object]

    #region --- 1. VMware Tools ----------------------------------------------
    Write-Host "`n=== VMware Tools ===" -ForegroundColor Cyan
    foreach ($vm in $vms) {
        $guest      = $vm.ExtensionData.Guest
        $verStatus  = $guest.ToolsVersionStatus2  # richer than ToolsStatus
        $runStatus  = $guest.ToolsRunningStatus
        $toolsVer   = if ($guest.ToolsVersion) { $guest.ToolsVersion } else { 'n/a' }

        if ($vm.PowerState -ne 'PoweredOn') {
            Add-Result 'VMwareTools' $vm.Name 'ToolsStatus' 'INFO' "Powered off - status not evaluated (last known v$toolsVer)"
            continue
        }

        switch ($verStatus) {
            'guestToolsCurrent' {
                Add-Result 'VMwareTools' $vm.Name 'ToolsStatus' 'PASS' "Current (v$toolsVer)"
            }
            { $_ -in 'guestToolsNeedUpgrade','guestToolsSupportedOld','guestToolsTooOld' } {
                Add-Result 'VMwareTools' $vm.Name 'ToolsStatus' 'WARN' "Needs upgrade (v$toolsVer, status $verStatus)"
                $toolsToUpdate.Add($vm)
            }
            'guestToolsNotInstalled' {
                Add-Result 'VMwareTools' $vm.Name 'ToolsStatus' 'FAIL' 'Not installed'
            }
            'guestToolsUnmanaged' {
                # Typically open-vm-tools managed by the OS/distro - normal, not actionable here
                Add-Result 'VMwareTools' $vm.Name 'ToolsStatus' 'INFO' "Unmanaged / OS-managed (v$toolsVer)"
            }
            { $_ -in 'guestToolsBlacklisted','guestToolsSupportedNew','guestToolsTooNew' } {
                Add-Result 'VMwareTools' $vm.Name 'ToolsStatus' 'WARN' "$verStatus (v$toolsVer)"
            }
            default {
                Add-Result 'VMwareTools' $vm.Name 'ToolsStatus' 'INFO' "$verStatus (v$toolsVer), running=$runStatus"
            }
        }
    }
    #endregion

    #region --- 2. Hardware version ------------------------------------------
    Write-Host "`n=== Hardware Version ===" -ForegroundColor Cyan
    foreach ($vm in $vms) {
        $hwVersion = $vm.HardwareVersion
        $hwNum = 0
        if ($hwVersion -match 'vmx-(\d+)') { $hwNum = [int]$Matches[1] }

        if ($hwNum -le 0) {
            Add-Result 'HardwareVersion' $vm.Name 'Compatibility' 'INFO' "Unknown version ($hwVersion)"
        } elseif ($hwNum -lt $targetHwNum) {
            Add-Result 'HardwareVersion' $vm.Name 'Compatibility' 'WARN' "$hwVersion (below target vmx-$targetHwNum)"
            $hwToUpgrade.Add($vm)
        } else {
            Add-Result 'HardwareVersion' $vm.Name 'Compatibility' 'PASS' "$hwVersion (>= target vmx-$targetHwNum)"
        }
    }
    #endregion

    #region --- 3. Optional remediation --------------------------------------
    if ($UpdateTools) {
        Write-Host "`n=== Remediate: VMware Tools ===" -ForegroundColor Cyan
        if (-not $toolsToUpdate) {
            Write-Host "  No powered-on VMs need a Tools upgrade." -ForegroundColor Green
        }
        foreach ($vm in $toolsToUpdate) {
            if ($PSCmdlet.ShouldProcess($vm.Name, "Update VMware Tools")) {
                try {
                    $p = @{ VM = $vm; ErrorAction = 'Stop' }
                    if ($NoReboot) { $p.NoReboot = $true }
                    Update-Tools @p
                    Add-Result 'VMwareTools' $vm.Name 'Remediation' 'INFO' 'Tools update initiated'
                } catch {
                    Add-Result 'VMwareTools' $vm.Name 'Remediation' 'FAIL' "Update failed: $($_.Exception.Message)"
                }
            }
        }
    }

    if ($UpgradeHardware) {
        Write-Host "`n=== Remediate: Hardware Version ===" -ForegroundColor Cyan
        if (-not $hwToUpgrade) {
            Write-Host "  No VMs below the target hardware version." -ForegroundColor Green
        }
        foreach ($vm in $hwToUpgrade) {
            # Hardware upgrade requires the VM to be powered off - never force it.
            if ($vm.PowerState -ne 'PoweredOff') {
                Add-Result 'HardwareVersion' $vm.Name 'Remediation' 'WARN' "Skipped - VM is $($vm.PowerState) (must be PoweredOff)"
                continue
            }
            if ($PSCmdlet.ShouldProcess($vm.Name, "Upgrade hardware to vmx-$targetHwNum")) {
                try {
                    # Set-VM -Version takes a named version (e.g. v19); build it from the number
                    Set-VM -VM $vm -Version "v$targetHwNum" -Confirm:$false -ErrorAction Stop | Out-Null
                    Add-Result 'HardwareVersion' $vm.Name 'Remediation' 'INFO' "Upgraded to vmx-$targetHwNum"
                } catch {
                    Add-Result 'HardwareVersion' $vm.Name 'Remediation' 'FAIL' "Upgrade failed: $($_.Exception.Message)"
                }
            }
        }
    }
    #endregion
}
finally {
    #region --- Report + disconnect ------------------------------------------
    $summary = $script:Results | Group-Object Status | ForEach-Object { "$($_.Name)=$($_.Count)" }
    Write-Host "`n=== Summary: $($summary -join '  ') ===" -ForegroundColor Cyan
    Write-Host ("Needing Tools upgrade: {0}   Below target HW: {1}" -f $toolsToUpdate.Count, $hwToUpgrade.Count) -ForegroundColor Cyan

    if (-not (Test-Path $ReportPath)) { New-Item -ItemType Directory -Path $ReportPath -Force | Out-Null }
    $stamp    = Get-Date -Format 'yyyyMMdd-HHmmss'
    $htmlFile = Join-Path $ReportPath "VMwareUpdateCompliance-$stamp.html"

    $style = @"
<style>
 body { font-family: Segoe UI, Arial, sans-serif; margin: 20px; }
 h1 { color: #333; }
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

    Add-Type -AssemblyName System.Web
    $rowsHtml = ($script:Results | ForEach-Object {
        "<tr><td>$($_.Category)</td><td>$($_.Object)</td><td>$($_.Check)</td>" +
        "<td class='$($_.Status)'>$($_.Status)</td><td>$([System.Web.HttpUtility]::HtmlEncode($_.Detail))</td></tr>"
    }) -join "`n"

    $html = @"
<!DOCTYPE html><html><head><meta charset='utf-8'>$style
<title>VMware Update Compliance $stamp</title></head><body>
<h1>VMware Update Compliance Report</h1>
<p>Generated: $(Get-Date)<br>vCenter(s): $($VCenter -join ', ')<br>
Target hardware version: vmx-$targetHwNum<br>
Summary: $($summary -join ' &nbsp; ')</p>
<table><tr><th>Category</th><th>Object</th><th>Check</th><th>Status</th><th>Detail</th></tr>
$rowsHtml
</table></body></html>
"@
    $html | Out-File -FilePath $htmlFile -Encoding utf8
    Write-Host "HTML report written to: $htmlFile" -ForegroundColor Green

    $csvFile = Join-Path $ReportPath "VMwareUpdateCompliance-$stamp.csv"
    $script:Results | Export-Csv -Path $csvFile -NoTypeInformation -Encoding utf8
    Write-Host "CSV report written to:  $csvFile" -ForegroundColor Green

    if ($connections) { Disconnect-VIServer -Server $connections -Confirm:$false -ErrorAction SilentlyContinue }
    #endregion
}
