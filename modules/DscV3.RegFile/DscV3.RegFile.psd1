@{
    RootModule           = 'DscV3.RegFile.psm1'
    ModuleVersion        = '0.3.0'
    GUID                 = '1ad49fdc-2ada-40a5-8adc-ca228f6cd69c'
    Author               = 'dsc-fleet contributors'
    CompanyName          = 'dsc-fleet'
    Copyright            = '(c) dsc-fleet'
    Description          = 'Single class-based DSC v3 resource for bulk Windows .reg file imports.'
    PowerShellVersion    = '7.2'
    CompatiblePSEditions = @('Core')

    # The class names exported as DSC resources. Loaded via the
    # Microsoft.DSC/PowerShell adapter (`dsc resource list --adapter Microsoft.DSC/PowerShell`).
    DscResourcesToExport = @('RegFile')

    FunctionsToExport    = @()
    CmdletsToExport      = @()
    AliasesToExport      = @()
    VariablesToExport    = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('DSC', 'DSCv3', 'Windows', 'Registry', 'RegFile')
            ProjectUri   = 'https://github.com/anwather/dsc-fleet'
            LicenseUri   = ''
            ReleaseNotes = '0.3.0: Parser now decodes hex(b)/REG_QWORD, hex(2)/REG_EXPAND_SZ, and hex(7)/REG_MULTI_SZ to typed values (was previously lumped into Binary, which broke comparison and threw on QWord). ExpandString comparison reads the unexpanded literal via .NET to avoid silent expansion. 0.2.0: Renamed from DscV3.Discovery; only RegFile retained. Winget/Choco/MSI/PSResource superseded by Microsoft.WinGet.DSC + PSDscResources.'
        }
    }
}
