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

.PARAMETER TrustAllCertificates
    Whether to ignore untrusted/self-signed vCenter TLS certificates when
    connecting (PowerCLI's InvalidCertificateAction). Default $true, since
    many vCenters run on internal or self-signed certs. Pass
    -TrustAllCertificates:$false to require a valid chain instead.

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
    [switch] $NoReboot,
    [switch] $TrustAllCertificates = $true
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

# -TrustAllCertificates (default on) ignores untrusted/self-signed vCenter
# certs; pass -TrustAllCertificates:$false to require a valid chain instead.
$certAction = if ($TrustAllCertificates) { 'Ignore' } else { 'Fail' }
Set-PowerCLIConfiguration -Scope Session -InvalidCertificateAction $certAction -ParticipateInCeip $false -Confirm:$false | Out-Null

#endregion

$connections = @()

# Track which VMs are flagged so remediation only touches those. Declared
# before the try so the finally block's summary line is always well-defined,
# even if the run errors before Get-VM completes.
$toolsToUpdate = New-Object System.Collections.Generic.List[object]
$hwToUpgrade   = New-Object System.Collections.Generic.List[object]

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

    Write-Host ("Mode: {0}   Target HW: vmx-{1}" -f `
        $(if ($UpdateTools -or $UpgradeHardware) { 'REMEDIATE' } else { 'REPORT-ONLY' }), $targetHwNum) -ForegroundColor Cyan
    #endregion

    $vms = Get-VM -Server $connections | Sort-Object Name

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
    Write-Host ("Needing Tools upgrade: {0}   Below target HW: {1}" -f $toolsToUpdate.Count, $hwToUpgrade.Count) -ForegroundColor Cyan

    if (-not (Test-Path $ReportPath)) { New-Item -ItemType Directory -Path $ReportPath -Force | Out-Null }
    $stamp    = Get-Date -Format 'yyyyMMdd-HHmmss'
    $htmlFile = Join-Path $ReportPath "VMwareUpdateCompliance-$stamp.html"

    # Styled after a Dell iDRAC-style dashboard: dark navy header/sidebar, a
    # blue accent, status pill badges, and a stat-tile summary row instead of
    # a plain text line.
    $style = @"
<style>
 :root {
  /* Dell blue, matched to the iDRAC 10 banner. --brand is for large
     surfaces only: at 4.14:1 on the page background it is too light for
     body-size link text, so --accent stays darker for anything read as
     text. --navy is the same hue family, deepened, so the sidebar and
     table headers read as Dell blue rather than near-black. */
  --brand: #0076ce; --brand-2: #0062ad;
  --navy: #0a3a63; --navy-2: #10497a; --accent: #045a9e;
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
 .sidebar { width: 270px; flex: 0 0 270px; background: var(--navy); color: #dbe6f0; padding: 18px 0; position: sticky; top: 0; align-self: flex-start; max-height: 100vh; overflow-y: auto; }
 .sidebar h3 { margin: 0 18px 10px; font-size: 12px; text-transform: uppercase; letter-spacing: .08em; color: #8fa3ba; }
 .sidebar .toc-cat { margin: 0 0 14px; }
 .sidebar .toc-cat-name { display: block; padding: 6px 18px; font-weight: 600; font-size: 12px; color: #a9bdd2; text-transform: uppercase; letter-spacing: .04em; }
 .sidebar ul { list-style: none; margin: 4px 0 0; padding: 0; }
 .sidebar li { margin: 0; }
 .sidebar a { display: flex; align-items: center; justify-content: space-between; gap: 6px; padding: 6px 18px; font-size: 13px; color: #dbe6f0; text-decoration: none; border-left: 3px solid transparent; cursor: pointer; }
 .sidebar a:hover { background: var(--navy-2); border-left-color: var(--accent); }
 .sidebar .toc-name { min-width: 0; overflow-wrap: anywhere; }
 .sidebar .toc-meta { display: inline-flex; align-items: center; flex: none; }
 .sidebar .muted { color: #9fb4c9; font-size: 11px; }
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
 h2 { color: var(--navy); margin: 28px 0 4px; padding-left: 10px; border-left: 4px solid var(--accent); font-size: 16px; scroll-margin-top: 118px; }
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
<title>VMware Update Compliance $stamp</title></head><body>
<header class="topbar">
 <div class="topbar-brand"><span class="brand-badge">UC</span><span class="brand-title">VMware Update Compliance Report</span></div>
 <div class="topbar-meta">Generated $(Get-Date) &nbsp;&bull;&nbsp; vCenter(s): $($VCenter -join ', ')</div>
</header>
<div class="layout">
 <nav class="sidebar">
  <h3>Contents</h3>
  $tocHtml
 </nav>
 <main class="content">
  <a id="top"></a>
  <p class="meta-line">Target hardware version: vmx-$targetHwNum &nbsp;&bull;&nbsp; Needing Tools upgrade: $($toolsToUpdate.Count) &nbsp;&bull;&nbsp; Below target HW: $($hwToUpgrade.Count)</p>
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

    $csvFile = Join-Path $ReportPath "VMwareUpdateCompliance-$stamp.csv"
    $script:Results | Export-Csv -Path $csvFile -NoTypeInformation -Encoding utf8
    Write-Host "CSV report written to:  $csvFile" -ForegroundColor Green

    if ($connections) { Disconnect-VIServer -Server $connections -Confirm:$false -ErrorAction SilentlyContinue }
    #endregion
}
