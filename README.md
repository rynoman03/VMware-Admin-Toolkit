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
- **VM compliance** — VMware Tools, OS system drive free space (`C:\` / `/`), all other guest drives, VM hardware version, mounted ISOs/CD-ROMs, snapshot age
- **Capacity** — datastore free space, cluster CPU/RAM utilization
- **Cluster config** — HA, admission control, DRS, EVC

Findings are tagged `PASS` / `WARN` / `FAIL` / `INFO`. The script never modifies configuration.

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

## Conventions

- Scripts are **read-only by default**; any script that changes state will say so clearly and support `-WhatIf` where practical.
- Thresholds and targets are **parameters**, not hard-coded values.
- Output is written to both console and a timestamped report file where it makes sense.

## Roadmap

- Stale snapshot cleanup (report + optional removal)
- Template-based VM provisioning
- Inventory / capacity trending exports
