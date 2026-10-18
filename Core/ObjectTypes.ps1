<#
  Object type catalog. Ids match the original IntuneManagement folder names so existing exports import as-is.
  Fields:
    Id, Title, Section (navigation group), Icon (Segoe Fluent/MDL2 glyph)
    Api, ListQuery, Version, NameProperty, ImportOrder (lower first), Permission
    Assignments ($true when the type supports assignments), ExpandAssignments ($expand=assignments on GET)
    AssignmentsProperty (body key for /assign), AssignmentProperties (assignment fields kept besides target)
    FullExpand (extra $expand when reading one object), PropertiesToRemove, PropertiesToRemoveForUpdate
    CanImport, CanDelete, Hooks (see Handlers.ps1), Notes
#>

$script:IMObjectTypes = $null

function New-IMObjectType {
    param([hashtable]$Def)
    $defaults = [ordered]@{
        Id = ''; Title = ''; Section = 'Devices'; Icon = [char]0xE7F4; Api = ''; ListQuery = ''; Version = $null
        NameProperty = 'displayName'; ImportOrder = 1000; Permission = 'DeviceManagementConfiguration.ReadWrite.All'
        Assignments = $true; ExpandAssignments = $true; AssignmentsProperty = 'assignments'; AssignmentProperties = @()
        FullExpand = @(); PropertiesToRemove = @(); PropertiesToRemoveForUpdate = @(); CanImport = $true; CanDelete = $true; CanCopy = $true
        ItemUri = $null; List = $null; PostList = $null; PostGet = $null; ExportFiles = $null; PreImport = $null; PostImport = $null
        Assign = $null; AssignUri = $null; PreUpdate = $null; AfterType = $null; GroupReferences = $null; Notes = ''
        Description = ''; Dependencies = @()
    }
    foreach ($k in $Def.Keys) { $defaults[$k] = $Def[$k] }
    [pscustomobject]$defaults
}

function Initialize-IMObjectTypes {
    $T = @(
        #region Devices - configuration
        @{ Id = 'DeviceConfiguration'; Title = 'Configuration profiles'; Section = 'Device configuration'; Icon = [char]0xE713
           Api = '/deviceManagement/deviceConfigurations'
           ListQuery = "`$filter=not isof('microsoft.graph.windowsUpdateForBusinessConfiguration') and not isof('microsoft.graph.iosUpdateConfiguration')"
           PostGet = { Invoke-IMPostGetDeviceConfiguration @args }; PreImport = { Invoke-IMPreImportDeviceConfiguration @args }; PostImport = { Invoke-IMPostImportDeviceConfiguration @args }
           Description = 'Template-based device configuration profiles (Wi-Fi, VPN, restrictions, custom OMA-URI, ...)' }
        @{ Id = 'SettingsCatalog'; Title = 'Settings catalog'; Section = 'Device configuration'; Icon = [char]0xE8FD
           Api = '/deviceManagement/configurationPolicies'; NameProperty = 'name'; FullExpand = @('settings'); Dependencies = @('ReusableSettings')
           PropertiesToRemove = @('settingCount'); PreImport = { Invoke-IMPreImportSettingsCatalog @args }; PreUpdate = { Invoke-IMPreUpdateSettingsCatalog @args }
           Description = 'Settings catalog and settings-catalog based endpoint security and baselines' }
        @{ Id = 'AdministrativeTemplates'; Title = 'Administrative templates'; Section = 'Device configuration'; Icon = [char]0xE8F1
           Api = '/deviceManagement/groupPolicyConfigurations'; Dependencies = @('ADMXFiles')
           PropertiesToRemove = @('policyConfigurationIngestionType')
           PostGet = { Invoke-IMPostGetAdministrativeTemplates @args }; PreImport = { Invoke-IMPreImportAdministrativeTemplates @args }; PostImport = { Invoke-IMPostImportAdministrativeTemplates @args } }
        @{ Id = 'ADMXFiles'; Title = 'Imported ADMX files'; Section = 'Device configuration'; Icon = [char]0xE8A5; ImportOrder = 45
           Api = '/deviceManagement/groupPolicyUploadedDefinitionFiles'; NameProperty = 'fileName'; Assignments = $false; ExpandAssignments = $false
           FullExpand = @('groupPolicyUploadedLanguageFiles'); CanCopy = $false
           PropertiesToRemove = @('languageCodes', 'targetPrefix', 'targetNamespace', 'policyType', 'revision', 'status', 'uploadDateTime', 'groupPolicyOperations')
           PreImport = { Invoke-IMPreImportADMXFiles @args }; PostImport = { Invoke-IMPostImportADMXFiles @args } }
        @{ Id = 'HardwareConfigurations'; Title = 'BIOS configurations'; Section = 'Device configuration'; Icon = [char]0xE950
           Api = '/deviceManagement/hardwareConfigurations'; PropertiesToRemoveForUpdate = @('version') }
        @{ Id = 'InventoryPolicies'; Title = 'Properties catalog'; Section = 'Device configuration'; Icon = [char]0xE9D9
           Api = '/deviceManagement/inventoryPolicies'; NameProperty = 'name'; FullExpand = @('settings'); PropertiesToRemove = @('settingCount')
           PreImport = { Invoke-IMPreImportSettingsCatalog @args }; PreUpdate = { Invoke-IMPreUpdateSettingsCatalog @args } }
        @{ Id = 'DeviceCategories'; Title = 'Device categories'; Section = 'Device configuration'; Icon = [char]0xE8EC
           Api = '/deviceManagement/deviceCategories'; Assignments = $false; ExpandAssignments = $false; Permission = 'DeviceManagementManagedDevices.Read.All' }
        @{ Id = 'W365ProvisioningPolicies'; Title = 'Windows 365 provisioning'; Section = 'Device configuration'; Icon = [char]0xE977
           Api = '/deviceManagement/virtualEndpoint/provisioningPolicies'; Permission = 'CloudPC.ReadWrite.All'; PreImport = { Invoke-IMPreImportW365Provisioning @args } }
        @{ Id = 'W365UserSettings'; Title = 'Windows 365 user settings'; Section = 'Device configuration'; Icon = [char]0xE77B
           Api = '/deviceManagement/virtualEndpoint/userSettings'; Permission = 'CloudPC.ReadWrite.All' }
        #endregion

        #region Compliance
        @{ Id = 'CompliancePolicies'; Title = 'Compliance policies'; Section = 'Compliance'; Icon = [char]0xE73E
           Api = '/deviceManagement/deviceCompliancePolicies'; FullExpand = @('scheduledActionsForRule($expand=scheduledActionConfigurations)')
           Dependencies = @('Notifications', 'ComplianceScripts')
           PostGet = { Invoke-IMPostGetCompliancePolicies @args }; PreImport = { Invoke-IMPreImportCompliancePolicies @args }; PreUpdate = { Invoke-IMPreUpdateCompliancePolicies @args }
           GroupReferences = { Get-IMComplianceGroupReferences @args } }
        @{ Id = 'CompliancePoliciesV2'; Title = 'Compliance policies (settings catalog)'; Section = 'Compliance'; Icon = [char]0xE73E
           Api = '/deviceManagement/compliancePolicies'; NameProperty = 'name'; FullExpand = @('settings', 'scheduledActionsForRule($expand=scheduledActionConfigurations)')
           PropertiesToRemove = @('settingCount'); PreImport = { Invoke-IMPreImportCompliancePoliciesV2 @args }; PreUpdate = { Invoke-IMPreUpdateSettingsCatalog @args } }
        @{ Id = 'ComplianceScripts'; Title = 'Compliance scripts'; Section = 'Compliance'; Icon = [char]0xE943; ImportOrder = 80
           Api = '/deviceManagement/deviceComplianceScripts'; Permission = 'DeviceManagementScripts.ReadWrite.All'; Assignments = $false; ExpandAssignments = $false
           ExportFiles = { Invoke-IMExportFilesComplianceScript @args }; PostImport = { Invoke-IMPostImportComplianceScripts @args }
           PropertiesToRemoveForUpdate = @('version') }
        @{ Id = 'Notifications'; Title = 'Notification templates'; Section = 'Compliance'; Icon = [char]0xE715; ImportOrder = 40
           Api = '/deviceManagement/notificationMessageTemplates'; Permission = 'DeviceManagementServiceConfig.ReadWrite.All'; Assignments = $false; ExpandAssignments = $false
           FullExpand = @('localizedNotificationMessages'); PropertiesToRemoveForUpdate = @('defaultLocale', 'localizedNotificationMessages')
           PreImport = { Invoke-IMPreImportNotifications @args }; PostImport = { Invoke-IMPostImportNotifications @args } }
        #endregion

        #region Endpoint security
        @{ Id = 'EndpointSecurity'; Title = 'Endpoint security (templates)'; Section = 'Endpoint security'; Icon = [char]0xE83D
           Api = '/deviceManagement/intents'; Dependencies = @('ReusableSettings'); PropertiesToRemove = @('#TemplateInfo')
           PostGet = { Invoke-IMPostGetEndpointSecurity @args }; PreImport = { Invoke-IMPreImportEndpointSecurity @args }; PreUpdate = { Invoke-IMPreUpdateEndpointSecurity @args }
           Notes = 'Legacy template-based policies. New endpoint security policies are under Settings catalog.' }
        @{ Id = 'ReusableSettings'; Title = 'Reusable settings'; Section = 'Endpoint security'; Icon = [char]0xE8C8; ImportOrder = 70
           Api = '/deviceManagement/reusablePolicySettings'; Assignments = $false; ExpandAssignments = $false; CanCopy = $false
           PreImport = { Invoke-IMPreImportReusableSettings @args } }
        #endregion

        #region Scripts
        @{ Id = 'PowerShellScripts'; Title = 'PowerShell scripts'; Section = 'Scripts'; Icon = [char]0xE756
           Api = '/deviceManagement/deviceManagementScripts'; Permission = 'DeviceManagementScripts.ReadWrite.All'; AssignmentsProperty = 'deviceManagementScriptAssignments'
           ExportFiles = { Invoke-IMExportFilesScript @args } }
        @{ Id = 'MacScripts'; Title = 'macOS shell scripts'; Section = 'Scripts'; Icon = [char]0xE756
           Api = '/deviceManagement/deviceShellScripts'; Permission = 'DeviceManagementScripts.ReadWrite.All'; AssignmentsProperty = 'deviceManagementScriptAssignments'
           ExportFiles = { Invoke-IMExportFilesShellScript @args } }
        @{ Id = 'MacCustomAttributes'; Title = 'macOS custom attributes'; Section = 'Scripts'; Icon = [char]0xE756
           Api = '/deviceManagement/deviceCustomAttributeShellScripts'; Permission = 'DeviceManagementScripts.ReadWrite.All'; AssignmentsProperty = 'deviceManagementScriptAssignments'
           PropertiesToRemoveForUpdate = @('customAttributeName', 'customAttributeType', 'displayName'); ExportFiles = { Invoke-IMExportFilesShellScript @args } }
        @{ Id = 'DeviceHealthScripts'; Title = 'Remediations'; Section = 'Scripts'; Icon = [char]0xE90F
           Api = '/deviceManagement/deviceHealthScripts'; Permission = 'DeviceManagementScripts.ReadWrite.All'; AssignmentsProperty = 'deviceHealthScriptAssignments'
           AssignmentProperties = @('runRemediationScript', 'runSchedule'); PropertiesToRemoveForUpdate = @('version', 'isGlobalScript', 'highestAvailableVersion')
           PostList = { Invoke-IMPostListHealthScripts @args }; PreImport = { Invoke-IMPreImportHealthScripts @args }; ExportFiles = { Invoke-IMExportFilesHealthScript @args } }
        #endregion

        #region Updates
        @{ Id = 'UpdatePolicies'; Title = 'Update rings'; Section = 'Windows updates'; Icon = [char]0xE895
           Api = '/deviceManagement/deviceConfigurations'
           ListQuery = "`$filter=isof('microsoft.graph.windowsUpdateForBusinessConfiguration') or isof('microsoft.graph.iosUpdateConfiguration')"
           PropertiesToRemoveForUpdate = @('version', 'qualityUpdatesPauseStartDate', 'featureUpdatesPauseStartDate', 'qualityUpdatesWillBeRolledBack', 'featureUpdatesWillBeRolledBack') }
        @{ Id = 'FeatureUpdates'; Title = 'Feature updates'; Section = 'Windows updates'; Icon = [char]0xE777
           Api = '/deviceManagement/windowsFeatureUpdateProfiles'; PropertiesToRemoveForUpdate = @('deployableContentDisplayName', 'endOfSupportDate') }
        @{ Id = 'QualityUpdates'; Title = 'Expedited quality updates'; Section = 'Windows updates'; Icon = [char]0xE777
           Api = '/deviceManagement/windowsQualityUpdateProfiles'; PropertiesToRemoveForUpdate = @('releaseDateDisplayName', 'deployableContentDisplayName') }
        @{ Id = 'QualityUpdatePolicies'; Title = 'Quality update policies'; Section = 'Windows updates'; Icon = [char]0xE777
           Api = '/deviceManagement/windowsQualityUpdatePolicies' }
        @{ Id = 'DriverUpdateProfiles'; Title = 'Driver updates'; Section = 'Windows updates'; Icon = [char]0xE964
           Api = '/deviceManagement/windowsDriverUpdateProfiles'; PreImport = { Invoke-IMPreImportDriverUpdates @args } }
        #endregion

        #region Enrollment
        @{ Id = 'AutoPilot'; Title = 'Autopilot profiles'; Section = 'Enrollment'; Icon = [char]0xE7F8
           Api = '/deviceManagement/windowsAutopilotDeploymentProfiles'; Permission = 'DeviceManagementServiceConfig.ReadWrite.All'
           PropertiesToRemoveForUpdate = @('managementServiceAppId'); Assign = { Invoke-IMAssignOneByOne @args } }
        @{ Id = 'EnrollmentStatusPage'; Title = 'Enrollment status page'; Section = 'Enrollment'; Icon = [char]0xE9F9
           Api = '/deviceManagement/deviceEnrollmentConfigurations'; Permission = 'DeviceManagementServiceConfig.ReadWrite.All'; Dependencies = @('Applications')
           AssignmentsProperty = 'enrollmentConfigurationAssignments'; PropertiesToRemoveForUpdate = @('priority')
           PostList = { Invoke-IMPostListESP @args }; PreImport = { Invoke-IMPreImportEnrollmentConfig @args }; Assign = { Invoke-IMAssignEnrollmentConfig @args } }
        @{ Id = 'EnrollmentRestrictions'; Title = 'Enrollment restrictions'; Section = 'Enrollment'; Icon = [char]0xE72E
           Api = '/deviceManagement/deviceEnrollmentConfigurations'; Permission = 'DeviceManagementServiceConfig.ReadWrite.All'
           AssignmentsProperty = 'enrollmentConfigurationAssignments'; PropertiesToRemoveForUpdate = @('priority')
           PostList = { Invoke-IMPostListEnrollmentRestrictions @args }; PreImport = { Invoke-IMPreImportEnrollmentConfig @args }; Assign = { Invoke-IMAssignEnrollmentConfig @args } }
        @{ Id = 'CoManagementSettings'; Title = 'Co-management settings'; Section = 'Enrollment'; Icon = [char]0xE8AB
           Api = '/deviceManagement/deviceEnrollmentConfigurations'; Permission = 'DeviceManagementServiceConfig.ReadWrite.All'
           AssignmentsProperty = 'enrollmentConfigurationAssignments'; PropertiesToRemoveForUpdate = @('priority')
           PostList = { Invoke-IMPostListCoManagement @args }; PreImport = { Invoke-IMPreImportEnrollmentConfig @args }; Assign = { Invoke-IMAssignEnrollmentConfig @args } }
        @{ Id = 'AppleEnrollmentTypes'; Title = 'Apple enrollment types'; Section = 'Enrollment'; Icon = [char]0xE8EA
           Api = '/deviceManagement/appleUserInitiatedEnrollmentProfiles'; Permission = 'DeviceManagementServiceConfig.ReadWrite.All'; PropertiesToRemoveForUpdate = @('platform') }
        @{ Id = 'iOSDepProfile'; Title = 'Apple ADE profiles'; Section = 'Enrollment'; Icon = [char]0xE8EA
           Api = '/deviceManagement/depOnboardingSettings'; Permission = 'DeviceManagementServiceConfig.ReadWrite.All'; Assignments = $false; ExpandAssignments = $false; CanCopy = $false
           List = { Invoke-IMListDepProfiles @args }; ItemUri = { Get-IMItemUriDepProfile @args }; PreImport = { Invoke-IMPreImportDepProfile @args } }
        #endregion

        #region Apps
        @{ Id = 'Applications'; Title = 'Apps'; Section = 'Apps'; Icon = [char]0xE71D; ImportOrder = 60
           Api = '/deviceAppManagement/mobileApps'; Permission = 'DeviceManagementApps.ReadWrite.All'
           ListQuery = "`$filter=(microsoft.graph.managedApp/appAvailability eq null or microsoft.graph.managedApp/appAvailability eq 'lineOfBusiness' or isAssigned eq true)&`$orderby=displayName"
           AssignmentsProperty = 'mobileAppAssignments'; AssignmentProperties = @('@odata.type', 'intent', 'settings')
           PropertiesToRemove = @('uploadState', 'publishingState', 'isAssigned', 'dependentAppCount', 'supersedingAppCount', 'supersededAppCount', 'committedContentVersion', 'isFeatured', 'size', 'categories')
           PostGet = { Invoke-IMPostGetApplications @args }; ExportFiles = { Invoke-IMExportFilesApplications @args }
           PreImport = { Invoke-IMPreImportApplications @args }; PostImport = { Invoke-IMPostImportApplications @args }; AfterType = { Invoke-IMAfterTypeApplications @args } }
        @{ Id = 'AppProtection'; Title = 'App protection'; Section = 'Apps'; Icon = [char]0xE8D7
           Api = '/deviceAppManagement/managedAppPolicies'; Permission = 'DeviceManagementApps.ReadWrite.All'; Dependencies = @('Applications'); ExpandAssignments = $false
           PropertiesToRemoveForUpdate = @('protectedAppLockerFiles', 'version')
           ItemUri = { Get-IMItemUriAppProtection @args }; PostList = { Invoke-IMPostListAppProtection @args }
           PreImport = { Invoke-IMPreImportAppProtection @args }; PostImport = { Invoke-IMPostImportAppProtection @args }; AssignUri = { Get-IMAssignUriAppProtection @args } }
        @{ Id = 'AppConfigurationManagedApp'; Title = 'App configuration (managed apps)'; Section = 'Apps'; Icon = [char]0xE90F
           Api = '/deviceAppManagement/targetedManagedAppConfigurations'; Permission = 'DeviceManagementApps.ReadWrite.All'; Dependencies = @('Applications')
           FullExpand = @('apps'); PreImport = { Invoke-IMPreImportManagedAppConfig @args }; PostImport = { Invoke-IMPostImportAppProtection @args } }
        @{ Id = 'AppConfigurationManagedDevice'; Title = 'App configuration (managed devices)'; Section = 'Apps'; Icon = [char]0xE90F
           Api = '/deviceAppManagement/mobileAppConfigurations'; Permission = 'DeviceManagementApps.ReadWrite.All'; Dependencies = @('Applications')
           PostList = { Invoke-IMPostListAppConfigDevice @args }; PreImport = { Invoke-IMPreImportAppConfigDevice @args } }
        @{ Id = 'AndroidOEMConfig'; Title = 'Android OEMConfig'; Section = 'Apps'; Icon = [char]0xE8EA
           Api = '/deviceAppManagement/mobileAppConfigurations'; Permission = 'DeviceManagementApps.ReadWrite.All'; Dependencies = @('Applications')
           PostList = { Invoke-IMPostListOEMConfig @args }; PreImport = { Invoke-IMPreImportAppConfigDevice @args } }
        @{ Id = 'PolicySets'; Title = 'Policy sets'; Section = 'Apps'; Icon = [char]0xE8F1; ImportOrder = 2000
           Api = '/deviceAppManagement/policySets'; Permission = 'DeviceManagementConfiguration.ReadWrite.All'; FullExpand = @('items')
           Dependencies = @('Applications', 'AppConfigurationManagedApp', 'AppProtection', 'AutoPilot', 'EnrollmentRestrictions', 'EnrollmentStatusPage', 'DeviceConfiguration', 'AdministrativeTemplates', 'SettingsCatalog', 'CompliancePolicies')
           PreImport = { Invoke-IMPreImportPolicySets @args }; PreUpdate = { Invoke-IMPreUpdatePolicySets @args } }
        #endregion

        #region Tenant administration
        @{ Id = 'ScopeTags'; Title = 'Scope tags'; Section = 'Tenant administration'; Icon = [char]0xE8EC; ImportOrder = 10
           Api = '/deviceManagement/roleScopeTags'; ListQuery = '$filter=isBuiltIn eq false'; Permission = 'DeviceManagementRBAC.ReadWrite.All'; ExpandAssignments = $false
           PropertiesToRemove = @('isBuiltIn'); CanCopy = $false }
        @{ Id = 'AssignmentFilters'; Title = 'Assignment filters'; Section = 'Tenant administration'; Icon = [char]0xE71C; ImportOrder = 15
           Api = '/deviceManagement/assignmentFilters'; Assignments = $false; ExpandAssignments = $false
           PropertiesToRemove = @('payloads'); PropertiesToRemoveForUpdate = @('platform') }
        @{ Id = 'RoleDefinitions'; Title = 'Intune roles'; Section = 'Tenant administration'; Icon = [char]0xE7EF; ImportOrder = 20
           Api = '/deviceManagement/roleDefinitions'; ListQuery = '$filter=isBuiltIn eq false'; Permission = 'DeviceManagementRBAC.ReadWrite.All'
           Assignments = $false; ExpandAssignments = $false; PropertiesToRemoveForUpdate = @('isBuiltInRoleDefinition', 'isBuiltIn', 'roleAssignments')
           PostGet = { Invoke-IMPostGetRoleDefinitions @args }; PreImport = { Invoke-IMPreImportRoleDefinitions @args }; PostImport = { Invoke-IMPostImportRoleDefinitions @args }
           GroupReferences = { Get-IMRoleDefinitionGroupReferences @args } }
        @{ Id = 'TermsAndConditions'; Title = 'Terms and conditions'; Section = 'Tenant administration'; Icon = [char]0xE8A5
           Api = '/deviceManagement/termsAndConditions'; Permission = 'DeviceManagementServiceConfig.ReadWrite.All'; ExpandAssignments = $false
           Assign = { Invoke-IMAssignOneByOne @args } }
        @{ Id = 'IntuneBranding'; Title = 'Company Portal branding'; Section = 'Tenant administration'; Icon = [char]0xE790
           Api = '/deviceManagement/intuneBrandingProfiles'; NameProperty = 'profileName'; Permission = 'DeviceManagementApps.ReadWrite.All'
           PropertiesToRemoveForUpdate = @('isDefaultProfile', 'disableClientTelemetry')
           PostGet = { Invoke-IMPostGetIntuneBranding @args }; PreImport = { Invoke-IMPreImportIntuneBranding @args } }
        #endregion

        #region Entra ID
        @{ Id = 'ConditionalAccess'; Title = 'Conditional Access'; Section = 'Entra ID'; Icon = [char]0xE72E; ImportOrder = 1500
           Api = '/identity/conditionalAccess/policies'; Permission = 'Policy.ReadWrite.ConditionalAccess'; Assignments = $false; ExpandAssignments = $false
           Dependencies = @('NamedLocations', 'TermsOfUse', 'AuthenticationStrengths', 'AuthenticationContext')
           PreImport = { Invoke-IMPreImportConditionalAccess @args }
           Notes = 'Imported policies are set to Off (or report-only) for safety.' }
        @{ Id = 'NamedLocations'; Title = 'Named locations'; Section = 'Entra ID'; Icon = [char]0xE707; ImportOrder = 50
           Api = '/identity/conditionalAccess/namedLocations'; Permission = 'Policy.ReadWrite.ConditionalAccess'; Assignments = $false; ExpandAssignments = $false }
        @{ Id = 'AuthenticationStrengths'; Title = 'Authentication strengths'; Section = 'Entra ID'; Icon = [char]0xE8D7; ImportOrder = 45
           Api = '/identity/conditionalAccess/authenticationStrength/policies'; Permission = 'Policy.ReadWrite.ConditionalAccess'; Assignments = $false; ExpandAssignments = $false
           PostList = { Invoke-IMPostListAuthStrengths @args }; PreImport = { Invoke-IMPreImportAuthStrengths @args } }
        @{ Id = 'AuthenticationContext'; Title = 'Authentication contexts'; Section = 'Entra ID'; Icon = [char]0xE8D7; ImportOrder = 46
           Api = '/identity/conditionalAccess/authenticationContextClassReferences'; Permission = 'Policy.ReadWrite.ConditionalAccess'; Assignments = $false; ExpandAssignments = $false
           CanCopy = $false; CanDelete = $false; PreImport = { Invoke-IMPreImportAuthContext @args } }
        @{ Id = 'TermsOfUse'; Title = 'Terms of use'; Section = 'Entra ID'; Icon = [char]0xE8A5; ImportOrder = 55
           Api = '/identityGovernance/termsOfUse/agreements'; Version = 'v1.0'; Permission = 'Agreement.ReadWrite.All'; Assignments = $false; ExpandAssignments = $false
           FullExpand = @('files'); CanCopy = $false; ExportFiles = { Invoke-IMExportFilesTermsOfUse @args }; PreImport = { Invoke-IMPreImportTermsOfUse @args } }
        @{ Id = 'AzureBranding'; Title = 'Company branding'; Section = 'Entra ID'; Icon = [char]0xE790
           Api = '/organization/{OrganizationId}/branding/localizations'; NameProperty = 'id'; Permission = 'Organization.ReadWrite.All'; Assignments = $false; ExpandAssignments = $false
           CanCopy = $false; CanDelete = $false; PostGet = { Invoke-IMPostGetAzureBranding @args }; PreImport = { Invoke-IMPreImportAzureBranding @args }; PostImport = { Invoke-IMPostImportAzureBranding @args } }
        #endregion
    )
    $script:IMObjectTypes = [ordered]@{}
    foreach ($d in $T) { $t = New-IMObjectType $d; $script:IMObjectTypes[$t.Id] = $t }
}

function Get-IMObjectType {
    <# All object types, or the ones matching -Id (wildcards allowed). #>
    [CmdletBinding()]
    param([string[]]$Id, [string]$Section)
    if (-not $script:IMObjectTypes) { Initialize-IMObjectTypes }
    $all = $script:IMObjectTypes.Values
    if ($Id) { $all = $all | Where-Object { $t = $_; $Id | Where-Object { $t.Id -like $_ } } }
    if ($Section) { $all = $all | Where-Object Section -eq $Section }
    @($all)
}

function Get-IMObjectTypeApi {
    <# Expands placeholders such as {OrganizationId}. #>
    param($Type)
    $api = $Type.Api
    if ($api -like '*{OrganizationId}*') { $api = $api.Replace('{OrganizationId}', $script:IMConnection.Organization.Id) }
    $api
}

function Get-IMObjectName {
    param($Type, $Obj)
    $n = Get-IMPropertyValue $Obj $Type.NameProperty
    if (-not $n) { $n = Get-IMPropertyValue $Obj 'displayName' }
    if (-not $n) { $n = Get-IMPropertyValue $Obj 'name' }
    if (-not $n) { $n = $Obj.id }
    [string]$n
}

function Get-IMObjectTypeSections {
    Get-IMObjectType | Group-Object Section | ForEach-Object { [pscustomobject]@{ Section = $_.Name; Types = @($_.Group) } }
}
