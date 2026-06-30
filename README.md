# VMware-Admin-Toolkit

A collection of PowerCLI scripts for automating routine VMware vSphere administration.
Everything here is built to be safe, parameterized, and report-driven.

## Contents

| Script | Purpose | Read-only? |
|--------|---------|------------|
| [`HealthCheck/Invoke-VMwareHealthCheck.ps1`](HealthCheck/Invoke-VMwareHealthCheck.ps1) | Health & compliance report across host health, VM compliance, capacity, and cluster config. Emits color-coded console output plus HTML and CSV reports. | ✅ Yes |
| [`UpdateCompliance/Invoke-VMwareUpdateCompliance.ps1`](UpdateCompliance/Invoke-VMwareUpdateCompliance.ps1) | Report VMs whose VMware Tools or VM hardware version need updating. Optional opt-in remediation (`-UpdateTools` / `-UpgradeHardware`) guarded by `-WhatIf`/`-Confirm`. | ✅ Report by default |

## Requirements

- **PowerShell** 5.1+ or PowerShell 7+
- **PowerCLI** module (Broadcom renamed it from `VMware.PowerCLI` to `VCF.PowerCLI` in 13.x; the scripts accept either):
  ```powershell
  Install-Module VCF.PowerCLI -Scope CurrentUser
  ```
  > Install into the **same PowerShell edition** you run the scripts with — PS7 (`pwsh`) and Windows PowerShell 5.1 use separate module paths.
- Network access and read credentials to your vCenter Server(s).

## Usage

### Health Check

```powershell
# Prompted for credentials
.\HealthCheck\Invoke-VMwareHealthCheck.ps1 -VCenter vcenter01.corp.local

# Multiple vCenters, saved credential, custom thresholds, custom report path
$cred = Get-Credential
.\HealthCheck\Invoke-VMwareHealthCheck.ps1 -VCenter vc1,vc2 -Credential $cred `
    -ReportPath C:\Reports -SnapshotAgeWarningDays 7 -DatastoreFreeWarnPercent 25
```

The script checks:

- **Host health** — connection state, NTP, syslog, uptime, datastore connectivity
- **VM compliance** — VMware Tools, OS system drive free space (`C:\` / `/`), all other guest drives, VM hardware version, mounted ISOs/CD-ROMs, connected floppy drives, snapshot age
- **Capacity** — datastore free space, cluster CPU/RAM utilization
- **Cluster config** — HA, admission control, DRS, EVC

Findings are tagged `PASS` / `WARN` / `FAIL` / `INFO`. The script never modifies configuration.

**Runtime** scales with total inventory, since checks run per-host and per-VM (each a round-trip to vCenter). Connecting to multiple vCenters adds their inventories together. Rough guide:

| Inventory | Estimate |
|-----------|----------|
| ~25 VMs / 2-3 hosts | under a minute |
| ~150 VMs | a few minutes |
| 500+ VMs | 10+ minutes |

Add ~10-30s for the initial PowerCLI module import. As long as `PASS`/`WARN` lines keep printing, it's working — not hung.

**Output.** Everything printed to the console is also written to two timestamped files in `-ReportPath` (**defaults to the current directory** if not specified):

- `VMwareHealthCheck-<yyyyMMdd-HHmmss>.html` — styled, color-coded table
- `VMwareHealthCheck-<yyyyMMdd-HHmmss>.csv` — same rows, for Excel / trending

Both carry the columns **Category, Object, Check, Status, Detail**, and are written in a `finally` block — so you still get a report even if the run errors partway through. Pass `-ReportPath C:\Reports` to keep output in a fixed location instead of wherever you launched from.

The **HTML report opens pre-filtered to just `FAIL` + `WARN`** (what needs fixing), with clickable buttons at the top — `Needs attention`, `FAIL`, `WARN`, `INFO`, `PASS`, `All` — each showing a live count, so you can drill straight to the problems instead of scrolling past everything that passed. The summary numbers themselves are clickable too.

Results are also broken into **per-check sections** (e.g. *VMware Tools*, *Hardware Version*, *Mounted ISOs*, *Snapshots*, *NTP*, *Datastore Free*), each its own table. A **Contents/appendix at the top** lists every section grouped by category with per-section counts and `FAIL`/`WARN` badges — click an entry to jump straight to that table. Severity filtering and section navigation work together: under a filter, sections with no matching rows are hidden automatically, and clicking a Contents link reveals the target. (The CSV stays complete and unfiltered for trending; open it in Excel and use AutoFilter on the Status column for the same effect.)

### Update Compliance (VMware Tools & Hardware Version)

```powershell
# Report only — which VMs need Tools or hardware-version updates (target vmx-19)
.\UpdateCompliance\Invoke-VMwareUpdateCompliance.ps1 -VCenter vcenter01.corp.local

# Preview hardware upgrades to vmx-20 without changing anything
.\UpdateCompliance\Invoke-VMwareUpdateCompliance.ps1 -VCenter vc1 -TargetHardwareVersion 20 -UpgradeHardware -WhatIf

# Update VMware Tools on flagged powered-on VMs, without rebooting the guest
.\UpdateCompliance\Invoke-VMwareUpdateCompliance.ps1 -VCenter vc1 -UpdateTools -NoReboot
```

- **Report-only by default.** Remediation is opt-in via `-UpdateTools` / `-UpgradeHardware`.
- Hardware upgrades only run on **powered-off** VMs — powered-on VMs are skipped, never forced off.
- Both remediation paths support `-WhatIf` and `-Confirm`. Always run with `-WhatIf` first.

**Output.** Like the health check, results are written to two timestamped files in `-ReportPath` (**defaults to the current directory**): `VMwareUpdateCompliance-<yyyyMMdd-HHmmss>.html` and `.csv`, both with the columns **Category, Object, Check, Status, Detail**, produced in a `finally` block even if the run errors. Pass `-ReportPath C:\Reports` to fix the location. The HTML report opens pre-filtered to `FAIL` + `WARN` with the same clickable status buttons as the health check.

## Conventions

- Scripts are **read-only by default**; any script that changes state will say so clearly and support `-WhatIf` where practical.
- Thresholds and targets are **parameters**, not hard-coded values.
- Output is written to both console and a timestamped report file where it makes sense.

## Roadmap

- Stale snapshot cleanup (report + optional removal)
- Template-based VM provisioning
- Inventory / capacity trending exports
