<# Copy within a tenant and bulk delete. Both reuse the import pipeline / type hooks. #>

function New-IMObjectCopy {
    <#
    .SYNOPSIS
    Copies an object in the connected tenant under a new name (settings, scope tags and optionally assignments).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Type, [Parameter(Mandatory)]$Item, [Parameter(Mandatory)][string]$NewName, [switch]$IncludeAssignments)
    if ($Type -is [string]) { $Type = Get-IMObjectType -Id $Type | Select-Object -First 1 }
    if (-not $Type.CanCopy) { throw "$($Type.Title) cannot be copied." }
    $full = Get-IMObject -Type $Type -Item $Item
    Set-IMProperty $full $Type.NameProperty $NewName

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("imcopy_" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path (Join-Path $tmp $Type.Id) -Force | Out-Null
    $file = Join-Path (Join-Path $tmp $Type.Id) 'copy.json'
    Write-IMJsonFile $file $full
    try {
        $op = Start-IMOperation -Name 'Copy' -Parameters @{ Type = $Type.Id; Source = $Item.id; NewName = $NewName }
        $ctx = New-IMImportContext -Root $tmp -Operation $op -Options @{ ConflictAction = 'Duplicate'; NamePrefix = ''; ImportAssignments = [bool]$IncludeAssignments; ImportScopeTags = $true; Quiet = $true }
        $ctx.SameTenant = $true
        $planItem = [pscustomobject]@{ Type = $Type; TypeId = $Type.Id; File = $file; Name = $NewName; SourceId = $full.id; Object = $full; Valid = $true; Order = 0 }
        $ctx.TypeState = @{ Relationships = @() }
        $r = Import-IMPlanItem -Item $planItem -Ctx $ctx -ExistingByName @{} -ExistingNames @()
        Complete-IMOperation -Operation $op | Out-Null
        if ($r.Status -eq 'Failed') { throw $r.Message }
        $r
    }
    finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

function Remove-IMObjects {
    <#
    .SYNOPSIS
    Deletes objects. Use -WhatIf to list what would be deleted. Default/built-in objects are skipped.
    .PARAMETER Items  Summary objects (from Get-IMObjectList) of one type.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Type, [Parameter(Mandatory)][object[]]$Items, [switch]$WhatIf, [hashtable]$Progress)
    if ($Type -is [string]) { $Type = Get-IMObjectType -Id $Type | Select-Object -First 1 }
    $op = Start-IMOperation -Name $(if ($WhatIf) { 'DeletePreview' } else { 'Delete' }) -Progress $Progress -Parameters @{ Type = $Type.Id; Count = $Items.Count }
    $i = 0
    foreach ($item in $Items) {
        $i++
        if (Test-IMCancelled $op) { break }
        $name = Get-IMObjectName $Type $item
        Update-IMProgress -Operation $op -Status "Deleting $($Type.Title)" -Current $i -Total $Items.Count -Item $name
        if (-not $Type.CanDelete -or $item.isBuiltIn -or $item.isDefaultProfile -or ($Type.Api -like '*deviceEnrollmentConfigurations' -and (Test-IMDefaultEnrollmentConfig $item))) {
            Add-IMOperationResult -Operation $op -ObjectType $Type.Id -Name $name -Action 'Skipped' -Status 'Skipped' -SourceId $item.id -Message 'Built-in or default object; cannot be deleted.' | Out-Null
            continue
        }
        if ($WhatIf) { Add-IMOperationResult -Operation $op -ObjectType $Type.Id -Name $name -Action 'WouldDelete' -SourceId $item.id | Out-Null; continue }
        try {
            $uri = (Get-IMItemUri $Type $item) -replace '\?.*$', ''
            Invoke-IMGraphRequest -Method DELETE -Uri $uri -Version $Type.Version | Out-Null
            Add-IMOperationResult -Operation $op -ObjectType $Type.Id -Name $name -Action 'Deleted' -SourceId $item.id | Out-Null
        }
        catch {
            $msg = if ($_.Exception.StatusCode -eq 400 -and $Type.Id -eq 'Applications') { 'The app may be used by another app (dependency/supersedence) or a policy set.' } else { $null }
            Add-IMOperationResult -Operation $op -ObjectType $Type.Id -Name $name -Action 'Delete' -Status 'Failed' -SourceId $item.id -Message $msg -ErrorRecord $_ | Out-Null
        }
    }
    Complete-IMOperation -Operation $op
}
