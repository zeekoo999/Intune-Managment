#Requires -Version 7.2
<#
  IntuneManager - export, import, compare, copy and document Microsoft Intune / Entra ID configuration.
  Inspired by and file-compatible with IntuneManagement by Mikael Karlsson (MIT).
#>

$script:IMModuleRoot = $PSScriptRoot
$coreFiles = @('Common', 'Logging', 'Settings', 'Graph', 'Auth', 'ObjectTypes', 'Handlers', 'Migration', 'Export', 'Import', 'AppContent', 'Compare', 'Operations', 'Documentation')
foreach ($f in $coreFiles) {
    $p = Join-Path $PSScriptRoot "Core/$f.ps1"
    if (Test-Path -LiteralPath $p) { . $p }
}

# Desktop UI (functions only; WPF assemblies are loaded when Show-IMApp runs)
. (Join-Path $PSScriptRoot 'UI/App.ps1')

Import-IMSettings | Out-Null
Initialize-IMObjectTypes

Export-ModuleMember -Function @(
    'Show-IMApp',
    # Connection
    'Connect-IMTenant', 'Disconnect-IMTenant', 'Get-IMConnection', 'Test-IMConnectionProfile', 'Get-IMPermissionReport',
    'Get-IMConnectionProfile', 'Save-IMConnectionProfile', 'Remove-IMConnectionProfile', 'Get-IMCertificateList',
    'Start-IMDeviceCodeLogin', 'Wait-IMDeviceCodeLogin', 'New-IMAppRegistration',
    # Objects
    'Get-IMObjectType', 'Get-IMObjectList', 'Get-IMObject', 'Invoke-IMGraphRequest', 'Get-IMGraphCollection', 'Invoke-IMGraphBatch',
    # Export / import
    'Export-IMObjects', 'Get-IMImportPlan', 'Import-IMObjects', 'Get-IMFailedFiles',
    # Other operations
    'Compare-IMObjects', 'Compare-IMExports', 'New-IMObjectCopy', 'Remove-IMObjects', 'New-IMDocumentation',
    'Export-IMAppContent', 'Publish-IMWin32AppContent',
    # Settings & logging
    'Get-IMSetting', 'Set-IMSetting', 'Get-IMSettings', 'Initialize-IMLogging', 'Write-IMLog', 'Get-IMLogFilePath'
)
