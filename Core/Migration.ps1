<#
  Migration: maps ids from the source tenant to the target tenant.
  - Groups/users: MigrationTable.json + Groups\*.json (format compatible with IntuneManagement)
  - Dependencies (filters, scope tags, apps, named locations, ...): exported files matched by name in the target
  - Objects created during this import are added to the map as they are created
#>

$script:IMGuidPattern = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

#region Export side: collect referenced groups/users and write the migration table
function New-IMMigrationCollector {
    [pscustomobject]@{ Groups = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase); Users = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase) }
}

function Add-IMMigrationReferences {
    <# Records groups/users referenced by an exported object. #>
    param($Collector, $Type, $Obj)
    foreach ($a in @($Obj.assignments)) {
        $t = $a.target
        if ($t.groupId -and $t.'@odata.type' -match 'groupAssignmentTarget|exclusionGroupAssignmentTarget|cloudPcManagementGroupAssignmentTarget') { [void]$Collector.Groups.Add($t.groupId) }
    }
    if ($Type.GroupReferences) { foreach ($g in @(& $Type.GroupReferences $Obj)) { if ($g) { [void]$Collector.Groups.Add($g) } } }
    if ($Type.Id -eq 'ConditionalAccess') {
        $refs = Get-IMConditionalAccessReferences $Obj
        foreach ($g in $refs.Groups) { [void]$Collector.Groups.Add($g) }
        foreach ($u in $refs.Users) { [void]$Collector.Users.Add($u) }
    }
}

function Save-IMMigrationTable {
    <# Reads referenced groups/users (batched) and writes MigrationTable.json and Groups\*.json. #>
    param([Parameter(Mandatory)]$Collector, [Parameter(Mandatory)][string]$Root, $Operation)
    $path = Join-Path $Root 'MigrationTable.json'
    $table = if (Test-Path -LiteralPath $path) { Read-IMJsonFile $path } else { $null }
    if (-not $table -or $table.TenantId -ne $script:IMConnection.TenantId) {
        $table = [pscustomobject]@{ TenantId = $script:IMConnection.TenantId; Organization = $script:IMConnection.Organization.DisplayName; Objects = @() }
    }
    $objects = [Collections.Generic.List[object]]::new()
    foreach ($o in @($table.Objects)) { if ($o) { $objects.Add($o) } }
    $known = [Collections.Generic.HashSet[string]]::new([string[]]@($objects | ForEach-Object Id), [StringComparer]::OrdinalIgnoreCase)

    $reqs = [Collections.Generic.List[object]]::new()
    foreach ($g in $Collector.Groups) { if (-not $known.Contains($g)) { $reqs.Add([pscustomobject]@{ id = "g|$g"; method = 'GET'; url = "/groups/$g`?`$select=id,displayName,description,mailEnabled,mailNickname,securityEnabled,groupTypes,membershipRule,membershipRuleProcessingState,isAssignableToRole,onPremisesSyncEnabled" }) } }
    foreach ($u in $Collector.Users) { if (-not $known.Contains($u)) { $reqs.Add([pscustomobject]@{ id = "u|$u"; method = 'GET'; url = "/users/$u`?`$select=id,displayName,userPrincipalName" }) } }
    if ($reqs.Count -eq 0) { Write-IMJsonFile $path $table; return }

    Write-IMLog -Category 'Export' -Message "Reading $($reqs.Count) referenced group(s)/user(s) for the migration table"
    $res = Invoke-IMGraphBatch -Requests $reqs -Version 'v1.0'
    $groupFolder = Join-Path $Root 'Groups'
    foreach ($key in $res.Keys) {
        $kind, $id = $key -split '\|', 2
        $r = $res[$key]
        if ($r.Status -ge 400) {
            Write-IMLog -Level Warning -Category 'Export' -Message "$(if ($kind -eq 'g') { 'Group' } else { 'User' }) $id referenced in an assignment could not be read ($($r.Error)). It may have been deleted."
            continue
        }
        $b = $r.Body
        if ($kind -eq 'g') {
            $file = (Get-IMSafeFileName $b.displayName) + '.json'
            if (Test-Path -LiteralPath (Join-Path $groupFolder $file)) {
                $existing = Read-IMJsonFile (Join-Path $groupFolder $file)
                if ($existing.id -ne $b.id) { $file = (Get-IMSafeFileName $b.displayName) + "_$($b.id).json" }
            }
            Write-IMJsonFile (Join-Path $groupFolder $file) $b
            $objects.Add([pscustomobject]@{ Id = $b.id; DisplayName = $b.displayName; Type = 'Group'; File = "Groups/$file" })
        }
        else {
            $objects.Add([pscustomobject]@{ Id = $b.id; DisplayName = $b.displayName; Type = 'User'; UserPrincipalName = $b.userPrincipalName })
        }
    }
    $table.Objects = $objects.ToArray()
    Write-IMJsonFile $path $table
}
#endregion

#region Import side: context and resolution
function New-IMImportContext {
    param([Parameter(Mandatory)][string]$Root, [hashtable]$Options, $Operation)

    $settings = @{}
    foreach ($k in 'ImportAssignments', 'ImportScopeTags', 'ReplaceDependencyIds', 'CreateMissingGroups', 'ConflictAction', 'RenameSuffix', 'NamePrefix', 'ContinueOnError') { $settings[$k] = Get-IMSetting $k }
    $settings.ConditionalAccessState = 'disabled'
    $settings.WhatIf = $false
    if ($Options) { foreach ($k in $Options.Keys) { $settings[$k] = $Options[$k] } }

    $migPath = @((Join-Path $Root 'MigrationTable.json'), (Join-Path (Split-Path $Root) 'MigrationTable.json')) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    $migration = if ($migPath) { Read-IMJsonFile $migPath } else { $null }
    $manifestPath = Join-Path $Root 'manifest.json'
    $manifest = if (Test-Path -LiteralPath $manifestPath) { Read-IMJsonFile $manifestPath } else { $null }
    $sourceTenant = $migration.TenantId ?? $manifest.TenantId

    $ctx = @{
        Root = $Root; MigrationRoot = if ($migPath) { Split-Path $migPath } else { $Root }
        Settings = $settings; Operation = $Operation; WhatIf = [bool]$settings.WhatIf
        SourceTenantId = $sourceTenant
        SameTenant = [bool]($sourceTenant -and $sourceTenant -eq $script:IMConnection.TenantId)
        Migration = @{}
        IdMap = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
        GroupMap = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
        UserMap = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
        LoadedDependencies = [Collections.Generic.HashSet[string]]::new()
        ExportIndex = @{}
        PlannedGroups = [Collections.Generic.List[string]]::new()
        # Per object (reset by the engine)
        File = $null; Source = $null; State = @{}; Warnings = [Collections.Generic.List[string]]::new(); Mode = 'Create'; TypeState = @{}
    }
    foreach ($o in @($migration.Objects)) { if ($o.Id) { $ctx.Migration[$o.Id] = $o } }
    if ($settings.Quiet) { return $ctx }
    if (-not $migPath) { Write-IMLog -Level Warning -Category 'Import' -Message 'No MigrationTable.json found. Group assignments can only be imported into the same tenant they were exported from.' }
    if ($ctx.SameTenant) { Write-IMLog -Category 'Import' -Message 'Source and target tenant are the same; ids are kept.' }
    elseif ($sourceTenant) { Write-IMLog -Category 'Import' -Message "Cross-tenant import from $($migration.Organization ?? $sourceTenant) to $($script:IMConnection.Organization.DisplayName)" }
    $ctx
}

function Reset-IMImportObjectState {
    param($Ctx, $File, $Source, [hashtable]$TypeState)
    $Ctx.File = $File; $Ctx.Source = $Source; $Ctx.State = @{}; $Ctx.Warnings = [Collections.Generic.List[string]]::new(); $Ctx.Mode = 'Create'
    if ($TypeState) { $Ctx.TypeState = $TypeState }
}

function Get-IMExportIndex {
    <# id/name of the exported objects of a type (reads only what is needed, cached). #>
    param($Ctx, [string]$TypeId)
    if ($Ctx.ExportIndex.ContainsKey($TypeId)) { return $Ctx.ExportIndex[$TypeId] }
    $type = Get-IMObjectType -Id $TypeId | Select-Object -First 1
    $folder = Join-Path $Ctx.Root $TypeId
    $list = @()
    if ($type -and (Test-Path -LiteralPath $folder)) {
        $list = foreach ($f in (Get-ChildItem -LiteralPath $folder -Filter '*.json' -File | Where-Object { $_.BaseName -notmatch '_Settings$' })) {
            try { $o = Read-IMJsonFile $f.FullName; if ($o.id) { [pscustomobject]@{ Id = [string]$o.id; Name = Get-IMObjectName $type $o; Type = $o.'@odata.type' } } } catch { }
        }
    }
    $Ctx.ExportIndex[$TypeId] = @($list)
    $Ctx.ExportIndex[$TypeId]
}

function Add-IMDependencyMap {
    <# Maps exported objects of a dependency type to existing target objects with the same name. #>
    param($Ctx, [string]$TypeId)
    if ($Ctx.SameTenant -or -not $Ctx.LoadedDependencies.Add($TypeId)) { return }
    $type = Get-IMObjectType -Id $TypeId | Select-Object -First 1
    if (-not $type) { return }
    $exported = Get-IMExportIndex -Ctx $Ctx -TypeId $TypeId
    if (-not $exported.Count) { return }
    try { $existing = @(Get-IMObjectList -Type $type) }
    catch { Write-IMLog -Level Warning -Category 'Import' -Message "Could not read $($type.Title) in the target to map dependencies" -ErrorRecord $_; return }
    $mapped = 0
    foreach ($e in $exported) {
        $match = @($existing | Where-Object { (Get-IMObjectName $type $_) -eq $e.Name -and (-not $e.Type -or -not $_.'@odata.type' -or $_.'@odata.type' -eq $e.Type) })
        if ($match.Count -ge 1) {
            $key = if ($TypeId -eq 'ScopeTags') { "ScopeTags:$($e.Id)" } else { $e.Id }
            if (-not $Ctx.IdMap.ContainsKey($key)) { $Ctx.IdMap[$key] = [string]$match[0].id; $mapped++ }
            if ($match.Count -gt 1) { Write-IMLog -Level Warning -Category 'Import' -Message "$($type.Title): several objects are named '$($e.Name)'; using the first one." }
        }
    }
    Write-IMLog -Level Debug -Category 'Import' -Message "Dependency map: $mapped of $($exported.Count) $($type.Title) found in the target by name"
}

function Register-IMImportedId {
    param($Ctx, $Type, [string]$OldId, [string]$NewId)
    if (-not $OldId -or -not $NewId) { return }
    $key = if ($Type.Id -eq 'ScopeTags') { "ScopeTags:$OldId" } else { $OldId }
    $Ctx.IdMap[$key] = $NewId
}

function Resolve-IMMappedId {
    param($Ctx, [string]$Id, [switch]$AllowSame)
    if (-not $Id) { return $null }
    if ($Ctx.IdMap.ContainsKey($Id)) { return $Ctx.IdMap[$Id] }
    if ($Ctx.SameTenant -or $AllowSame) { return $Id }
    $null
}

function Resolve-IMScopeTagId {
    param($Ctx, [string]$Id)
    if ($Id -eq '0' -or $Ctx.SameTenant) { return $Id }
    if ($Ctx.IdMap.ContainsKey("ScopeTags:$Id")) { return $Ctx.IdMap["ScopeTags:$Id"] }
    $null
}

function Set-IMScopeTags {
    param($Obj, $Ctx)
    $prop = if (Test-IMProperty $Obj 'roleScopeTagIds') { 'roleScopeTagIds' } elseif (Test-IMProperty $Obj 'roleScopeTags') { 'roleScopeTags' } else { return }
    $ids = @($Obj.$prop | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
    if (-not $Ctx.Settings.ImportScopeTags) { $Obj.$prop = @('0'); return }
    $new = @(foreach ($i in $ids) {
        $m = Resolve-IMScopeTagId -Ctx $Ctx -Id $i
        if ($m) { $m } else { $Ctx.Warnings.Add("Scope tag $i not found in target; removed.") }
    })
    if (-not $new.Count) { $new = @('0') }
    $Obj.$prop = @($new | Select-Object -Unique)
}

function Find-IMGroupByName {
    param([string]$Name)
    @(Get-IMGraphCollection "/groups?`$filter=displayName eq '$(ConvertTo-IMODataString $Name)'&`$select=id,displayName" -Version 'v1.0')
}

function New-IMGroupFromExport {
    param($Ctx, $MigrationEntry)
    $name = $MigrationEntry.DisplayName.Trim()
    $file = if ($MigrationEntry.File) { Join-Path $Ctx.MigrationRoot $MigrationEntry.File } else { Join-Path $Ctx.MigrationRoot "Groups/$(Get-IMSafeFileName $name).json" }
    $body = [ordered]@{ displayName = $name; mailEnabled = $false; mailNickname = ('im' + [guid]::NewGuid().ToString('N').Substring(0, 10)); securityEnabled = $true }
    if (Test-Path -LiteralPath $file) {
        $g = Read-IMJsonFile $file
        if ($g.description) { $body.description = $g.description }
        if ($g.groupTypes) { $body.groupTypes = @($g.groupTypes) }
        if ($g.membershipRule) { $body.membershipRule = $g.membershipRule; $body.membershipRuleProcessingState = $g.membershipRuleProcessingState ?? 'On' }
        if ($g.isAssignableToRole) { $body.isAssignableToRole = $true }
        if ($g.mailNickname) {
            $nick = ($g.mailNickname -replace '[^A-Za-z0-9._-]', '')
            if ($nick) { $body.mailNickname = $nick }
        }
        if ($g.groupTypes -contains 'Unified') { $body.mailEnabled = $true }
        if ($g.onPremisesSyncEnabled) { Write-IMLog -Level Warning -Category 'Import' -Message "Group '$name' is synced from on-premises in the source; it is created as a cloud group." }
    }
    else { Write-IMLog -Level Warning -Category 'Import' -Message "No group file for '$name'; creating an assigned security group with default settings." }
    try { $created = Invoke-IMGraphRequest -Method POST -Uri '/groups' -Body $body -Version 'v1.0' }
    catch {
        if ($_.Exception.ErrorCode -eq 'Request_BadRequest' -and $_.Exception.GraphMessage -match 'mailNickname') {
            $body.mailNickname = 'im' + [guid]::NewGuid().ToString('N').Substring(0, 10)
            $created = Invoke-IMGraphRequest -Method POST -Uri '/groups' -Body $body -Version 'v1.0'
        }
        else { throw }
    }
    Write-IMLog -Level Success -Category 'Import' -Message "Created group '$name' ($($created.id))"
    if ($Ctx.Operation) { Add-IMOperationResult -Operation $Ctx.Operation -ObjectType 'Group' -Name $name -Action 'Created' -SourceId $MigrationEntry.Id -TargetId $created.id | Out-Null }
    $created.id
}

function Resolve-IMGroupId {
    <# Target group id for a source group id; creates the group if allowed. $null when it cannot be resolved. #>
    param($Ctx, [string]$Id)
    if (-not $Id) { return $null }
    if ($Ctx.SameTenant) { return $Id }
    if ($Ctx.GroupMap.ContainsKey($Id)) { return $Ctx.GroupMap[$Id] }
    $entry = $Ctx.Migration[$Id]
    $result = $null
    if (-not $entry) {
        # Maybe the id is valid in this tenant (e.g. migration table missing but same ids)
        $g = Invoke-IMGraphRequest -Uri "/groups/$Id`?`$select=id" -Version 'v1.0' -IgnoreNotFound -NoLog
        if ($g) { $result = $g.id } else { Write-IMLog -Level Warning -Category 'Import' -Message "Group $Id is not in the migration table and not in this tenant." }
    }
    else {
        $found = Find-IMGroupByName $entry.DisplayName.Trim()
        if ($found.Count -ge 1) {
            $result = $found[0].id
            if ($found.Count -gt 1) { Write-IMLog -Level Warning -Category 'Import' -Message "Several groups are named '$($entry.DisplayName)'; using $result." }
        }
        elseif ($Ctx.Settings.CreateMissingGroups) {
            if ($Ctx.WhatIf) { $Ctx.PlannedGroups.Add($entry.DisplayName); $result = "whatif-$Id" }
            else {
                try { $result = New-IMGroupFromExport -Ctx $Ctx -MigrationEntry $entry }
                catch { Write-IMLog -Level Error -Category 'Import' -Message "Could not create group '$($entry.DisplayName)'" -ErrorRecord $_ }
            }
        }
        else { Write-IMLog -Level Warning -Category 'Import' -Message "Group '$($entry.DisplayName)' does not exist in this tenant and creating groups is turned off." }
    }
    $Ctx.GroupMap[$Id] = $result
    $result
}

function Resolve-IMUserId {
    param($Ctx, [string]$Id)
    if ($Ctx.SameTenant) { return $Id }
    if ($Ctx.UserMap.ContainsKey($Id)) { return $Ctx.UserMap[$Id] }
    $entry = $Ctx.Migration[$Id]
    $result = $null
    if ($entry.UserPrincipalName) {
        $u = Invoke-IMGraphRequest -Uri "/users/$([Uri]::EscapeDataString($entry.UserPrincipalName))?`$select=id" -Version 'v1.0' -IgnoreNotFound -NoLog
        $result = $u.id
    }
    $Ctx.UserMap[$Id] = $result
    $result
}

function Initialize-IMGroupMap {
    <# Resolves all groups referenced by the files to import up-front (batched name lookups). #>
    param($Ctx, [string[]]$GroupIds)
    if ($Ctx.SameTenant) { return }
    $todo = @($GroupIds | Where-Object { $_ -and -not $Ctx.GroupMap.ContainsKey($_) } | Select-Object -Unique)
    if (-not $todo.Count) { return }
    Write-IMLog -Category 'Import' -Message "Resolving $($todo.Count) group(s) in the target tenant"
    $reqs = @(foreach ($id in $todo) {
        $e = $Ctx.Migration[$id]
        if ($e) { [pscustomobject]@{ id = $id; method = 'GET'; url = "/groups?`$filter=displayName eq '$([Uri]::EscapeDataString((ConvertTo-IMODataString $e.DisplayName.Trim())))'&`$select=id,displayName" } }
    })
    if ($reqs.Count) {
        $res = Invoke-IMGraphBatch -Requests $reqs -Version 'v1.0'
        foreach ($id in $res.Keys) {
            $v = @($res[$id].Body.value)
            if ($res[$id].Status -lt 400 -and $v.Count -ge 1) {
                $Ctx.GroupMap[$id] = $v[0].id
                if ($v.Count -gt 1) { Write-IMLog -Level Warning -Category 'Import' -Message "Several groups are named '$($v[0].displayName)'; using $($v[0].id)." }
            }
        }
    }
    # Remaining ones are created (or reported) on demand
    foreach ($id in $todo) { if (-not $Ctx.GroupMap.ContainsKey($id)) { Resolve-IMGroupId -Ctx $Ctx -Id $id | Out-Null } }
}

function Update-IMIdReferences {
    <# Replaces every known source GUID in an object with its target GUID (dependencies + groups). #>
    param($Obj, $Ctx)
    if ($Ctx.SameTenant -or -not $Ctx.Settings.ReplaceDependencyIds) { return $Obj }
    if ($Ctx.IdMap.Count -eq 0 -and $Ctx.GroupMap.Count -eq 0) { return $Obj }
    $json = ConvertTo-IMJson $Obj -Compress
    $new = [regex]::Replace($json, $script:IMGuidPattern, {
        param($m)
        $v = $null
        if ($Ctx.IdMap.TryGetValue($m.Value, [ref]$v) -and $v) { return $v }
        if ($Ctx.GroupMap.TryGetValue($m.Value, [ref]$v) -and $v -and $v -notlike 'whatif-*') { return $v }
        $m.Value
    })
    if ($new -cne $json) { return ConvertFrom-IMJson $new }
    $Obj
}

function Get-IMReferencedGroupIds {
    param($Type, $Obj)
    $ids = [Collections.Generic.List[string]]::new()
    foreach ($a in @($Obj.assignments)) { if ($a.target.groupId) { $ids.Add($a.target.groupId) } }
    if ($Type.GroupReferences) { foreach ($g in @(& $Type.GroupReferences $Obj)) { if ($g) { $ids.Add($g) } } }
    if ($Type.Id -eq 'ConditionalAccess') { foreach ($g in (Get-IMConditionalAccessReferences $Obj).Groups) { $ids.Add($g) } }
    $ids
}
#endregion
