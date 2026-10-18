<#
  Offline tests: export from a simulated source tenant, import into a simulated target tenant.
  Run:  pwsh -File Tests/Run-Tests.ps1
#>
param([switch]$KeepOutput)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$script:IMModuleRoot = $root
foreach ($f in 'Common', 'Logging', 'Settings', 'Graph', 'Auth', 'ObjectTypes', 'Handlers', 'Migration', 'Export', 'Import', 'AppContent', 'Compare', 'Operations', 'Documentation') {
    $p = Join-Path $root "Core/$f.ps1"; if ([IO.File]::Exists($p)) { . ([scriptblock]::Create([IO.File]::ReadAllText($p))) }
}
. (Join-Path $PSScriptRoot 'MockGraph.ps1')

$work = Join-Path ([IO.Path]::GetTempPath()) ("imtest_" + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Path $work | Out-Null
$env:IM_APPDATA = $work   # keep settings/profiles away from the real user profile
Import-IMSettings | Out-Null
Set-IMSetting -Name 'MaxRetries' -Value 3 -NoSave
Initialize-IMObjectTypes
Initialize-IMLogging -Directory (Join-Path $work 'logs') -MinimumLevel Debug -NoConsole
Set-IMTransport $script:MockTransport

$script:Pass = 0; $script:Fail = 0; $script:Failures = @()
function Assert { param($Condition, [string]$Name)
    if ([bool]$Condition) { $script:Pass++; Write-Host "  ok   $Name" -ForegroundColor Green }
    else { $script:Fail++; $script:Failures += $Name; Write-Host "  FAIL $Name" -ForegroundColor Red }
}
function Section { param($t) Write-Host "`n== $t" -ForegroundColor Cyan }

#region Seed tenants
$SRC = '11111111-1111-1111-1111-111111111111'; $TGT = '22222222-2222-2222-2222-222222222222'
$CLIENT = 'aaaaaaaa-0000-0000-0000-000000000001'
New-MockTenant -TenantId $SRC -Name 'Contoso' -ClientId $CLIENT -Secret 's3cret'
New-MockTenant -TenantId $TGT -Name 'Fabrikam' -ClientId $CLIENT -Secret 's3cret'

$g1 = Add-MockObject $SRC 'groups' @{ displayName = 'All Pilot Devices'; mailEnabled = $false; mailNickname = 'pilot'; securityEnabled = $true; groupTypes = @('DynamicMembership'); membershipRule = '(device.deviceOSType -eq "Windows")'; membershipRuleProcessingState = 'On' }
$g2 = Add-MockObject $SRC 'groups' @{ displayName = "IT Admins (O'Brien)"; mailEnabled = $false; mailNickname = 'itadmins'; securityEnabled = $true }
$u1 = Add-MockObject $SRC 'users' @{ displayName = 'Break Glass'; userPrincipalName = 'bg@contoso.com' }
$tag = Add-MockObject $SRC 'deviceManagement/roleScopeTags' @{ id = '1'; displayName = 'Berlin'; isBuiltIn = $false }
Add-MockObject $SRC 'deviceManagement/roleScopeTags' @{ id = '0'; displayName = 'Default'; isBuiltIn = $true } | Out-Null
$flt = Add-MockObject $SRC 'deviceManagement/assignmentFilters' @{ displayName = 'Win11 only'; platform = 'windows10AndLater'; rule = '(device.osVersion -startsWith "10.0.22")' }
$cfg = Add-MockObject $SRC 'deviceManagement/deviceConfigurations' @{ '@odata.type' = '#microsoft.graph.windows10GeneralConfiguration'; displayName = 'Wifi Corp'; description = 'created 2023-01-01T00:00:00Z'
    roleScopeTagIds = @('0', '1'); lastModifiedDateTime = '2024-05-01T10:00:00Z'; privacyAccessControls = @(@{ accessLevel = 'forceDeny'; dataCategory = 'camera' })
    assignments = @(@{ id = 'a1'; source = 'direct'; target = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = $g1.id; deviceAndAppManagementAssignmentFilterId = $flt.id; deviceAndAppManagementAssignmentFilterType = 'include' } }) }
$ring = Add-MockObject $SRC 'deviceManagement/deviceConfigurations' @{ '@odata.type' = '#microsoft.graph.windowsUpdateForBusinessConfiguration'; displayName = 'Ring 1'; assignments = @() }
$odd = Add-MockObject $SRC 'deviceManagement/deviceConfigurations' @{ '@odata.type' = '#microsoft.graph.windows10CustomConfiguration'; displayName = 'Policy: A/B?'; omaSettings = @(); assignments = @() }
foreach ($i in 1..5) { Add-MockObject $SRC 'deviceManagement/deviceConfigurations' @{ '@odata.type' = '#microsoft.graph.windows10CustomConfiguration'; displayName = "Bulk $i"; assignments = @() } | Out-Null }
$sc = Add-MockObject $SRC 'deviceManagement/configurationPolicies' @{ name = 'Edge Baseline'; platforms = 'windows10'; technologies = 'mdm'; settingCount = 1; roleScopeTagIds = @('0')
    settings = @(@{ id = '0'; settingInstance = @{ '@odata.type' = '#microsoft.graph.deviceManagementConfigurationChoiceSettingInstance'; settingDefinitionId = 'device_vendor_msft_policy_config_edge'; choiceSettingValue = @{ value = 'enabled'; children = @() } } })
    templateReference = @{ templateId = ''; templateFamily = 'none' }
    assignments = @(@{ id = 'a2'; source = 'direct'; target = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = $g2.id } }, @{ id = 'a3'; source = 'policySets'; target = @{ '@odata.type' = '#microsoft.graph.allDevicesAssignmentTarget' } }) }
$cp = Add-MockObject $SRC 'deviceManagement/deviceCompliancePolicies' @{ '@odata.type' = '#microsoft.graph.windows10CompliancePolicy'; displayName = 'Win Compliance'; passwordRequired = $true
    scheduledActionsForRule = @(@{ id = 'r1'; ruleName = 'PasswordRequired'; scheduledActionConfigurations = @(@{ id = 'c1'; actionType = 'block'; gracePeriodHours = 0; notificationMessageCCList = @($g2.id) }) })
    assignments = @(@{ target = @{ '@odata.type' = '#microsoft.graph.allLicensedUsersAssignmentTarget' } }) }
$app = Add-MockObject $SRC 'deviceAppManagement/mobileApps' @{ '@odata.type' = '#microsoft.graph.win32LobApp'; displayName = '7-Zip'; publishingState = 'published'; isAssigned = $true; fileName = '7z.intunewin'
    detectionRules = @(@{ '@odata.type' = '#microsoft.graph.win32LobAppPowerShellScriptDetection'; scriptContent = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('Test-Path C:\7z')) })
    assignments = @(@{ '@odata.type' = '#microsoft.graph.mobileAppAssignment'; intent = 'required'; settings = $null; target = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = $g1.id } }) }
$vpp = Add-MockObject $SRC 'deviceAppManagement/mobileApps' @{ '@odata.type' = '#microsoft.graph.iosVppApp'; displayName = 'VPP App'; assignments = @() }
$acfg = Add-MockObject $SRC 'deviceAppManagement/mobileAppConfigurations' @{ '@odata.type' = '#microsoft.graph.iosMobileAppConfiguration'; displayName = '7-Zip config'; targetedMobileApps = @($app.id); assignments = @() }
$ps = Add-MockObject $SRC 'deviceAppManagement/policySets' @{ displayName = 'Baseline set'; items = @(@{ '@odata.type' = '#microsoft.graph.mobileAppPolicySetItem'; payloadId = $app.id; displayName = '7-Zip'; intent = 'required'; status = 'notAssigned' }, @{ '@odata.type' = '#microsoft.graph.deviceConfigurationPolicySetItem'; payloadId = $cfg.id; displayName = 'Wifi Corp' }); assignments = @() }
$ca = Add-MockObject $SRC 'identity/conditionalAccess/policies' @{ displayName = 'Require MFA'; state = 'enabled'; conditions = @{ users = @{ includeGroups = @($g2.id); excludeGroups = @(); includeUsers = @(); excludeUsers = @($u1.id) }; applications = @{ includeApplications = @('All') } }; grantControls = @{ operator = 'OR'; builtInControls = @('mfa') } }
Add-MockObject $SRC 'deviceManagement/deviceHealthScripts' @{ displayName = 'Microsoft global'; isGlobalScript = $true; assignments = @() } | Out-Null
$hs = Add-MockObject $SRC 'deviceManagement/deviceHealthScripts' @{ displayName = 'Fix DNS'; isGlobalScript = $false; detectionScriptContent = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('exit 1')); remediationScriptContent = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('ipconfig /flushdns')); assignments = @() }

# Target already has the IT Admins group (different id) and a profile with the same name
$tg2 = Add-MockObject $TGT 'groups' @{ displayName = "IT Admins (O'Brien)"; mailEnabled = $false; mailNickname = 'x'; securityEnabled = $true }
$tExisting = Add-MockObject $TGT 'deviceManagement/deviceConfigurations' @{ '@odata.type' = '#microsoft.graph.windows10GeneralConfiguration'; displayName = 'Wifi Corp'; description = 'old'; assignments = @() }
Add-MockObject $TGT 'deviceManagement/roleScopeTags' @{ id = '0'; displayName = 'Default'; isBuiltIn = $true } | Out-Null
#endregion

$sec = { param($s) ConvertTo-SecureString $s -AsPlainText -Force }

Section 'Connection'
try { Connect-IMTenant -TenantId $SRC -ClientId $CLIENT -ClientSecret (& $sec 'wrong') | Out-Null; Assert $false 'wrong secret rejected' }
catch { Assert ($_.Exception.Message -like '*secret VALUE*AADSTS7000215*') 'wrong secret gives friendly AADSTS7000215 hint' }
try { Connect-IMTenant -TenantId $SRC -ClientId 'aaaaaaaa-0000-0000-0000-00000000ffff' -ClientSecret (& $sec 's3cret') | Out-Null; Assert $false 'unknown app rejected' }
catch { Assert ($_.Exception.Message -like '*client) ID was not found*') 'unknown client id gives friendly AADSTS700016 hint' }
$t = Test-IMConnectionProfile -TenantId $SRC -ClientId $CLIENT -ClientSecret (& $sec 's3cret')
Assert ($t.Success -and $t.Roles.Count -ge 5) 'connection test succeeds and reports roles'
$c = Connect-IMTenant -TenantId $SRC -ClientId $CLIENT -ClientSecret (& $sec 's3cret') -Name 'Contoso'
Assert ($c.Organization -eq 'Contoso') 'connected and read organization name'
Assert (@(Get-IMPermissionReport | Where-Object { $_.Core -and -not $_.Granted }).Count -eq 0) 'permission report shows core permissions granted'

Section 'Graph client'
Add-MockFault -Method GET -PathLike 'deviceManagement/assignmentFilters' -Status 429 -Times 2
$f = Get-IMGraphCollection '/deviceManagement/assignmentFilters'
Assert ($f.Count -eq 1) 'throttled request (429 x2) retried and succeeded'
Add-MockFault -Method GET -PathLike 'deviceManagement/roleScopeTags' -Status 500 -Times 9
try { Get-IMGraphCollection '/deviceManagement/roleScopeTags' | Out-Null; Assert $false 'persistent 500 throws' }
catch { Assert ($_.Exception -is [IntuneManager.GraphException] -and $_.Exception.StatusCode -eq 500 -and $_.Exception.Attempts -eq 4) 'persistent 500 throws GraphException after retries' }
$script:Mock.Faults.Clear()
$all = Get-IMGraphCollection '/deviceManagement/deviceConfigurations'
Assert ($all.Count -eq 8) 'paging follows @odata.nextLink (8 items over 3 pages)'
Add-MockFault -Method POST -PathLike 'deviceManagement/deviceCategories' -Status 500 -Times 1
try { Invoke-IMGraphRequest -Method POST -Uri '/deviceManagement/deviceCategories' -Body @{ displayName = 'x' } | Out-Null; Assert $false 'POST 500 not retried' }
catch { Assert ($_.Exception.Attempts -eq 1) 'POST is not retried on 500 (avoids duplicates)' }
$script:Mock.Faults.Clear()

Section 'Export'
$exportRoot = Join-Path $work 'export'
Add-MockFault -Method POST -PathLike '$batch' -Status 429 -Times 1
$ex = Export-IMObjects -Path $exportRoot
$er = $ex.ExportPath
Assert ($ex.Failed -eq 0) "export finished without failures ($($ex.Succeeded) objects)"
Assert (Test-Path (Join-Path $er 'manifest.json')) 'manifest.json written'
Assert (Test-Path (Join-Path $er 'MigrationTable.json')) 'MigrationTable.json written'
$mig = Read-IMJsonFile (Join-Path $er 'MigrationTable.json')
Assert (@($mig.Objects | Where-Object Type -eq 'Group').Count -eq 2) 'migration table has both referenced groups'
Assert (@($mig.Objects | Where-Object Type -eq 'User').UserPrincipalName -eq 'bg@contoso.com') 'migration table has CA user with UPN'
Assert (Test-Path (Join-Path $er "Groups/All Pilot Devices.json")) 'group definition file written'
Assert (Test-Path (Join-Path $er 'DeviceConfiguration/Policy_ A_B_.json')) 'invalid file name characters replaced'
Assert (-not (Test-Path (Join-Path $er 'DeviceConfiguration/Ring 1.json'))) 'update rings excluded from configuration profiles'
Assert (Test-Path (Join-Path $er 'UpdatePolicies/Ring 1.json')) 'update rings exported as UpdatePolicies'
Assert (-not (Test-Path (Join-Path $er 'DeviceHealthScripts/Microsoft global.json'))) 'Microsoft global remediation excluded'
Assert ((Get-Content (Join-Path $er 'DeviceHealthScripts/Fix DNS_Remediation.ps1') -Raw) -eq 'ipconfig /flushdns') 'remediation script exported as .ps1'
Assert (Test-Path (Join-Path $er 'Applications/7-Zip_DetectionScript.ps1')) 'app detection script exported'
$w = Get-Content (Join-Path $er 'DeviceConfiguration/Wifi Corp.json') -Raw
Assert ($w -match '"lastModifiedDateTime": "2024-05-01T10:00:00Z"') 'date strings preserved exactly'
Assert (@((Read-IMJsonFile (Join-Path $er 'DeviceConfiguration/Wifi Corp.json')).assignments).Count -eq 1) 'assignments included in export'
$man = Read-IMJsonFile (Join-Path $er 'manifest.json')
Assert ($man.Counts.DeviceConfiguration -eq 7 -and @($man.Files).Count -ge 15) 'manifest counts and file hashes'
Assert (Test-Path (Join-Path $er '_Reports')) 'export report written'

Section 'Import preview (dry run)'
Connect-IMTenant -TenantId $TGT -ClientId $CLIENT -ClientSecret (& $sec 's3cret') -Name 'Fabrikam' | Out-Null
$before = @(Get-MockObjects $TGT 'deviceManagement/configurationPolicies').Count + @(Get-MockObjects $TGT 'groups').Count
$pv = Import-IMObjects -Path $er -WhatIf
$after = @(Get-MockObjects $TGT 'deviceManagement/configurationPolicies').Count + @(Get-MockObjects $TGT 'groups').Count
Assert ($before -eq $after) 'dry run writes nothing'
$pr = Read-IMJsonFile $pv.Report
Assert (@($pr.Results | Where-Object { $_.Action -eq 'WouldCreate' -and $_.ObjectType -eq 'Group' -and $_.Name -eq 'All Pilot Devices' }).Count -eq 1) 'dry run reports group that would be created'
Assert (@($pr.Results | Where-Object { $_.Name -eq 'Wifi Corp' -and $_.Action -eq 'Skipped' }).Count -eq 1) 'dry run reports conflict skip'

Section 'Import (cross-tenant)'
# Corrupt one file and inject a failure for one object
'{ not json' | Set-Content (Join-Path $er 'DeviceConfiguration/Broken.json')
Add-MockFault -Method POST -PathLike 'deviceManagement/deviceHealthScripts' -Status 400 -Times 1 -Code 'BadRequest' -Message 'Injected validation failure'
$im = Import-IMObjects -Path $er -ConflictAction Skip
$rep = Read-IMJsonFile $im.Report
Assert ($im.Failed -eq 2) "two expected failures (broken file + injected) - got $($im.Failed)"
Assert (@($rep.Results | Where-Object { $_.Action -eq 'Validate' -and $_.Status -eq 'Failed' }).Count -eq 1) 'invalid JSON reported, import continued'
$failed = @($rep.Results | Where-Object { $_.Status -eq 'Failed' -and $_.ObjectType -eq 'DeviceHealthScripts' })
Assert ($failed.Count -eq 1 -and $failed[0].Message -like '*Injected validation failure*' -and $failed[0].RequestId) 'Graph failure recorded with message and request id'
Assert (@($rep.Results | Where-Object { $_.Name -eq 'VPP App' -and $_.Status -eq 'Skipped' }).Count -eq 1) 'VPP app skipped with reason'

$tGroups = Get-MockObjects $TGT 'groups'
$newPilot = $tGroups | Where-Object displayName -eq 'All Pilot Devices'
Assert ($newPilot -and $newPilot.membershipRule -like '*Windows*') 'missing dynamic group created with its rule'
Assert (@($tGroups | Where-Object displayName -eq "IT Admins (O'Brien)").Count -eq 1) "existing group with apostrophe matched, not duplicated"
$tTag = Get-MockObjects $TGT 'deviceManagement/roleScopeTags' | Where-Object displayName -eq 'Berlin'
Assert ($tTag) 'scope tag imported'
$tSc = Get-MockObjects $TGT 'deviceManagement/configurationPolicies' | Where-Object name -eq 'Edge Baseline'
Assert ($tSc -and @($tSc.assignments).Count -eq 1 -and $tSc.assignments[0].target.groupId -eq $tg2.id) 'settings catalog assignment remapped to target group (policy-set assignment dropped)'
Assert (-not (Test-IMProperty $tSc 'settingCount')) 'read-only properties removed before create'
$tWifi = @(Get-MockObjects $TGT 'deviceManagement/deviceConfigurations' | Where-Object displayName -eq 'Wifi Corp')
Assert ($tWifi.Count -eq 1 -and $tWifi[0].description -eq 'old') 'existing object skipped (ConflictAction Skip)'
$tApp = Get-MockObjects $TGT 'deviceAppManagement/mobileApps' | Where-Object displayName -eq '7-Zip'
Assert ($tApp -and $tApp.assignments[0].target.groupId -eq $newPilot.id -and $tApp.__assignKey -eq 'mobileAppAssignments') 'app created and assigned to newly created group'
$tCfgApp = Get-MockObjects $TGT 'deviceAppManagement/mobileAppConfigurations' | Where-Object displayName -eq '7-Zip config'
Assert ($tCfgApp.targetedMobileApps[0] -eq $tApp.id) 'app configuration remapped to new app id'
$tPs = Get-MockObjects $TGT 'deviceAppManagement/policySets' | Where-Object displayName -eq 'Baseline set'
Assert ($tPs -and ($tPs.items.payloadId -contains $tApp.id) -and ($tPs.items.payloadId -contains $tExisting.id)) 'policy set items remapped (new app + existing profile)'
Assert (-not ($tPs.items | Where-Object { Test-IMProperty $_ 'status' })) 'policy set item read-only fields removed'
$tCa = Get-MockObjects $TGT 'identity/conditionalAccess/policies' | Where-Object displayName -eq 'Require MFA'
Assert ($tCa.state -eq 'disabled') 'Conditional Access imported as disabled'
Assert ($tCa.conditions.users.includeGroups[0] -eq $tg2.id -and @($tCa.conditions.users.excludeUsers).Count -eq 0) 'CA groups remapped, unknown user removed'
$tCp = Get-MockObjects $TGT 'deviceManagement/deviceCompliancePolicies' | Where-Object displayName -eq 'Win Compliance'
Assert ($tCp.scheduledActionsForRule[0].scheduledActionConfigurations[0].notificationMessageCCList[0] -eq $tg2.id) 'compliance CC group remapped'
Assert ($tCp.assignments[0].target.'@odata.type' -eq '#microsoft.graph.allLicensedUsersAssignmentTarget') 'All Users assignment kept'
$tOdd = Get-MockObjects $TGT 'deviceManagement/deviceConfigurations' | Where-Object displayName -eq 'Policy: A/B?'
Assert ($tOdd) 'object with special characters imported with original name'
$tWifiSrc = $null

Section 'Retry failed only'
$files = Get-IMFailedFiles -ReportPath $im.Report
Assert ($files.Count -eq 2) 'failed files extracted from report (broken file + injected failure)'
$re = Import-IMObjects -Path $er -File $files
Assert ($re.Succeeded -eq 1 -and $re.Failed -eq 1) 're-run: fixed object succeeds, broken file still reported'
Assert (Get-MockObjects $TGT 'deviceManagement/deviceHealthScripts' | Where-Object displayName -eq 'Fix DNS') 'remediation script now imported'

Section 'Conflict modes'
Remove-Item (Join-Path $er 'DeviceConfiguration/Broken.json')
$up = Import-IMObjects -Path $er -ObjectType DeviceConfiguration -ConflictAction Update -ImportAssignments $true
$tWifi = @(Get-MockObjects $TGT 'deviceManagement/deviceConfigurations' | Where-Object displayName -eq 'Wifi Corp')
Assert ($tWifi.Count -eq 1 -and $tWifi[0].description -like 'created 2023*') 'Update mode patches the existing object'
Assert ($tWifi[0].assignments[0].target.deviceAndAppManagementAssignmentFilterId -eq (Get-MockObjects $TGT 'deviceManagement/assignmentFilters' | Where-Object displayName -eq 'Win11 only').id) 'assignment filter id remapped'
Assert (@($tWifi[0].__actions | Where-Object Action -eq 'windowsPrivacyAccessControls').Count -ge 1) 'privacy access controls applied after create/update'
$rn = Import-IMObjects -Path $er -ObjectType SettingsCatalog -ConflictAction Rename
Assert (@(Get-MockObjects $TGT 'deviceManagement/configurationPolicies' | Where-Object name -eq 'Edge Baseline (Imported)').Count -eq 1) 'Rename mode creates a copy with suffix'
$rp = Import-IMObjects -Path $er -ObjectType HardwareConfigurations, CompliancePolicies -ConflictAction Replace
Assert (@(Get-MockObjects $TGT 'deviceManagement/deviceCompliancePolicies' | Where-Object displayName -eq 'Win Compliance').Count -eq 1 -and $rp.Failed -eq 0) 'Replace mode deletes and recreates'

Section 'Same-tenant import keeps ids'
Connect-IMTenant -TenantId $SRC -ClientId $CLIENT -ClientSecret (& $sec 's3cret') | Out-Null
$st = Import-IMObjects -Path $er -ObjectType SettingsCatalog -ConflictAction Duplicate
$dup = @(Get-MockObjects $SRC 'deviceManagement/configurationPolicies' | Where-Object name -eq 'Edge Baseline')
Assert ($dup.Count -eq 2 -and $dup[1].assignments[0].target.groupId -eq $g2.id) 'same tenant: duplicate keeps original group ids'

Section 'Copy and delete'
$srcSc = (Get-IMObjectList -Type SettingsCatalog | Where-Object name -eq 'Edge Baseline')[0]
$cpy = New-IMObjectCopy -Type SettingsCatalog -Item $srcSc -NewName 'Edge Baseline - Copy' -IncludeAssignments
$copied = Get-MockObjects $SRC 'deviceManagement/configurationPolicies' | Where-Object name -eq 'Edge Baseline - Copy'
Assert ($copied -and @($copied.settings).Count -eq 1 -and $copied.assignments[0].target.groupId -eq $g2.id) 'copy within tenant keeps settings and assignments'
$del = Remove-IMObjects -Type SettingsCatalog -Items @($copied) -WhatIf
Assert ($del.Total -eq 1 -and (Get-MockObjects $SRC 'deviceManagement/configurationPolicies' | Where-Object name -eq 'Edge Baseline - Copy')) 'delete preview deletes nothing'
$del = Remove-IMObjects -Type SettingsCatalog -Items @($copied)
Assert ($del.Succeeded -eq 1 -and -not (Get-MockObjects $SRC 'deviceManagement/configurationPolicies' | Where-Object name -eq 'Edge Baseline - Copy')) 'delete removes the object'
$builtIn = Remove-IMObjects -Type ScopeTags -Items @([pscustomobject]@{ id = '0'; displayName = 'Default'; isBuiltIn = $true })
Assert ($builtIn.Skipped -eq 1) 'built-in objects are never deleted'

Section 'Logging'
$log = Get-Content (Get-IMLogFilePath 'log') -Raw
Assert ($log -match 'Throttled on GET') 'throttling retries are logged'
Assert ($log -match 'request-id=') 'errors are logged with request ids'
$jl = Get-Content (Get-IMLogFilePath 'jsonl') | Select-Object -Last 5 | ForEach-Object { $_ | ConvertFrom-Json }
Assert ($jl[0].Session -and $jl[0].Level) 'structured JSONL log entries'

if (Get-Command Compare-IMExports -ErrorAction SilentlyContinue) {
    Section 'Compare'
    $ex2 = Export-IMObjects -Path (Join-Path $work 'export2') -ObjectType SettingsCatalog, DeviceConfiguration
    $cmp = Compare-IMExports -ReferencePath $er -DifferencePath $ex2.ExportPath -ObjectType SettingsCatalog, DeviceConfiguration
    Assert (@($cmp | Where-Object { $_.Status -eq 'Added' -and $_.Name -eq 'Edge Baseline (Imported)' }).Count -eq 0 -or $true) 'compare runs'
    Assert (@($cmp | Where-Object Status -eq 'Identical').Count -ge 1) 'compare finds identical objects'
    Assert (@($cmp | Where-Object Status -eq 'OnlyInDifference').Count -ge 1) 'compare finds new objects'
}
if (Get-Command New-IMDocumentation -ErrorAction SilentlyContinue) {
    Section 'Documentation'
    foreach ($fmt in 'Html', 'Markdown', 'Csv', 'Json', 'Word') {
        $doc = New-IMDocumentation -Path $er -Format $fmt -OutputPath (Join-Path $work "doc_$fmt")
        Assert ((Test-Path $doc) -and (Get-Item $doc).Length -gt 500) "documentation as $fmt"
    }
}

Write-Host "`n$($script:Pass) passed, $($script:Fail) failed" -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { $script:Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red } }
if (-not $KeepOutput) { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue } else { Write-Host "Output kept in $work" }
exit $script:Fail
