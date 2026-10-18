<# Application settings persisted per user as JSON. #>

$script:IMDefaultSettings = [ordered]@{
    # General
    Theme                      = 'Dark'          # Dark | Light
    LogLevel                   = 'Info'          # Trace | Debug | Info | Warning | Error
    LogDirectory               = ''              # empty = %APPDATA%\IntuneManager\Logs
    LogRetentionDays           = 30
    GraphApiVersion            = 'beta'          # beta exposes all Intune properties; v1.0 drops many
    # Graph client
    MaxRetries                 = 6
    RequestTimeoutSeconds      = 100
    BatchSize                  = 20
    # Export
    ExportRoot                 = ''
    ExportAssignments          = $true
    AddObjectIdToFileName      = $false
    AddDateFolder              = $true          # Export to <root>\<tenant>\<yyyy-MM-dd_HHmm>
    ExportAppContent           = $false
    ExportSettingsDefinitions  = $false
    # Import
    ImportAssignments          = $true
    ImportScopeTags            = $true
    ReplaceDependencyIds       = $true
    CreateMissingGroups        = $true
    ConflictAction             = 'Skip'          # Skip | Rename | Update | Replace | Duplicate
    RenameSuffix               = ' (Imported)'
    NamePrefix                 = ''
    ContinueOnError            = $true
    # UI
    ShowLogPanel               = $true
    LastProfile                = ''
    LastExportPath             = ''
    LastImportPath             = ''
}

$script:IMSettings = $null

function Get-IMSettingsPath { Join-Path (Get-IMAppDataPath) 'settings.json' }

function Import-IMSettings {
    $settings = [ordered]@{}
    foreach ($k in $script:IMDefaultSettings.Keys) { $settings[$k] = $script:IMDefaultSettings[$k] }
    $path = Get-IMSettingsPath
    if (Test-Path -LiteralPath $path) {
        try {
            $saved = Read-IMJsonFile $path
            foreach ($p in $saved.PSObject.Properties) { if ($settings.Contains($p.Name)) { $settings[$p.Name] = $p.Value } }
        }
        catch { Write-Warning "Settings file '$path' is invalid and was ignored: $($_.Exception.Message)" }
    }
    $script:IMSettings = $settings
    $settings
}

function Save-IMSettings {
    if (-not $script:IMSettings) { return }
    Write-IMJsonFile -Path (Get-IMSettingsPath) -InputObject $script:IMSettings
}

function Get-IMSetting {
    param([Parameter(Mandatory)][string]$Name)
    if (-not $script:IMSettings) { Import-IMSettings | Out-Null }
    if (-not $script:IMSettings.Contains($Name)) { throw "Unknown setting '$Name'" }
    $script:IMSettings[$Name]
}

function Set-IMSetting {
    param([Parameter(Mandatory)][string]$Name, $Value, [switch]$NoSave)
    if (-not $script:IMSettings) { Import-IMSettings | Out-Null }
    if (-not $script:IMDefaultSettings.Contains($Name)) { throw "Unknown setting '$Name'" }
    $script:IMSettings[$Name] = $Value
    if (-not $NoSave) { Save-IMSettings }
}

function Get-IMSettings {
    if (-not $script:IMSettings) { Import-IMSettings | Out-Null }
    $script:IMSettings
}

function Set-IMSettingsSnapshot {
    <# Background runspaces receive the UI's current settings instead of reading the file. #>
    param([System.Collections.IDictionary]$Settings)
    $script:IMSettings = [ordered]@{}
    foreach ($k in $Settings.Keys) { $script:IMSettings[$k] = $Settings[$k] }
}
