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

    [string] $ReportPath = (Get-Location).Path,

    [bool] $TrustAllCertificates = $true
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
# Sidebar label for a check name. Check names are CamelCase identifiers
# ('CertificateExpiry'), which the narrow sidebar has to break mid-word; spacing
# them lets the column wrap at word boundaries instead. Only the sidebar uses
# this - section headings keep the raw name, which matches the CSV.
function Format-CheckLabel {
    param([string] $Check)

    # Names the generic rules below get wrong, or that have a house spelling.
    $overrides = @{
        'VersionVsVCenter' = 'Version vs vCenter'
    }
    if ($overrides.ContainsKey($Check)) { return $overrides[$Check] }

    # lowercase/digit followed by a capital: Certificate|Expiry
    $label = $Check -creplace '([a-z0-9])([A-Z])', '$1 $2'
    # end of an acronym run: SSH|Enabled, OS|Drive, DRS|Automation. The {2,} is
    # what keeps 'VMwareTools' from becoming 'V Mware Tools'.
    $label = $label -creplace '([A-Z]{2,})([A-Z][a-z])', '$1 $2'
    return $label
}

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
    #region --- Connect ---------------------------------------------------------
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

    #region --- MTU consistency ------------------------------------------------
    Write-Host "`n=== MTU Consistency ===" -ForegroundColor Cyan
    $vmHosts = Get-VMHost -Server $connections

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
            # Guard against $proxy being $null (no matching ProxySwitch entry): the
            # property chain would otherwise resolve to $null, and @($null) is a
            # 1-element array containing null rather than an empty one, producing a
            # spurious row with a blank NIC name below.
            $uplinkNics = if ($proxy) { @($proxy.Spec.Backing.PnicSpec.PnicDevice) } else { @() }

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

            # Scoped to this VDS via -VDSwitch (not just -Name then filtered) so two
            # different VDSes with a same-named portgroup (common in multi-datacenter
            # environments) can't make -Select-Object -First 1 pick the wrong one and
            # silently drop this VMkernel adapter from the check.
            $vmks = @($h | Get-VMHostNetworkAdapter -VMKernel | Where-Object {
                $pg = Get-VDPortgroup -VDSwitch $vds -Name $_.PortGroupName -ErrorAction SilentlyContinue | Select-Object -First 1
                $null -ne $pg
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
    $htmlFile  = Join-Path $ReportPath "VMwareMtuConsistencyCheck-$stamp.html"

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
 /* The tiles AND the filter buttons freeze together as one toolbar. Freezing
    only the tiles left the FAIL/WARN/INFO/PASS buttons - and their counts -
    scrolling away under it. Negative margin + matching padding bleeds the
    background across .content's 24px gutters, so rows scrolling underneath
    don't show through at the edges. */
 .toolbar { position: sticky; top: 0; z-index: 20; background: var(--bg);
            margin: 0 -24px 18px; padding: 12px 24px 12px;
            box-shadow: 0 1px 0 var(--border), 0 4px 10px -6px rgba(16,24,40,.28); }
 .stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 12px; margin: 0 0 12px; }
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
 h2 { color: var(--brand-2); margin: 28px 0 4px; padding-left: 10px; border-left: 4px solid var(--accent); font-size: 16px; scroll-margin-top: 172px; }
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
  .toolbar { position: static; margin: 0 0 18px; padding: 0; box-shadow: none; }
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
            "<li><a data-jump='$($sec.Id)' href='#$($sec.Id)'><span class='toc-name'>$(Format-CheckLabel $sec.Check)</span><span class='toc-meta'>$badges</span></a></li>"
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
<title>VMware MTU Consistency Check $stamp</title></head><body>
<header class="topbar">
 <div class="topbar-brand"><span class="brand-badge">MTU</span><span class="brand-title">VMware MTU Consistency Report</span></div>
 <div class="topbar-meta">Generated $(Get-Date) &nbsp;&bull;&nbsp; vCenter(s): $($VCenter -join ', ')</div>
</header>
<div class="layout">
 <nav class="sidebar">
  <h3>Contents</h3>
  $tocHtml
 </nav>
 <main class="content">
  <a id="top"></a>
  <div class="toolbar">
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
    $csvFile = Join-Path $ReportPath "VMwareMtuConsistencyCheck-$stamp.csv"
    $script:Results | Export-Csv -Path $csvFile -NoTypeInformation -Encoding utf8
    Write-Host "CSV report written to:  $csvFile" -ForegroundColor Green

    if ($connections) { Disconnect-VIServer -Server $connections -Confirm:$false -ErrorAction SilentlyContinue }
    #endregion
}
