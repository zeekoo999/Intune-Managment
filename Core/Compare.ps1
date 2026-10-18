<#
  Compare
  - Compare-IMExports:  two export folders (two tenants, or two points in time)
  - Compare-IMObjects:  an export folder against the connected tenant
  Objects are matched by type + name. Volatile properties are ignored, settings arrays are keyed by
  setting id (not position), and assignments are compared by group name so cross-tenant compares work.
#>

$script:IMCompareIgnore = @('id', 'createdDateTime', 'lastModifiedDateTime', 'modifiedDateTime', 'version', 'settingCount', 'supportsScopeTags',
    'isAssigned', 'deviceStatusOverview', 'userStatusOverview', 'uploadState', 'publishingState', 'committedContentVersion', 'size',
    'dependentAppCount', 'supersedingAppCount', 'supersededAppCount', 'creationSource', 'priorityMetaData', 'roleScopeTagIds', 'deletedDateTime')

function Get-IMArrayItemKey {
    param($Item)
    if ($Item -isnot [psobject] -or $Item -is [string] -or $Item -is [ValueType]) { return $null }
    foreach ($k in 'settingDefinitionId', 'definitionId', 'omaUri', '#Definition_Id', 'ruleName', 'payloadId', 'locale', 'displayName', 'name', 'key') {
        $v = Get-IMPropertyValue $Item $k
        if ($v) { return "$k=$v" }
    }
    $si = Get-IMPropertyValue $Item 'settingInstance'
    if ($si.settingDefinitionId) { return $si.settingDefinitionId }
    $null
}

function ConvertTo-IMFlatTable {
    <# Flattens an object into path -> string value. #>
    param($InputObject, [string]$Prefix = '', [hashtable]$Table = @{})
    if ($null -eq $InputObject) { if ($Prefix) { $Table[$Prefix] = '' }; return $Table }
    if ($InputObject -is [array]) {
        if ($InputObject.Count -eq 0) { $Table[$Prefix] = '[]'; return $Table }
        $i = 0
        foreach ($item in $InputObject) {
            $key = Get-IMArrayItemKey $item
            $seg = if ($key) { "[$key]" } else { "[$i]" }
            ConvertTo-IMFlatTable -InputObject $item -Prefix "$Prefix$seg" -Table $Table | Out-Null
            $i++
        }
        return $Table
    }
    if ($InputObject -is [psobject] -and $InputObject -isnot [string] -and $InputObject -isnot [ValueType]) {
        foreach ($p in $InputObject.PSObject.Properties) {
            if ($p.Name -in $script:IMCompareIgnore -or $p.Name -like '*@odata.context' -or $p.Name -like '*@odata.*Link' -or ($p.Name -like '#*' -and $p.Name -notlike '#Definition*')) { continue }
            $path = if ($Prefix) { "$Prefix.$($p.Name)" } else { $p.Name }
            ConvertTo-IMFlatTable -InputObject $p.Value -Prefix $path -Table $Table | Out-Null
        }
        return $Table
    }
    $Table[$Prefix] = [string]$InputObject
    $Table
}

function ConvertTo-IMComparableAssignments {
    param($Assignments, [hashtable]$GroupNames, [hashtable]$FilterNames)
    $list = foreach ($a in @($Assignments | Where-Object { $_ })) {
        $t = $a.target
        $kind = ($t.'@odata.type' -split '\.')[-1] -replace 'AssignmentTarget$', ''
        $who = if ($t.groupId) { $GroupNames[$t.groupId] ?? $t.groupId } else { '' }
        $f = if ($t.deviceAndAppManagementAssignmentFilterId -and $t.deviceAndAppManagementAssignmentFilterType -ne 'none') { " filter:$($t.deviceAndAppManagementAssignmentFilterType):$($FilterNames[$t.deviceAndAppManagementAssignmentFilterId] ?? $t.deviceAndAppManagementAssignmentFilterId)" } else { '' }
        $intent = if ($a.intent) { " [$($a.intent)]" } else { '' }
        "$kind $who$intent$f".Trim()
    }
    @($list | Sort-Object)
}

function Get-IMExportNameMaps {
    param([string]$Root)
    $groups = @{}; $filters = @{}
    $mig = Join-Path $Root 'MigrationTable.json'
    if (Test-Path -LiteralPath $mig) { foreach ($o in @((Read-IMJsonFile $mig).Objects)) { if ($o.Id) { $groups[$o.Id] = $o.DisplayName } } }
    $ff = Join-Path $Root 'AssignmentFilters'
    if (Test-Path -LiteralPath $ff) { foreach ($f in Get-ChildItem -LiteralPath $ff -Filter *.json) { try { $o = Read-IMJsonFile $f.FullName; $filters[$o.id] = $o.displayName } catch { } } }
    @{ Groups = $groups; Filters = $filters }
}

function Compare-IMObjectPair {
    param($Type, $Reference, $Difference, [hashtable]$RefNames, [hashtable]$DiffNames, [switch]$IgnoreAssignments)
    $r = Copy-IMObject $Reference; $d = Copy-IMObject $Difference
    $ra = $r.assignments; $da = $d.assignments
    Remove-IMProperty $r 'assignments'; Remove-IMProperty $d 'assignments'
    # Endpoint security settings exported by the original tool live in a sidecar; ignore differences in storage
    $rt = ConvertTo-IMFlatTable $r; $dt = ConvertTo-IMFlatTable $d
    if (-not $IgnoreAssignments) {
        $rt['assignments'] = (ConvertTo-IMComparableAssignments $ra $RefNames.Groups $RefNames.Filters) -join '; '
        $dt['assignments'] = (ConvertTo-IMComparableAssignments $da $DiffNames.Groups $DiffNames.Filters) -join '; '
    }
    $keys = @($rt.Keys) + @($dt.Keys) | Select-Object -Unique | Sort-Object
    @(foreach ($k in $keys) {
        $a = $rt[$k]; $b = $dt[$k]
        if ($a -cne $b) { [pscustomobject]@{ Property = $k; Reference = $a; Difference = $b } }
    })
}

function Read-IMExportObjects {
    param([string]$Root, $Type)
    $folder = Join-Path $Root $Type.Id
    if (-not (Test-Path -LiteralPath $folder)) { return @() }
    @(foreach ($f in Get-ChildItem -LiteralPath $folder -Filter *.json -File | Where-Object { $_.BaseName -notmatch '_Settings$' }) {
        try {
            $o = Read-IMJsonFile $f.FullName
            if ($Type.Id -eq 'EndpointSecurity' -and -not $o.settings) { $side = Read-IMSidecarJson $f.FullName; if ($side.settings) { Set-IMProperty $o 'settings' $side.settings } }
            if ($Type.Id -eq 'AdministrativeTemplates' -and -not $o.definitionValues) { $side = Read-IMSidecarJson $f.FullName; if ($side) { Set-IMProperty $o 'definitionValues' @($side) } }
            [pscustomobject]@{ Name = Get-IMObjectName $Type $o; Object = $o; File = $f.FullName }
        }
        catch { Write-IMLog -Level Warning -Category 'Compare' -Message "Skipped invalid file $($f.FullName)" }
    })
}

function Compare-IMSets {
    param($Type, $RefItems, $DiffItems, [hashtable]$RefNames, [hashtable]$DiffNames, [switch]$IgnoreAssignments, [scriptblock]$LoadDiff)
    # Pair objects by name; duplicates are paired in order so an extra copy shows up as added/removed
    $key = { param($items) $seen = @{}; foreach ($i in $items) { $n = $i.Name; $seen[$n] = 1 + ($seen[$n] ?? 0); [pscustomobject]@{ Key = "$n`u{1}$($seen[$n])"; Label = $(if ($seen[$n] -gt 1) { "$n ($($seen[$n]))" } else { $n }); Item = $i } } }
    $refKeyed = @(& $key $RefItems); $diffKeyed = @(& $key $DiffItems)
    $diffByKey = @{}; foreach ($d in $diffKeyed) { $diffByKey[$d.Key] = $d }
    $matched = @{}
    foreach ($r in $refKeyed) {
        $d = $diffByKey[$r.Key]
        if (-not $d) { [pscustomobject]@{ ObjectType = $Type.Id; TypeTitle = $Type.Title; Name = $r.Label; Status = 'OnlyInReference'; Differences = @() }; continue }
        $matched[$r.Key] = $true
        $dObj = if ($LoadDiff) { & $LoadDiff $d.Item } else { $d.Item.Object }
        $diffs = Compare-IMObjectPair -Type $Type -Reference $r.Item.Object -Difference $dObj -RefNames $RefNames -DiffNames $DiffNames -IgnoreAssignments:$IgnoreAssignments
        [pscustomobject]@{ ObjectType = $Type.Id; TypeTitle = $Type.Title; Name = $r.Label; Status = if ($diffs.Count) { 'Different' } else { 'Identical' }; Differences = $diffs }
    }
    foreach ($d in $diffKeyed) { if (-not $matched.ContainsKey($d.Key)) { [pscustomobject]@{ ObjectType = $Type.Id; TypeTitle = $Type.Title; Name = $d.Label; Status = 'OnlyInDifference'; Differences = @() } } }
}

function Compare-IMExports {
    <#
    .SYNOPSIS
    Compares two export folders. Status: Identical, Different, OnlyInReference, OnlyInDifference.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ReferencePath, [Parameter(Mandatory)][string]$DifferencePath, [string[]]$ObjectType = @('*'), [switch]$IgnoreAssignments, [hashtable]$Progress)
    $op = Start-IMOperation -Name 'Compare' -Progress $Progress -Parameters @{ Reference = $ReferencePath; Difference = $DifferencePath }
    $rn = Get-IMExportNameMaps $ReferencePath; $dn = Get-IMExportNameMaps $DifferencePath
    $types = Get-IMObjectType -Id $ObjectType
    $i = 0
    $result = foreach ($t in $types) {
        $i++; Update-IMProgress -Operation $op -Status "Comparing $($t.Title)" -Current $i -Total $types.Count
        $ri = Read-IMExportObjects $ReferencePath $t; $di = Read-IMExportObjects $DifferencePath $t
        if (-not $ri.Count -and -not $di.Count) { continue }
        Compare-IMSets -Type $t -RefItems $ri -DiffItems $di -RefNames $rn -DiffNames $dn -IgnoreAssignments:$IgnoreAssignments
    }
    $result = @($result)
    Write-IMLog -Category 'Compare' -Message ("Compared {0} object(s): {1} identical, {2} different, {3} only in reference, {4} only in difference" -f $result.Count,
        @($result | Where-Object Status -eq 'Identical').Count, @($result | Where-Object Status -eq 'Different').Count,
        @($result | Where-Object Status -eq 'OnlyInReference').Count, @($result | Where-Object Status -eq 'OnlyInDifference').Count)
    $script:IMCurrentOperationId = $null
    $result
}

function Compare-IMObjects {
    <#
    .SYNOPSIS
    Compares an export folder (reference) with the connected tenant (difference).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ReferencePath, [string[]]$ObjectType = @('*'), [switch]$IgnoreAssignments, [hashtable]$Progress)
    if (-not $script:IMConnection) { throw 'Not connected. Connect to a tenant first.' }
    $op = Start-IMOperation -Name 'Compare' -Progress $Progress -Parameters @{ Reference = $ReferencePath; Difference = $script:IMConnection.TenantId }
    $rn = Get-IMExportNameMaps $ReferencePath
    $groupCache = @{}
    $filters = @{}
    try { foreach ($f in (Get-IMGraphCollection '/deviceManagement/assignmentFilters?$select=id,displayName')) { $filters[$f.id] = $f.displayName } } catch { }
    $dn = @{ Groups = $groupCache; Filters = $filters }
    $types = @(Get-IMObjectType -Id $ObjectType | Where-Object { Test-IMPermission $_.Permission })
    $i = 0
    $result = foreach ($t in $types) {
        $i++; Update-IMProgress -Operation $op -Status "Comparing $($t.Title)" -Current $i -Total $types.Count
        $ri = Read-IMExportObjects $ReferencePath $t
        try { $live = @(Get-IMObjectList -Type $t) } catch { Write-IMLog -Level Warning -Category 'Compare' -Message "Could not list $($t.Title)" -ErrorRecord $_; continue }
        if (-not $ri.Count -and -not $live.Count) { continue }
        $di = @($live | ForEach-Object { [pscustomobject]@{ Name = Get-IMObjectName $t $_; Object = $null; Item = $_ } })
        $loader = {
            param($d)
            $o = Get-IMObject -Type $t -Item $d.Item
            foreach ($a in @($o.assignments)) {
                $g = $a.target.groupId
                if ($g -and -not $groupCache.ContainsKey($g)) {
                    $groupCache[$g] = (Invoke-IMGraphRequest -Uri "/groups/$g`?`$select=displayName" -Version 'v1.0' -IgnoreNotFound -NoLog).displayName
                }
            }
            $o
        }.GetNewClosure()
        Compare-IMSets -Type $t -RefItems $ri -DiffItems $di -RefNames $rn -DiffNames $dn -IgnoreAssignments:$IgnoreAssignments -LoadDiff $loader
    }
    $script:IMCurrentOperationId = $null
    @($result)
}

function Export-IMCompareReport {
    <# Writes compare results as CSV (one row per difference) or a self-contained HTML page. #>
    param([Parameter(Mandatory)][object[]]$Result, [Parameter(Mandatory)][string]$Path, [ValidateSet('Csv', 'Html')][string]$Format = 'Html', [string]$ReferenceLabel = 'Reference', [string]$DifferenceLabel = 'Difference')
    if ($Format -eq 'Csv') {
        $rows = foreach ($r in $Result) {
            if ($r.Differences.Count) { foreach ($d in $r.Differences) { [pscustomobject]@{ Type = $r.TypeTitle; Name = $r.Name; Status = $r.Status; Property = $d.Property; $ReferenceLabel = $d.Reference; $DifferenceLabel = $d.Difference } } }
            else { [pscustomobject]@{ Type = $r.TypeTitle; Name = $r.Name; Status = $r.Status; Property = ''; $ReferenceLabel = ''; $DifferenceLabel = '' } }
        }
        $rows | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding utf8
        return $Path
    }
    $enc = { param($s) [Net.WebUtility]::HtmlEncode([string]$s) }
    $sb = [Text.StringBuilder]::new()
    $counts = $Result | Group-Object Status | ForEach-Object { "<span class='pill $($_.Name)'>$($_.Name): $($_.Count)</span>" }
    [void]$sb.Append(@"
<!doctype html><html><head><meta charset="utf-8"><title>Compare report</title><style>
body{font-family:Segoe UI,system-ui,sans-serif;margin:24px;color:#1b1b1f;background:#fafafa}h1{font-weight:600}
table{border-collapse:collapse;width:100%;margin:8px 0 24px;background:#fff}td,th{border:1px solid #e3e3e8;padding:6px 8px;text-align:left;vertical-align:top;font-size:13px}
th{background:#f2f2f6}.pill{display:inline-block;padding:3px 10px;border-radius:12px;margin-right:6px;font-size:12px;background:#eee}
.Different{background:#fff2d6}.OnlyInReference{background:#ffe0e0}.OnlyInDifference{background:#ddf0ff}.Identical{background:#e3f5e1}
code{font-family:Cascadia Code,Consolas,monospace;font-size:12px;word-break:break-all}
</style></head><body><h1>Compare report</h1><p>$(& $enc $ReferenceLabel) &rarr; $(& $enc $DifferenceLabel) &middot; $(Get-Date -Format 'yyyy-MM-dd HH:mm')</p><p>$($counts -join '')</p>
<table><tr><th>Type</th><th>Name</th><th>Status</th><th>Property</th><th>$(& $enc $ReferenceLabel)</th><th>$(& $enc $DifferenceLabel)</th></tr>
"@)
    foreach ($r in ($Result | Sort-Object TypeTitle, Name)) {
        if ($r.Differences.Count) {
            $first = $true
            foreach ($d in $r.Differences) {
                [void]$sb.Append("<tr class='$($r.Status)'>$(if ($first) { "<td rowspan='$($r.Differences.Count)'>$(& $enc $r.TypeTitle)</td><td rowspan='$($r.Differences.Count)'>$(& $enc $r.Name)</td><td rowspan='$($r.Differences.Count)'>$($r.Status)</td>" })<td><code>$(& $enc $d.Property)</code></td><td><code>$(& $enc $d.Reference)</code></td><td><code>$(& $enc $d.Difference)</code></td></tr>")
                $first = $false
            }
        }
        else { [void]$sb.Append("<tr class='$($r.Status)'><td>$(& $enc $r.TypeTitle)</td><td>$(& $enc $r.Name)</td><td>$($r.Status)</td><td colspan='3'></td></tr>") }
    }
    [void]$sb.Append('</table></body></html>')
    [IO.File]::WriteAllText($Path, $sb.ToString(), [Text.UTF8Encoding]::new($false))
    $Path
}
