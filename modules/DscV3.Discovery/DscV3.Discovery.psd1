@{
    RootModule           = 'DscV3.Discovery.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = 'b8f7a4d2-3e1c-4a8d-9f5b-2c4e6a8f0d11'
    Author               = 'dsc-v3-discovery contributors'
    CompanyName          = 'dsc-v3-discovery'
    Copyright            = '(c) dsc-v3-discovery'
    Description          = 'Class-based DSC v3 resources for Winget, Chocolatey, MSI-from-share, PSResourceGet, and bulk .reg file imports.'
    PowerShellVersion    = '7.2'
    CompatiblePSEditions = @('Core')

    # The class names exported as DSC resources. Loaded via the
    # Microsoft.DSC/PowerShell adapter (`dsc resource list --adapter Microsoft.DSC/PowerShell`).
    DscResourcesToExport = @(
        'WingetPackage'
        'ChocolateyPackage'
        'MsiFromShare'
        'PSResourceInstall'
        'RegFile'
    )

    FunctionsToExport    = @()
    CmdletsToExport      = @()
    AliasesToExport      = @()
    VariablesToExport    = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('DSC', 'DSCv3', 'Windows', 'Registry', 'Winget', 'Chocolatey', 'MSI')
            ProjectUri   = 'https://github.com/example/dsc-v3-discovery'
            LicenseUri   = ''
            ReleaseNotes = 'Initial release.'
        }
    }
}
