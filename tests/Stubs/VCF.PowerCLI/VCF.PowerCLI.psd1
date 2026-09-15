@{
    ModuleVersion     = '13.0.0'
    RootModule        = 'VCF.PowerCLI.psm1'
    GUID              = '9f1b2c3d-4e5f-6071-8293-a4b5c6d7e8f9'
    Author            = 'VMware-Admin-Toolkit tests'
    Description       = 'Test stub standing in for PowerCLI. Not PowerCLI. See tests/README.md.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Set-PowerCLIConfiguration', 'Connect-VIServer', 'Disconnect-VIServer',
        'Get-VMHost', 'Get-VMHostService', 'Get-VMHostNtpServer', 'Get-VMHostSysLogServer',
        'Get-AdvancedSetting', 'Get-ScsiLun', 'Get-ScsiLunPath', 'Get-Datastore',
        'Get-VM', 'Get-Snapshot', 'Get-CDDrive', 'Get-FloppyDrive', 'Get-Cluster'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
