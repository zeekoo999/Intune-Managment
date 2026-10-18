#Requires -Version 7.2
<#
  IntuneManager - export, import, compare, copy and document Microsoft Intune / Entra ID configuration.
  Inspired by and file-compatible with IntuneManagement by Mikael Karlsson (MIT).
#>

$script:IMModuleRoot = $PSScriptRoot

# Every file the module needs. Checked up front so a missing file gives a clear message
# instead of "The term '...' is not recognized".
$coreFiles = @('Common', 'Logging', 'Settings', 'Graph', 'Auth', 'ObjectTypes', 'Handlers', 'Migration', 'Export', 'Import', 'AppContent', 'Compare', 'Operations', 'Documentation')
$required = @($coreFiles | ForEach-Object { "Core/$_.ps1" }) + @(
    'Core/Native.cs', 'UI/App.ps1', 'UI/Theme.xaml', 'UI/MainWindow.xaml',
    'UI/Panels/ConnectPanel.xaml', 'UI/Panels/ExportPanel.xaml', 'UI/Panels/ImportPanel.xaml', 'UI/Panels/ComparePanel.xaml',
    'UI/Panels/DocsPanel.xaml', 'UI/Panels/SettingsPanel.xaml', 'UI/Panels/ConfirmPanel.xaml'
)
$missing = @($required | Where-Object { -not [IO.File]::Exists((Join-Path $PSScriptRoot $_)) })
if ($missing.Count) {
    throw ("IntuneManager is incomplete. These files are missing from '$PSScriptRoot':`n  " + ($missing -join "`n  ") +
        "`n`nLikely causes: the zip was not fully extracted (use 'Extract All' instead of opening the zip), a folder was not uploaded or copied, " +
        "or antivirus removed a file (check Windows Security > Protection history). Download and extract the package again.")
}

# Load the source files. If the folder path contains [ ] (wildcards to PowerShell), dot-sourcing by path
# fails, so the file is read and dot-sourced as a scriptblock instead.
$wildcardPath = [Management.Automation.WildcardPattern]::ContainsWildcardCharacters($PSScriptRoot)
foreach ($rel in @($coreFiles | ForEach-Object { "Core/$_.ps1" }) + 'UI/App.ps1') {
    $full = Join-Path $PSScriptRoot $rel
    if ($wildcardPath) { . ([scriptblock]::Create([IO.File]::ReadAllText($full))) }
    else { . $full }   # normal dot-sourcing keeps file names and line numbers in error logs
}

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
