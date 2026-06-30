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

    Add-Type -AssemblyName System.Web

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
            "<tr data-status='$($_.Status)'><td>$([System.Web.HttpUtility]::HtmlEncode($_.Object))</td>" +
            "<td class='$($_.Status)'>$($_.Status)</td><td>$([System.Web.HttpUtility]::HtmlEncode($_.Detail))</td></tr>"
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
<title>VMware Update Compliance $stamp</title></head><body>
<a id="top"></a>
<h1>VMware Update Compliance Report</h1>
<p>Generated: $(Get-Date)<br>vCenter(s): $($VCenter -join ', ')<br>
Target hardware version: vmx-$targetHwNum<br>
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

    $csvFile = Join-Path $ReportPath "VMwareUpdateCompliance-$stamp.csv"
    $script:Results | Export-Csv -Path $csvFile -NoTypeInformation -Encoding utf8
    Write-Host "CSV report written to:  $csvFile" -ForegroundColor Green

    if ($connections) { Disconnect-VIServer -Server $connections -Confirm:$false -ErrorAction SilentlyContinue }
    #endregion
}
