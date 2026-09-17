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
                )
                Vswitch = @(
                    [pscustomobject]@{ Name = 'vSwitch0'; Pnic = @(
                        'key-vim.host.PhysicalNic-vmnic0', 'key-vim.host.PhysicalNic-vmnic1') }
                )
                ProxySwitch = @()
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
            ToolsStatus = 'toolsOk'
            Disk        = @([pscustomobject]@{ DiskPath = 'C:\'; FreeSpace = 64GB; Capacity = 120GB })
        }
        Snapshot = $null
    }
}

function Get-FixtureHostView {
    param($Server)
    switch (Get-FixtureScenario) {
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
            @( New-FixtureHostView -Name 'esx01.fixture.local' -MoRef 'HostSystem-host-1' `
                 -Version '6.7.0' -Build '17167734' -CertDaysValid 10 -NoPasswordSetting -NoStorageDevice )
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
    $vms
}

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

# Still PowerCLI objects, and still ONE bulk call each: Get-VM only so
# Get-Snapshot has something to take, and Get-Snapshot only for snapshot SIZE,
# which the view layout doesn't expose directly.
function Get-VM {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)] $InputObject, $Server)
    process {
        Write-FixtureCall 'Get-VM'
        @(Get-FixtureVmView | ForEach-Object {
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
    @()
}

Export-ModuleMember -Function Set-PowerCLIConfiguration, Connect-VIServer, Disconnect-VIServer,
    Get-View, Get-VM, Get-Snapshot
