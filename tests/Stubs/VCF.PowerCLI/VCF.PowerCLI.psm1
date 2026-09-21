<#
    Test stub standing in for PowerCLI.

    This is NOT PowerCLI. It implements only the handful of cmdlets
    Invoke-VMwareHealthCheck.ps1 calls, returning fixed objects with the
    properties that script reads, so the health check can be run end to end
    without a vCenter. It is deliberately dumb: no vSphere API, no real
    inventory, no attempt at general-purpose fidelity.

    The module is named VCF.PowerCLI so the health check's own module
    detection (Get-Module -ListAvailable) finds it the way it would find the
    real thing. Put tests/Stubs on PSModulePath to activate it.

    $env:HEALTHCHECK_FIXTURE_SCENARIO selects the inventory:
      Healthy      every check passes
      HostDown     one host NotResponding (the rest of its checks must be skipped)
      Degraded     WARN/INFO paths: version skew at the boundary, unparsable
                   hardware version, LUN query failure, absent password setting,
                   expiring certificate
      MultiVCenter two vCenters on different versions, each with its own
                   hosts, so a host mispaired with the wrong vCenter shows up
      ConnectFail  every Connect-VIServer throws

    See tests/README.md.
#>

function Get-FixtureScenario {
    if ($env:HEALTHCHECK_FIXTURE_SCENARIO) { $env:HEALTHCHECK_FIXTURE_SCENARIO } else { 'Healthy' }
}

# PEM bytes in the shape vCenter returns for HostConfigInfo.certificate: a
# byte[] of PEM text, which is why the health check has to decode it rather
# than read .NotAfter directly.
function New-FixtureCertificatePem {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory value for the fixture; changes no system state.')]
    param([int] $DaysValid = 300)

    $notBefore = [DateTimeOffset]::UtcNow.AddDays(-30)
    $notAfter  = [DateTimeOffset]::UtcNow.AddDays($DaysValid)

    # CertificateRequest needs .NET Framework 4.7.2+ (or .NET Core). Where it
    # is missing, on an older Windows PowerShell host, fall back to the PKI
    # module so the fixture still works.
    if ('System.Security.Cryptography.X509Certificates.CertificateRequest' -as [type]) {
        $rsa = [System.Security.Cryptography.RSA]::Create(2048)
        $req = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
            'CN=esx.fixture.local', $rsa,
            [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        $raw = $req.CreateSelfSigned($notBefore, $notAfter).RawData
    } else {
        $made = New-SelfSignedCertificate -Subject 'CN=esx.fixture.local' `
            -CertStoreLocation 'Cert:\CurrentUser\My' `
            -NotBefore $notBefore.LocalDateTime -NotAfter $notAfter.LocalDateTime
        $raw = $made.RawData
        Remove-Item -Path "Cert:\CurrentUser\My\$($made.Thumbprint)" -Force -ErrorAction SilentlyContinue
    }

    $pem = "-----BEGIN CERTIFICATE-----`n" +
           [Convert]::ToBase64String($raw, 'InsertLineBreaks') +
           "`n-----END CERTIFICATE-----`n"
    [System.Text.Encoding]::ASCII.GetBytes($pem)
}

function Set-PowerCLIConfiguration {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '',
        Justification = 'Stub: declares SupportsShouldProcess only so it accepts -Confirm like the real cmdlet does.')]
    [CmdletBinding(SupportsShouldProcess)]
    param($Scope, $InvalidCertificateAction, $ParticipateInCeip)
    # Record the certificate policy the script asked for, so a test can assert
    # that -TrustAllCertificates actually reaches PowerCLI.
    if ($env:HEALTHCHECK_FIXTURE_PROBE) {
        "InvalidCertificateAction=$InvalidCertificateAction" |
            Out-File -FilePath $env:HEALTHCHECK_FIXTURE_PROBE -Encoding utf8
    }
}

# Each fixture vCenter runs its own version, so a host paired with the wrong
# one reports a version mismatch instead of a match.
function Get-FixtureVCenterVersion {
    param([string] $ServerName)
    if ($ServerName -like '*vcenter-b*') {
        [pscustomobject]@{ Version = '7.0.3'; Build = '20395099' }
    } else {
        [pscustomobject]@{ Version = '8.0.2'; Build = '22617221' }
    }
}

function Connect-VIServer {
    [CmdletBinding()]
    param($Server, [System.Management.Automation.PSCredential] $Credential)
    if ((Get-FixtureScenario) -eq 'ConnectFail') {
        throw 'Cannot complete login due to an incorrect user name or password.'
    }
    $v = Get-FixtureVCenterVersion -ServerName $Server
    [pscustomobject]@{ Name = $Server; Version = $v.Version; Build = $v.Build }
}

function Disconnect-VIServer {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '',
        Justification = 'Stub: declares SupportsShouldProcess only so it accepts -Confirm like the real cmdlet does.')]
    [CmdletBinding(SupportsShouldProcess)]
    param($Server)
}

# Real VMware.Vim device classes, so the health check's
# "$_ -is [VMware.Vim.VirtualCdrom]" test is exactly the test that runs in
# production. Modelling these as pscustomobjects would have made the fixture
# agree with a check that could never match a real device.
if (-not ('VMware.Vim.VirtualCdrom' -as [type])) {
    Add-Type -TypeDefinition @'
namespace VMware.Vim {
    public class VirtualDeviceConnectInfo { public bool Connected; public bool StartConnected; }
    public class VirtualDeviceBackingInfo { public string FileName; }
    public class VirtualDevice {
        public int Key;
        public VirtualDeviceConnectInfo Connectable;
        public VirtualDeviceBackingInfo Backing;
    }
    public class VirtualCdrom : VirtualDevice { }
    public class VirtualFloppy : VirtualDevice { }
    public class VirtualDisk   : VirtualDevice { }
}
'@
}

# Records every inventory call when $env:HEALTHCHECK_FIXTURE_CALLLOG is set,
# so a test can assert the health check makes a FIXED number of them rather
# than one per host, per LUN or per VM. Without this, a refactor could quietly
# reintroduce per-object round-trips and every behavioural assertion would
# still pass.
function Write-FixtureCall {
    param([string] $What)
    if ($env:HEALTHCHECK_FIXTURE_CALLLOG) {
        Add-Content -LiteralPath $env:HEALTHCHECK_FIXTURE_CALLLOG -Value $What
    }
}

function New-FixtureDevice {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory object for the fixture; changes no system state.')]
    param([string] $Kind, [string] $FileName, [bool] $Connected, [bool] $StartConnected)
    $d = New-Object "VMware.Vim.$Kind"
    $d.Connectable = New-Object VMware.Vim.VirtualDeviceConnectInfo
    $d.Connectable.Connected      = $Connected
    $d.Connectable.StartConnected = $StartConnected
    if ($FileName) {
        $d.Backing = New-Object VMware.Vim.VirtualDeviceBackingInfo
        $d.Backing.FileName = $FileName
    }
    $d
}

# A HostSystem view in the shape Get-View returns it, carrying every property
# the health check asks for in its -Property list.
function New-FixtureHostView {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory object for the fixture; changes no system state.')]
    param(
        [string] $Name,
        [string] $MoRef,
        [string] $ConnectionState = 'connected',
        [string] $Version = '8.0.2',
        [string] $Build = '22380479',
        [int]    $CertDaysValid = 300,
        [switch] $NoPasswordSetting,
        [switch] $NoStorageDevice
    )

    $options = New-Object System.Collections.Generic.List[object]
    $options.Add([pscustomobject]@{ Key = 'Syslog.global.logHost'; Value = 'udp://syslog.fixture.local:514' })
    if (-not $NoPasswordSetting) {
        $options.Add([pscustomobject]@{ Key = 'Security.PasswordMaxDays'; Value = 90 })
    }

    $storage = $null
    if (-not $NoStorageDevice) {
        $storage = [pscustomobject]@{
            ScsiLun = @(
                [pscustomobject]@{ Key = 'key-vim.host.ScsiDisk-1'; CanonicalName = 'naa.60000000000000000000000000000001'; DeviceType = 'disk' }
                [pscustomobject]@{ Key = 'key-vim.host.ScsiDisk-2'; CanonicalName = 'naa.60000000000000000000000000000002'; DeviceType = 'disk' }
            )
            MultipathInfo = [pscustomobject]@{
                Lun = @(
                    [pscustomobject]@{ Lun = 'key-vim.host.ScsiDisk-1'; Path = @(
                        [pscustomobject]@{ PathState = 'active' }, [pscustomobject]@{ PathState = 'active' }
                        [pscustomobject]@{ PathState = 'active' }, [pscustomobject]@{ PathState = 'active' }) }
                    [pscustomobject]@{ Lun = 'key-vim.host.ScsiDisk-2'; Path = @(
                        [pscustomobject]@{ PathState = 'active' }, [pscustomobject]@{ PathState = 'active' }
                        [pscustomobject]@{ PathState = 'active' }, [pscustomobject]@{ PathState = 'active' }) }
                )
            }
        }
    }

    [pscustomobject]@{
        Name      = $Name
        MoRef     = $MoRef
        Parent    = 'ClusterComputeResource-domain-c1'
        # Degraded also mounts the datastore whose Summary never populates, so
        # the host-side accessibility check actually sees it.
        Datastore = if ((Get-FixtureScenario) -eq 'Degraded') {
            @('Datastore-datastore-1', 'Datastore-datastore-2')
        } else {
            @('Datastore-datastore-1')
        }
        Runtime   = [pscustomobject]@{
            ConnectionState = $ConnectionState
            # A host vCenter can't reach reports no boot time.
            BootTime        = if ($ConnectionState -eq 'connected') { (Get-Date).AddDays(-45) } else { $null }
        }
        Config    = [pscustomobject]@{
            Product       = [pscustomobject]@{ Version = $Version; Build = $Build }
            Certificate   = New-FixtureCertificatePem -DaysValid $CertDaysValid
            LockdownMode  = 'lockdownNormal'
            Service       = [pscustomobject]@{ Service = @(
                [pscustomobject]@{ Key = 'ntpd';           Label = 'NTP Daemon';        Policy = 'on';  Running = $true  }
                [pscustomobject]@{ Key = 'TSM-SSH';        Label = 'SSH';               Policy = 'off'; Running = $false }
                [pscustomobject]@{ Key = 'vpxa';           Label = 'VMware vCenter Agent'; Policy = 'on'; Running = $true }
                [pscustomobject]@{ Key = 'DCUI';           Label = 'Direct Console UI'; Policy = 'on';  Running = $true  }
                # Policy 'off' AND stopped: switched off on purpose, so this
                # must not be reported as a service that is down.
                [pscustomobject]@{ Key = 'snmpd';          Label = 'SNMP Server';       Policy = 'off'; Running = $false }
                # Degraded: a service that IS set to start with the host but
                # isn't running - the case the check exists for.
                [pscustomobject]@{ Key = 'sfcbd-watchdog'; Label = 'CIM Server';        Policy = 'on';
                                   Running = ((Get-FixtureScenario) -ne 'Degraded') }
            ) }
            DateTimeInfo  = [pscustomobject]@{ NtpConfig = [pscustomobject]@{ Server = @('time1.fixture.local', 'time2.fixture.local') } }
            Option        = $options.ToArray()
            StorageDevice = $storage
            Network       = [pscustomobject]@{
                Pnic = @(
                    [pscustomobject]@{ Key = 'key-vim.host.PhysicalNic-vmnic0'; Device = 'vmnic0'; LinkSpeed = [pscustomobject]@{ SpeedMb = 10000 } }
                    # Degraded: an uplink assigned to a switch with no link -
                    # the case the check exists for.
                    [pscustomobject]@{ Key = 'key-vim.host.PhysicalNic-vmnic1'; Device = 'vmnic1'
                                       LinkSpeed = if ((Get-FixtureScenario) -eq 'Degraded') { $null } else { [pscustomobject]@{ SpeedMb = 10000 } } }
                    # Unassigned NIC with no cable: normal, and must NOT be
                    # reported - flagging spare NICs would bury the real one.
                    [pscustomobject]@{ Key = 'key-vim.host.PhysicalNic-vmnic7'; Device = 'vmnic7'; LinkSpeed = $null }
                    # DeadSwitch: both uplinks of a second switch are down, so
                    # that switch's traffic is actually off the network. The
                    # report has to name vmnic4 and vmnic5 - a switch name and
                    # a count is not something anyone can act on.
                    [pscustomobject]@{ Key = 'key-vim.host.PhysicalNic-vmnic4'; Device = 'vmnic4'
                                       LinkSpeed = if ((Get-FixtureScenario) -eq 'DeadSwitch') { $null } else { [pscustomobject]@{ SpeedMb = 10000 } } }
                    [pscustomobject]@{ Key = 'key-vim.host.PhysicalNic-vmnic5'; Device = 'vmnic5'
                                       LinkSpeed = if ((Get-FixtureScenario) -eq 'DeadSwitch') { $null } else { [pscustomobject]@{ SpeedMb = 10000 } } }
                )
                Vswitch = @(
                    [pscustomobject]@{ Name = 'vSwitch0'; Pnic = @(
                        'key-vim.host.PhysicalNic-vmnic0', 'key-vim.host.PhysicalNic-vmnic1') }
                    [pscustomobject]@{ Name = 'vSwitch1'; Pnic = @(
                        'key-vim.host.PhysicalNic-vmnic4', 'key-vim.host.PhysicalNic-vmnic5') }
                )
                # UnresolvedUplink: a switch whose single uplink key has no
                # matching entry in Pnic above. Nothing is known about that
                # uplink's link state - which is NOT the same as knowing it is
                # down, though the check used to report it as exactly that,
                # with a detail reading "0 of 1 uplink(s) up" and no NIC named
                # because none had been resolved to name.
                ProxySwitch = if ((Get-FixtureScenario) -eq 'UnresolvedUplink') {
                    @( [pscustomobject]@{ DvsName = 'DSwitch-Prod'; Pnic = @('key-vim.host.PhysicalNic-vmnic99') } )
                } else { @() }
                DnsConfig   = [pscustomobject]@{ Address = @('10.10.0.5', '10.10.0.6') }
            }
        }
        Summary   = [pscustomobject]@{
            Hardware   = [pscustomobject]@{ CpuMhz = 2500; NumCpuCores = 24; MemorySize = [int64]512 * 1GB }
            QuickStats = [pscustomobject]@{ OverallCpuUsage = 12000; OverallMemoryUsage = 204800 }
        }
    }
}

function New-FixtureVmView {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory object for the fixture; changes no system state.')]
    param(
        [string] $Name,
        [string] $MoRef,
        [string] $HostMoRef = 'HostSystem-host-1',
        [string] $ConnectionState = 'connected',
        [object] $Consolidation = $false,
        [string] $HardwareVersion = 'vmx-19',
        [object] $Snapshot = $null,
        [string] $ToolsStatus = 'toolsOk',
        [switch] $NoUpdateableRuntime
    )
    $runtime = [pscustomobject]@{
        ConnectionState     = $ConnectionState
        ConsolidationNeeded = $Consolidation
        PowerState          = 'poweredOn'
        Host                = $HostMoRef
    }
    [pscustomobject]@{
        Name    = $Name
        MoRef   = $MoRef
        Runtime = $runtime
        Config  = [pscustomobject]@{
            Version        = $HardwareVersion
            GuestFullName  = 'Microsoft Windows Server 2019 (64-bit)'
            Hardware       = [pscustomobject]@{ Device = @(
                # A stale ISO on a DISCONNECTED drive blocks nothing, so it
                # must not be reported as mounted media.
                (New-FixtureDevice -Kind 'VirtualCdrom' -FileName '[DS-FIXTURE-01] iso/installer.iso' -Connected $false -StartConnected $false)
            ) }
        }
        Guest   = [pscustomobject]@{
            ToolsStatus = $ToolsStatus
            Disk        = @([pscustomobject]@{ DiskPath = 'C:\'; FreeSpace = 64GB; Capacity = 120GB })
        }
        Snapshot = $Snapshot
    }
}

# One node of a VM's snapshot tree, shaped the way Snapshot.RootSnapshotList
# comes back: a name, a creation time, and a child list that the script has to
# recurse into to find nested snapshots.
function New-FixtureSnapshotNode {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory object for the fixture; changes no system state.')]
    param(
        [string] $Name,
        [int]    $AgeDays,
        [object[]] $Children = @()
    )
    [pscustomobject]@{
        Name              = $Name
        Snapshot          = "VirtualMachineSnapshot-snapshot-$Name"
        CreateTime        = (Get-Date).AddDays(-$AgeDays)
        ChildSnapshotList = $Children
    }
}

function Get-FixtureHostView {
    param($Server)
    switch (Get-FixtureScenario) {
        'VlcmBaselines' {
            # Three hosts so all three baseline verdicts appear in one run:
            # host-1 non-compliant, host-2 compliant, host-3 never scanned.
            @(
                (New-FixtureHostView -Name 'esx01.fixture.local' -MoRef 'HostSystem-host-1')
                (New-FixtureHostView -Name 'esx02.fixture.local' -MoRef 'HostSystem-host-2')
                (New-FixtureHostView -Name 'esx03.fixture.local' -MoRef 'HostSystem-host-3')
            )
        }
        'HostDown' {
            @(
                (New-FixtureHostView -Name 'esx01.fixture.local' -MoRef 'HostSystem-host-1')
                (New-FixtureHostView -Name 'esx02.fixture.local' -MoRef 'HostSystem-host-2' -ConnectionState 'notResponding')
            )
        }
        'Degraded' {
            # ESXi 6.x under vCenter 8.x is exactly two majors behind: the
            # documented boundary, which is WARN and not FAIL. No storage
            # device data and no password setting, so those checks must report
            # their "couldn't read" paths rather than inventing a result.
            $degraded = @( New-FixtureHostView -Name 'esx01.fixture.local' -MoRef 'HostSystem-host-1' `
                 -Version '6.7.0' -Build '17167734' -CertDaysValid 10 -NoPasswordSetting -NoStorageDevice )
            # A host whose Runtime.ConnectionState never comes back. An empty
            # string is not 'connected', so a bare -ne test reported a running
            # host as FAIL with a detail reading "State is  -".
            $blind = New-FixtureHostView -Name 'esx-blindstate.fixture.local' -MoRef 'HostSystem-host-9'
            $blind.Runtime.ConnectionState = $null
            $degraded += $blind
            $degraded
        }
        'MultiVCenter' {
            $tag = if ($Server -and $Server.Name) { ($Server.Name -split '\.')[0] } else { 'vcenter-a' }
            $v   = Get-FixtureVCenterVersion -ServerName $(if ($Server) { $Server.Name } else { 'vcenter-a' })
            @( New-FixtureHostView -Name "$tag-esx01.fixture.local" -MoRef "HostSystem-$tag-1" -Version $v.Version -Build $v.Build )
        }
        default {
            @(
                (New-FixtureHostView -Name 'esx01.fixture.local' -MoRef 'HostSystem-host-1')
                (New-FixtureHostView -Name 'esx02.fixture.local' -MoRef 'HostSystem-host-2')
            )
        }
    }
}

function Get-FixtureVmView {
    $vms = @( New-FixtureVmView -Name 'app01' -MoRef 'VirtualMachine-vm-101' `
                -HardwareVersion $(if ((Get-FixtureScenario) -eq 'Degraded') { 'unknown' } else { 'vmx-19' }) )

    if ((Get-FixtureScenario) -eq 'Degraded') {
        # A healthy, powered-on VM whose Runtime.ConnectionState and
        # ConsolidationNeeded never come back. A $null that falls through to a
        # FAIL catch-all is what reported running VMs as failed with a blank
        # detail.
        $ghost = New-FixtureVmView -Name 'ghost01' -MoRef 'VirtualMachine-vm-102'
        $ghost.Runtime.ConnectionState     = $null
        $ghost.Runtime.ConsolidationNeeded = $null
        $vms += $ghost
    }

    if ((Get-FixtureScenario) -eq 'StaleToolsBundle') {
        # Most of this host's powered-on VMs report out-of-date Tools, which
        # is the signature of the host's own bundled Tools package being
        # behind - one host to patch instead of N VMs to chase.
        foreach ($n in 1..4) {
            $vms += New-FixtureVmView -Name "stale0$n" -MoRef "VirtualMachine-vm-4$n" -ToolsStatus 'toolsOld'
        }
    }

    if ((Get-FixtureScenario) -eq 'Degraded') {
        # VMware Tools states. 'not installed' is the single most common
        # finding on a real estate, so its severity decides whether the
        # report's critical count means anything.
        $vms += New-FixtureVmView -Name 'notools01' -MoRef 'VirtualMachine-vm-301' -ToolsStatus 'toolsNotInstalled'
        $vms += New-FixtureVmView -Name 'toolsoff01' -MoRef 'VirtualMachine-vm-302' -ToolsStatus 'toolsNotRunning'
        $vms += New-FixtureVmView -Name 'toolsold01' -MoRef 'VirtualMachine-vm-303' -ToolsStatus 'toolsOld'
    }

    # A VM carrying a nested snapshot tree: an old root with a recent child.
    # Exercises the recursive tree walk, the age thresholds on both nodes, and
    # the size lookup - none of which had any coverage while every fixture VM
    # had Snapshot = $null.
    # MultiVCenter deliberately has NO snapshots anywhere, so the suite can
    # assert the other half of the contract: when nothing has a snapshot, the
    # sizing calls do not happen at all.
    if ((Get-FixtureScenario) -ne 'MultiVCenter') {
        # Two roots, one with a child, and two of the three carrying a size:
        # a fixture that returns a single row lets a stub bug that collapses
        # the result set into one object pass unnoticed.
        $vms += New-FixtureVmView -Name 'snapvm01' -MoRef 'VirtualMachine-vm-201' -Snapshot ([pscustomobject]@{
            RootSnapshotList = @(
                New-FixtureSnapshotNode -Name 'before-patching' -AgeDays 45 -Children @(
                    New-FixtureSnapshotNode -Name 'after-patching' -AgeDays 1
                )
                New-FixtureSnapshotNode -Name 'pre-upgrade' -AgeDays 90
            )
        })
    }
    $vms
}

# Snapshot sizes the stub's Get-Snapshot hands back, by snapshot name. Only
# the root has a size here, so the report still has to cope with a snapshot
# whose size it cannot resolve.
$script:FixtureSnapshotSizes = @{ 'before-patching' = 12.5; 'pre-upgrade' = 3.5 }

function Get-FixtureClusterView {
    $clusters = @([pscustomobject]@{
        Name          = 'CL-FIXTURE'
        MoRef         = 'ClusterComputeResource-domain-c1'
        Host          = @('HostSystem-host-1', 'HostSystem-host-2')
        Summary       = [pscustomobject]@{ CurrentEVCModeKey = 'intel-skylake' }
        Configuration = [pscustomobject]@{
            DasConfig = [pscustomobject]@{ Enabled = $true; AdmissionControlEnabled = $true }
            DrsConfig = [pscustomobject]@{ Enabled = $true; DefaultVmBehavior = 'fullyAutomated' }
        }
    })

    if ((Get-FixtureScenario) -eq 'Degraded') {
        # A cluster whose view never populates Summary or Configuration.
        # Treating those $nulls as answers reported EVC as "not configured"
        # and admission control as "Disabled" - findings never established.
        $clusters += [pscustomobject]@{
            Name          = 'CL-BLIND'
            MoRef         = 'ClusterComputeResource-domain-c2'
            Host          = @('HostSystem-host-1')
            Summary       = $null
            Configuration = $null
        }
        # And one where the view IS populated and EVC genuinely is off, so the
        # WARN still fires where it should.
        $clusters += [pscustomobject]@{
            Name          = 'CL-NOEVC'
            MoRef         = 'ClusterComputeResource-domain-c3'
            Host          = @('HostSystem-host-1')
            Summary       = [pscustomobject]@{ CurrentEVCModeKey = $null }
            Configuration = [pscustomobject]@{
                DasConfig = [pscustomobject]@{ Enabled = $true; AdmissionControlEnabled = $false }
                DrsConfig = [pscustomobject]@{ Enabled = $true; DefaultVmBehavior = 'fullyAutomated' }
            }
        }
    }
    $clusters
}

function Get-FixtureDatastoreView {
    $stores = @([pscustomobject]@{
        Name    = 'DS-FIXTURE-01'
        MoRef   = 'Datastore-datastore-1'
        Host    = @([pscustomobject]@{ Key = 'HostSystem-host-1' })
        Summary = [pscustomobject]@{ Accessible = $true; Capacity = [int64]4096 * 1GB; FreeSpace = [int64]1800 * 1GB }
    })
    if ((Get-FixtureScenario) -eq 'Degraded') {
        # Summary absent: '-not $null' is true, so this used to be reported as
        # an inaccessible datastore - a FAIL for a healthy store.
        $stores += [pscustomobject]@{
            Name    = 'DS-NOSUMMARY'
            MoRef   = 'Datastore-datastore-2'
            Host    = @([pscustomobject]@{ Key = 'HostSystem-host-1' })
            Summary = $null
        }
    }
    $stores
}

# The one entry point the health check now uses for inventory. Only the
# -ViewType / -Property / -Id forms the script actually calls are supported;
# an unknown ViewType returns nothing rather than pretending.
function Get-View {
    [CmdletBinding()]
    param(
        [string]   $ViewType,
        [string[]] $Property,
        [object]   $Id,
        $Server
    )

    if ($Id) {
        Write-FixtureCall "Get-View:Id"
        # EnvironmentBrowser lookup: the only -Id call the script makes.
        $eb = [pscustomobject]@{ MoRef = "$Id" }
        $eb | Add-Member -MemberType ScriptMethod -Name QueryConfigOptionDescriptor -Value {
            @(
                [pscustomobject]@{ Key = 'vmx-17' }
                [pscustomobject]@{ Key = 'vmx-19' }
                [pscustomobject]@{ Key = 'vmx-21' }
            )
        } -Force
        return $eb
    }

    Write-FixtureCall "Get-View:$ViewType"
    switch ($ViewType) {
        'HostSystem'             { return (Get-FixtureHostView -Server $Server) }
        'VirtualMachine'         { return (Get-FixtureVmView) }
        'ClusterComputeResource' { return (Get-FixtureClusterView) }
        'Datastore'              { return (Get-FixtureDatastoreView) }
        'ComputeResource'        {
            return @(Get-FixtureClusterView | ForEach-Object {
                [pscustomobject]@{
                    Name               = $_.Name
                    MoRef              = $_.MoRef
                    EnvironmentBrowser = "EnvironmentBrowser-$($_.MoRef)"
                }
            })
        }
        default { return @() }
    }
}

# Still PowerCLI objects: Get-VM only so Get-Snapshot has something to take,
# and Get-Snapshot only for snapshot SIZE, which the view layout doesn't
# expose directly. Both are now expected to be asked ONLY about the VMs that
# actually have snapshots, so -Id is honoured rather than ignored - a stub
# that quietly returned the whole inventory for any argument could not tell a
# scoped call from an unscoped one.
function Get-VM {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline)] $InputObject,
        [string[]] $Id,
        $Server
    )
    process {
        # Logged with its scope, not just its name: the property under test is
        # that the script asks about a handful of VMs rather than all of them,
        # and a bare 'Get-VM' in the log cannot express that.
        # Scope AND server binding are both logged. A MoRef is only unique
        # within one vCenter, so an unqualified Get-VM -Id in a multi-vCenter
        # run can match the wrong vCenter's VM; the test asserts the call
        # carries -Server, which a bare name in the log could not show.
        $scope  = if ($Id) { "scoped:$(@($Id).Count)" } else { 'all' }
        $bound  = if ($Server) { 'server' } else { 'noserver' }
        Write-FixtureCall "Get-VM:$scope`:$bound"
        $wanted = $null
        if ($Id) {
            $wanted = @{}
            foreach ($i in $Id) { $wanted["$i"] = $true }
        }
        @(Get-FixtureVmView | Where-Object { $null -eq $wanted -or $wanted.ContainsKey("$($_.MoRef)") } | ForEach-Object {
            [pscustomobject]@{
                Name          = $_.Name
                ExtensionData = [pscustomobject]@{ MoRef = $_.MoRef }
            }
        })
    }
}

function Get-Snapshot {
    [CmdletBinding()]
    param($VM)
    Write-FixtureCall 'Get-Snapshot'
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($v in @($VM)) {
        $view = @(Get-FixtureVmView | Where-Object { "$($_.MoRef)" -eq "$($v.ExtensionData.MoRef)" })[0]
        if (-not $view -or -not $view.Snapshot) { continue }
        foreach ($node in (Get-FixtureSnapshotFlat -Nodes $view.Snapshot.RootSnapshotList)) {
            if (-not $script:FixtureSnapshotSizes.ContainsKey($node.Name)) { continue }
            $out.Add([pscustomobject]@{
                Name   = $node.Name
                SizeGB = $script:FixtureSnapshotSizes[$node.Name]
                VM     = $v
            })
        }
    }
    # Output the elements, not the collection: ', $out.ToArray()' emits the
    # array as a single object, and @(...) at the call site then wraps it
    # instead of unrolling it - every property read back as an array of all
    # the rows' values at once.
    $out.ToArray()
}

function Get-FixtureSnapshotFlat {
    param([object] $Nodes)
    foreach ($n in @($Nodes)) {
        if (-not $n) { continue }
        $n
        if ($n.ChildSnapshotList) { Get-FixtureSnapshotFlat -Nodes $n.ChildSnapshotList }
    }
}

# vSphere Lifecycle Manager / Update Manager. This ships with PowerCLI but is
# not present in every install, and estates that don't use baselines have
# nothing for it to read - so the health check probes for it with Get-Command
# rather than assuming it. That probe is itself worth testing in both states,
# so the stub only offers Get-Compliance in the scenario that asks for it; in
# every other scenario Get-Command finds nothing, which is the no-vLCM path.
function Get-Compliance {
    [CmdletBinding()]
    param($Entity)
    Write-FixtureCall 'Get-Compliance'
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($e in @($Entity)) {
        $k = "$e"
        # host-1 is behind its patch baseline, host-2 is compliant with both
        # of its own. host-3 has baselines attached that were never scanned.
        switch ($k) {
            'HostSystem-host-1' {
                $out.Add([pscustomobject]@{ Entity = $k; Status = 'NonCompliant'; Baseline = [pscustomobject]@{ Name = 'Critical Host Patches' } })
                $out.Add([pscustomobject]@{ Entity = $k; Status = 'Compliant';    Baseline = [pscustomobject]@{ Name = 'Non-Critical Host Patches' } })
            }
            'HostSystem-host-2' {
                $out.Add([pscustomobject]@{ Entity = $k; Status = 'Compliant'; Baseline = [pscustomobject]@{ Name = 'Critical Host Patches' } })
                $out.Add([pscustomobject]@{ Entity = $k; Status = 'Compliant'; Baseline = [pscustomobject]@{ Name = 'Non-Critical Host Patches' } })
            }
            'HostSystem-host-3' {
                $out.Add([pscustomobject]@{ Entity = $k; Status = 'Unknown'; Baseline = [pscustomobject]@{ Name = 'Critical Host Patches' } })
            }
        }
    }
    # Output the elements, not the collection: ', $out.ToArray()' emits the
    # array as a single object, and @(...) at the call site then wraps it
    # instead of unrolling it - every property read back as an array of all
    # the rows' values at once.
    $out.ToArray()
}

$exported = @(
    'Set-PowerCLIConfiguration', 'Connect-VIServer', 'Disconnect-VIServer',
    'Get-View', 'Get-VM', 'Get-Snapshot'
)
if ((Get-FixtureScenario) -eq 'VlcmBaselines') { $exported += 'Get-Compliance' }
Export-ModuleMember -Function $exported
