<#
  Import engine
  1. Plan:      scan the export, parse + validate every file, order by dependencies (ImportOrder)
  2. Prepare:   permission check, dependency id map (by name), group resolution (batched)
  3. Import:    per object: conflict handling, scope tags, PreImport hook, id remapping, create/update,
                PostImport hook, assignments. One failure never stops the run (unless ContinueOnError = $false).
  4. Report:    JSON + CSV report with every object, action, target id and Graph request id.
  -WhatIf runs steps 1-2 and reports what would happen without writing anything.
#>

$script:IMDefaultRemove = @('id', 'createdDateTime', 'lastModifiedDateTime', 'modifiedDateTime', 'supportsScopeTags', 'assignments', 'isAssigned', 'deletedDateTime')
$script:IMSkipFolders = @('Groups', '_Reports')

function Get-IMImportPlan {
    <# Scans an export folder and returns validated, ordered plan items. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [string[]]$ObjectType = @('*'), [string[]]$File)

    if (-not (Test-Path -LiteralPath $Path)) { throw "Import folder not found: $Path" }
    $root = (Resolve-Path -LiteralPath $Path).Path
    $types = Get-IMObjectType -Id $ObjectType
    $known = @{}; foreach ($t in (Get-IMObjectType)) { $known[$t.Id] = $t }

    # A type folder itself was selected -> its parent is the root
    $leaf = Split-Path $root -Leaf
    $folders = if ($known.ContainsKey($leaf)) { $root = Split-Path $root; @(Get-Item -LiteralPath (Join-Path $root $leaf)) }
               else { @(Get-ChildItem -LiteralPath $root -Directory | Where-Object { $known.ContainsKey($_.Name) }) }

    $manifest = $null
    $mp = Join-Path $root 'manifest.json'
    if (Test-Path -LiteralPath $mp) { try { $manifest = Read-IMJsonFile $mp } catch { Write-IMLog -Level Warning -Category 'Import' -Message 'manifest.json is invalid and was ignored.' } }
    $hashes = @{}
    foreach ($f in @($manifest.Files)) { if ($f.File) { $hashes[$f.File.Replace('\', '/').ToLowerInvariant()] = $f.Sha256 } }
    $fileFilter = if ($File) { [Collections.Generic.HashSet[string]]::new([string[]]@($File | ForEach-Object { [IO.Path]::GetFullPath($_) }), [StringComparer]::OrdinalIgnoreCase) } else { $null }

    $plan = foreach ($folder in $folders) {
        $type = $known[$folder.Name]
        if ($type -notin $types) { continue }
        foreach ($fi in (Get-ChildItem -LiteralPath $folder.FullName -Filter '*.json' -File | Where-Object { $_.BaseName -notmatch '_Settings$' })) {
            if ($fileFilter -and -not $fileFilter.Contains($fi.FullName)) { continue }
            $item = [pscustomobject]@{ Type = $type; TypeId = $type.Id; File = $fi.FullName; Name = $fi.BaseName; SourceId = $null; Object = $null
                Valid = $true; Error = $null; Order = $type.ImportOrder; Modified = $false; AssignmentCount = 0; Selected = $true }
            try {
                $o = Read-IMJsonFile $fi.FullName
                if ($o -isnot [psobject] -or $o -is [array]) { throw 'The file does not contain a single object.' }
                if (-not $type.CanImport) { throw "$($type.Title) cannot be imported." }
                $item.Object = $o
                $item.Name = Get-IMObjectName $type $o
                $item.SourceId = [string]$o.id
                $item.AssignmentCount = @($o.assignments | Where-Object { $_ }).Count
                $rel = [IO.Path]::GetRelativePath($root, $fi.FullName).Replace('\', '/').ToLowerInvariant()
                if ($hashes.ContainsKey($rel) -and $hashes[$rel] -ne (Get-IMFileHash $fi.FullName)) { $item.Modified = $true }
            }
            catch { $item.Valid = $false; $item.Error = $_.Exception.Message }
            $item
        }
    }
    $sorted = @($plan | Sort-Object Order, TypeId, Name)
    Write-IMLog -Category 'Import' -Message "Import plan: $($sorted.Count) file(s), $(@($sorted | Where-Object { -not $_.Valid }).Count) invalid, $(@($sorted | Where-Object Modified).Count) modified since export"
    [pscustomobject]@{ Root = $root; Manifest = $manifest; Items = $sorted }
}

function Remove-IMImportNoise {
    param($Obj, $Type)
    Remove-IMProperty $Obj ($script:IMDefaultRemove + @($Type.PropertiesToRemove))
    foreach ($p in @($Obj.PSObject.Properties.Name)) {
        if ($p -like '*@odata.context' -or $p -like '*@odata.navigationLink' -or $p -like '*@odata.associationLink' -or $p -like '*@odata.id' -or ($p -like '#*')) { Remove-IMProperty $Obj $p }
        elseif ($p -like '*@odata.type' -and $p -ne '@odata.type') { Remove-IMProperty $Obj $p }
    }
}

function ConvertTo-IMAssignmentBody {
    <# Cleans exported assignments and maps groups/filters. Returns the list to send. #>
    param($Type, $Assignments, $Ctx)
    $keepTarget = @('@odata.type', 'groupId', 'deviceAndAppManagementAssignmentFilterId', 'deviceAndAppManagementAssignmentFilterType', 'collectionId')
    $out = foreach ($a in @($Assignments)) {
        if (-not $a -or -not $a.target) { continue }
        if ($a.source -and $a.source -ne 'direct') { continue }   # e.g. inherited from a policy set
        $c = Copy-IMObject $a
        foreach ($n in @($c.PSObject.Properties.Name)) { if ($n -ne 'target' -and $n -notin $Type.AssignmentProperties) { Remove-IMProperty $c $n } }
        foreach ($n in @($c.target.PSObject.Properties.Name)) { if ($n -notin $keepTarget) { Remove-IMProperty $c.target $n } }
        if ($c.target.groupId) {
            $g = Resolve-IMGroupId -Ctx $Ctx -Id $c.target.groupId
            if (-not $g) { $Ctx.Warnings.Add("Assignment to group $($Ctx.Migration[$c.target.groupId].DisplayName ?? $c.target.groupId) skipped (group not available)."); continue }
            $c.target.groupId = $g
        }
        $fid = Get-IMPropertyValue $c.target 'deviceAndAppManagementAssignmentFilterId'
        if ($fid -and $fid -ne '00000000-0000-0000-0000-000000000000') {
            $nf = Resolve-IMMappedId -Ctx $Ctx -Id $fid
            if ($nf) { $c.target.deviceAndAppManagementAssignmentFilterId = $nf }
            else {
                $Ctx.Warnings.Add("Assignment filter $fid not found in target; assignment imported without filter.")
                $c.target.deviceAndAppManagementAssignmentFilterId = $null; $c.target.deviceAndAppManagementAssignmentFilterType = 'none'
            }
        }
        # Remap ids inside assignment settings (e.g. app settings referencing other objects)
        if ($c.settings) { $c.settings = Update-IMIdReferences $c.settings $Ctx }
        $c
    }
    @($out)
}

function Import-IMAssignments {
    param($Type, $Target, $Assignments, $Ctx)
    $list = ConvertTo-IMAssignmentBody -Type $Type -Assignments $Assignments -Ctx $Ctx
    if (-not $list.Count) { return 0 }
    if ($Type.Assign) { if (& $Type.Assign $Type $Target $list $Ctx) { return $list.Count } }
    $uri = if ($Type.AssignUri) { & $Type.AssignUri $Type $Target $Ctx } else { "$(Get-IMObjectTypeApi $Type)/$($Target.id)/assign" }
    Invoke-IMGraphRequest -Method POST -Uri $uri -Body @{ $Type.AssignmentsProperty = $list } -Version $Type.Version | Out-Null
    $list.Count
}

function Get-IMUniqueName {
    param([string]$Name, [string]$Suffix, [string[]]$Existing)
    $candidate = "$Name$Suffix"; $i = 2
    while ($candidate -in $Existing) { $candidate = "$Name$Suffix ($i)"; $i++ }
    $candidate
}

function Import-IMPlanItem {
    <# Imports one object. Returns the result record. #>
    param($Item, $Ctx, $ExistingByName, [string[]]$ExistingNames)
    $type = $Item.Type
    $op = $Ctx.Operation
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $src = $Item.Object
    $obj = Copy-IMObject $src
    $assignments = @($obj.assignments | Where-Object { $_ })
    Reset-IMImportObjectState -Ctx $Ctx -File $Item.File -Source $src
    $name = $Item.Name
    $s = $Ctx.Settings
    $targetName = "$($s.NamePrefix)$name"
    $existing = $ExistingByName[$targetName]
    $mode = 'Create'
    $verb = { param($m) switch ($m) { 'Create' { 'Created' } 'Update' { 'Updated' } 'Replace' { 'Replaced' } default { $m } } }

    if ($existing) {
        switch ($s.ConflictAction) {
            'Skip' {
                Register-IMImportedId -Ctx $Ctx -Type $type -OldId $src.id -NewId $existing.id
                return Add-IMOperationResult -Operation $op -ObjectType $type.Id -Name $name -Action 'Skipped' -Status 'Skipped' -SourceId $src.id -TargetId $existing.id -File $Item.File -Message 'An object with this name already exists.' -Seconds $sw.Elapsed.TotalSeconds
            }
            'Rename' { $targetName = Get-IMUniqueName -Name $targetName -Suffix $s.RenameSuffix -Existing $ExistingNames }
            'Update' { $mode = 'Update' }
            'Replace' { $mode = 'Replace' }
            default { }
        }
    }
    $Ctx.Mode = $mode

    if ($Ctx.WhatIf) {
        Register-IMImportedId -Ctx $Ctx -Type $type -OldId $src.id -NewId ($existing.id ?? "whatif-$($src.id)")
        $list = if ($s.ImportAssignments -and $type.Assignments) { ConvertTo-IMAssignmentBody -Type $type -Assignments $assignments -Ctx $Ctx } else { @() }
        $msg = @()
        if ($targetName -ne $name) { $msg += "as '$targetName'" }
        if ($s.ImportAssignments -and $assignments.Count) { $msg += "$($list.Count)/$($assignments.Count) assignment(s)" }
        $msg += $Ctx.Warnings
        $action = "Would$mode"
        return Add-IMOperationResult -Operation $op -ObjectType $type.Id -Name $name -Action $action -Status $(if ($Ctx.Warnings.Count) { 'Warning' } else { 'Success' }) -SourceId $src.id -TargetId $existing.id -File $Item.File -Message ($msg -join '; ') -Seconds $sw.Elapsed.TotalSeconds
    }

    $created = $null
    try {
        Remove-IMProperty $obj 'assignments'
        if ($type.NameProperty -notin 'id', 'fileName' -and (Test-IMProperty $obj $type.NameProperty)) { $obj.($type.NameProperty) = $targetName }
        Set-IMScopeTags $obj $Ctx

        $pre = if ($type.PreImport) { & $type.PreImport $type $obj $Ctx } else { $null }
        if ($pre -isnot [hashtable]) { $pre = @{} }
        if ($pre.Skip) {
            if ($pre.ExistingId) { Register-IMImportedId -Ctx $Ctx -Type $type -OldId $src.id -NewId $pre.ExistingId }
            return Add-IMOperationResult -Operation $op -ObjectType $type.Id -Name $name -Action 'Skipped' -Status 'Skipped' -SourceId $src.id -TargetId $pre.ExistingId -File $Item.File -Message $pre.Reason -Seconds $sw.Elapsed.TotalSeconds
        }

        $body = if ($pre.Body) { $pre.Body } else { Remove-IMImportNoise $obj $type; $obj }
        $body = Update-IMIdReferences $body $Ctx
        $api = Get-IMObjectTypeApi $type
        $version = $pre.Version ?? $type.Version

        if ($pre.ForceUpdate) {
            # Singleton/default objects: always PATCH the existing one
            Invoke-IMGraphRequest -Method ($pre.Method ?? 'PATCH') -Uri $pre.Uri -Body $body -Version $version | Out-Null
            $created = [pscustomobject]@{ id = $pre.ExistingId; displayName = $targetName; '@odata.type' = $src.'@odata.type' }
            $mode = 'Update'; $Ctx.Mode = 'Update'
        }
        elseif ($mode -eq 'Update') {
            $Ctx.Mode = 'Update'
            $pu = if ($type.PreUpdate) { & $type.PreUpdate $type $body $existing $Ctx } else { $null }
            if ($pu -isnot [hashtable]) { $pu = @{} }
            $method = $pu.Method ?? 'PATCH'
            if ($method -eq 'PATCH') { Remove-IMProperty $body @($type.PropertiesToRemoveForUpdate) }
            $uri = $pu.Uri ?? (($pre.Uri ?? $api) + "/$($existing.id)")
            Invoke-IMGraphRequest -Method $method -Uri $uri -Body $body -Version $version | Out-Null
            $created = [pscustomobject]@{ id = $existing.id; displayName = $targetName; '@odata.type' = $src.'@odata.type' }
        }
        else {
            if ($mode -eq 'Replace') {
                $delUri = if ($type.ItemUri) { (& $type.ItemUri $type $existing) -replace '\?.*$', '' } else { "$api/$($existing.id)" }
                Invoke-IMGraphRequest -Method DELETE -Uri $delUri -Version $version | Out-Null
                Write-IMLog -Category 'Import' -Message "Deleted existing '$targetName' ($($existing.id)) before re-creating it"
            }
            $created = Invoke-IMGraphRequest -Method ($pre.Method ?? 'POST') -Uri ($pre.Uri ?? $api) -Body $body -Version $version
            if (-not $created.id -and $pre.ExistingId) { $created = [pscustomobject]@{ id = $pre.ExistingId } }
        }
        Register-IMImportedId -Ctx $Ctx -Type $type -OldId $src.id -NewId $created.id
    }
    catch {
        $msg = $_.Exception.Message
        if ($_.Exception -is [IntuneManager.GraphException] -and $_.Exception.StatusCode -eq 400) {
            $msg = "$msg  Check the object in the export file; the property list may not match this tenant's API version."
        }
        Write-IMLog -Level Debug -Category 'Import' -Message "Request body for failed '$name'" -Data @{ File = $Item.File }
        return Add-IMOperationResult -Operation $op -ObjectType $type.Id -Name $name -Action (& $verb $mode) -Status 'Failed' -SourceId $src.id -File $Item.File -Message $msg -ErrorRecord $_ -Seconds $sw.Elapsed.TotalSeconds
    }

    # Follow-up steps: object exists now; failures become warnings
    if ($type.PostImport) {
        try { & $type.PostImport $type $src $created $Ctx }
        catch { $Ctx.Warnings.Add("Follow-up step failed: $($_.Exception.Message)$(if ($_.Exception.RequestId) { " (request-id $($_.Exception.RequestId))" })") ; Write-IMLog -Level Warning -Category 'Import' -Message "Post-import step for '$name' failed" -ErrorRecord $_ }
    }
    $assigned = 0
    if ($s.ImportAssignments -and $type.Assignments -and $assignments.Count -and -not $pre.NoAssign) {
        try { $assigned = Import-IMAssignments -Type $type -Target $created -Assignments $assignments -Ctx $Ctx }
        catch { $Ctx.Warnings.Add("Assignments failed: $($_.Exception.Message)"); Write-IMLog -Level Warning -Category 'Import' -Message "Assignments for '$name' failed" -ErrorRecord $_ }
    }
    $msg = @()
    if ($targetName -ne $name) { $msg += "as '$targetName'" }
    if ($assignments.Count -and $s.ImportAssignments -and $type.Assignments) { $msg += "$assigned/$($assignments.Count) assignment(s)" }
    $msg += $Ctx.Warnings
    Add-IMOperationResult -Operation $op -ObjectType $type.Id -Name $name -Action (& $verb $mode) -Status $(if ($Ctx.Warnings.Count) { 'Warning' } else { 'Success' }) -SourceId $src.id -TargetId $created.id -File $Item.File -Message ($msg -join '; ') -Seconds $sw.Elapsed.TotalSeconds
}

function Import-IMObjects {
    <#
    .SYNOPSIS
    Imports an export folder into the connected tenant.
    .PARAMETER ConflictAction  Skip | Rename | Update | Replace | Duplicate when an object with the same name exists.
    .PARAMETER WhatIf          Validate and report what would happen; nothing is written.
    .PARAMETER File            Import only these files (e.g. the failed ones from a report).
    .EXAMPLE
    Import-IMObjects -Path C:\Backup\Contoso\2026-10-17_0900 -WhatIf
    .EXAMPLE
    Import-IMObjects -Path C:\Backup\Contoso\2026-10-17_0900 -ObjectType SettingsCatalog -ConflictAction Update
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$ObjectType = @('*'),
        [string[]]$File,
        [ValidateSet('Skip', 'Rename', 'Update', 'Replace', 'Duplicate')][string]$ConflictAction,
        [Nullable[bool]]$ImportAssignments,
        [Nullable[bool]]$ImportScopeTags,
        [Nullable[bool]]$CreateMissingGroups,
        [string]$NamePrefix,
        [ValidateSet('disabled', 'enabledForReportingButNotEnforced', 'enabled')][string]$ConditionalAccessState = 'disabled',
        [switch]$WhatIf,
        $Plan,
        [hashtable]$Progress
    )
    if (-not $script:IMConnection) { throw 'Not connected. Connect to a tenant first.' }
    $options = @{ WhatIf = [bool]$WhatIf; ConditionalAccessState = $ConditionalAccessState }
    if ($ConflictAction) { $options.ConflictAction = $ConflictAction }
    if ($null -ne $ImportAssignments) { $options.ImportAssignments = [bool]$ImportAssignments }
    if ($null -ne $ImportScopeTags) { $options.ImportScopeTags = [bool]$ImportScopeTags }
    if ($null -ne $CreateMissingGroups) { $options.CreateMissingGroups = [bool]$CreateMissingGroups }
    if ($PSBoundParameters.ContainsKey('NamePrefix')) { $options.NamePrefix = $NamePrefix }

    if (-not $Plan) { $Plan = Get-IMImportPlan -Path $Path -ObjectType $ObjectType -File $File }
    else {
        # A plan built in another runspace (the UI) carries hook scriptblocks bound to that runspace; rebind to ours
        foreach ($i in $Plan.Items) { $i.Type = Get-IMObjectType -Id $i.TypeId | Select-Object -First 1 }
    }
    $opName = if ($WhatIf) { 'ImportPreview' } else { 'Import' }
    $op = Start-IMOperation -Name $opName -Progress $Progress -Parameters @{ Path = $Plan.Root; Types = @($Plan.Items.TypeId | Select-Object -Unique); Options = $options; Tenant = $script:IMConnection.TenantId }
    $ctx = New-IMImportContext -Root $Plan.Root -Options $options -Operation $op

    $items = @($Plan.Items | Where-Object { $_.Selected -ne $false })
    foreach ($bad in @($items | Where-Object { -not $_.Valid })) {
        Add-IMOperationResult -Operation $op -ObjectType $bad.TypeId -Name $bad.Name -Action 'Validate' -Status 'Failed' -File $bad.File -Message "Invalid file: $($bad.Error)" | Out-Null
    }
    $items = @($items | Where-Object Valid)
    foreach ($m in @($items | Where-Object Modified)) { Write-IMLog -Level Info -Category 'Import' -Message "'$($m.Name)' was modified after export." }

    # Permission check per type
    $denied = @($items.Type | Select-Object -Unique | Where-Object { -not (Test-IMPermission $_.Permission -Write) })
    foreach ($t in $denied) {
        foreach ($i in @($items | Where-Object TypeId -eq $t.Id)) { Add-IMOperationResult -Operation $op -ObjectType $t.Id -Name $i.Name -Action 'Skipped' -Status 'Skipped' -File $i.File -Message "Missing permission $($t.Permission)" | Out-Null }
    }
    $items = @($items | Where-Object { $_.Type -notin $denied })

    try {
        # Dependency maps: always scope tags + filters, plus every dependency of the selected types
        Update-IMProgress -Operation $op -Status 'Preparing: mapping dependencies' -Current 0 -Total $items.Count -Item ''
        $deps = [Collections.Generic.HashSet[string]]::new([string[]]@('ScopeTags', 'AssignmentFilters'))
        foreach ($t in ($items.Type | Select-Object -Unique)) { foreach ($d in @($t.Dependencies)) { [void]$deps.Add($d) } }
        foreach ($d in $deps) { Add-IMDependencyMap -Ctx $ctx -TypeId $d }

        if ($ctx.Settings.ImportAssignments) {
            Update-IMProgress -Operation $op -Status 'Preparing: resolving groups' -Current 0 -Total $items.Count -Item ''
            $gids = foreach ($i in $items) { Get-IMReferencedGroupIds -Type $i.Type -Obj $i.Object }
            Initialize-IMGroupMap -Ctx $ctx -GroupIds @($gids)
        }
    }
    catch { Write-IMLog -Level Error -Category 'Import' -Message 'Preparation failed; continuing with what could be resolved' -ErrorRecord $_ }

    $n = 0
    $stop = $false
    foreach ($group in ($items | Group-Object TypeId | Sort-Object { $_.Group[0].Order })) {
        if ($stop -or (Test-IMCancelled $op)) { break }
        $type = $group.Group[0].Type
        $byName = @{}; $names = @()
        try {
            $existingList = @(Get-IMObjectList -Type $type)
            foreach ($e in $existingList) { $nm = Get-IMObjectName $type $e; $names += $nm; if (-not $byName.ContainsKey($nm)) { $byName[$nm] = $e } }
        }
        catch { Write-IMLog -Level Warning -Category 'Import' -Message "Could not list existing $($type.Title); conflicts cannot be detected" -ErrorRecord $_ }

        $typeState = @{ Relationships = @() }
        $imported = [Collections.Generic.List[object]]::new()
        foreach ($item in $group.Group) {
            if (Test-IMCancelled $op) { break }
            $n++
            Update-IMProgress -Operation $op -Status "$(if ($ctx.WhatIf) { 'Checking' } else { 'Importing' }) $($type.Title)" -Current $n -Total $items.Count -Item $item.Name
            $ctx.TypeState = $typeState
            $r = Import-IMPlanItem -Item $item -Ctx $ctx -ExistingByName $byName -ExistingNames $names
            if ($r.Status -in 'Success', 'Warning') { $imported.Add($r); $names += $r.Name }
            if ($r.Status -eq 'Failed' -and -not $ctx.Settings.ContinueOnError) { $stop = $true; Write-IMLog -Level Error -Category 'Import' -Message 'Stopping because ContinueOnError is off.'; break }
        }
        if ($type.AfterType -and -not $ctx.WhatIf -and $imported.Count) {
            $ctx.TypeState = $typeState
            try { & $type.AfterType $type $imported $ctx } catch { Write-IMLog -Level Warning -Category 'Import' -Message "Final step for $($type.Title) failed" -ErrorRecord $_ }
        }
    }

    if ($ctx.WhatIf -and $ctx.PlannedGroups.Count) {
        Write-IMLog -Level Info -Category 'ImportPreview' -Message "Groups that would be created: $(($ctx.PlannedGroups | Select-Object -Unique) -join ', ')"
        foreach ($g in ($ctx.PlannedGroups | Select-Object -Unique)) { Add-IMOperationResult -Operation $op -ObjectType 'Group' -Name $g -Action 'WouldCreate' | Out-Null }
    }
    Complete-IMOperation -Operation $op
}

function Get-IMFailedFiles {
    <# Files that failed in an import report, to re-run just those (Import-IMObjects -File). #>
    param([Parameter(Mandatory)][string]$ReportPath)
    $r = Read-IMJsonFile $ReportPath
    @($r.Results | Where-Object { $_.Status -eq 'Failed' -and $_.File } | ForEach-Object File | Select-Object -Unique)
}
