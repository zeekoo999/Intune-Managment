<#
  Reading objects and exporting them.
  Layout (compatible with IntuneManagement):
    <root>\manifest.json            tool/tenant info, counts, file hashes
    <root>\MigrationTable.json      groups/users referenced by assignments
    <root>\Groups\<name>.json       group definitions used to recreate groups
    <root>\<TypeId>\<name>.json     one file per object, assignments included
#>

$script:IMToolVersion = '1.0.0'

function Get-IMObjectList {
    <# Lists objects of a type (summary objects from the collection endpoint). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Type)
    if ($Type -is [string]) { $Type = Get-IMObjectType -Id $Type | Select-Object -First 1 }
    $items = @(if ($Type.List) { & $Type.List $Type }
    else {
        $api = Get-IMObjectTypeApi $Type
        $uri = if ($Type.ListQuery) { "$api`?$($Type.ListQuery)" } else { $api }
        try { Get-IMGraphCollection $uri -Version $Type.Version }
        catch {
            if ($Type.ListQuery -and $_.Exception -is [IntuneManager.GraphException] -and $_.Exception.StatusCode -eq 400) {
                # Some tenants reject certain filters; fall back to listing all and let PostList filter
                Write-IMLog -Level Debug -Category 'Graph' -Message "$($Type.Title): list filter rejected, retrying without it"
                Get-IMGraphCollection $api -Version $Type.Version
            }
            else { throw }
        }
    })
    if ($Type.PostList) { $items = @(& $Type.PostList $Type $items) }
    $items | Where-Object { $_ }
}

function Get-IMItemUri {
    param($Type, $Item, [switch]$WithExpand)
    $uri = if ($Type.ItemUri) { & $Type.ItemUri $Type $Item } else { "$(Get-IMObjectTypeApi $Type)/$($Item.id)" }
    if ($WithExpand -and $uri -notmatch '\$expand=') {
        $expand = @($Type.FullExpand)
        if ($Type.Assignments -and $Type.ExpandAssignments) { $expand += 'assignments' }
        if ($expand.Count) { $uri += $(if ($uri.Contains('?')) { '&' } else { '?' }) + "`$expand=$($expand -join ',')" }
    }
    $uri
}

function Complete-IMFullObject {
    <# Adds assignments when they were not expanded and runs the PostGet hook. #>
    param($Type, $Obj)
    if ($Type.Assignments -and -not (Test-IMProperty $Obj 'assignments')) {
        $base = Get-IMItemUri $Type $Obj
        $base = $base -replace '\?.*$', ''
        $a = Get-IMGraphCollection "$base/assignments" -Version $Type.Version -IgnoreNotFound
        Set-IMProperty $Obj 'assignments' @($a)
    }
    if ($Type.PostGet) { & $Type.PostGet $Type $Obj }
    $Obj
}

function Get-IMObject {
    <# Reads one full object (settings, assignments and type-specific data). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Type, [Parameter(Mandatory)]$Item)
    if ($Type -is [string]) { $Type = Get-IMObjectType -Id $Type | Select-Object -First 1 }
    if ($Item -is [string]) { $Item = [pscustomobject]@{ id = $Item } }
    try { $obj = Invoke-IMGraphRequest -Uri (Get-IMItemUri $Type $Item -WithExpand) -Version $Type.Version }
    catch {
        if ($_.Exception -isnot [IntuneManager.GraphException] -or $_.Exception.StatusCode -ne 400) { throw }
        Write-IMLog -Level Debug -Category 'Graph' -Message "$($Type.Title): expand rejected for $($Item.id), reading without expand"
        $obj = Invoke-IMGraphRequest -Uri (Get-IMItemUri $Type $Item) -Version $Type.Version
    }
    # Keep list-only helper properties (e.g. '#DepToken')
    foreach ($p in @($Item.PSObject.Properties | Where-Object { $_.Name -like '#*' })) { Set-IMProperty $obj $p.Name $p.Value }
    Complete-IMFullObject $Type $obj
}

function Get-IMObjectsBatched {
    <# Reads many full objects with $batch, falling back to single reads for any that fail. #>
    param([Parameter(Mandatory)]$Type, [Parameter(Mandatory)][object[]]$Items, $Operation)
    $results = [Collections.Generic.List[object]]::new()
    $reqs = for ($i = 0; $i -lt $Items.Count; $i++) { [pscustomobject]@{ id = "$i"; method = 'GET'; url = (Get-IMItemUri $Type $Items[$i] -WithExpand) } }
    $batch = if ($Items.Count -gt 1) { Invoke-IMGraphBatch -Requests $reqs -Version $Type.Version } else { @{} }
    for ($i = 0; $i -lt $Items.Count; $i++) {
        if ($Operation -and (Test-IMCancelled $Operation)) { break }
        $item = $Items[$i]
        $r = $batch["$i"]
        try {
            if ($r -and $r.Status -lt 300 -and $r.Body) {
                $obj = $r.Body
                foreach ($p in @($item.PSObject.Properties | Where-Object { $_.Name -like '#*' })) { Set-IMProperty $obj $p.Name $p.Value }
                $obj = Complete-IMFullObject $Type $obj
            }
            else { $obj = Get-IMObject -Type $Type -Item $item }
            $results.Add([pscustomobject]@{ Item = $item; Object = $obj; Error = $null })
        }
        catch { $results.Add([pscustomobject]@{ Item = $item; Object = $null; Error = $_ }) }
    }
    , $results.ToArray()
}

function Get-IMExportFilePath {
    param([string]$Folder, [string]$BaseName, [string]$Id, [Collections.Generic.HashSet[string]]$Used)
    $name = $BaseName
    if (-not $Used.Add($name.ToLowerInvariant())) {
        $name = "${BaseName}_$Id"
        [void]$Used.Add($name.ToLowerInvariant())
    }
    [pscustomobject]@{ Path = Join-Path $Folder "$name.json"; BaseName = $name }
}

function Export-IMObjects {
    <#
    .SYNOPSIS
    Exports Intune/Entra objects to JSON with assignments, a migration table and a manifest.
    .EXAMPLE
    Export-IMObjects -Path C:\Backup -ObjectType SettingsCatalog,CompliancePolicies
    .EXAMPLE
    Export-IMObjects -Path C:\Backup   # all object types the app has permission for
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$ObjectType = @('*'),
        [hashtable]$Selection,          # TypeId -> array of summary objects (export only these)
        [Nullable[bool]]$IncludeAssignments,
        [switch]$NoDateFolder,
        [hashtable]$Progress
    )
    if (-not $script:IMConnection) { throw 'Not connected. Connect to a tenant first.' }
    $assign = if ($null -ne $IncludeAssignments) { [bool]$IncludeAssignments } else { [bool](Get-IMSetting 'ExportAssignments') }
    $types = if ($Selection) { @(Get-IMObjectType | Where-Object { $Selection.ContainsKey($_.Id) }) } else { @(Get-IMObjectType -Id $ObjectType) }

    $root = $Path
    if (-not $NoDateFolder -and (Get-IMSetting 'AddDateFolder')) {
        $tenant = Get-IMSafeFileName ($script:IMConnection.Organization.DisplayName ?? $script:IMConnection.TenantId)
        $root = Join-Path (Join-Path $Path $tenant) (Get-Date -Format 'yyyy-MM-dd_HHmm')
    }
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $root = (Resolve-Path -LiteralPath $root).Path

    $op = Start-IMOperation -Name 'Export' -Progress $Progress -Parameters @{ Path = $root; Types = @($types.Id); Assignments = $assign; Tenant = $script:IMConnection.TenantId }
    $collector = New-IMMigrationCollector
    $files = [Collections.Generic.List[object]]::new()
    $counts = [ordered]@{}
    $typeIndex = 0

    foreach ($type in $types) {
        $typeIndex++
        if (Test-IMCancelled $op) { break }
        Update-IMProgress -Operation $op -Status "Reading $($type.Title)" -Current $typeIndex -Total $types.Count -Item ''
        if (-not (Test-IMPermission $type.Permission)) {
            Add-IMOperationResult -Operation $op -ObjectType $type.Id -Name "($($type.Title))" -Action 'Skipped' -Status 'Skipped' -Message "Missing permission $($type.Permission)" | Out-Null
            continue
        }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try { $items = @(if ($Selection) { $Selection[$type.Id] } else { Get-IMObjectList -Type $type }) }
        catch {
            $msg = if ($_.Exception.StatusCode -eq 403) { "Access denied. Grant $($type.Permission) to the app." } elseif ($_.Exception.StatusCode -eq 404 -or $_.Exception.StatusCode -eq 400) { 'Not available in this tenant (feature not licensed or API not enabled).' } else { $null }
            Add-IMOperationResult -Operation $op -ObjectType $type.Id -Name "($($type.Title))" -Action 'List' -Status $(if ($msg -and $_.Exception.StatusCode -ne 403) { 'Skipped' } else { 'Failed' }) -Message $msg -ErrorRecord $_ | Out-Null
            continue
        }
        if (-not $items.Count) { Write-IMLog -Level Debug -Category 'Export' -Message "$($type.Title): nothing to export"; continue }

        Write-IMLog -Category 'Export' -Message "$($type.Title): exporting $($items.Count) object(s)"
        $folder = Join-Path $root $type.Id
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        $used = [Collections.Generic.HashSet[string]]::new()
        $counts[$type.Id] = 0

        # Read in chunks so progress stays responsive and memory stays bounded
        $chunkSize = 40
        for ($c = 0; $c -lt $items.Count; $c += $chunkSize) {
            if (Test-IMCancelled $op) { break }
            $chunk = $items[$c..([math]::Min($c + $chunkSize, $items.Count) - 1)]
            $read = Get-IMObjectsBatched -Type $type -Items $chunk -Operation $op
            $n = $c
            foreach ($r in $read) {
                $n++
                $name = Get-IMObjectName $type ($r.Object ?? $r.Item)
                Update-IMProgress -Operation $op -Status "Exporting $($type.Title) ($n/$($items.Count))" -Current $typeIndex -Total $types.Count -Item $name
                $osw = [Diagnostics.Stopwatch]::StartNew()
                if ($r.Error) {
                    Add-IMOperationResult -Operation $op -ObjectType $type.Id -Name $name -Action 'Export' -Status 'Failed' -SourceId $r.Item.id -ErrorRecord $r.Error | Out-Null
                    continue
                }
                try {
                    $obj = $r.Object
                    foreach ($p in @($obj.PSObject.Properties.Name | Where-Object { $_ -like '*@odata.context' -or $_ -like '*@odata.navigationLink' -or $_ -like '*@odata.associationLink' })) { Remove-IMProperty $obj $p }
                    if (-not $assign) { Remove-IMProperty $obj 'assignments' }
                    $baseName = Get-IMBaseFileName $type $obj
                    $target = Get-IMExportFilePath -Folder $folder -BaseName $baseName -Id $obj.id -Used $used
                    Write-IMJsonFile -Path $target.Path -InputObject $obj
                    if ($type.ExportFiles) {
                        try { & $type.ExportFiles $type $obj $folder $target.BaseName }
                        catch { Write-IMLog -Level Warning -Category 'Export' -Message "Extra files for '$name' were not written" -ErrorRecord $_ }
                    }
                    if ($assign) { Add-IMMigrationReferences -Collector $collector -Type $type -Obj $obj }
                    $rel = [IO.Path]::GetRelativePath($root, $target.Path)
                    $files.Add([pscustomobject]@{ Type = $type.Id; Name = $name; Id = [string]$obj.id; File = $rel; Sha256 = Get-IMFileHash $target.Path })
                    $counts[$type.Id]++
                    Add-IMOperationResult -Operation $op -ObjectType $type.Id -Name $name -Action 'Exported' -SourceId $obj.id -File $rel -Seconds $osw.Elapsed.TotalSeconds | Out-Null
                }
                catch { Add-IMOperationResult -Operation $op -ObjectType $type.Id -Name $name -Action 'Export' -Status 'Failed' -SourceId $r.Item.id -ErrorRecord $_ | Out-Null }
            }
        }
        Write-IMLog -Level Debug -Category 'Export' -Message "$($type.Title) done in $(Format-IMDuration $sw.Elapsed)"
    }

    if ($assign -and ($collector.Groups.Count -or $collector.Users.Count)) {
        Update-IMProgress -Operation $op -Status 'Writing migration table' -Current $types.Count -Total $types.Count -Item ''
        try { Save-IMMigrationTable -Collector $collector -Root $root -Operation $op }
        catch { Write-IMLog -Level Error -Category 'Export' -Message 'Could not write the migration table; group assignments cannot be imported to another tenant.' -ErrorRecord $_ }
    }

    $manifest = [ordered]@{
        Tool = 'IntuneManager'; ToolVersion = $script:IMToolVersion; FormatVersion = 1
        ExportedAt = (Get-Date).ToString('o'); TenantId = $script:IMConnection.TenantId
        Organization = $script:IMConnection.Organization.DisplayName; Cloud = $script:IMConnection.Cloud
        GraphVersion = Get-IMSetting 'GraphApiVersion'; Assignments = $assign; Complete = -not $op.Cancelled
        Counts = $counts; Files = $files.ToArray()
    }
    Write-IMJsonFile -Path (Join-Path $root 'manifest.json') -InputObject $manifest
    $summary = Complete-IMOperation -Operation $op -ReportDirectory (Join-Path $root '_Reports')
    $summary | Add-Member -NotePropertyName ExportPath -NotePropertyValue $root -PassThru
}
