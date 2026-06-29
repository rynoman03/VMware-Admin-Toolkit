# vmware-admin-toolkit

A collection of PowerCLI scripts for automating routine VMware vSphere administration.
Everything here is built to be safe, parameterized, and report-driven.

## Contents

| Script | Purpose | Read-only? |
|--------|---------|------------|
| [`HealthCheck/Invoke-VMwareHealthCheck.ps1`](HealthCheck/Invoke-VMwareHealthCheck.ps1) | Health & compliance report across host health, VM compliance, capacity, and cluster config. Emits color-coded console output plus HTML and CSV reports. | ✅ Yes |

## Requirements

- **PowerShell** 5.1+ or PowerShell 7+
- **VMware.PowerCLI** module:
  ```powershell
  Install-Module VMware.PowerCLI -Scope CurrentUser
  ```
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

## Conventions

- Scripts are **read-only by default**; any script that changes state will say so clearly and support `-WhatIf` where practical.
- Thresholds and targets are **parameters**, not hard-coded values.
- Output is written to both console and a timestamped report file where it makes sense.

## Roadmap

- Stale snapshot cleanup (report + optional removal)
- Template-based VM provisioning
- Inventory / capacity trending exports
