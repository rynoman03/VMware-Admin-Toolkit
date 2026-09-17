@{
    ModuleVersion     = '13.0.0'
    RootModule        = 'VCF.PowerCLI.psm1'
    GUID              = '9f1b2c3d-4e5f-6071-8293-a4b5c6d7e8f9'
    Author            = 'VMware-Admin-Toolkit tests'
    Description       = 'Test stub standing in for PowerCLI. Not PowerCLI. See tests/README.md.'
    PowerShellVersion = '5.1'
    # The health check now reads inventory through bulk Get-View calls, so the
    # per-object cmdlets it used to call are gone from both sides.
    # The set of names the manifest ALLOWS. The .psm1 narrows this further at
    # import time - Get-Compliance is only actually exported in the scenario
    # that wants vLCM present, so the health check's Get-Command probe for it
    # is exercised in both states. Export-ModuleMember cannot widen this list,
    # so a name missing here is simply not exported however the .psm1 asks.
    FunctionsToExport = @(
        'Set-PowerCLIConfiguration', 'Connect-VIServer', 'Disconnect-VIServer',
        'Get-View', 'Get-VM', 'Get-Snapshot', 'Get-Compliance'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
