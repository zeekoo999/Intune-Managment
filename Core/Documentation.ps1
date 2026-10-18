<#
  Documentation
  Builds a document model from an export folder (or the live tenant via a temporary export) and writes it as
  HTML (self-contained, searchable), Markdown, CSV, JSON or Word (.docx, no Office needed).
  When connected, settings catalog / endpoint security ids are resolved to their display names.
#>

$script:IMDocNoise = @('id', 'createdDateTime', 'lastModifiedDateTime', 'modifiedDateTime', 'version', 'settingCount', 'supportsScopeTags', 'isAssigned',
    'assignments', 'settings', 'definitionValues', 'roleScopeTagIds', 'creationSource', 'priorityMetaData', 'scheduledActionsForRule', 'templateReference',
    'displayName', 'name', 'description', '@odata.type', 'uploadState', 'publishingState', 'committedContentVersion', 'deviceStatusOverview', 'userStatusOverview',
    'largeIcon', 'scriptContent', 'detectionScriptContent', 'remediationScriptContent', 'templateId', 'roleAssignments', 'items', 'apps', 'content', 'fileData')

#region Name resolution
function New-IMSettingResolver {
    param([switch]$Online)
    [pscustomobject]@{ Online = [bool]$Online -and [bool]$script:IMConnection; Defs = @{}; IntentDefs = @{} }
}

function Format-IMSettingId {
    param([string]$Id)
    if (-not $Id) { return '' }
    $s = $Id -replace '^(device|user)_vendor_msft_policy_config_', '' -replace '^(device|user)_vendor_msft_', '' -replace '^deviceConfiguration--', ''
    ($s -split '_' | Where-Object { $_ } | ForEach-Object { $_.Substring(0, 1).ToUpper() + $_.Substring(1) }) -join ' › '
}

function Initialize-IMSettingNames {
    <# Batch-loads setting definitions for the ids found in the objects. #>
    param($Resolver, [string[]]$Ids, [string[]]$IntentIds)
    if (-not $Resolver.Online) { return }
    $todo = @($Ids | Where-Object { $_ -and -not $Resolver.Defs.ContainsKey($_) } | Select-Object -Unique)
    if ($todo.Count) {
        $reqs = @(for ($i = 0; $i -lt $todo.Count; $i++) { [pscustomobject]@{ id = "$i"; url = "/deviceManagement/configurationSettings('$($todo[$i])')?`$select=id,displayName,options,categoryId" } })
        try {
            $res = Invoke-IMGraphBatch -Requests $reqs
            for ($i = 0; $i -lt $todo.Count; $i++) { if ($res["$i"].Status -lt 300) { $Resolver.Defs[$todo[$i]] = $res["$i"].Body } else { $Resolver.Defs[$todo[$i]] = $null } }
        }
        catch { Write-IMLog -Level Warning -Category 'Documentation' -Message 'Could not resolve setting names; ids are shown instead.' -ErrorRecord $_ }
    }
    $todo = @($IntentIds | Where-Object { $_ -and -not $Resolver.IntentDefs.ContainsKey($_) } | Select-Object -Unique)
    if ($todo.Count) {
        $reqs = @(for ($i = 0; $i -lt $todo.Count; $i++) { [pscustomobject]@{ id = "$i"; url = "/deviceManagement/settingDefinitions('$($todo[$i])')?`$select=id,displayName" } })
        try {
            $res = Invoke-IMGraphBatch -Requests $reqs
            for ($i = 0; $i -lt $todo.Count; $i++) { $Resolver.IntentDefs[$todo[$i]] = if ($res["$i"].Status -lt 300) { $res["$i"].Body.displayName } else { $null } }
        } catch { }
    }
}

function Get-IMSettingName { param($Resolver, [string]$Id) $d = $Resolver.Defs[$Id]; if ($d.displayName) { $d.displayName } else { Format-IMSettingId $Id } }
function Get-IMOptionName {
    param($Resolver, [string]$DefId, [string]$Value)
    $d = $Resolver.Defs[$DefId]
    $o = @($d.options) | Where-Object { $_.itemId -eq $Value } | Select-Object -First 1
    if ($o.displayName) { return $o.displayName }
    if ($Value -and $Value.StartsWith("${DefId}_")) { return $Value.Substring($DefId.Length + 1) }
    $Value
}
#endregion

#region Rows
function Get-IMSettingInstanceRows {
    param($Instance, $Resolver, [int]$Depth = 0)
    if (-not $Instance) { return }
    $id = $Instance.settingDefinitionId
    $name = Get-IMSettingName $Resolver $id
    $t = ($Instance.'@odata.type' -split '\.')[-1]
    switch -Wildcard ($t) {
        'deviceManagementConfigurationChoiceSettingInstance' {
            [pscustomobject]@{ Setting = $name; Value = Get-IMOptionName $Resolver $id $Instance.choiceSettingValue.value; Depth = $Depth; Id = $id }
            foreach ($c in @($Instance.choiceSettingValue.children)) { Get-IMSettingInstanceRows $c $Resolver ($Depth + 1) }
        }
        'deviceManagementConfigurationChoiceSettingCollectionInstance' {
            $vals = @($Instance.choiceSettingCollectionValue | ForEach-Object { Get-IMOptionName $Resolver $id $_.value })
            [pscustomobject]@{ Setting = $name; Value = $vals -join ', '; Depth = $Depth; Id = $id }
        }
        'deviceManagementConfigurationSimpleSettingInstance' {
            $v = $Instance.simpleSettingValue
            $val = if ($v.'@odata.type' -like '*SecretSettingValue') { '******** (secret)' } else { [string]$v.value }
            [pscustomobject]@{ Setting = $name; Value = $val; Depth = $Depth; Id = $id }
        }
        'deviceManagementConfigurationSimpleSettingCollectionInstance' {
            [pscustomobject]@{ Setting = $name; Value = (@($Instance.simpleSettingCollectionValue | ForEach-Object { [string]$_.value }) -join ', '); Depth = $Depth; Id = $id }
        }
        'deviceManagementConfigurationGroupSettingCollectionInstance' {
            [pscustomobject]@{ Setting = $name; Value = "$(@($Instance.groupSettingCollectionValue).Count) item(s)"; Depth = $Depth; Id = $id }
            $n = 0
            foreach ($g in @($Instance.groupSettingCollectionValue)) {
                $n++
                if (@($Instance.groupSettingCollectionValue).Count -gt 1) { [pscustomobject]@{ Setting = "Item $n"; Value = ''; Depth = $Depth + 1; Id = '' } }
                foreach ($c in @($g.children)) { Get-IMSettingInstanceRows $c $Resolver ($Depth + 2) }
            }
        }
        'deviceManagementConfigurationGroupSettingInstance' {
            [pscustomobject]@{ Setting = $name; Value = ''; Depth = $Depth; Id = $id }
            foreach ($c in @($Instance.groupSettingValue.children)) { Get-IMSettingInstanceRows $c $Resolver ($Depth + 1) }
        }
        default { [pscustomobject]@{ Setting = $name; Value = ''; Depth = $Depth; Id = $id } }
    }
}

function Get-IMSettingInstanceIds {
    param($Obj)
    $json = ConvertTo-IMJson $Obj.settings -Compress
    @([regex]::Matches($json, '"settingDefinitionId":"([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)
}

function Format-IMDocValue {
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [bool]) { return $(if ($Value) { 'Yes' } else { 'No' }) }
    if ($Value -is [array]) { return (@($Value | ForEach-Object { Format-IMDocValue $_ }) -join ', ') }
    if ($Value -is [psobject] -and $Value -isnot [string] -and $Value -isnot [ValueType]) { return (ConvertTo-IMJson $Value -Compress) }
    [string]$Value
}

function Get-IMObjectDocRows {
    param($Type, $Obj, $Resolver, [string]$File)
    $rows = [Collections.Generic.List[object]]::new()
    switch ($Type.Id) {
        { $_ -in 'SettingsCatalog', 'CompliancePoliciesV2', 'InventoryPolicies' } {
            foreach ($s in @($Obj.settings)) { foreach ($r in @(Get-IMSettingInstanceRows $s.settingInstance $Resolver)) { $rows.Add($r) } }
        }
        'AdministrativeTemplates' {
            $vals = $Obj.definitionValues ?? (Read-IMSidecarJson $File)
            foreach ($v in @($vals)) {
                $rows.Add([pscustomobject]@{ Setting = "$($v.'#Definition_categoryPath') › $($v.'#Definition_displayName')"; Value = $(if ($v.enabled) { 'Enabled' } else { 'Disabled' }); Depth = 0; Id = $v.'#Definition_Id' })
                foreach ($p in @($v.presentationValues)) {
                    if (-not $p) { continue }
                    $val = if ($null -ne $p.value) { Format-IMDocValue $p.value } elseif ($p.values) { (@($p.values | ForEach-Object { if ($_.name) { "$($_.name)=$($_.value)" } else { $_.value } }) -join '; ') } else { '' }
                    $rows.Add([pscustomobject]@{ Setting = $p.'#Presentation_Label' ?? 'Value'; Value = $val; Depth = 1; Id = '' })
                }
            }
        }
        'EndpointSecurity' {
            $settings = $Obj.settings ?? (Read-IMSidecarJson $File).settings
            foreach ($s in @($settings)) {
                $name = $Resolver.IntentDefs[$s.definitionId] ?? (Format-IMSettingId ($s.definitionId -replace '^.*_', ''))
                $val = try { Format-IMDocValue (ConvertFrom-IMJson $s.valueJson) } catch { $s.valueJson }
                $rows.Add([pscustomobject]@{ Setting = $name; Value = $val; Depth = 0; Id = $s.definitionId })
            }
        }
    }
    # Generic properties (all types; for catalog-style types these are the basics)
    $flat = @{}
    $copy = Copy-IMObject $Obj
    Remove-IMProperty $copy $script:IMDocNoise
    foreach ($p in @($copy.PSObject.Properties)) {
        if ($p.Name -like '*@odata*' -or $p.Name -like '#*') { continue }
        $v = $p.Value
        if ($null -eq $v -or ($v -is [string] -and $v -eq '') -or ($v -is [array] -and $v.Count -eq 0)) { continue }
        $isObjArray = $v -is [array] -and @($v | Where-Object { $_ -is [psobject] -and $_ -isnot [string] -and $_ -isnot [ValueType] }).Count -gt 0
        if ($isObjArray -or ($v -is [psobject] -and $v -isnot [string] -and $v -isnot [ValueType] -and $v -isnot [array])) {
            foreach ($kv in (ConvertTo-IMFlatTable $v $p.Name).GetEnumerator() | Sort-Object Key) { if ($kv.Value -ne '' -and $kv.Value -ne '[]' -and $kv.Key -notlike '*@odata*') { $rows.Add([pscustomobject]@{ Setting = $kv.Key; Value = $kv.Value; Depth = 0; Id = '' }) } }
        }
        else { $rows.Add([pscustomobject]@{ Setting = $p.Name; Value = Format-IMDocValue $v; Depth = 0; Id = '' }) }
    }
    foreach ($r in @($Obj.scheduledActionsForRule | Where-Object { $_ })) {
        foreach ($c in @($r.scheduledActionConfigurations | Where-Object { $_ })) {
            $rows.Add([pscustomobject]@{ Setting = "Non-compliance action: $($c.actionType)"; Value = $(if ($c.gracePeriodHours) { "after $($c.gracePeriodHours) hour(s)" } else { 'immediately' }); Depth = 0; Id = '' })
        }
    }
    $rows
}

function Get-IMDocAssignments {
    param($Obj, [hashtable]$Names)
    @(foreach ($a in @($Obj.assignments | Where-Object { $_ })) {
        $t = $a.target
        $kind = switch -Wildcard ($t.'@odata.type') {
            '*exclusionGroupAssignmentTarget' { 'Exclude' } '*allLicensedUsersAssignmentTarget' { 'All users' } '*allDevicesAssignmentTarget' { 'All devices' } default { 'Include' }
        }
        $who = if ($t.groupId) { $Names.Groups[$t.groupId] ?? $t.groupId } else { '' }
        $filter = if ($t.deviceAndAppManagementAssignmentFilterId -and $t.deviceAndAppManagementAssignmentFilterType -notin $null, 'none') { "filter $($t.deviceAndAppManagementAssignmentFilterType): $($Names.Filters[$t.deviceAndAppManagementAssignmentFilterId] ?? $t.deviceAndAppManagementAssignmentFilterId)" }
        [pscustomobject]@{ Target = $kind; Group = $who; Intent = $a.intent; Filter = $filter }
    })
}
#endregion

#region Model
function Get-IMDocModel {
    param([Parameter(Mandatory)][string]$Path, [string[]]$ObjectType = @('*'), $Resolver)
    $names = Get-IMExportNameMaps $Path
    $manifest = if (Test-Path -LiteralPath (Join-Path $Path 'manifest.json')) { Read-IMJsonFile (Join-Path $Path 'manifest.json') } else { $null }
    $types = Get-IMObjectType -Id $ObjectType
    $loaded = foreach ($t in $types) { foreach ($o in (Read-IMExportObjects $Path $t)) { [pscustomobject]@{ Type = $t; Item = $o } } }
    $loaded = @($loaded)
    if ($Resolver.Online) {
        $ids = foreach ($l in $loaded) { if ($l.Item.Object.settings -and $l.Type.Id -ne 'EndpointSecurity') { Get-IMSettingInstanceIds $l.Item.Object } }
        $iids = foreach ($l in $loaded) { if ($l.Type.Id -eq 'EndpointSecurity') { @($l.Item.Object.settings).definitionId } }
        Initialize-IMSettingNames -Resolver $Resolver -Ids @($ids) -IntentIds @($iids)
    }
    $sections = foreach ($grp in ($loaded | Group-Object { $_.Type.Section })) {
        [pscustomobject]@{
            Section = $grp.Name
            Types   = @(foreach ($tg in ($grp.Group | Group-Object { $_.Type.Id })) {
                $t = $tg.Group[0].Type
                [pscustomobject]@{
                    Id = $t.Id; Title = $t.Title
                    Objects = @(foreach ($l in ($tg.Group | Sort-Object { $_.Item.Name })) {
                        $o = $l.Item.Object
                        [pscustomobject]@{
                            Name = $l.Item.Name; Description = $o.description; ODataType = ($o.'@odata.type' -split '\.')[-1]
                            Platform = $o.platforms ?? $o.platform; Modified = $o.lastModifiedDateTime
                            ScopeTags = @($o.roleScopeTagIds)
                            Settings = @(Get-IMObjectDocRows -Type $t -Obj $o -Resolver $Resolver -File $l.Item.File)
                            Assignments = Get-IMDocAssignments $o $names
                        }
                    })
                }
            })
        }
    }
    [pscustomobject]@{ Title = "Intune documentation - $($manifest.Organization ?? (Split-Path $Path -Leaf))"; Tenant = $manifest.Organization; TenantId = $manifest.TenantId
        Exported = $manifest.ExportedAt; Generated = (Get-Date).ToString('yyyy-MM-dd HH:mm'); Sections = @($sections) }
}
#endregion

#region Writers
function ConvertTo-IMDocHtml {
    param($Model)
    $e = { param($s) [Net.WebUtility]::HtmlEncode([string]$s) }
    $sb = [Text.StringBuilder]::new()
    $nav = [Text.StringBuilder]::new()
    $body = [Text.StringBuilder]::new()
    $n = 0
    foreach ($sec in $Model.Sections) {
        [void]$nav.Append("<div class='navsec'>$(& $e $sec.Section)</div>")
        foreach ($t in $sec.Types) {
            [void]$nav.Append("<a href='#t-$($t.Id)'>$(& $e $t.Title) <span>$($t.Objects.Count)</span></a>")
            [void]$body.Append("<h2 id='t-$($t.Id)'>$(& $e $t.Title)</h2>")
            foreach ($o in $t.Objects) {
                $n++
                [void]$body.Append("<section class='obj' data-search='$(& $e (($o.Name + ' ' + $o.Description).ToLower()))'><h3>$(& $e $o.Name)</h3>")
                $meta = @()
                if ($o.ODataType) { $meta += & $e $o.ODataType }
                if ($o.Platform) { $meta += & $e $o.Platform }
                if ($o.Modified) { $meta += "modified $(& $e $o.Modified)" }
                if ($meta) { [void]$body.Append("<div class='meta'>$($meta -join ' · ')</div>") }
                if ($o.Description) { [void]$body.Append("<p>$(& $e $o.Description)</p>") }
                if ($o.Assignments.Count) {
                    [void]$body.Append("<h4>Assignments</h4><table><tr><th>Target</th><th>Group</th><th>Intent</th><th>Filter</th></tr>")
                    foreach ($a in $o.Assignments) { [void]$body.Append("<tr><td>$(& $e $a.Target)</td><td>$(& $e $a.Group)</td><td>$(& $e $a.Intent)</td><td>$(& $e $a.Filter)</td></tr>") }
                    [void]$body.Append('</table>')
                }
                if ($o.Settings.Count) {
                    [void]$body.Append("<h4>Settings</h4><table><tr><th>Setting</th><th>Value</th></tr>")
                    foreach ($r in $o.Settings) { [void]$body.Append("<tr><td style='padding-left:$(8 + 18 * $r.Depth)px'>$(& $e $r.Setting)</td><td>$(& $e $r.Value)</td></tr>") }
                    [void]$body.Append('</table>')
                }
                [void]$body.Append('</section>')
            }
        }
    }
    [void]$sb.Append(@"
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>$(& $e $Model.Title)</title>
<style>
:root{--bg:#f7f7fa;--card:#fff;--text:#1b1b1f;--muted:#6b6b76;--line:#e4e4ea;--accent:#4f46e5;--head:#f1f1f6}
@media (prefers-color-scheme:dark){:root{--bg:#121216;--card:#1b1b21;--text:#ececf1;--muted:#a0a0ad;--line:#2c2c35;--accent:#8b85ff;--head:#24242c}}
*{box-sizing:border-box}body{margin:0;font-family:"Segoe UI Variable","Segoe UI",system-ui,sans-serif;background:var(--bg);color:var(--text);display:flex}
nav{position:sticky;top:0;height:100vh;overflow:auto;width:280px;flex:none;padding:20px 12px;border-right:1px solid var(--line);background:var(--card)}
nav a{display:flex;justify-content:space-between;padding:6px 10px;border-radius:6px;color:var(--text);text-decoration:none;font-size:14px}nav a:hover{background:var(--head)}
nav a span{color:var(--muted);font-size:12px}.navsec{font-size:11px;letter-spacing:.06em;text-transform:uppercase;color:var(--muted);margin:16px 10px 6px}
main{flex:1;min-width:0;padding:28px 36px;max-width:1200px}h1{margin:0 0 4px;font-weight:650}.sub{color:var(--muted);margin-bottom:18px}
input{width:100%;padding:10px 12px;border:1px solid var(--line);border-radius:8px;background:var(--card);color:var(--text);font-size:14px;margin-bottom:20px}
h2{margin:36px 0 12px;font-weight:600;border-bottom:2px solid var(--accent);padding-bottom:6px}.obj{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:16px 20px;margin:14px 0}
h3{margin:0 0 4px;font-weight:600}h4{margin:14px 0 6px;font-size:13px;color:var(--muted);text-transform:uppercase;letter-spacing:.04em}.meta{color:var(--muted);font-size:12px}
table{border-collapse:collapse;width:100%;font-size:13px}td,th{border-bottom:1px solid var(--line);padding:6px 8px;text-align:left;vertical-align:top;word-break:break-word}th{background:var(--head);font-weight:600}
td:first-child{width:45%}@media(max-width:800px){nav{display:none}main{padding:16px}}@media print{nav,input{display:none}.obj{break-inside:avoid}}
</style></head><body><nav><div style="font-weight:650;margin:0 10px 8px">Contents</div>$($nav.ToString())</nav><main>
<h1>$(& $e $Model.Title)</h1><div class="sub">Generated $(& $e $Model.Generated)$(if ($Model.Exported) { " · exported $(& $e $Model.Exported)" }) · $n object(s)</div>
<input id="q" placeholder="Filter objects by name..." oninput="var v=this.value.toLowerCase();document.querySelectorAll('.obj').forEach(function(s){s.style.display=s.dataset.search.indexOf(v)>=0?'':'none'})">
$($body.ToString())</main></body></html>
"@)
    $sb.ToString()
}

function ConvertTo-IMDocMarkdown {
    param($Model)
    $md = { param($s) ([string]$s).Replace('|', '\|').Replace("`r", ' ').Replace("`n", ' ') }
    $sb = [Text.StringBuilder]::new()
    [void]$sb.AppendLine("# $($Model.Title)`n`nGenerated $($Model.Generated)`n")
    foreach ($sec in $Model.Sections) {
        [void]$sb.AppendLine("## $($sec.Section)`n")
        foreach ($t in $sec.Types) {
            [void]$sb.AppendLine("### $($t.Title)`n")
            foreach ($o in $t.Objects) {
                [void]$sb.AppendLine("#### $($o.Name)`n")
                if ($o.Description) { [void]$sb.AppendLine("$($o.Description)`n") }
                if ($o.Assignments.Count) {
                    [void]$sb.AppendLine("| Target | Group | Intent | Filter |`n|---|---|---|---|")
                    foreach ($a in $o.Assignments) { [void]$sb.AppendLine("| $(& $md $a.Target) | $(& $md $a.Group) | $(& $md $a.Intent) | $(& $md $a.Filter) |") }
                    [void]$sb.AppendLine()
                }
                if ($o.Settings.Count) {
                    [void]$sb.AppendLine("| Setting | Value |`n|---|---|")
                    foreach ($r in $o.Settings) { [void]$sb.AppendLine("| $(('&nbsp;&nbsp;' * $r.Depth))$(& $md $r.Setting) | $(& $md $r.Value) |") }
                    [void]$sb.AppendLine()
                }
            }
        }
    }
    $sb.ToString()
}

function ConvertTo-IMDocRows {
    param($Model)
    foreach ($sec in $Model.Sections) { foreach ($t in $sec.Types) { foreach ($o in $t.Objects) {
        foreach ($a in $o.Assignments) { [pscustomobject]@{ Section = $sec.Section; Type = $t.Title; Object = $o.Name; Kind = 'Assignment'; Setting = $a.Target; Value = (@($a.Group, $a.Intent, $a.Filter) | Where-Object { $_ }) -join ' · ' } }
        foreach ($r in $o.Settings) { [pscustomobject]@{ Section = $sec.Section; Type = $t.Title; Object = $o.Name; Kind = 'Setting'; Setting = (('  ' * $r.Depth) + $r.Setting); Value = $r.Value } }
    } } }
}

function ConvertTo-IMXmlText {
    param([string]$s)
    $clean = [regex]::Replace([string]$s, '[\x00-\x08\x0B\x0C\x0E-\x1F]', '')
    [Security.SecurityElement]::Escape($clean)
}

function Write-IMDocWord {
    <# Minimal .docx writer (OpenXML), no Word installation required. #>
    param($Model, [string]$Path)
    $p = { param($text, $style)
        $pPr = if ($style) { '<w:pPr><w:pStyle w:val="{0}"/></w:pPr>' -f $style } else { '' }
        '<w:p>{0}<w:r><w:t xml:space="preserve">{1}</w:t></w:r></w:p>' -f $pPr, (ConvertTo-IMXmlText $text) }
    $cell = { param($text, [bool]$head, [int]$indent = 0)
        $shd = if ($head) { '<w:shd w:val="clear" w:color="auto" w:fill="E8E8EE"/>' } else { '' }
        $ind = if ($indent) { "<w:pPr><w:ind w:left=`"$($indent * 240)`"/></w:pPr>" } else { '' }
        $b = if ($head) { '<w:rPr><w:b/></w:rPr>' } else { '' }
        "<w:tc><w:tcPr>$shd</w:tcPr><w:p>$ind<w:r>$b<w:t xml:space=`"preserve`">$(ConvertTo-IMXmlText $text)</w:t></w:r></w:p></w:tc>" }
    $table = { param([string[]]$headers, $rows)
        $x = '<w:tbl><w:tblPr><w:tblStyle w:val="TableGrid"/><w:tblW w:w="5000" w:type="pct"/></w:tblPr><w:tr>'
        foreach ($h in $headers) { $x += & $cell $h $true }
        $x += '</w:tr>'
        foreach ($r in $rows) { $x += '<w:tr>'; $i = 0; foreach ($v in $r.Values) { $x += & $cell $v $false $(if ($i -eq 0) { $r.Indent } else { 0 }); $i++ }; $x += '</w:tr>' }
        $x + '</w:tbl>' + (& $p '' $null) }

    $body = [Text.StringBuilder]::new()
    [void]$body.Append((& $p $Model.Title 'Title'))
    [void]$body.Append((& $p "Generated $($Model.Generated)" $null))
    foreach ($sec in $Model.Sections) {
        [void]$body.Append((& $p $sec.Section 'Heading1'))
        foreach ($t in $sec.Types) {
            [void]$body.Append((& $p $t.Title 'Heading2'))
            foreach ($o in $t.Objects) {
                [void]$body.Append((& $p $o.Name 'Heading3'))
                if ($o.Description) { [void]$body.Append((& $p $o.Description $null)) }
                if ($o.Assignments.Count) { [void]$body.Append((& $table @('Target', 'Group', 'Intent', 'Filter') @($o.Assignments | ForEach-Object { @{ Values = @($_.Target, $_.Group, $_.Intent, $_.Filter); Indent = 0 } }))) }
                if ($o.Settings.Count) { [void]$body.Append((& $table @('Setting', 'Value') @($o.Settings | ForEach-Object { @{ Values = @($_.Setting, $_.Value); Indent = $_.Depth } }))) }
            }
        }
    }
    $ns = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"'
    $document = "<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?><w:document $ns><w:body>$($body.ToString())<w:sectPr><w:pgSz w:w=`"11906`" w:h=`"16838`"/><w:pgMar w:top=`"1134`" w:right=`"1134`" w:bottom=`"1134`" w:left=`"1134`" w:header=`"709`" w:footer=`"709`" w:gutter=`"0`"/></w:sectPr></w:body></w:document>"
    $hs = { param($id, $name, $size, $color) "<w:style w:type=`"paragraph`" w:styleId=`"$id`"><w:name w:val=`"$name`"/><w:basedOn w:val=`"Normal`"/><w:next w:val=`"Normal`"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before=`"240`" w:after=`"80`"/><w:outlineLvl w:val=`"$([math]::Max(0, [int]($id -replace '\D', '') - 1))`"/></w:pPr><w:rPr><w:b/><w:color w:val=`"$color`"/><w:sz w:val=`"$size`"/></w:rPr></w:style>" }
    $styles = "<?xml version=`"1.0`" encoding=`"UTF-8`" standalone=`"yes`"?><w:styles $ns><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii=`"Segoe UI`" w:hAnsi=`"Segoe UI`" w:cs=`"Segoe UI`"/><w:sz w:val=`"19`"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after=`"60`"/></w:pPr></w:pPrDefault></w:docDefaults>" +
        "<w:style w:type=`"paragraph`" w:default=`"1`" w:styleId=`"Normal`"><w:name w:val=`"Normal`"/><w:qFormat/></w:style>" +
        "<w:style w:type=`"paragraph`" w:styleId=`"Title`"><w:name w:val=`"Title`"/><w:basedOn w:val=`"Normal`"/><w:qFormat/><w:rPr><w:sz w:val=`"48`"/><w:color w:val=`"312E81`"/></w:rPr></w:style>" +
        (& $hs 'Heading1' 'heading 1' 34 '312E81') + (& $hs 'Heading2' 'heading 2' 28 '4338CA') + (& $hs 'Heading3' 'heading 3' 23 '1F2937') +
        "<w:style w:type=`"table`" w:styleId=`"TableGrid`"><w:name w:val=`"Table Grid`"/><w:tblPr><w:tblBorders><w:top w:val=`"single`" w:sz=`"4`" w:color=`"D4D4DC`"/><w:left w:val=`"single`" w:sz=`"4`" w:color=`"D4D4DC`"/><w:bottom w:val=`"single`" w:sz=`"4`" w:color=`"D4D4DC`"/><w:right w:val=`"single`" w:sz=`"4`" w:color=`"D4D4DC`"/><w:insideH w:val=`"single`" w:sz=`"4`" w:color=`"D4D4DC`"/><w:insideV w:val=`"single`" w:sz=`"4`" w:color=`"D4D4DC`"/></w:tblBorders><w:tblCellMar><w:left w:w=`"80`" w:type=`"dxa`"/><w:right w:w=`"80`" w:type=`"dxa`"/></w:tblCellMar></w:tblPr></w:style></w:styles>"
    $parts = [ordered]@{
        '[Content_Types].xml' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/></Types>'
        '_rels/.rels' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>'
        'word/_rels/document.xml.rels' = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>'
        'word/document.xml' = $document
        'word/styles.xml' = $styles
    }
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $zip = [IO.Compression.ZipFile]::Open($Path, 'Create')
    try {
        foreach ($k in $parts.Keys) {
            $w = [IO.StreamWriter]::new($zip.CreateEntry($k).Open(), [Text.UTF8Encoding]::new($false))
            $w.Write($parts[$k]); $w.Dispose()
        }
    }
    finally { $zip.Dispose() }
}
#endregion

function New-IMDocumentation {
    <#
    .SYNOPSIS
    Documents an export folder (or the connected tenant with -Live) as Html, Markdown, Csv, Json or Word.
    .EXAMPLE
    New-IMDocumentation -Path C:\Backup\Contoso\2026-10-17_0900 -Format Html
    .EXAMPLE
    New-IMDocumentation -Live -ObjectType SettingsCatalog -Format Word -OutputPath C:\Docs
    #>
    [CmdletBinding()]
    param(
        [string]$Path, [switch]$Live,
        [ValidateSet('Html', 'Markdown', 'Csv', 'Json', 'Word')][string]$Format = 'Html',
        [string]$OutputPath, [string[]]$ObjectType = @('*'), [switch]$NoNameResolution, [hashtable]$Progress
    )
    $tmp = $null
    if ($Live) {
        if (-not $script:IMConnection) { throw 'Not connected. Connect to a tenant first.' }
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("imdoc_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $Path = (Export-IMObjects -Path $tmp -ObjectType $ObjectType -NoDateFolder -Progress $Progress).ExportPath
    }
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { throw 'Choose an export folder (or use -Live).' }
    try {
        $resolver = New-IMSettingResolver -Online:(-not $NoNameResolution)
        $model = Get-IMDocModel -Path $Path -ObjectType $ObjectType -Resolver $resolver
        $ext = @{ Html = 'html'; Markdown = 'md'; Csv = 'csv'; Json = 'json'; Word = 'docx' }[$Format]
        if (-not $OutputPath) { $OutputPath = $Path }
        if (-not [IO.Path]::HasExtension($OutputPath)) {
            New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
            $OutputPath = Join-Path $OutputPath ("Documentation_{0:yyyyMMdd_HHmm}.$ext" -f (Get-Date))
        }
        switch ($Format) {
            'Html' { [IO.File]::WriteAllText($OutputPath, (ConvertTo-IMDocHtml $model), [Text.UTF8Encoding]::new($false)) }
            'Markdown' { [IO.File]::WriteAllText($OutputPath, (ConvertTo-IMDocMarkdown $model), [Text.UTF8Encoding]::new($false)) }
            'Csv' { ConvertTo-IMDocRows $model | Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding utf8 }
            'Json' { Write-IMJsonFile $OutputPath $model }
            'Word' { Write-IMDocWord -Model $model -Path $OutputPath }
        }
        $count = @($model.Sections.Types.Objects).Count
        Write-IMLog -Level Success -Category 'Documentation' -Message "Documented $count object(s) to $OutputPath"
        $OutputPath
    }
    finally { if ($tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } }
}
