@{
    RootModule           = 'IntuneManager.psm1'
    ModuleVersion        = '1.0.0'
    GUID                 = '6f0f7c2a-3d4e-4b8a-9a51-2c7f0e1d9b44'
    Author               = 'IntuneManager contributors'
    Description          = 'Export, import, compare, copy and document Microsoft Intune and Entra ID configuration with Microsoft Graph. Modern WPF desktop app plus cmdlets for automation. File-compatible with IntuneManagement exports.'
    PowerShellVersion    = '7.2'
    CompatiblePSEditions = @('Core')
    FunctionsToExport    = @(
        'Show-IMApp',
        'Connect-IMTenant', 'Disconnect-IMTenant', 'Get-IMConnection', 'Test-IMConnectionProfile', 'Get-IMPermissionReport',
        'Get-IMConnectionProfile', 'Save-IMConnectionProfile', 'Remove-IMConnectionProfile', 'Get-IMCertificateList',
        'Start-IMDeviceCodeLogin', 'Wait-IMDeviceCodeLogin', 'New-IMAppRegistration',
        'Get-IMObjectType', 'Get-IMObjectList', 'Get-IMObject', 'Invoke-IMGraphRequest', 'Get-IMGraphCollection', 'Invoke-IMGraphBatch',
        'Export-IMObjects', 'Get-IMImportPlan', 'Import-IMObjects', 'Get-IMFailedFiles',
        'Compare-IMObjects', 'Compare-IMExports', 'New-IMObjectCopy', 'Remove-IMObjects', 'New-IMDocumentation',
        'Export-IMAppContent', 'Publish-IMWin32AppContent',
        'Get-IMSetting', 'Set-IMSetting', 'Get-IMSettings', 'Initialize-IMLogging', 'Write-IMLog', 'Get-IMLogFilePath'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags       = @('Intune', 'Endpoint', 'Graph', 'Backup', 'Migration', 'EntraID', 'ConditionalAccess')
            LicenseUri = 'https://opensource.org/licenses/MIT'
        }
    }
}
