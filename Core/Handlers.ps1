<#
  Type-specific behaviour ("hooks") used by ObjectTypes.ps1.
  Hook signatures:
    ItemUri     param($Type, $Item)                         -> relative URI used to read one object
    PostList    param($Type, $Items)                        -> filtered/enriched list
    PostGet     param($Type, $Obj)                          -> modify the full object before export
    ExportFiles param($Type, $Obj, $Folder, $BaseName)      -> write extra files next to the JSON
    PreImport   param($Type, $Obj, $Ctx)                    -> modify $Obj; may return @{ Uri; Method; Skip; Reason }
    PostImport  param($Type, $Source, $Created, $Ctx)       -> follow-up calls after create/update
    Assign      param($Type, $Target, $Assignments, $Ctx)   -> custom assignment import (return $true when handled)
    PreUpdate   param($Type, $Obj, $Existing, $Ctx)         -> may return @{ Method; Uri }
    AfterType   param($Type, $Imported, $Ctx)               -> runs once after all objects of a type were imported
#>

#region Shared helpers
function Get-IMBaseFileName {
    param($Type, $Obj)
    $name = Get-IMObjectName $Type $Obj
    $n = Get-IMSafeFileName $name
    if ((Get-IMSetting 'AddObjectIdToFileName') -and $Obj.id) { $n = "$n`_$($Obj.id)" }
    $n
}

function Save-IMBase64File {
    param([string]$Base64, [string]$Path)
    if ([string]::IsNullOrEmpty($Base64)) { return }
    try { [IO.File]::WriteAllBytes($Path, [Convert]::FromBase64String($Base64)) }
    catch { Write-IMLog -Level Warning -Category 'Export' -Message "Could not write '$Path': $($_.Exception.Message)" }
}

function Read-IMSidecarJson {
    <# Original IntuneManagement exports store some settings in '<name>_Settings.json'. #>
    param([string]$File, [string]$Suffix = '_Settings')
    if (-not $File) { return $null }
    $fi = [IO.FileInfo]$File
    $side = Join-Path $fi.DirectoryName ($fi.BaseName + "$Suffix.json")
    if (Test-Path -LiteralPath $side) { Read-IMJsonFile $side }
}

function Remove-IMReadOnlyRecursive {
    <# Removes 'id' and odata noise from nested setting objects. #>
    param($Obj, [string[]]$Names = @('id', 'createdDateTime', 'lastModifiedDateTime'))
    if ($null -eq $Obj) { return }
    if ($Obj -is [array]) { foreach ($i in $Obj) { Remove-IMReadOnlyRecursive $i $Names }; return }
    if ($Obj -isnot [psobject] -or $Obj -is [string] -or $Obj -is [ValueType]) { return }
    Remove-IMProperty $Obj $Names
    foreach ($p in @($Obj.PSObject.Properties)) {
        if ($p.Name -like '*@odata.context' -or $p.Name -like '*@odata.navigationLink' -or $p.Name -like '*@odata.associationLink') { $Obj.PSObject.Properties.Remove($p.Name); continue }
        if ($p.Value -is [psobject] -or $p.Value -is [array]) { Remove-IMReadOnlyRecursive $p.Value $Names }
    }
}

function Get-IMGraphBindUrl {
    <# Rewrites @odata.bind URLs exported from another cloud/tenant to the current Graph endpoint. #>
    param([string]$Url)
    if (-not $Url) { return $Url }
    $Url -replace '^https://[^/]+/(beta|v1\.0)/', "$($script:IMConnection.GraphUrl)/beta/"
}
#endregion

#region Device configuration
function Invoke-IMPostGetDeviceConfiguration {
    param($Type, $Obj)
    # Encrypted OMA-URI values: fetch the plain text value so the export can be imported elsewhere
    foreach ($oma in @($Obj.omaSettings | Where-Object { $_.isEncrypted -eq $true -and $_.secretReferenceValueId })) {
        try {
            $plain = Invoke-IMGraphRequest -Uri "/deviceManagement/deviceConfigurations/$($Obj.id)/getOmaSettingPlainTextValue(secretReferenceValueId='$($oma.secretReferenceValueId)')"
            if ($null -ne $plain.value) {
                $oma.isEncrypted = $false; $oma.secretReferenceValueId = $null
                if ($oma.'@odata.type' -eq '#microsoft.graph.omaSettingStringXml' -or (Get-IMPropertyValue $oma 'value@odata.type') -eq '#Binary') {
                    $oma.value = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($plain.value))
                }
                else { $oma.value = $plain.value }
            }
        }
        catch { Write-IMLog -Level Warning -Category 'Export' -Message "Could not decrypt OMA setting '$($oma.displayName)' in '$($Obj.displayName)'. It will be exported encrypted and cannot be imported to another tenant." -ErrorRecord $_ }
    }
}

function Invoke-IMPreImportDeviceConfiguration {
    param($Type, $Obj, $Ctx)
    $Ctx.State.PrivacyAccessControls = $Obj.privacyAccessControls
    Remove-IMProperty $Obj 'privacyAccessControls'
    foreach ($oma in @($Obj.omaSettings)) { Remove-IMProperty $oma 'secretReferenceValueId' }
    if (@($Obj.omaSettings | Where-Object isEncrypted -eq $true).Count) {
        Write-IMLog -Level Warning -Category 'Import' -Message "'$($Obj.displayName)' contains encrypted OMA-URI values from the source tenant. They will be imported but will not decrypt correctly."
    }
}

function Invoke-IMPostImportDeviceConfiguration {
    param($Type, $Source, $Created, $Ctx)
    $pac = $Ctx.State.PrivacyAccessControls
    if ($Created.'@odata.type' -like '*windows10GeneralConfiguration' -and @($pac).Count -gt 0) {
        Invoke-IMGraphRequest -Method POST -Uri "/deviceManagement/deviceConfigurations('$($Created.id)')/windowsPrivacyAccessControls" -Body @{ windowsPrivacyAccessControls = @($pac) } | Out-Null
    }
}
#endregion

#region Settings catalog / inventory / compliance v2
function Invoke-IMPreImportSettingsCatalog {
    param($Type, $Obj, $Ctx)
    Remove-IMProperty $Obj @('settingCount', 'creationSource', 'isAssigned', 'priorityMetaData', 'createdDateTime', 'lastModifiedDateTime')
    if ($Obj.templateReference) {
        $tr = $Obj.templateReference
        Remove-IMProperty $tr @('templateDisplayName', 'templateDisplayVersion', 'templateFamily')
        if ($tr.templateId -and $tr.templateId -ne '') {
            # Template GUIDs are case sensitive; some exports differ in casing from the live template
            try {
                $tid = $tr.templateId
                $templateIds = Get-IMCached "sctemplate:$tid" {
                    $st = Get-IMGraphCollection "/deviceManagement/configurationPolicyTemplates('$tid')/settingTemplates?`$expand=settingDefinitions&`$top=1000"
                    $json = ConvertTo-IMJson $st -Compress
                    @([regex]::Matches($json, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}') | ForEach-Object Value | Select-Object -Unique)
                }
                if ($templateIds) {
                    $lookup = @{}
                    foreach ($g in $templateIds) { $lookup[$g.ToLowerInvariant()] = $g }
                    $settingsJson = ConvertTo-IMJson $Obj.settings -Compress
                    $fixed = [regex]::Replace($settingsJson, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}', {
                        param($m) $k = $m.Value.ToLowerInvariant(); if ($lookup.ContainsKey($k)) { $lookup[$k] } else { $m.Value } })
                    if ($fixed -cne $settingsJson) {
                        $Obj.settings = ConvertFrom-IMJson $fixed
                        Write-IMLog -Level Debug -Category 'Import' -Message "Corrected template id casing in '$($Obj.name)'"
                    }
                }
            }
            catch { Write-IMLog -Level Warning -Category 'Import' -Message "Could not verify template '$($tr.templateId)' for '$($Obj.name)'. Import may fail if the template is retired." -ErrorRecord $_ }
        }
    }
    foreach ($s in @($Obj.settings)) { Remove-IMProperty $s @('id', 'settingDefinitions') }
}

function Invoke-IMPreUpdateSettingsCatalog { param($Type, $Obj, $Existing, $Ctx) @{ Method = 'PUT' } }

function Invoke-IMPreImportCompliancePoliciesV2 {
    param($Type, $Obj, $Ctx)
    Invoke-IMPreImportSettingsCatalog $Type $Obj $Ctx
    foreach ($r in @($Obj.scheduledActionsForRule)) {
        Remove-IMProperty $r @('id')
        foreach ($c in @($r.scheduledActionConfigurations)) { Remove-IMProperty $c @('id') }
    }
}
#endregion

#region Compliance policies
function Invoke-IMPostGetCompliancePolicies {
    param($Type, $Obj)
    if (-not (Test-IMProperty $Obj 'scheduledActionsForRule')) {
        $r = Invoke-IMGraphRequest -Uri "/deviceManagement/deviceCompliancePolicies/$($Obj.id)/scheduledActionsForRule?`$expand=scheduledActionConfigurations"
        Set-IMProperty $Obj 'scheduledActionsForRule' @($r.value)
    }
}

function Get-IMComplianceGroupReferences {
    param($Obj)
    foreach ($r in @($Obj.scheduledActionsForRule)) { foreach ($c in @($r.scheduledActionConfigurations)) { foreach ($g in @($c.notificationMessageCCList)) { if ($g) { $g } } } }
}

function Invoke-IMPreImportCompliancePolicies {
    param($Type, $Obj, $Ctx)
    # Create requires at least the block rule; strip ids
    if (-not $Obj.scheduledActionsForRule) {
        Set-IMProperty $Obj 'scheduledActionsForRule' @([pscustomobject]@{ ruleName = 'PasswordRequired'; scheduledActionConfigurations = @([pscustomobject]@{ actionType = 'block'; gracePeriodHours = 0; notificationTemplateId = ''; notificationMessageCCList = @() }) })
    }
    foreach ($r in @($Obj.scheduledActionsForRule)) {
        Remove-IMProperty $r @('id')
        foreach ($c in @($r.scheduledActionConfigurations)) { Remove-IMProperty $c @('id') }
    }
}

function Invoke-IMPreUpdateCompliancePolicies {
    param($Type, $Obj, $Existing, $Ctx)
    if ($Obj.scheduledActionsForRule) {
        Invoke-IMGraphRequest -Method POST -Uri "/deviceManagement/deviceCompliancePolicies/$($Existing.id)/scheduleActionsForRules" -Body @{ deviceComplianceScheduledActionForRules = @($Obj.scheduledActionsForRule) } | Out-Null
    }
    Remove-IMProperty $Obj 'scheduledActionsForRule'
}
#endregion

#region Endpoint security (intents)
function Invoke-IMPostGetEndpointSecurity {
    param($Type, $Obj)
    $settings = Get-IMGraphCollection "/deviceManagement/intents/$($Obj.id)/settings"
    Set-IMProperty $Obj 'settings' @($settings)
    try {
        $tpl = Get-IMCached "intenttemplate:$($Obj.templateId)" { Invoke-IMGraphRequest -Uri "/deviceManagement/templates/$($Obj.templateId)" -IgnoreNotFound }
        if ($tpl) { Set-IMProperty $Obj '#TemplateInfo' ([pscustomobject]@{ displayName = $tpl.displayName; templateType = $tpl.templateType; versionInfo = $tpl.versionInfo; isDeprecated = $tpl.isDeprecated }) }
    } catch { }
}

function Invoke-IMPreImportEndpointSecurity {
    param($Type, $Obj, $Ctx)
    $settings = $Obj.settings
    if (-not $settings) { $settings = (Read-IMSidecarJson $Ctx.File).settings }
    $settings = @($settings | Where-Object { $_ })
    Remove-IMReadOnlyRecursive $settings @('id')
    $Ctx.State.Settings = $settings
    if (-not $Obj.templateId) { return @{ Skip = $true; Reason = 'The export has no templateId.' } }
    $tpl = Get-IMCached "intenttemplate:$($Obj.templateId)" { Invoke-IMGraphRequest -Uri "/deviceManagement/templates/$($Obj.templateId)" -IgnoreNotFound }
    if (-not $tpl) { return @{ Skip = $true; Reason = "Template $($Obj.templateId) does not exist in this tenant (retired template). Recreate it as a Settings catalog policy." } }
    if ($tpl.isDeprecated) { $Ctx.Warnings.Add("Template '$($tpl.displayName)' is deprecated.") }
    if ($Ctx.Mode -eq 'Update') {
        # PATCH only the basics; settings are written by PreUpdate
        foreach ($n in @($Obj.PSObject.Properties.Name | Where-Object { $_ -notin 'displayName', 'description', 'roleScopeTagIds', '@odata.type' })) { Remove-IMProperty $Obj $n }
        return
    }
    $body = [ordered]@{ displayName = $Obj.displayName; description = $Obj.description; roleScopeTagIds = @($Obj.roleScopeTagIds ?? @('0')); settingsDelta = $settings }
    @{ Uri = "/deviceManagement/templates/$($Obj.templateId)/createInstance"; Method = 'POST'; Body = $body }
}

function Invoke-IMPreUpdateEndpointSecurity {
    param($Type, $Obj, $Existing, $Ctx)
    if ($Ctx.State.Settings.Count) {
        Invoke-IMGraphRequest -Method POST -Uri "/deviceManagement/intents/$($Existing.id)/updateSettings" -Body @{ settings = @($Ctx.State.Settings) } | Out-Null
    }
}
#endregion

#region Administrative templates
function Get-IMAdminTemplateSettings {
    param($Obj)
    $values = @(Get-IMGraphCollection "/deviceManagement/groupPolicyConfigurations/$($Obj.id)/definitionValues?`$expand=definition")
    if (-not $values.Count) { return @() }
    # Presentation values for all settings in batches instead of one call per setting
    $reqs = for ($i = 0; $i -lt $values.Count; $i++) {
        [pscustomobject]@{ id = "$i"; method = 'GET'; url = "/deviceManagement/groupPolicyConfigurations/$($Obj.id)/definitionValues/$($values[$i].id)/presentationValues?`$expand=presentation" }
    }
    $batch = Invoke-IMGraphBatch -Requests $reqs
    $graphBase = "$($script:IMConnection.GraphUrl)/beta"
    for ($i = 0; $i -lt $values.Count; $i++) {
        $dv = $values[$i]
        $s = [ordered]@{ enabled = $dv.enabled; 'definition@odata.bind' = "$graphBase/deviceManagement/groupPolicyDefinitions('$($dv.definition.id)')" }
        $s['#Definition_Id'] = $dv.definition.id
        $s['#Definition_displayName'] = $dv.definition.displayName
        $s['#Definition_classType'] = $dv.definition.classType
        $s['#Definition_categoryPath'] = $dv.definition.categoryPath
        $pv = @($batch["$i"].Body.value)
        if ($batch["$i"].Status -ge 400) { Write-IMLog -Level Warning -Category 'Export' -Message "Could not read presentation values for '$($dv.definition.displayName)': $($batch["$i"].Error)" }
        if ($pv.Count) {
            $s.presentationValues = @(foreach ($p in $pv) {
                Set-IMProperty $p 'presentation@odata.bind' "$graphBase/deviceManagement/groupPolicyDefinitions('$($dv.definition.id)')/presentations('$($p.presentation.id)')"
                Set-IMProperty $p '#Presentation_Id' $p.presentation.id
                Set-IMProperty $p '#Presentation_Label' $p.presentation.label
                Remove-IMProperty $p @('presentation', 'id', 'lastModifiedDateTime', 'createdDateTime')
                $p
            })
        }
        [pscustomobject]$s
    }
}

function Invoke-IMPostGetAdministrativeTemplates {
    param($Type, $Obj)
    Set-IMProperty $Obj 'definitionValues' @(Get-IMAdminTemplateSettings $Obj)
}

function Invoke-IMPreImportAdministrativeTemplates {
    param($Type, $Obj, $Ctx)
    $settings = $Obj.definitionValues
    if (-not $settings) { $settings = Read-IMSidecarJson $Ctx.File }
    $Ctx.State.DefinitionValues = @($settings)
    Remove-IMProperty $Obj @('definitionValues', 'policyConfigurationIngestionType')
}

function Resolve-IMAdminTemplateSettings {
    param($Settings)
    $hasCustom = @($Settings | Where-Object { $_.'#Definition_categoryPath' -and $_.'definition@odata.bind' -and ($_.'#Definition_Id') }) | Where-Object { $_ }
    $customDefs = $null
    $out = foreach ($s in $Settings) {
        $s = Copy-IMObject $s
        $s.'definition@odata.bind' = Get-IMGraphBindUrl $s.'definition@odata.bind'
        foreach ($p in @($s.presentationValues)) { if ($p) { $p.'presentation@odata.bind' = Get-IMGraphBindUrl $p.'presentation@odata.bind' } }

        # Does the definition exist in this tenant? Built-in ADMX ids are the same everywhere; custom (ingested) ones differ.
        $defId = $s.'#Definition_Id'
        if ($defId) {
            $exists = Get-IMCached "gpdef:$defId" { [bool](Invoke-IMGraphRequest -Uri "/deviceManagement/groupPolicyDefinitions('$defId')?`$select=id" -IgnoreNotFound -NoLog) }
            if (-not $exists) {
                if (-not $customDefs) {
                    $customDefs = Get-IMCached 'gpcustomdefs' {
                        $map = @{}
                        foreach ($cat in (Get-IMGraphCollection "/deviceManagement/groupPolicyCategories?`$expand=definitions(`$select=id,displayName,categoryPath,classType)&`$select=id,displayName&`$filter=ingestionSource eq 'custom'")) {
                            foreach ($d in @($cat.definitions)) { $map[("$($d.displayName)|$($d.categoryPath)|$($d.classType)").ToLowerInvariant()] = $d.id }
                        }
                        $map
                    }
                }
                $key = ("$($s.'#Definition_displayName')|$($s.'#Definition_categoryPath')|$($s.'#Definition_classType')").ToLowerInvariant()
                $newId = $customDefs[$key]
                if (-not $newId) {
                    Write-IMLog -Level Warning -Category 'Import' -Message "Setting '$($s.'#Definition_displayName')' ($($s.'#Definition_categoryPath')) was not found in this tenant. Import the ADMX file first. The setting is skipped."
                    continue
                }
                $s.'definition@odata.bind' = $s.'definition@odata.bind' -replace [regex]::Escape($defId), $newId
                if (@($s.presentationValues).Count) {
                    $pres = @(Get-IMGraphCollection "/deviceManagement/groupPolicyDefinitions('$newId')/presentations")
                    foreach ($p in @($s.presentationValues)) {
                        $match = $pres | Where-Object label -eq $p.'#Presentation_Label' | Select-Object -First 1
                        if ($match) { $p.'presentation@odata.bind' = "$($script:IMConnection.GraphUrl)/beta/deviceManagement/groupPolicyDefinitions('$newId')/presentations('$($match.id)')" }
                        else { Write-IMLog -Level Warning -Category 'Import' -Message "Presentation '$($p.'#Presentation_Label')' not found for '$($s.'#Definition_displayName')'." }
                    }
                }
            }
        }
        foreach ($n in @($s.PSObject.Properties.Name | Where-Object { $_ -like '#*' })) { Remove-IMProperty $s $n }
        foreach ($p in @($s.presentationValues)) {
            if ($p) { foreach ($n in @($p.PSObject.Properties.Name | Where-Object { $_ -like '#*' -or $_ -in 'id', 'lastModifiedDateTime', 'createdDateTime' })) { Remove-IMProperty $p $n } }
        }
        Remove-IMProperty $s @('id', 'createdDateTime', 'lastModifiedDateTime')
        $s
    }
    @($out)
}

function Invoke-IMPostImportAdministrativeTemplates {
    param($Type, $Source, $Created, $Ctx)
    $settings = @($Ctx.State.DefinitionValues | Where-Object { $_ })
    if (-not $settings.Count) { return }
    $resolved = Resolve-IMAdminTemplateSettings $settings
    if (-not $resolved.Count) { return }
    if ($Ctx.Mode -eq 'Update') {
        # Remove existing values first so the result matches the export
        $existing = @(Get-IMGraphCollection "/deviceManagement/groupPolicyConfigurations/$($Created.id)/definitionValues")
        if ($existing.Count) { Invoke-IMGraphRequest -Method POST -Uri "/deviceManagement/groupPolicyConfigurations/$($Created.id)/updateDefinitionValues" -Body @{ added = @(); updated = @(); deletedIds = @($existing.id) } | Out-Null }
    }
    # One call for all settings
    Invoke-IMGraphRequest -Method POST -Uri "/deviceManagement/groupPolicyConfigurations/$($Created.id)/updateDefinitionValues" -Body @{ added = @($resolved); updated = @(); deletedIds = @() } | Out-Null
    Write-IMLog -Level Debug -Category 'Import' -Message "Imported $($resolved.Count) setting(s) into '$($Created.displayName)'"
}
#endregion

#region ADMX files
function Invoke-IMPreImportADMXFiles {
    param($Type, $Obj, $Ctx)
    if (-not $Obj.content) {
        # Content may be next to the export as the original .admx/.adml
        $folder = Split-Path $Ctx.File
        $admx = Join-Path $folder $Obj.fileName
        if (Test-Path -LiteralPath $admx) { Set-IMProperty $Obj 'content' ([Convert]::ToBase64String([IO.File]::ReadAllBytes($admx))) }
        else { return @{ Skip = $true; Reason = "The ADMX content is not in the export and '$($Obj.fileName)' was not found in the export folder." } }
    }
    # Already ingested?
    $existing = Get-IMGraphCollection "/deviceManagement/groupPolicyUploadedDefinitionFiles?`$select=id,fileName,status"
    if ($existing | Where-Object fileName -eq $Obj.fileName) { return @{ Skip = $true; Reason = 'An ADMX file with this name is already uploaded.'; ExistingId = ($existing | Where-Object fileName -eq $Obj.fileName | Select-Object -First 1).id } }
    $langs = @(foreach ($l in @($Obj.groupPolicyUploadedLanguageFiles)) { if ($l) { [ordered]@{ fileName = $l.fileName; languageCode = $l.languageCode; content = $l.content } } })
    $body = [ordered]@{ fileName = $Obj.fileName; content = $Obj.content; defaultLanguageCode = $Obj.defaultLanguageCode ?? 'en-US'; groupPolicyUploadedLanguageFiles = $langs }
    @{ Body = $body }
}

function Invoke-IMPostImportADMXFiles {
    param($Type, $Source, $Created, $Ctx)
    # Ingestion is asynchronous. Wait so dependent Administrative Templates can find the definitions.
    $deadline = (Get-Date).AddMinutes(3)
    while ((Get-Date) -lt $deadline) {
        $f = Invoke-IMGraphRequest -Uri "/deviceManagement/groupPolicyUploadedDefinitionFiles/$($Created.id)?`$select=id,status" -IgnoreNotFound
        if ($f.status -eq 'available') { Clear-IMCache; return }
        if ($f.status -like '*Failed*') { throw "ADMX ingestion failed with status '$($f.status)'. Check that all dependent ADMX files (for example Windows.admx) are uploaded first." }
        Start-Sleep -Seconds 5
    }
    Write-IMLog -Level Warning -Category 'Import' -Message "ADMX '$($Source.fileName)' is still processing; dependent settings may be skipped."
}
#endregion

#region Scripts
function Export-IMScriptFile {
    param($Obj, $Folder, $BaseName, [string]$Property = 'scriptContent', [string]$Extension)
    $content = Get-IMPropertyValue $Obj $Property
    if (-not $content) { return }
    $ext = $Extension ?? ([IO.Path]::GetExtension($Obj.fileName ?? '') ?? '.ps1')
    if (-not $ext) { $ext = '.ps1' }
    Save-IMBase64File $content (Join-Path $Folder "$BaseName$ext")
}

function Invoke-IMExportFilesScript { param($Type, $Obj, $Folder, $BaseName) Export-IMScriptFile $Obj $Folder $BaseName 'scriptContent' }
function Invoke-IMExportFilesShellScript { param($Type, $Obj, $Folder, $BaseName) Export-IMScriptFile $Obj $Folder $BaseName 'scriptContent' '.sh' }

function Invoke-IMExportFilesHealthScript {
    param($Type, $Obj, $Folder, $BaseName)
    Export-IMScriptFile $Obj $Folder "${BaseName}_Detection" 'detectionScriptContent' '.ps1'
    Export-IMScriptFile $Obj $Folder "${BaseName}_Remediation" 'remediationScriptContent' '.ps1'
}

function Invoke-IMExportFilesComplianceScript { param($Type, $Obj, $Folder, $BaseName) Export-IMScriptFile $Obj $Folder $BaseName 'detectionScriptContent' '.ps1' }

function Invoke-IMPostListHealthScripts { param($Type, $Items) @($Items | Where-Object { $_.isGlobalScript -ne $true }) }

function Invoke-IMPreImportHealthScripts {
    param($Type, $Obj, $Ctx)
    if ($Obj.isGlobalScript) { return @{ Skip = $true; Reason = 'Microsoft-provided remediation scripts cannot be imported.' } }
    Remove-IMProperty $Obj @('version', 'isGlobalScript', 'highestAvailableVersion', 'deviceHealthScriptType')
}

function Invoke-IMPostImportComplianceScripts {
    param($Type, $Source, $Created, $Ctx)
    # Compliance scripts take a moment before they can be referenced by a compliance policy
    for ($i = 0; $i -lt 12; $i++) {
        if (Invoke-IMGraphRequest -Uri "$($Type.Api)/$($Created.id)?`$select=id" -IgnoreNotFound -NoLog) { return }
        Start-Sleep -Seconds 5
    }
    Write-IMLog -Level Warning -Category 'Import' -Message "Compliance script '$($Created.displayName)' is not yet readable; dependent compliance policies may fail."
}
#endregion

#region Applications
$script:IMNonImportableApps = @('#microsoft.graph.iosVppApp', '#microsoft.graph.macOsVppApp', '#microsoft.graph.androidManagedStoreApp', '#microsoft.graph.androidManagedStoreWebApp',
    '#microsoft.graph.microsoftStoreForBusinessApp', '#microsoft.graph.androidForWorkApp', '#microsoft.graph.windowsStoreForBusinessApp', '#microsoft.graph.managedAndroidStoreApp', '#microsoft.graph.managedIOSStoreApp')

function Invoke-IMPostGetApplications {
    param($Type, $Obj)
    # Relationships (dependencies / supersedence) are needed to rebuild them after import
    try {
        $rel = @(Get-IMGraphCollection "/deviceAppManagement/mobileApps/$($Obj.id)/relationships")
        if ($rel.Count) { Set-IMProperty $Obj '#Relationships' @($rel | Where-Object { $_.sourceId -eq $Obj.id -or -not $_.sourceId }) }
    } catch { }
}

function Invoke-IMExportFilesApplications {
    param($Type, $Obj, $Folder, $BaseName)
    foreach ($r in @($Obj.detectionRules | Where-Object { $_.'@odata.type' -like '*PowerShellScriptDetection' })) { Save-IMBase64File $r.scriptContent (Join-Path $Folder "${BaseName}_DetectionScript.ps1") }
    foreach ($r in @($Obj.rules | Where-Object { $_.'@odata.type' -like '*PowerShellScriptRule' -and $_.ruleType -eq 'detection' })) { Save-IMBase64File $r.scriptContent (Join-Path $Folder "${BaseName}_DetectionScript.ps1") }
    $i = 0
    foreach ($r in @($Obj.requirementRules | Where-Object { $_.'@odata.type' -like '*PowerShellScriptRequirement' })) { $i++; Save-IMBase64File $r.scriptContent (Join-Path $Folder "${BaseName}_RequirementScript$i.ps1") }
    if ((Get-IMSetting 'ExportAppContent') -and $Obj.'@odata.type' -eq '#microsoft.graph.win32LobApp') {
        try { Export-IMAppContent -App $Obj -Folder $Folder -BaseName $BaseName }
        catch { Write-IMLog -Level Warning -Category 'Export' -Message "App content for '$($Obj.displayName)' was not downloaded" -ErrorRecord $_ }
    }
}

function Invoke-IMPreImportApplications {
    param($Type, $Obj, $Ctx)
    if ($Obj.'@odata.type' -in $script:IMNonImportableApps) {
        return @{ Skip = $true; Reason = "$(Get-IMODataTypeName $Obj) apps are synced from a store/token and cannot be created with Graph." }
    }
    $Ctx.State.Relationships = $Obj.'#Relationships'
    Remove-IMProperty $Obj @('#Relationships', 'largeIcon@odata.mediaContentType')
    # LOB apps without uploaded content stay in 'notPublished' state
    if ($Obj.'@odata.type' -match 'LobApp|win32|AppX|msi' -and $Obj.'@odata.type' -notlike '*Store*') { $Ctx.State.NeedsContent = $true }
}

function Invoke-IMPostImportApplications {
    param($Type, $Source, $Created, $Ctx)
    if ($Ctx.State.NeedsContent -and $Ctx.Mode -ne 'Update') {
        $pkg = Find-IMAppPackage -App $Source -File $Ctx.File
        if ($pkg -and $Created.'@odata.type' -eq '#microsoft.graph.win32LobApp') {
            Publish-IMWin32AppContent -AppId $Created.id -PackagePath $pkg -Operation $Ctx.Operation
        }
        else {
            $Ctx.Warnings.Add('App created without content. Upload the package in Intune, or place the .intunewin next to the export file and import again.')
        }
    }
    if ($Ctx.State.Relationships) {
        $Ctx.TypeState.Relationships += @([pscustomobject]@{ NewId = $Created.id; Relationships = $Ctx.State.Relationships; Name = $Created.displayName })
    }
}

function Invoke-IMAfterTypeApplications {
    param($Type, $Imported, $Ctx)
    foreach ($entry in @($Ctx.TypeState.Relationships)) {
        if (-not $entry) { continue }
        $rels = foreach ($r in @($entry.Relationships)) {
            $target = Resolve-IMMappedId -Ctx $Ctx -Id $r.targetId
            if (-not $target) { Write-IMLog -Level Warning -Category 'Import' -Message "App '$($entry.Name)': related app $($r.targetDisplayName) was not imported; relationship skipped."; continue }
            $o = [ordered]@{ '@odata.type' = $r.'@odata.type'; targetId = $target }
            if ($r.dependencyType) { $o.dependencyType = $r.dependencyType }
            if ($r.supersedenceType) { $o.supersedenceType = $r.supersedenceType }
            $o
        }
        if (@($rels).Count) {
            try {
                Invoke-IMGraphRequest -Method POST -Uri "/deviceAppManagement/mobileApps/$($entry.NewId)/updateRelationships" -Body @{ relationships = @($rels) } | Out-Null
                Write-IMLog -Category 'Import' -Message "Restored $(@($rels).Count) relationship(s) for '$($entry.Name)'"
            }
            catch { Write-IMLog -Level Warning -Category 'Import' -Message "Could not restore relationships for '$($entry.Name)'" -ErrorRecord $_ }
        }
    }
}
#endregion

#region App protection & managed app configuration
$script:IMAppProtectionClasses = @{
    'iosManagedAppProtection'                    = 'iosManagedAppProtections'
    'androidManagedAppProtection'                = 'androidManagedAppProtections'
    'windowsManagedAppProtection'                = 'windowsManagedAppProtections'
    'mdmWindowsInformationProtectionPolicy'      = 'mdmWindowsInformationProtectionPolicies'
    'windowsInformationProtectionPolicy'         = 'windowsInformationProtectionPolicies'
    'targetedManagedAppConfiguration'            = 'targetedManagedAppConfigurations'
}

function Get-IMAppProtectionCollection {
    param($Obj)
    $t = Get-IMODataTypeName $Obj
    if (-not $t -or -not $script:IMAppProtectionClasses.ContainsKey($t)) { return $null }
    "/deviceAppManagement/$($script:IMAppProtectionClasses[$t])"
}

function Get-IMItemUriAppProtection {
    param($Type, $Item)
    $col = Get-IMAppProtectionCollection $Item
    if (-not $col) { return "$($Type.Api)/$($Item.id)" }
    $expand = if ($col -like '*InformationProtection*') { 'assignments,protectedAppLockerFiles,exemptAppLockerFiles' } else { 'apps,assignments' }
    "$col/$($Item.id)?`$expand=$expand"
}

function Invoke-IMPostListAppProtection {
    param($Type, $Items)
    @($Items | Where-Object { $_.'@odata.type' -ne '#microsoft.graph.targetedManagedAppConfiguration' -and $_.'@odata.type' -ne '#microsoft.graph.defaultManagedAppProtection' })
}

function Invoke-IMPreImportAppProtection {
    param($Type, $Obj, $Ctx)
    $Ctx.State.Apps = @($Obj.apps | Where-Object { $_ })
    Remove-IMProperty $Obj @('apps', 'apps@odata.context', 'deployedAppCount', 'isAssigned', 'version', 'exemptAppLockerFiles', 'protectedAppLockerFiles')
    $col = Get-IMAppProtectionCollection $Obj
    if (-not $col) { $col = $Type.Api }
    $Ctx.State.Collection = $col
    @{ Uri = $col }
}

function Invoke-IMPostImportAppProtection {
    param($Type, $Source, $Created, $Ctx)
    if ($Ctx.State.Apps.Count -and $Ctx.State.Collection -notlike '*InformationProtection*') {
        $apps = @(foreach ($a in $Ctx.State.Apps) { $c = Copy-IMObject $a; Remove-IMProperty $c @('id', 'version'); $c })
        $body = @{ apps = $apps }
        if ($Source.appGroupType) { $body.appGroupType = $Source.appGroupType }
        Invoke-IMGraphRequest -Method POST -Uri "$($Ctx.State.Collection)/$($Created.id)/targetApps" -Body $body | Out-Null
    }
}

function Get-IMAssignUriAppProtection {
    param($Type, $Target, $Ctx)
    $col = $Ctx.State.Collection ?? (Get-IMAppProtectionCollection $Target) ?? $Type.Api
    "$col/$($Target.id)/assign"
}

function Invoke-IMPreImportManagedAppConfig {
    param($Type, $Obj, $Ctx)
    $Ctx.State.Apps = @($Obj.apps | Where-Object { $_ })
    $Ctx.State.Collection = '/deviceAppManagement/targetedManagedAppConfigurations'
    Remove-IMProperty $Obj @('apps', 'apps@odata.context', 'deployedAppCount', 'isAssigned', 'version')
}
#endregion

#region Managed device app configuration
function Invoke-IMPostListAppConfigDevice {
    param($Type, $Items)
    @($Items | Where-Object { -not ($_.'@odata.type' -eq '#microsoft.graph.androidManagedStoreAppConfiguration' -and $_.appSupportsOemConfig -eq $true) })
}
function Invoke-IMPostListOEMConfig {
    param($Type, $Items)
    @($Items | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.androidManagedStoreAppConfiguration' -and $_.appSupportsOemConfig -eq $true })
}
function Invoke-IMPreImportAppConfigDevice {
    param($Type, $Obj, $Ctx)
    $mapped = @(foreach ($a in @($Obj.targetedMobileApps)) { $m = Resolve-IMMappedId -Ctx $Ctx -Id $a; if ($m) { $m } else { Write-IMLog -Level Warning -Category 'Import' -Message "'$($Obj.displayName)': targeted app $a not found in this tenant." } })
    if (@($Obj.targetedMobileApps).Count -and -not $mapped.Count) { return @{ Skip = $true; Reason = 'None of the targeted apps exist in this tenant. Import the apps first.' } }
    if ($null -ne $Obj.targetedMobileApps) { $Obj.targetedMobileApps = $mapped }
}
#endregion

#region Policy sets
function Invoke-IMPreImportPolicySets {
    param($Type, $Obj, $Ctx)
    Remove-IMProperty $Obj @('items@odata.context', 'status', 'errorCode')
    $keep = @('@odata.type', 'payloadId', 'intent', 'settings')
    $items = foreach ($i in @($Obj.items)) {
        if (-not $i) { continue }
        $newPayload = Resolve-IMMappedId -Ctx $Ctx -Id $i.payloadId
        if (-not $newPayload) { Write-IMLog -Level Warning -Category 'Import' -Message "Policy set '$($Obj.displayName)': item '$($i.displayName)' does not exist in this tenant and is skipped."; continue }
        foreach ($n in @($i.PSObject.Properties.Name | Where-Object { $_ -notin $keep })) { Remove-IMProperty $i $n }
        $i.payloadId = $newPayload
        $i
    }
    Set-IMProperty $Obj 'items' @($items)
}

function Invoke-IMPreUpdatePolicySets {
    param($Type, $Obj, $Existing, $Ctx)
    # Items are managed with the "update" action
    $current = Get-IMGraphCollection "/deviceAppManagement/policySets/$($Existing.id)/items"
    Invoke-IMGraphRequest -Method POST -Uri "/deviceAppManagement/policySets/$($Existing.id)/update" -Body @{ addedPolicySetItems = @($Obj.items); updatedPolicySetItems = @(); deletedPolicySetItems = @($current.id) } | Out-Null
    Remove-IMProperty $Obj 'items'
}
#endregion

#region Enrollment configurations
function Test-IMDefaultEnrollmentConfig { param($Obj) $Obj.priority -eq 0 -or $Obj.id -like '*_Default*' -or $Obj.id -like '*DefaultWindows10EnrollmentCompletionPageConfiguration' }

function Invoke-IMPostListESP { param($Type, $Items) @($Items | Where-Object '@odata.type' -eq '#microsoft.graph.windows10EnrollmentCompletionPageConfiguration') }
function Invoke-IMPostListCoManagement { param($Type, $Items) @($Items | Where-Object '@odata.type' -eq '#microsoft.graph.deviceComanagementAuthorityConfiguration') }
function Invoke-IMPostListEnrollmentRestrictions {
    param($Type, $Items)
    @($Items | Where-Object '@odata.type' -notin '#microsoft.graph.windows10EnrollmentCompletionPageConfiguration', '#microsoft.graph.deviceComanagementAuthorityConfiguration')
}

function Invoke-IMPreImportEnrollmentConfig {
    param($Type, $Obj, $Ctx)
    Remove-IMProperty $Obj @('windowsMobileRestriction', 'version')
    if ($Obj.selectedMobileAppIds) {
        $Obj.selectedMobileAppIds = @(foreach ($a in @($Obj.selectedMobileAppIds)) { $m = Resolve-IMMappedId -Ctx $Ctx -Id $a; if ($m) { $m } })
    }
    if (Test-IMDefaultEnrollmentConfig $Obj) {
        # Default configurations always exist: update the tenant's default instead of creating
        $existing = Get-IMGraphCollection $Type.Api | Where-Object { $_.'@odata.type' -eq $Obj.'@odata.type' -and $_.priority -eq 0 } | Select-Object -First 1
        if (-not $existing) { return @{ Skip = $true; Reason = 'Matching default configuration not found in this tenant.' } }
        Remove-IMProperty $Obj @('priority', 'displayName', 'description')
        $Ctx.State.IsDefault = $true
        return @{ Uri = "$($Type.Api)/$($existing.id)"; Method = 'PATCH'; ExistingId = $existing.id; ForceUpdate = $true }
    }
    Remove-IMProperty $Obj 'priority'
}

function Invoke-IMAssignEnrollmentConfig {
    param($Type, $Target, $Assignments, $Ctx)
    if ($Ctx.State.IsDefault) { $Ctx.Warnings.Add('Default enrollment configurations cannot be assigned; assignments skipped.'); return $true }
    $false
}
#endregion

#region Per-assignment POST (Autopilot, Terms & conditions)
function Invoke-IMAssignOneByOne {
    param($Type, $Target, $Assignments, $Ctx)
    $existing = Get-IMGraphCollection "$($Type.Api)/$($Target.id)/assignments"
    foreach ($a in @($Assignments)) {
        $dup = $existing | Where-Object { $_.target.groupId -eq $a.target.groupId -and $_.target.'@odata.type' -eq $a.target.'@odata.type' }
        if ($dup) { continue }
        Invoke-IMGraphRequest -Method POST -Uri "$($Type.Api)/$($Target.id)/assignments" -Body @{ target = $a.target } | Out-Null
    }
    $true
}
#endregion

#region Notifications
function Invoke-IMPreImportNotifications {
    param($Type, $Obj, $Ctx)
    $Ctx.State.Messages = @($Obj.localizedNotificationMessages | Where-Object { $_ })
    Remove-IMProperty $Obj @('defaultLocale', 'localizedNotificationMessages', 'localizedNotificationMessages@odata.context')
}
function Invoke-IMPostImportNotifications {
    param($Type, $Source, $Created, $Ctx)
    $existing = if ($Ctx.Mode -eq 'Update') { Get-IMGraphCollection "$($Type.Api)/$($Created.id)/localizedNotificationMessages" } else { @() }
    foreach ($m in $Ctx.State.Messages) {
        $body = [ordered]@{ locale = $m.locale; subject = $m.subject; messageTemplate = $m.messageTemplate; isDefault = $m.isDefault }
        $cur = $existing | Where-Object locale -eq $m.locale | Select-Object -First 1
        if ($cur) { Invoke-IMGraphRequest -Method PATCH -Uri "$($Type.Api)/$($Created.id)/localizedNotificationMessages/$($cur.id)" -Body $body | Out-Null }
        else { Invoke-IMGraphRequest -Method POST -Uri "$($Type.Api)/$($Created.id)/localizedNotificationMessages" -Body $body | Out-Null }
    }
}
#endregion

#region Role definitions & scope tags
function Invoke-IMPostGetRoleDefinitions {
    param($Type, $Obj)
    $ra = Get-IMGraphCollection "/deviceManagement/roleDefinitions/$($Obj.id)/roleAssignments"
    $full = foreach ($a in $ra) { Invoke-IMGraphRequest -Uri "/deviceManagement/roleAssignments/$($a.id)?`$expand=roleScopeTags" -IgnoreNotFound }
    Set-IMProperty $Obj 'roleAssignments' @($full | Where-Object { $_ })
}

function Get-IMRoleDefinitionGroupReferences {
    param($Obj)
    foreach ($a in @($Obj.roleAssignments)) { foreach ($g in @($a.members) + @($a.resourceScopes)) { if ($g -and (Test-IMGuid $g)) { $g } } }
}

function Invoke-IMPreImportRoleDefinitions {
    param($Type, $Obj, $Ctx)
    $Ctx.State.RoleAssignments = @($Obj.roleAssignments | Where-Object { $_ })
    Remove-IMProperty $Obj @('roleAssignments', 'roleAssignments@odata.context', 'isBuiltIn', 'isBuiltInRoleDefinition')
}

function Invoke-IMPostImportRoleDefinitions {
    param($Type, $Source, $Created, $Ctx)
    if (-not $Ctx.Settings.ImportAssignments) { return }
    foreach ($a in $Ctx.State.RoleAssignments) {
        $members = @(foreach ($g in @($a.members)) { $m = Resolve-IMGroupId -Ctx $Ctx -Id $g; if ($m) { $m } })
        $scopes = @(foreach ($g in @($a.resourceScopes)) { $m = Resolve-IMGroupId -Ctx $Ctx -Id $g; if ($m) { $m } })
        $body = [ordered]@{
            displayName = $a.displayName; description = $a.description; members = $members; resourceScopes = $scopes
            scopeType = $a.scopeType ?? 'resourceScope'
            'roleDefinition@odata.bind' = "$($script:IMConnection.GraphUrl)/beta/deviceManagement/roleDefinitions('$($Created.id)')"
        }
        if ($a.scopeType -and $a.scopeType -ne 'resourceScope') { $body.resourceScopes = @() }
        try {
            $newRa = Invoke-IMGraphRequest -Method POST -Uri '/deviceManagement/roleAssignments' -Body $body
            $tags = @(foreach ($t in @($a.roleScopeTags)) { $n = Resolve-IMScopeTagId -Ctx $Ctx -Id $t.id; if ($n -and $n -ne '0') { $n } })
            foreach ($t in $tags) {
                Invoke-IMGraphRequest -Method POST -Uri "/deviceManagement/roleAssignments('$($newRa.id)')/roleScopeTags/`$ref" -Body @{ '@odata.id' = "$($script:IMConnection.GraphUrl)/beta/deviceManagement/roleScopeTags('$t')" } | Out-Null
            }
        }
        catch { $Ctx.Warnings.Add("Role assignment '$($a.displayName)' failed: $($_.Exception.Message)") }
    }
}
#endregion

#region Branding
function Invoke-IMPostGetIntuneBranding {
    param($Type, $Obj)
    try {
        $img = Invoke-IMGraphRequest -Uri "$($Type.Api)/$($Obj.id)?`$select=themeColorLogo,lightBackgroundLogo,landingPageCustomizedImage"
        foreach ($p in 'themeColorLogo', 'lightBackgroundLogo', 'landingPageCustomizedImage') { if ($img.$p) { Set-IMProperty $Obj $p $img.$p } }
    } catch { }
}
function Invoke-IMPreImportIntuneBranding {
    param($Type, $Obj, $Ctx)
    Remove-IMProperty $Obj @('isDefaultProfile', 'disableClientTelemetry')
    if ($Ctx.Source.isDefaultProfile) {
        $default = Get-IMGraphCollection $Type.Api | Where-Object isDefaultProfile | Select-Object -First 1
        if ($default) { return @{ Uri = "$($Type.Api)/$($default.id)"; Method = 'PATCH'; ExistingId = $default.id; ForceUpdate = $true; NoAssign = $true } }
    }
}

function Invoke-IMPostGetAzureBranding {
    param($Type, $Obj)
    foreach ($img in 'bannerLogo', 'squareLogo', 'backgroundImage', 'squareLogoDark', 'favicon') {
        try {
            $raw = Invoke-IMGraphRequest -Uri "/organization/$($script:IMConnection.Organization.Id)/branding/localizations/$($Obj.id)/$img" -Raw -AsBytes -NoLog -IgnoreNotFound
            if ($raw -and $raw.StatusCode -eq 200 -and $raw.Content.Length -gt 0) {
                Set-IMProperty $Obj "#$img" ([pscustomobject]@{ contentType = $raw.Headers['content-type']; data = [Convert]::ToBase64String([byte[]]$raw.Content) })
            }
        } catch { }
    }
}
function Invoke-IMPreImportAzureBranding {
    param($Type, $Obj, $Ctx)
    $orgId = $script:IMConnection.Organization.Id
    $locale = $Obj.id
    foreach ($n in @($Obj.PSObject.Properties.Name | Where-Object { $_ -like '#*' -or $_ -like '*RelativeUrl' -or $_ -eq 'cdnList' })) { $Ctx.State[$n] = $Obj.$n; Remove-IMProperty $Obj $n }
    Remove-IMProperty $Obj 'id'
    if (-not $locale -or $locale -eq '0') { return @{ Uri = "/organization/$orgId/branding"; Method = 'PATCH'; ForceUpdate = $true; ExistingId = '0'; NoAssign = $true } }
    $exists = Invoke-IMGraphRequest -Uri "/organization/$orgId/branding/localizations/$locale" -IgnoreNotFound -NoLog
    if ($exists) { return @{ Uri = "/organization/$orgId/branding/localizations/$locale"; Method = 'PATCH'; ForceUpdate = $true; ExistingId = $locale; NoAssign = $true } }
    Set-IMProperty $Obj 'id' $locale
    @{ Uri = "/organization/$orgId/branding/localizations"; Method = 'POST'; NoAssign = $true }
}
function Invoke-IMPostImportAzureBranding {
    param($Type, $Source, $Created, $Ctx)
    $orgId = $script:IMConnection.Organization.Id
    $locale = if ($Source.id -and $Source.id -ne '0') { $Source.id } else { '0' }
    foreach ($img in 'bannerLogo', 'squareLogo', 'backgroundImage', 'squareLogoDark', 'favicon') {
        $info = $Ctx.State["#$img"]
        if (-not $info.data) { continue }
        try {
            Invoke-IMGraphRequest -Method PUT -Uri "/organization/$orgId/branding/localizations/$locale/$img" -BinaryBody ([Convert]::FromBase64String($info.data)) -ContentType ($info.contentType ?? 'image/png') -Version 'v1.0' | Out-Null
        }
        catch { $Ctx.Warnings.Add("Image '$img' was not imported: $($_.Exception.Message)") }
    }
}
#endregion

#region Conditional Access & identity

function Get-IMConditionalAccessReferences {
    <# Users and groups referenced by a CA policy, used to build the migration table. #>
    param($Obj)
    $u = $Obj.conditions.users
    [pscustomobject]@{
        Groups = @(@($u.includeGroups) + @($u.excludeGroups) | Where-Object { $_ -and (Test-IMGuid $_) })
        Users  = @(@($u.includeUsers) + @($u.excludeUsers) | Where-Object { $_ -and (Test-IMGuid $_) })
    }
}

function Invoke-IMPreImportConditionalAccess {
    param($Type, $Obj, $Ctx)
    Remove-IMProperty $Obj @('templateId', 'partialEnablementStrategy', 'deletedDateTime')
    # Safety: never import Conditional Access as enforced
    $state = $Ctx.Settings.ConditionalAccessState ?? 'disabled'
    if ($Obj.state -ne 'disabled') { $Obj.state = $state }
    $u = $Obj.conditions.users
    if ($u) {
        foreach ($p in 'includeGroups', 'excludeGroups') {
            if ($u.$p) { $u.$p = @(foreach ($g in @($u.$p)) { $m = Resolve-IMGroupId -Ctx $Ctx -Id $g; if ($m) { $m } else { $Ctx.Warnings.Add("Group $g ($p) not found; removed.") } }) }
        }
        foreach ($p in 'includeUsers', 'excludeUsers') {
            if ($u.$p) { $u.$p = @(foreach ($x in @($u.$p)) { if (-not (Test-IMGuid $x)) { $x; continue }; $m = Resolve-IMUserId -Ctx $Ctx -Id $x; if ($m) { $m } else { $Ctx.Warnings.Add("User $x ($p) not found; removed.") } }) }
        }
        if ($u.includeUsers -is [array] -and $u.includeUsers.Count -eq 0 -and -not @($u.includeGroups).Count -and -not @($u.includeRoles).Count -and -not $u.includeGuestsOrExternalUsers) {
            $u.includeUsers = @('None'); $Ctx.Warnings.Add('No included users/groups could be mapped; policy targets None.')
        }
    }
    if ($Obj.grantControls.authenticationStrength) {
        $as = $Obj.grantControls.authenticationStrength
        $newId = Resolve-IMMappedId -Ctx $Ctx -Id $as.id -AllowSame
        $Obj.grantControls.authenticationStrength = [pscustomobject]@{ id = $newId ?? $as.id }
    }
    Remove-IMProperty $Obj.grantControls @('authenticationStrength@odata.context')
    Remove-IMProperty $Obj.sessionControls @('applicationEnforcedRestrictions@odata.context')
}

function Invoke-IMPostListAuthStrengths { param($Type, $Items) @($Items | Where-Object policyType -eq 'custom') }
function Invoke-IMPreImportAuthStrengths {
    param($Type, $Obj, $Ctx)
    foreach ($n in @($Obj.PSObject.Properties.Name | Where-Object { $_ -notin 'displayName', 'description', 'allowedCombinations', 'combinationConfigurations' })) { Remove-IMProperty $Obj $n }
    Remove-IMProperty $Obj 'combinationConfigurations'
}

function Invoke-IMPreImportAuthContext {
    param($Type, $Obj, $Ctx)
    $id = $Obj.id
    Remove-IMProperty $Obj @('@odata.type')
    $existing = Invoke-IMGraphRequest -Uri "$($Type.Api)/$id" -IgnoreNotFound -NoLog -Version 'v1.0'
    if ($existing -and $existing.displayName -and $existing.displayName -ne $Obj.displayName -and $Ctx.Settings.ConflictAction -ne 'Update') {
        return @{ Skip = $true; Reason = "Authentication context $id is already used by '$($existing.displayName)'." }
    }
    Set-IMProperty $Obj 'id' $id
    @{ Uri = "$($Type.Api)/$id"; Method = 'PATCH'; ForceUpdate = $true; ExistingId = $id; NoAssign = $true; Version = 'v1.0' }
}

function Invoke-IMExportFilesTermsOfUse {
    param($Type, $Obj, $Folder, $BaseName)
    foreach ($f in @($Obj.files)) {
        try {
            $data = Invoke-IMGraphRequest -Uri "/identityGovernance/termsOfUse/agreements/$($Obj.id)/file/localizations('$($f.id)')/fileData" -Version 'v1.0'
            if ($data.data) { Set-IMProperty $f 'fileData' ([pscustomobject]@{ data = $data.data }) }
            Save-IMBase64File $data.data (Join-Path $Folder "${BaseName}_$(Get-IMSafeFileName $f.fileName)")
        }
        catch { Write-IMLog -Level Warning -Category 'Export' -Message "Terms of use file '$($f.fileName)' was not exported" -ErrorRecord $_ }
    }
}
function Invoke-IMPreImportTermsOfUse {
    param($Type, $Obj, $Ctx)
    $files = @(foreach ($f in @($Obj.files)) {
        $data = $f.fileData.data
        if (-not $data) {
            $p = Join-Path (Split-Path $Ctx.File) "$([IO.Path]::GetFileNameWithoutExtension($Ctx.File))_$(Get-IMSafeFileName $f.fileName)"
            if (Test-Path -LiteralPath $p) { $data = [Convert]::ToBase64String([IO.File]::ReadAllBytes($p)) }
        }
        if ($data) { [ordered]@{ fileName = $f.fileName; language = $f.language; isDefault = $f.isDefault; fileData = @{ data = $data } } }
    })
    if (-not $files.Count) { return @{ Skip = $true; Reason = 'Terms of use PDF file is missing from the export.' } }
    Remove-IMProperty $Obj @('files', 'files@odata.context', 'file')
    Set-IMProperty $Obj 'files' $files
}
#endregion

#region Reusable settings, W365, updates, DEP
function Invoke-IMPreImportReusableSettings {
    param($Type, $Obj, $Ctx)
    Remove-IMProperty $Obj @('version', 'referencingConfigurationPolicyCount', 'referencingConfigurationPolicies', 'createdDateTime', 'lastModifiedDateTime')
}

function Invoke-IMPreImportW365Provisioning {
    param($Type, $Obj, $Ctx)
    Remove-IMProperty $Obj @('alternateResourceUrl', 'gracePeriodInHours', 'localAdminEnabled', 'managedBy')
    foreach ($d in @($Obj.domainJoinConfigurations)) { if ($d.onPremisesConnectionId) { $Ctx.Warnings.Add("References on-premises network connection $($d.onPremisesConnectionId); verify it in the target tenant.") } }
    if ($Obj.onPremisesConnectionId) { $Ctx.Warnings.Add('References an on-premises network connection; verify it in the target tenant.') }
}

function Invoke-IMPreImportDriverUpdates {
    param($Type, $Obj, $Ctx)
    Remove-IMProperty $Obj @('deviceReporting', 'newUpdates', 'inventorySyncStatus')
}

function Invoke-IMListDepProfiles {
    param($Type)
    $tokens = Get-IMGraphCollection '/deviceManagement/depOnboardingSettings' -IgnoreNotFound
    foreach ($t in $tokens) {
        foreach ($p in (Get-IMGraphCollection "/deviceManagement/depOnboardingSettings/$($t.id)/enrollmentProfiles" -IgnoreNotFound)) {
            Set-IMProperty $p '#DepToken' ([pscustomobject]@{ id = $t.id; tokenName = $t.tokenName; appleIdentifier = $t.appleIdentifier })
            $p
        }
    }
}
function Get-IMItemUriDepProfile { param($Type, $Item) "/deviceManagement/depOnboardingSettings/$($Item.'#DepToken'.id)/enrollmentProfiles/$($Item.id)" }
function Invoke-IMPreImportDepProfile {
    param($Type, $Obj, $Ctx)
    $tokens = @(Get-IMGraphCollection '/deviceManagement/depOnboardingSettings' -IgnoreNotFound)
    if (-not $tokens.Count) { return @{ Skip = $true; Reason = 'No Apple enrollment program token in this tenant.' } }
    $token = $tokens | Where-Object tokenName -eq $Obj.'#DepToken'.tokenName | Select-Object -First 1
    if (-not $token) { $token = $tokens[0]; $Ctx.Warnings.Add("Token '$($Obj.'#DepToken'.tokenName)' not found; using '$($token.tokenName)'.") }
    Remove-IMProperty $Obj @('#DepToken', 'isDefault')
    @{ Uri = "/deviceManagement/depOnboardingSettings/$($token.id)/enrollmentProfiles"; NoAssign = $true }
}
#endregion
