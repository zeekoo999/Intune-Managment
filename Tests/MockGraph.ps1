<#
  In-memory Microsoft Graph + Entra token endpoint used by the offline tests.
  Supports: client-credentials tokens, collections, items, create/update/delete, /assign, /assignments,
  /$batch, group search by displayName, fault injection (429/500/400) and a request log.
#>

$script:Mock = @{
    Tenants  = @{}          # tid -> @{ Name; Store = @{ collectionPath -> List[object] } }
    Faults   = [Collections.Generic.List[object]]::new()   # @{ Method; PathLike; Status; Times; Body; RetryAfter }
    Requests = [Collections.Generic.List[object]]::new()
    Secrets  = @{}          # clientId -> secret
}

$script:MockCollections = @(
    'deviceManagement/deviceConfigurations', 'deviceManagement/configurationPolicies', 'deviceManagement/groupPolicyConfigurations',
    'deviceManagement/deviceCompliancePolicies', 'deviceManagement/compliancePolicies', 'deviceManagement/deviceComplianceScripts',
    'deviceManagement/notificationMessageTemplates', 'deviceManagement/intents', 'deviceManagement/reusablePolicySettings',
    'deviceManagement/deviceManagementScripts', 'deviceManagement/deviceShellScripts', 'deviceManagement/deviceCustomAttributeShellScripts',
    'deviceManagement/deviceHealthScripts', 'deviceManagement/windowsFeatureUpdateProfiles', 'deviceManagement/windowsQualityUpdateProfiles',
    'deviceManagement/windowsDriverUpdateProfiles', 'deviceManagement/windowsAutopilotDeploymentProfiles', 'deviceManagement/deviceEnrollmentConfigurations',
    'deviceManagement/roleScopeTags', 'deviceManagement/assignmentFilters', 'deviceManagement/roleDefinitions', 'deviceManagement/termsAndConditions',
    'deviceManagement/intuneBrandingProfiles', 'deviceManagement/deviceCategories', 'deviceAppManagement/mobileApps',
    'deviceAppManagement/managedAppPolicies', 'deviceAppManagement/iosManagedAppProtections', 'deviceAppManagement/androidManagedAppProtections',
    'deviceAppManagement/targetedManagedAppConfigurations', 'deviceAppManagement/mobileAppConfigurations', 'deviceAppManagement/policySets',
    'identity/conditionalAccess/policies', 'identity/conditionalAccess/namedLocations', 'groups', 'users', 'organization'
)

function New-MockTenant {
    param([string]$TenantId, [string]$Name, [string]$ClientId, [string]$Secret)
    $store = @{}
    foreach ($c in $script:MockCollections) { $store[$c] = [Collections.Generic.List[object]]::new() }
    $script:Mock.Tenants[$TenantId] = @{ Name = $Name; Store = $store }
    $store['organization'].Add([pscustomobject]@{ id = $TenantId; displayName = $Name; verifiedDomains = @([pscustomobject]@{ name = "$($Name.ToLower()).onmicrosoft.com"; isDefault = $true; isInitial = $true }) })
    $script:Mock.Secrets[$ClientId] = $Secret
}

function Add-MockObject {
    param([string]$TenantId, [string]$Collection, [hashtable]$Object)
    if (-not $Object.ContainsKey('id')) { $Object.id = [guid]::NewGuid().ToString() }
    $o = ConvertFrom-IMJson (ConvertTo-Json $Object -Depth 30 -Compress)
    $script:Mock.Tenants[$TenantId].Store[$Collection].Add($o)
    $o
}

function Get-MockObjects { param([string]$TenantId, [string]$Collection) $script:Mock.Tenants[$TenantId].Store[$Collection].ToArray() }

function Add-MockFault {
    param([string]$Method = '*', [string]$PathLike, [int]$Status, [int]$Times = 1, [string]$Code = 'BadRequest', [string]$Message = 'Injected error', [string]$RetryAfter = '0')
    $script:Mock.Faults.Add(@{ Method = $Method; PathLike = $PathLike; Status = $Status; Times = $Times; Code = $Code; Message = $Message; RetryAfter = $RetryAfter })
}

function New-MockJwt {
    param([string]$TenantId, [string[]]$Roles)
    $enc = { param($o) [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($o | ConvertTo-Json -Compress))).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
    "$(& $enc @{alg='none'}).$(& $enc @{ tid = $TenantId; roles = $Roles; app_displayname = 'IntuneManager Test' }).sig"
}

function New-MockResponse { param([int]$Status, $Body, [hashtable]$Headers = @{})
    $h = @{ 'request-id' = [guid]::NewGuid().ToString() }; foreach ($k in $Headers.Keys) { $h[$k] = $Headers[$k] }
    [pscustomobject]@{ StatusCode = $Status; Headers = $h; Content = if ($null -eq $Body) { '' } elseif ($Body -is [string]) { $Body } else { ConvertTo-Json $Body -Depth 50 -Compress } }
}

function Invoke-MockRequest {
    param([string]$TenantId, [string]$Method, [string]$Path, [string]$Query, $Body)
    $store = $script:Mock.Tenants[$TenantId].Store
    $err = { param($s, $c, $m) New-MockResponse $s @{ error = @{ code = $c; message = $m; innerError = @{ 'request-id' = [guid]::NewGuid().ToString() } } } }

    # Faults
    foreach ($f in @($script:Mock.Faults)) {
        if ($f.Times -gt 0 -and ($f.Method -eq '*' -or $f.Method -eq $Method) -and $Path -like $f.PathLike) {
            $f.Times--
            return New-MockResponse $f.Status @{ error = @{ code = $f.Code; message = $f.Message } } @{ 'retry-after' = $f.RetryAfter }
        }
    }

    # $batch
    if ($Path -eq '$batch') {
        $responses = foreach ($r in @($Body.requests)) {
            $u = [string]$r.url; $p = $u.TrimStart('/'); $q = ''
            if ($p.Contains('?')) { $q = $p.Substring($p.IndexOf('?') + 1); $p = $p.Substring(0, $p.IndexOf('?')) }
            $resp = Invoke-MockRequest -TenantId $TenantId -Method $r.method -Path $p -Query ([Uri]::UnescapeDataString($q)) -Body $r.body
            [ordered]@{ id = $r.id; status = $resp.StatusCode; headers = @{ 'Retry-After' = $resp.Headers['retry-after'] }; body = if ($resp.Content) { ConvertFrom-IMJson $resp.Content } else { $null } }
        }
        return New-MockResponse 200 @{ responses = @($responses) }
    }

    # Group search
    if ($Path -eq 'groups' -and $Method -eq 'GET' -and $Query -match "displayName eq '(.+?)'(&|$)") {
        $name = $Matches[1].Replace("''", "'")
        return New-MockResponse 200 @{ value = @($store['groups'] | Where-Object displayName -eq $name) }
    }

    $collection = $script:MockCollections | Where-Object { $Path -eq $_ -or $Path.StartsWith("$_/") } | Sort-Object Length -Descending | Select-Object -First 1
    if (-not $collection) {
        # Unknown action/endpoint: record and accept
        if ($Method -eq 'GET') { return New-MockResponse 404 @{ error = @{ code = 'ResourceNotFound'; message = "No mock for $Path" } } }
        return New-MockResponse 204 $null
    }
    $list = $store[$collection]
    $rest = $Path.Substring($collection.Length).TrimStart('/')
    $segments = @(if ($rest) { $rest -split '/' })
    $id = if ($segments.Count) { $segments[0] -replace "^\('?|'?\)$", '' } else { $null }
    if ($id -match "^\('(.+)'\)$") { $id = $Matches[1] }
    $item = if ($id) { $list | Where-Object { [string]$_.id -eq $id } | Select-Object -First 1 } else { $null }

    if (-not $id) {
        switch ($Method) {
            'GET' {
                $items = @($list.ToArray())
                if ($Query -match 'isBuiltIn eq false') { $items = @($items | Where-Object { -not $_.isBuiltIn }) }
                if ($Query -match "not isof\('microsoft.graph.windowsUpdateForBusinessConfiguration'\)") { $items = @($items | Where-Object '@odata.type' -ne '#microsoft.graph.windowsUpdateForBusinessConfiguration') }
                elseif ($Query -match "isof\('microsoft.graph.windowsUpdateForBusinessConfiguration'\)") { $items = @($items | Where-Object '@odata.type' -eq '#microsoft.graph.windowsUpdateForBusinessConfiguration') }
                # Paging: 3 per page to exercise nextLink
                $skip = 0; if ($Query -match 'skiptoken=(\d+)') { $skip = [int]$Matches[1] }
                $page = @($items | Select-Object -Skip $skip -First 3 | ForEach-Object { $c = Copy-IMObject $_; Remove-IMProperty $c 'assignments'; $c })
                $resp = [ordered]@{ value = $page }
                if ($skip + 3 -lt $items.Count) { $q2 = ($Query -replace '&?\$skiptoken=\d+', '').TrimStart('&'); $resp['@odata.nextLink'] = "https://graph.microsoft.com/beta/$collection`?`$skiptoken=$($skip + 3)$(if ($q2) { "&$q2" })" }
                return New-MockResponse 200 $resp
            }
            'POST' {
                if (-not $Body) { return & $err 400 'BadRequest' 'Empty body' }
                $new = Copy-IMObject $Body
                foreach ($bad in 'id', 'createdDateTime', 'lastModifiedDateTime') { if ((Test-IMProperty $new $bad) -and $collection -ne 'organization') { if ($bad -eq 'id' -and $collection -like '*conditionalAccess/authenticationContext*') { continue }; return & $err 400 'BadRequest' "Property '$bad' is read-only" } }
                if ($collection -eq 'groups' -and $store['groups'] | Where-Object mailNickname -eq $new.mailNickname) { return & $err 400 'Request_BadRequest' 'Another object with the same value for property mailNickname already exists.' }
                Set-IMProperty $new 'id' ([guid]::NewGuid().ToString())
                Set-IMProperty $new 'createdDateTime' '2026-10-17T00:00:00Z'
                $list.Add($new)
                return New-MockResponse 201 $new
            }
        }
    }
    if (-not $item) { return & $err 404 'ResourceNotFound' "Object $id not found in $collection" }
    if ($segments.Count -eq 1) {
        switch ($Method) {
            'GET' {
                $c = Copy-IMObject $item
                if ($Query -notmatch 'expand=.*assignments') { Remove-IMProperty $c 'assignments' }
                elseif (-not (Test-IMProperty $c 'assignments')) { Set-IMProperty $c 'assignments' @() }
                return New-MockResponse 200 $c
            }
            { $_ -in 'PATCH', 'PUT' } {
                foreach ($p in $Body.PSObject.Properties) { Set-IMProperty $item $p.Name $p.Value }
                Set-IMProperty $item 'lastModifiedDateTime' '2026-10-17T01:00:00Z'
                return New-MockResponse 204 $null
            }
            'DELETE' { [void]$list.Remove($item); return New-MockResponse 204 $null }
        }
    }
    $action = $segments[1]
    switch ($action) {
        'assign' {
            $key = @($Body.PSObject.Properties.Name)[0]
            $assigned = @(foreach ($a in @($Body.$key)) { $c = Copy-IMObject $a; Set-IMProperty $c 'id' ([guid]::NewGuid().ToString()); $c })
            Set-IMProperty $item 'assignments' $assigned
            Set-IMProperty $item '__assignKey' $key
            return New-MockResponse 200 @{ value = $assigned }
        }
        'assignments' {
            if ($Method -eq 'GET') { return New-MockResponse 200 @{ value = @($item.assignments | Where-Object { $_ }) } }
            $c = Copy-IMObject $Body; Set-IMProperty $c 'id' ([guid]::NewGuid().ToString())
            Set-IMProperty $item 'assignments' (@($item.assignments | Where-Object { $_ }) + $c)
            return New-MockResponse 201 $c
        }
        default {
            if ($Method -eq 'GET') {
                $v = Get-IMPropertyValue $item $action
                return New-MockResponse 200 @{ value = @($v | Where-Object { $_ }) }
            }
            # Record follow-up actions on the item for assertions
            $calls = @(Get-IMPropertyValue $item '__actions') + @([pscustomobject]@{ Action = $action; Body = $Body })
            Set-IMProperty $item '__actions' @($calls | Where-Object { $_ })
            return New-MockResponse 200 @{ ok = $true }
        }
    }
}

$script:MockTransport = {
    param($r)
    $script:Mock.Requests.Add([pscustomobject]@{ Method = $r.Method; Uri = $r.Uri })
    $uri = [Uri]$r.Uri
    if ($uri.Host -eq 'login.microsoftonline.com') {
        $tenant = $uri.AbsolutePath.Split('/')[1]
        $form = @{}; foreach ($kv in $r.Body.Split('&')) { $k, $v = $kv.Split('=', 2); $form[$k] = [Uri]::UnescapeDataString($v) }
        if (-not $script:Mock.Tenants.ContainsKey($tenant)) { return New-MockResponse 400 @{ error = 'invalid_request'; error_description = "AADSTS90002: Tenant '$tenant' not found." } }
        if (-not $script:Mock.Secrets.ContainsKey($form.client_id)) { return New-MockResponse 400 @{ error = 'unauthorized_client'; error_description = "AADSTS700016: Application with identifier '$($form.client_id)' was not found in the directory." } }
        if ($script:Mock.Secrets[$form.client_id] -ne $form.client_secret) { return New-MockResponse 401 @{ error = 'invalid_client'; error_description = "AADSTS7000215: Invalid client secret provided.`r`nTrace ID: x" } }
        $roles = @('DeviceManagementConfiguration.ReadWrite.All', 'DeviceManagementApps.ReadWrite.All', 'DeviceManagementServiceConfig.ReadWrite.All', 'DeviceManagementRBAC.ReadWrite.All', 'DeviceManagementScripts.ReadWrite.All', 'Group.ReadWrite.All', 'Organization.Read.All', 'Policy.ReadWrite.ConditionalAccess', 'Policy.Read.All', 'User.Read.All', 'DeviceManagementManagedDevices.Read.All')
        return New-MockResponse 200 @{ access_token = (New-MockJwt $tenant $roles); expires_in = 3599; token_type = 'Bearer' }
    }
    $auth = $r.Headers.Authorization
    if (-not $auth) { return New-MockResponse 401 @{ error = @{ code = 'InvalidAuthenticationToken'; message = 'Missing token' } } }
    $tid = (ConvertFrom-IMJwt ($auth -replace '^Bearer ', '')).tid
    $path = [Uri]::UnescapeDataString($uri.AbsolutePath) -replace '^/(beta|v1\.0)/', '' -replace "\('([^']+)'\)", '/$1'
    $query = [Uri]::UnescapeDataString($uri.Query.TrimStart('?'))
    $body = if ($r.Body) { ConvertFrom-IMJson $r.Body } else { $null }
    Invoke-MockRequest -TenantId $tid -Method $r.Method -Path $path -Query $query -Body $body
}
