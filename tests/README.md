# Tests

End-to-end tests for `HealthCheck/Invoke-VMwareHealthCheck.ps1` that run without a vCenter.

```powershell
pwsh -File tests/Invoke-HealthCheckTests.ps1
```

Exits `0` when every assertion passes and `1` otherwise, so it can gate a commit or a CI job.
Pass `-KeepOutput` to keep the generated HTML/CSV reports and console logs for inspection, or
`-ScriptPath` to point the suite at a different copy of the script.

## How it works

`Stubs/VCF.PowerCLI/` is a stand-in for PowerCLI: it implements only the cmdlets the health
check calls, returning fixed objects with the properties that script reads. It is **not**
PowerCLI and makes no attempt at general-purpose fidelity — it exists so the health check can
be run end to end and have its output checked.

The stub is named `VCF.PowerCLI` so the health check's own module detection
(`Get-Module -ListAvailable`) finds it the way it would find the real module. The runner puts
`tests/Stubs` on `PSModulePath`, sets `HEALTHCHECK_FIXTURE_SCENARIO`, runs the script in a
child process, and asserts against the **CSV report** rather than console output, so the tests
check what a consumer of the report actually sees.

## Scenarios

| Scenario | Inventory | Expected exit |
|---|---|---|
| `Healthy` | two connected hosts, everything passing | `0` |
| `HostDown` | one host `NotResponding` | `2` |
| `Degraded` | WARN/INFO paths: version skew at the documented boundary, unparsable hardware version, failed LUN query, absent password setting, expiring certificate | `0` |
| `MultiVCenter` | two vCenters on different versions, each with its own host; no snapshots anywhere | `0` |
| `VlcmBaselines` | three hosts with vLCM patch baselines attached — one non-compliant, one compliant, one never scanned | `0` |
| `ConnectFail` | every `Connect-VIServer` throws | `1` |

`Healthy` is also re-run under several argument sets (`-ExpectedEsxiBuild`,
`-ExpectedVCenterBuild`) to cover the Updates section's build-comparison path.

## What the assertions are for

They are regression tests. Each one covers a check that once reported the wrong result
silently — a false `NORMAL`, a false all-clear, or a row that vanished from the report
altogether — rather than failing visibly.

Every assertion is added only after it has been **watched fail** against a variant of the
script with the fix removed, changing one line so the failure can't be blamed on anything
else. An assertion that passes against both versions tests nothing, and a whole-script
comparison proves less than it appears to: an early attempt at one produced twenty failures
that turned out to be an unrelated crash rather than evidence.

Some assertions count API calls rather than inspect rows. Behavioural assertions alone can't
notice a refactor that quietly reintroduces a per-host or per-LUN round-trip — the report
still comes out right, just slowly — so the call log is asserted on directly.

`MultiVCenter` exists because the host-to-vCenter pairing bug only shows up with more than one
connection; with a single vCenter the old code's fallback masked it, so a single-vCenter
fixture would have passed while the bug was live.

## CI

[`.github/workflows/tests.yml`](../.github/workflows/tests.yml) runs this suite on every push
to `main` and every pull request, across three platforms:

| Job | Why |
|---|---|
| Linux / PowerShell 7 | fast baseline |
| Windows / PowerShell 7 | the platform most of these scripts actually run on |
| Windows / Windows PowerShell 5.1 | the edition the scripts support but that nothing else exercises — parts of the health check are written specifically for it |

Each job also parse-checks every `.ps1` and `.psm1` in the repo, and uploads the generated
reports and console logs as an artifact when a job fails, since a failure confined to one
PowerShell edition is otherwise awkward to reproduce.

A fourth job runs **PSScriptAnalyzer** over the repo at Error and Warning severity, pinned to
a known version so CI cannot go red because the analyzer changed rather than the code.
Configuration lives in [`PSScriptAnalyzerSettings.psd1`](../PSScriptAnalyzerSettings.psd1) at
the repo root, where every exclusion is explained. To run it yourself:

```powershell
Install-Module PSScriptAnalyzer -Scope CurrentUser
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
```

Prefer fixing a finding, or suppressing it at the one site with a justified
`[Diagnostics.CodeAnalysis.SuppressMessageAttribute]`, over adding a repo-wide exclusion.

## Notes

- No vCenter is contacted, but the health check does attempt a TLS handshake against the
  `-VCenter` name to read its certificate. The fixture uses `.invalid` names so this fails
  fast and lands as a `WARN` row.
- `MultiVCenter` is invoked via `-Command` rather than `-File`: `-File` passes arguments as
  plain strings, so a list cannot be passed through it. The other scenarios use `-File`, so
  both halves of that trade-off — described in the script's `.NOTES` — get exercised.
- Adding a check to the health check script does not require touching these tests unless it
  reads a property the stub does not set.
