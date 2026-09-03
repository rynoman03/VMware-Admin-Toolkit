<#
.SYNOPSIS
    Read-only MTU consistency audit for a vCenter environment.

.DESCRIPTION
    For every ESXi host, compares MTU across three layers and flags mismatches
    that cause jumbo-frame/packet-loss problems:
        1. VMkernel adapter MTU (vmk0, vMotion, storage, etc.)
        2. The standard vSwitch or distributed vSwitch (VDS) it sits on
        3. The MTU reported by the physically connected switch port via CDP

    Every check is READ-ONLY. The script never changes configuration.
    Results are written to the console (color-coded) and an HTML report.

.PARAMETER VCenter
    One or more vCenter Server FQDNs/IPs to connect to.

.PARAMETER Credential
    PSCredential for vCenter. If omitted, you are prompted (or pass-through/SSO is used).

.PARAMETER ReportPath
    Folder for the HTML report. Defaults to the current directory.

.EXAMPLE
    .\Invoke-VMwareMtuConsistencyCheck.ps1 -VCenter vcenter01.corp.local

.EXAMPLE
    $cred = Get-Credential
    .\Invoke-VMwareMtuConsistencyCheck.ps1 -VCenter vc1,vc2 -Credential $cred -ReportPath C:\Reports

.NOTES
    Requires PowerCLI. Install with:  Install-Module VCF.PowerCLI -Scope CurrentUser
    (older releases use the VMware.PowerCLI module name; both are supported)

    CDP data requires CDP to be enabled/advertised on the physically connected
    switch port. If the switch only speaks LLDP, or CDP is disabled, the
    CDP-vs-switch checks report INFO instead of PASS/FAIL rather than guessing.

    Output: every result shown on the console is also written to two
    timestamped files in -ReportPath (default: current directory):
      VMwareMtuConsistencyCheck-<yyyyMMdd-HHmmss>.html  (styled table)
      VMwareMtuConsistencyCheck-<yyyyMMdd-HHmmss>.csv   (same rows, for Excel)
    Both share the columns Category, Object, Check, Status, Detail, and
    are written in a finally block so they are produced even if the run
    errors partway through. Pass -ReportPath to control where they land.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string[]] $VCenter,

    [System.Management.Automation.PSCredential] $Credential,

    [string] $ReportPath = (Get-Location).Path
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
    #region --- MTU consistency ------------------------------------------------
    Write-Host "`n=== MTU Consistency ===" -ForegroundColor Cyan
    $vmHosts = Get-VMHost

    foreach ($h in $vmHosts) {
        if ($h.ConnectionState -ne 'Connected') {
            Add-Result 'MtuConsistency' $h.Name 'HostReachable' 'WARN' "State is $($h.ConnectionState) - skipped"
            continue
        }

        # CDP info per physical NIC, keyed by device name (e.g. vmnic0).
        $cdpByPnic = @{}
        $pnicNames = @($h | Get-VMHostNetworkAdapter -Physical | Select-Object -ExpandProperty Name)
        if ($pnicNames) {
            $netSys = Get-View -Id $h.ExtensionData.ConfigManager.NetworkSystem
            foreach ($hint in @($netSys.QueryNetworkHint($pnicNames))) {
                if ($hint.ConnectedSwitchPort) { $cdpByPnic[$hint.Device] = $hint.ConnectedSwitchPort }
            }
        }

        # --- Standard vSwitches: uplinks vs CDP, VMkernel adapters vs vSwitch ---
        foreach ($vs in @($h | Get-VirtualSwitch -Standard)) {
            $vsMtu = $vs.Mtu

            foreach ($nic in @($vs.Nic)) {
                $cdp = $cdpByPnic[$nic]
                if ($cdp -and $cdp.Mtu) {
                    if ($cdp.Mtu -eq $vsMtu) {
                        Add-Result 'MtuConsistency' "$($h.Name)/$nic" 'CDP-vs-vSwitch' 'PASS' "$($vs.Name) MTU $vsMtu matches switch-reported MTU $($cdp.Mtu) ($($cdp.DevId)/$($cdp.PortId))"
                    } else {
                        Add-Result 'MtuConsistency' "$($h.Name)/$nic" 'CDP-vs-vSwitch' 'FAIL' "$($vs.Name) MTU $vsMtu does not match switch-reported MTU $($cdp.Mtu) ($($cdp.DevId)/$($cdp.PortId))"
                    }
                } else {
                    Add-Result 'MtuConsistency' "$($h.Name)/$nic" 'CDP-vs-vSwitch' 'INFO' "No CDP MTU data for $nic on $($vs.Name) (CDP disabled, or the switch doesn't advertise MTU via CDP)"
                }
            }

            $vmks = @($h | Get-VMHostNetworkAdapter -VMKernel | Where-Object {
                $pg = $h | Get-VirtualPortGroup -Standard -Name $_.PortGroupName -ErrorAction SilentlyContinue
                $pg -and $pg.VirtualSwitchName -eq $vs.Name
            })
            foreach ($vmk in $vmks) {
                if ($vmk.Mtu -eq $vsMtu) {
                    Add-Result 'MtuConsistency' "$($h.Name)/$($vmk.Name)" 'VMkernel-vs-vSwitch' 'PASS' "$($vmk.Name) MTU $($vmk.Mtu) matches $($vs.Name) MTU $vsMtu"
                } else {
                    Add-Result 'MtuConsistency' "$($h.Name)/$($vmk.Name)" 'VMkernel-vs-vSwitch' 'FAIL' "$($vmk.Name) MTU $($vmk.Mtu) does not match $($vs.Name) MTU $vsMtu"
                }
            }
        }

        # --- Distributed vSwitches: uplinks vs CDP, VMkernel adapters vs VDS ---
        foreach ($vds in @($h | Get-VDSwitch)) {
            $vdsMtu = $vds.Mtu
            $proxy = $h.ExtensionData.Config.Network.ProxySwitch | Where-Object { $_.DvsUuid -eq $vds.ExtensionData.Uuid }
            $uplinkNics = @($proxy.Spec.Backing.PnicSpec.PnicDevice)

            foreach ($nic in $uplinkNics) {
                $cdp = $cdpByPnic[$nic]
                if ($cdp -and $cdp.Mtu) {
                    if ($cdp.Mtu -eq $vdsMtu) {
                        Add-Result 'MtuConsistency' "$($h.Name)/$nic" 'CDP-vs-VDS' 'PASS' "$($vds.Name) MTU $vdsMtu matches switch-reported MTU $($cdp.Mtu) ($($cdp.DevId)/$($cdp.PortId))"
                    } else {
                        Add-Result 'MtuConsistency' "$($h.Name)/$nic" 'CDP-vs-VDS' 'FAIL' "$($vds.Name) MTU $vdsMtu does not match switch-reported MTU $($cdp.Mtu) ($($cdp.DevId)/$($cdp.PortId))"
                    }
                } else {
                    Add-Result 'MtuConsistency' "$($h.Name)/$nic" 'CDP-vs-VDS' 'INFO' "No CDP MTU data for $nic on $($vds.Name) (CDP disabled, or the switch doesn't advertise MTU via CDP)"
                }
            }

            $vmks = @($h | Get-VMHostNetworkAdapter -VMKernel | Where-Object {
                $pg = Get-VDPortgroup -Name $_.PortGroupName -ErrorAction SilentlyContinue | Select-Object -First 1
                $pg -and $pg.VDSwitch.Name -eq $vds.Name
            })
            foreach ($vmk in $vmks) {
                if ($vmk.Mtu -eq $vdsMtu) {
                    Add-Result 'MtuConsistency' "$($h.Name)/$($vmk.Name)" 'VMkernel-vs-VDS' 'PASS' "$($vmk.Name) MTU $($vmk.Mtu) matches $($vds.Name) MTU $vdsMtu"
                } else {
                    Add-Result 'MtuConsistency' "$($h.Name)/$($vmk.Name)" 'VMkernel-vs-VDS' 'FAIL' "$($vmk.Name) MTU $($vmk.Mtu) does not match $($vds.Name) MTU $vdsMtu"
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

    if (-not (Test-Path $ReportPath)) { New-Item -ItemType Directory -Path $ReportPath -Force | Out-Null }
    $stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'
    $htmlFile  = Join-Path $ReportPath "VMwareMtuConsistencyCheck-$stamp.html"

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
    # $script:Results is a List[object]; read .Count directly. Wrapping it as
    # @($script:Results).Count throws "Argument types do not match" in WinPS 5.1.
    $cAll  = $script:Results.Count

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
<title>VMware MTU Consistency Check $stamp</title></head><body>
<a id="top"></a>
<h1>VMware MTU Consistency Report</h1>
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
    $csvFile = Join-Path $ReportPath "VMwareMtuConsistencyCheck-$stamp.csv"
    $script:Results | Export-Csv -Path $csvFile -NoTypeInformation -Encoding utf8
    Write-Host "CSV report written to:  $csvFile" -ForegroundColor Green

    if ($connections) { Disconnect-VIServer -Server $connections -Confirm:$false -ErrorAction SilentlyContinue }
    #endregion
}
