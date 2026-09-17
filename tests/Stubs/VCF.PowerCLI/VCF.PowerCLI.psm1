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

function New-FixtureVMHost {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory object for the fixture; changes no system state.')]
    param(
        [string] $Name,
        [string] $ConnectionState = 'Connected',
        [string] $Version = '8.0.2',
        [string] $Build = '22380479',
        [int]    $CertDaysValid = 300
    )
    [pscustomobject]@{
        Name            = $Name
        ConnectionState = $ConnectionState
        Version         = $Version
        Build           = $Build
        # An SSO login puts a second '@' in the Uid - the shape that made
        # parsing the managing server out of it unreliable.
        Uid             = "/VIServer=administrator@vsphere.local@vcenter.fixture.invalid:443/VMHost=HostSystem-host-1/"
        CpuTotalMhz     = 60000
        CpuUsageMhz     = 12000
        MemoryTotalGB   = 512.0
        MemoryUsageGB   = 200.0
        ExtensionData   = [pscustomobject]@{
            Summary = [pscustomobject]@{
                Runtime = [pscustomobject]@{
                    # A NotResponding host reports no boot time.
                    BootTime = if ($ConnectionState -eq 'Connected') { (Get-Date).AddDays(-45) } else { $null }
                }
            }
            Config  = [pscustomobject]@{
                Certificate  = New-FixtureCertificatePem -DaysValid $CertDaysValid
                LockdownMode = 'lockdownNormal'
            }
        }
    }
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

function Get-VMHost {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)] $InputObject, $Server)
    process {
        switch (Get-FixtureScenario) {
            'HostDown' {
                @(
                    (New-FixtureVMHost -Name 'esx01.fixture.local')
                    (New-FixtureVMHost -Name 'esx02.fixture.local' -ConnectionState 'NotResponding')
                )
            }
            'Degraded' {
                # ESXi 6.x under vCenter 8.x is exactly two majors behind: the
                # documented boundary, which is WARN and not FAIL.
                @( New-FixtureVMHost -Name 'esx01.fixture.local' -Version '6.7.0' -Build '17167734' -CertDaysValid 10 )
            }
            'MultiVCenter' {
                # Hosts belong to the connection they were enumerated through,
                # and run that vCenter's version. Pairing a host with the other
                # vCenter turns its PASS into a WARN.
                if ($Server -and $Server.Name) {
                    $tag = ($Server.Name -split '\.')[0]
                    $v   = Get-FixtureVCenterVersion -ServerName $Server.Name
                    @( New-FixtureVMHost -Name "$tag-esx01.fixture.local" -Version $v.Version -Build $v.Build )
                } else {
                    # Pipeline call from the cluster checks, which don't care
                    # which vCenter a host came from.
                    @( New-FixtureVMHost -Name 'esx01.fixture.local' )
                }
            }
            default {
                @(
                    (New-FixtureVMHost -Name 'esx01.fixture.local')
                    (New-FixtureVMHost -Name 'esx02.fixture.local')
                )
            }
        }
    }
}

function Get-VMHostService {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)] $InputObject)
    process {
        @(
            [pscustomobject]@{ Key = 'ntpd';    Running = $true  }
            [pscustomobject]@{ Key = 'TSM-SSH'; Running = $false }
        )
    }
}

function Get-VMHostNtpServer {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)] $InputObject)
    process { @('time1.fixture.local', 'time2.fixture.local') }
}

function Get-VMHostSysLogServer {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)] $InputObject)
    process { @([pscustomobject]@{ Host = 'syslog.fixture.local'; Port = 514 }) }
}

function Get-AdvancedSetting {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)] $InputObject, $Name)
    process {
        # Degraded: the setting is absent. The cmdlet returns nothing rather
        # than erroring, which is what used to read as "aging disabled".
        if ((Get-FixtureScenario) -eq 'Degraded') { return }

        # Only answer for advanced settings that actually exist on ESXi. This
        # stub used to echo back whatever -Name it was handed, which meant a
        # setting name that does not exist on a real host still produced a
        # value here and sailed through CI - exactly how the health check
        # shipped asking for 'Security.PasswordExpirationInDays', which is not
        # a real setting. An unknown name now returns nothing, like the real
        # cmdlet does.
        $known = @{
            'Security.PasswordMaxDays' = 90
        }
        if (-not $known.ContainsKey($Name)) { return }
        [pscustomobject]@{ Name = $Name; Value = $known[$Name] }
    }
}

function Get-ScsiLun {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)] $InputObject, $LunType)
    process {
        if ((Get-FixtureScenario) -eq 'Degraded') {
            Write-Error 'Unable to communicate with the remote host.'
            return
        }
        @(
            [pscustomobject]@{ CanonicalName = 'naa.60000000000000000000000000000001' }
            [pscustomobject]@{ CanonicalName = 'naa.60000000000000000000000000000002' }
        )
    }
}

function Get-ScsiLunPath {
    [CmdletBinding()]
    param($ScsiLun)
    @(
        [pscustomobject]@{ State = 'Active'  }
        [pscustomobject]@{ State = 'Active'  }
        [pscustomobject]@{ State = 'Standby' }
        [pscustomobject]@{ State = 'Standby' }
    )
}

function Get-Datastore {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)] $InputObject, $Server)
    process {
        @([pscustomobject]@{
            Name          = 'DS-FIXTURE-01'
            CapacityGB    = 4096.0
            FreeSpaceGB   = 1800.0
            ExtensionData = [pscustomobject]@{ Summary = [pscustomobject]@{ Accessible = $true } }
        })
    }
}

function Get-VM {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)] $InputObject, $Server)
    process {
        # Degraded: a hardware version matching neither 'vmx-NN' nor a bare
        # number, which used to fall through to PASS.
        $hw = if ((Get-FixtureScenario) -eq 'Degraded') { 'unknown' } else { 'vmx-19' }
        @([pscustomobject]@{
            Name          = 'app01'
            Uid           = '/VIServer=administrator@vsphere.local@vcenter.fixture.invalid:443/VirtualMachine=vm-101/'
            PowerState    = 'PoweredOn'
            HardwareVersion = $hw
            ExtensionData = [pscustomobject]@{
                Runtime = [pscustomobject]@{ ConnectionState = 'connected'; ConsolidationNeeded = $false }
                Guest   = [pscustomobject]@{
                    ToolsStatus = 'toolsOk'
                    Disk        = @([pscustomobject]@{ DiskPath = 'C:\'; FreeSpace = 64GB; Capacity = 120GB })
                }
            }
        })
    }
}

function Get-Snapshot {
    [CmdletBinding()]
    param($VM)
    @()
}

function Get-CDDrive {
    [CmdletBinding()]
    param($VM)
    # A stale IsoPath on a DISCONNECTED drive: blocks nothing, so it must not
    # be reported as mounted media.
    @([pscustomobject]@{
        Parent          = @($VM)[0]
        IsoPath         = '[DS-FIXTURE-01] iso/installer.iso'
        HostDevice      = $null
        RemoteDevice    = $null
        ConnectionState = [pscustomobject]@{ Connected = $false; StartConnected = $false }
    })
}

function Get-FloppyDrive {
    [CmdletBinding()]
    param($VM)
    @()
}

function Get-Cluster {
    [CmdletBinding()]
    param($Server)
    @([pscustomobject]@{
        Name               = 'CL-FIXTURE'
        HAEnabled          = $true
        DrsEnabled         = $true
        DrsAutomationLevel = 'FullyAutomated'
        ExtensionData      = [pscustomobject]@{
            Configuration = [pscustomobject]@{ DasConfig = [pscustomobject]@{ AdmissionControlEnabled = $true } }
            Summary       = [pscustomobject]@{ CurrentEVCModeKey = 'intel-skylake' }
        }
    })
}

Export-ModuleMember -Function Set-PowerCLIConfiguration, Connect-VIServer, Disconnect-VIServer,
    Get-VMHost, Get-VMHostService, Get-VMHostNtpServer, Get-VMHostSysLogServer, Get-AdvancedSetting,
    Get-ScsiLun, Get-ScsiLunPath, Get-Datastore, Get-VM, Get-Snapshot, Get-CDDrive, Get-FloppyDrive,
    Get-Cluster
