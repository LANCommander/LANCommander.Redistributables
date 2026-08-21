@{
    RootModule        = 'LANCommander.Redistributables.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'b1f4b1a2-6c3e-4e2d-9a55-2f0d3c8e7a41'
    Author            = 'LANCommander'
    CompanyName       = 'LANCommander'
    Copyright         = '(c) 2026 LANCommander. MIT licensed.'
    Description       = 'Builds LANCommander redistributable import packages (.LCX) and keeps their OptionSchema in sync with upstream configuration files.'
    PowerShellVersion = '7.2'

    FunctionsToExport = @(
        'ConvertTo-OptionSchema'
        'Merge-SchemaOverlay'
        'New-LcxPackage'
        'Test-OptionSchema'
        'Test-LcxPackage'
        'Resolve-UpstreamVersion'
        'Test-RedistributableLicense'
        'Update-OptionSchemaFile'
        'Get-RedistributableDefinition'
        'Export-OptionSchemaFile'
        'Resolve-RedistributablePayload'
        'Invoke-RedistributableBuild'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags       = @('LANCommander', 'Redistributable', 'LCX', 'Packaging')
            LicenseUri = 'https://github.com/LANCommander/LANCommander.Redistributables/blob/main/LICENSE'
            ProjectUri = 'https://github.com/LANCommander/LANCommander.Redistributables'
        }
    }
}
