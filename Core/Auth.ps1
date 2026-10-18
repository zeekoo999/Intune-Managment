<#
  Authentication & connection profiles
  - App-only (client credentials) with client secret or certificate. Pure REST, no MSAL dependency.
  - Profiles saved per user; secrets protected with DPAPI (Windows) and never written in clear text.
  - Friendly explanations for common AADSTS errors.
  - Permission check against the token's roles.
  - One-time setup helper that creates a ready-to-use app registration (New-IMAppRegistration).
#>

$script:IMClouds = [ordered]@{
    Global   = @{ Login = 'https://login.microsoftonline.com'; Graph = 'https://graph.microsoft.com'; Portal = 'https://intune.microsoft.com' }
    USGov    = @{ Login = 'https://login.microsoftonline.us'; Graph = 'https://graph.microsoft.us'; Portal = 'https://intune.microsoft.us' }
    USGovDoD = @{ Login = 'https://login.microsoftonline.us'; Graph = 'https://dod-graph.microsoft.us'; Portal = 'https://intune.microsoft.us' }
    China    = @{ Login = 'https://login.chinacloudapi.cn'; Graph = 'https://microsoftgraph.chinacloudapi.cn'; Portal = 'https://intune.microsoftonline.cn' }
}

$script:IMGraphAppId = '00000003-0000-0000-c000-000000000000'
# Microsoft Graph Command Line Tools: public client, used ONLY by the one-time app registration setup
$script:IMSetupClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e'

# Application permissions the tool can use. "Core" = needed for typical Intune export/import.
$script:IMPermissionCatalog = @(
    [pscustomobject]@{ Name = 'DeviceManagementConfiguration.ReadWrite.All'; Core = $true; Purpose = 'Configuration, compliance, settings catalog, endpoint security, updates, filters' }
    [pscustomobject]@{ Name = 'DeviceManagementApps.ReadWrite.All'; Core = $true; Purpose = 'Apps, app protection, app configuration, branding, policy sets' }
    [pscustomobject]@{ Name = 'DeviceManagementServiceConfig.ReadWrite.All'; Core = $true; Purpose = 'Enrollment, Autopilot, terms and conditions, notifications' }
    [pscustomobject]@{ Name = 'DeviceManagementRBAC.ReadWrite.All'; Core = $true; Purpose = 'Scope tags and role definitions' }
    [pscustomobject]@{ Name = 'DeviceManagementScripts.ReadWrite.All'; Core = $true; Purpose = 'PowerShell, shell, remediation and compliance scripts' }
    [pscustomobject]@{ Name = 'DeviceManagementManagedDevices.Read.All'; Core = $true; Purpose = 'Device categories and device lookups' }
    [pscustomobject]@{ Name = 'Group.ReadWrite.All'; Core = $true; Purpose = 'Read assignment groups and create missing groups during import' }
    [pscustomobject]@{ Name = 'Organization.Read.All'; Core = $true; Purpose = 'Tenant name and id' }
    [pscustomobject]@{ Name = 'Policy.Read.All'; Core = $false; Purpose = 'Read Conditional Access' }
    [pscustomobject]@{ Name = 'Policy.ReadWrite.ConditionalAccess'; Core = $false; Purpose = 'Conditional Access, named locations, authentication strengths' }
    [pscustomobject]@{ Name = 'Application.Read.All'; Core = $false; Purpose = 'Resolve app names in Conditional Access' }
    [pscustomobject]@{ Name = 'Agreement.ReadWrite.All'; Core = $false; Purpose = 'Terms of use' }
    [pscustomobject]@{ Name = 'Organization.ReadWrite.All'; Core = $false; Purpose = 'Entra company branding' }
    [pscustomobject]@{ Name = 'CloudPC.ReadWrite.All'; Core = $false; Purpose = 'Windows 365 policies' }
    [pscustomobject]@{ Name = 'User.Read.All'; Core = $false; Purpose = 'Resolve users in Conditional Access' }
)

$script:IMAadstsHelp = @{
    'AADSTS7000215' = 'The client secret is not valid. Make sure you copied the secret VALUE (shown once when the secret is created), not the Secret ID.'
    'AADSTS7000222' = 'The client secret has expired. Create a new secret on the app registration and update the profile.'
    'AADSTS700016'  = 'The app (client) ID was not found in this tenant. Check the Application (client) ID and the Tenant ID, or confirm the app was created in this tenant.'
    'AADSTS90002'   = 'The tenant was not found. Check the Tenant ID or domain name, and the selected cloud.'
    'AADSTS900023'  = 'The Tenant ID is not in a valid format. Use the Directory (tenant) ID GUID or a verified domain such as contoso.onmicrosoft.com.'
    'AADSTS700027'  = 'The certificate was rejected. Upload the public key (.cer) of this certificate to the app registration, under Certificates & secrets.'
    'AADSTS700024'  = 'The certificate assertion is outside its valid time range. Check that the computer clock is correct.'
    'AADSTS7000112' = 'The application is disabled in this tenant.'
    'AADSTS500011'  = 'Microsoft Graph was not found in this tenant or cloud. Check the selected cloud.'
    'AADSTS53003'   = 'Access was blocked by a Conditional Access policy (workload identity policy).'
    'AADSTS1002012' = 'The requested scope is invalid.'
    'AADSTS50059'   = 'No tenant was specified. Enter the Tenant ID.'
    'AADSTS7000229' = 'The app has no service principal in this tenant. Grant admin consent for the app in this tenant first.'
}

$script:IMConnection = $null

#region Profiles
function Get-IMProfilePath { Join-Path (Get-IMAppDataPath) 'profiles.json' }

function Get-IMConnectionProfile {
    [CmdletBinding()]
    param([string]$Name)
    $path = Get-IMProfilePath
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    $all = @(Read-IMJsonFile $path)
    if ($Name) { return $all | Where-Object { $_.Name -eq $Name -or $_.Id -eq $Name } }
    $all | Sort-Object Name
}

function Protect-IMSecret {
    param([Parameter(Mandatory)][securestring]$Secret)
    if (-not $script:IMIsWindows) {
        throw 'Saving secrets is only supported on Windows (DPAPI). On other platforms pass -ClientSecret at connect time or set the IM_CLIENT_SECRET environment variable.'
    }
    ConvertFrom-SecureString -SecureString $Secret   # DPAPI, bound to this user on this computer
}

function Unprotect-IMSecret {
    param([string]$Protected)
    if ([string]::IsNullOrEmpty($Protected)) { return $null }
    try { ConvertTo-SecureString -String $Protected -ErrorAction Stop }
    catch { throw 'The saved secret cannot be decrypted. Secrets are tied to the Windows user and computer that saved them. Edit the profile and enter the secret again.' }
}

function Save-IMConnectionProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [ValidateSet('Secret', 'Certificate')][string]$AuthType = 'Secret',
        [securestring]$ClientSecret,
        [string]$CertificateThumbprint,
        [string]$CertificatePath,
        [securestring]$CertificatePassword,
        [ValidateSet('Global', 'USGov', 'USGovDoD', 'China')][string]$Cloud = 'Global',
        [string]$TenantName,
        [string]$SecretExpires,
        [string]$Color,
        [string]$Id
    )
    $TenantId = $TenantId.Trim(); $ClientId = $ClientId.Trim()
    if (-not (Test-IMGuid $ClientId)) { throw 'The Application (client) ID must be a GUID.' }
    if (-not (Test-IMGuid $TenantId) -and $TenantId -notmatch '^[a-z0-9-]+(\.[a-z0-9-]+)+$') { throw 'The Tenant ID must be a GUID or a domain name such as contoso.onmicrosoft.com.' }

    $profiles = [System.Collections.Generic.List[object]]::new()
    foreach ($p in (Get-IMConnectionProfile)) { $profiles.Add($p) }
    $existing = $profiles | Where-Object { ($Id -and $_.Id -eq $Id) -or (-not $Id -and $_.Name -eq $Name) } | Select-Object -First 1

    $prof = [pscustomobject][ordered]@{
        Id                    = $existing.Id ?? [guid]::NewGuid().ToString()
        Name                  = $Name.Trim()
        TenantId              = $TenantId
        TenantName            = $TenantName ?? $existing.TenantName
        ClientId              = $ClientId
        AuthType              = $AuthType
        Cloud                 = $Cloud
        CertificateThumbprint = if ($AuthType -eq 'Certificate') { ($CertificateThumbprint -replace '[^0-9A-Fa-f]', '').ToUpperInvariant() } else { $null }
        CertificatePath       = if ($AuthType -eq 'Certificate') { $CertificatePath } else { $null }
        CertificatePassword   = $null
        Secret                = $null
        SecretExpires         = $SecretExpires ?? $existing.SecretExpires
        Color                 = $Color ?? $existing.Color
        LastConnected         = $existing.LastConnected
    }
    if ($AuthType -eq 'Secret') {
        if ($ClientSecret -and $ClientSecret.Length -gt 0) { $prof.Secret = Protect-IMSecret $ClientSecret }
        elseif ($existing.Secret) { $prof.Secret = $existing.Secret }
    }
    if ($CertificatePassword -and $CertificatePassword.Length -gt 0) { $prof.CertificatePassword = Protect-IMSecret $CertificatePassword }
    elseif ($existing.CertificatePassword) { $prof.CertificatePassword = $existing.CertificatePassword }
    if ($AuthType -eq 'Certificate' -and -not $prof.CertificateThumbprint -and -not $prof.CertificatePath) {
        throw 'Choose a certificate (thumbprint from the certificate store, or a .pfx file).'
    }

    if ($existing) { $profiles[$profiles.IndexOf($existing)] = $prof } else { $profiles.Add($prof) }
    Write-IMJsonFile -Path (Get-IMProfilePath) -InputObject @($profiles)
    Write-IMLog -Category 'Connection' -Message "Saved connection profile '$($prof.Name)' ($AuthType, tenant $TenantId)"
    $prof
}

function Remove-IMConnectionProfile {
    param([Parameter(Mandatory)][string]$Name)
    $profiles = @(Get-IMConnectionProfile | Where-Object { $_.Name -ne $Name -and $_.Id -ne $Name })
    Write-IMJsonFile -Path (Get-IMProfilePath) -InputObject $profiles
    Write-IMLog -Category 'Connection' -Message "Removed connection profile '$Name'"
}

function Update-IMProfileField {
    param([string]$Id, [string]$Field, $Value)
    $profiles = @(Get-IMConnectionProfile)
    $p = $profiles | Where-Object Id -eq $Id
    if (-not $p) { return }
    Set-IMProperty $p $Field $Value
    Write-IMJsonFile -Path (Get-IMProfilePath) -InputObject $profiles
}
#endregion

#region Certificates
function Get-IMCertificate {
    <# Finds a certificate with private key by thumbprint (CurrentUser\My, then LocalMachine\My) or loads a PFX. #>
    param([string]$Thumbprint, [string]$Path, [securestring]$Password)

    if ($Path) {
        if (-not (Test-Path -LiteralPath $Path)) { throw "Certificate file not found: $Path" }
        $flags = [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet
        if ($script:IMIsWindows) { $flags = [Security.Cryptography.X509Certificates.X509KeyStorageFlags]::UserKeySet }
        $plain = if ($Password) { [Net.NetworkCredential]::new('', $Password).Password } else { $null }
        try { $cert = [Security.Cryptography.X509Certificates.X509Certificate2]::new($Path, $plain, $flags) }
        catch { throw "Could not open the certificate file. Check the password. $($_.Exception.InnerException.Message ?? $_.Exception.Message)" }
    }
    else {
        $Thumbprint = ($Thumbprint -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
        $cert = $null
        foreach ($location in 'CurrentUser', 'LocalMachine') {
            $store = [Security.Cryptography.X509Certificates.X509Store]::new('My', $location)
            try {
                $store.Open('ReadOnly, OpenExistingOnly')
                $cert = $store.Certificates | Where-Object Thumbprint -eq $Thumbprint | Select-Object -First 1
            }
            catch { } finally { $store.Close() }
            if ($cert) { break }
        }
        if (-not $cert) { throw "No certificate with thumbprint $Thumbprint was found in CurrentUser\My or LocalMachine\My." }
    }
    if (-not $cert.HasPrivateKey) { throw "The certificate '$($cert.Subject)' has no private key on this computer. Import the .pfx (not the .cer)." }
    if ($cert.NotAfter -lt (Get-Date)) { throw "The certificate '$($cert.Subject)' expired on $($cert.NotAfter.ToString('d'))." }
    if ($cert.NotAfter -lt (Get-Date).AddDays(30)) { Write-IMLog -Level Warning -Category 'Connection' -Message "Certificate '$($cert.Subject)' expires on $($cert.NotAfter.ToString('d'))." }
    $cert
}

function Get-IMCertificateList {
    <# Certificates with a private key in the user's and machine's personal store, for the connection dialog picker. #>
    $list = foreach ($location in 'CurrentUser', 'LocalMachine') {
        $store = [Security.Cryptography.X509Certificates.X509Store]::new('My', $location)
        try {
            $store.Open('ReadOnly, OpenExistingOnly')
            foreach ($c in $store.Certificates) {
                if ($c.HasPrivateKey -and $c.NotAfter -gt (Get-Date)) {
                    [pscustomobject]@{ Thumbprint = $c.Thumbprint; Subject = $c.Subject; Expires = $c.NotAfter; Store = "$location\My"
                        Display = "$($c.Subject)  ·  expires $($c.NotAfter.ToString('yyyy-MM-dd'))  ·  $($c.Thumbprint.Substring(0,8))…" }
                }
            }
        }
        catch { } finally { $store.Close() }
    }
    $list | Sort-Object Expires -Descending
}

function ConvertTo-IMBase64Url {
    param([byte[]]$Bytes)
    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-IMClientAssertion {
    param([Parameter(Mandatory)][Security.Cryptography.X509Certificates.X509Certificate2]$Certificate, [string]$ClientId, [string]$Audience)
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $header = [ordered]@{ alg = 'RS256'; typ = 'JWT'; x5t = (ConvertTo-IMBase64Url $Certificate.GetCertHash()) }
    $payload = [ordered]@{ aud = $Audience; iss = $ClientId; sub = $ClientId; jti = [guid]::NewGuid().ToString(); nbf = $now - 60; iat = $now - 60; exp = $now + 600 }
    $enc = [Text.Encoding]::UTF8
    $unsigned = (ConvertTo-IMBase64Url $enc.GetBytes(($header | ConvertTo-Json -Compress))) + '.' + (ConvertTo-IMBase64Url $enc.GetBytes(($payload | ConvertTo-Json -Compress)))
    $rsa = [Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Certificate)
    if (-not $rsa) { throw 'The certificate private key is not an RSA key or cannot be accessed.' }
    $sig = $rsa.SignData($enc.GetBytes($unsigned), [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    "$unsigned.$(ConvertTo-IMBase64Url $sig)"
}
#endregion

#region Tokens
function ConvertFrom-IMJwt {
    param([Parameter(Mandatory)][string]$Token)
    $part = $Token.Split('.')[1].Replace('-', '+').Replace('_', '/')
    switch ($part.Length % 4) { 2 { $part += '==' } 3 { $part += '=' } }
    ConvertFrom-IMJson ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($part)))
}

function Get-IMFriendlyAuthError {
    param([string]$ResponseBody, [string]$Fallback)
    $err = $null
    try { $err = ConvertFrom-IMJson $ResponseBody } catch { }
    $desc = $err.error_description ?? $Fallback ?? $ResponseBody
    $code = if ($desc -match '(AADSTS\d+)') { $Matches[1] } else { $null }
    $hint = if ($code -and $script:IMAadstsHelp.ContainsKey($code)) { $script:IMAadstsHelp[$code] } else { $null }
    $firstLine = ($desc -split "`r?`n")[0]
    [pscustomobject]@{ Code = $code; Hint = $hint; Raw = $firstLine; Message = if ($hint) { "$hint ($code)" } else { $firstLine } }
}

function Request-IMToken {
    <# Requests an app-only token. Throws with a friendly message on failure. #>
    param([Parameter(Mandatory)][hashtable]$Connection)

    $tokenUrl = "$($Connection.LoginUrl)/$($Connection.TenantId)/oauth2/v2.0/token"
    $form = [ordered]@{
        client_id  = $Connection.ClientId
        scope      = "$($Connection.GraphUrl)/.default"
        grant_type = 'client_credentials'
    }
    if ($Connection.AuthType -eq 'Certificate') {
        $form.client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
        $form.client_assertion = New-IMClientAssertion -Certificate $Connection.Certificate -ClientId $Connection.ClientId -Audience $tokenUrl
    }
    else {
        $form.client_secret = [Net.NetworkCredential]::new('', $Connection.Secret).Password
    }
    $body = ($form.GetEnumerator() | ForEach-Object { "$($_.Key)=$([Uri]::EscapeDataString([string]$_.Value))" }) -join '&'

    try {
        $resp = Invoke-IMHttp -Method POST -Uri $tokenUrl -Body $body -ContentType 'application/x-www-form-urlencoded' -TimeoutSeconds 60
    }
    catch {
        throw "Could not reach the sign-in service at $($Connection.LoginUrl). Check the network or proxy. $($_.Exception.Message)"
    }
    if ($resp.StatusCode -ne 200) {
        $friendly = Get-IMFriendlyAuthError -ResponseBody $resp.Content -Fallback "HTTP $($resp.StatusCode)"
        $ex = [System.Security.Authentication.AuthenticationException]::new($friendly.Message)
        $ex.Data['AADSTS'] = $friendly.Code
        $ex.Data['Raw'] = $friendly.Raw
        throw $ex
    }
    $json = ConvertFrom-IMJson $resp.Content
    $claims = ConvertFrom-IMJwt $json.access_token
    [pscustomobject]@{
        AccessToken = $json.access_token
        ExpiresOn   = [DateTimeOffset]::UtcNow.AddSeconds([int]$json.expires_in)
        Roles       = @($claims.roles)
        TenantId    = $claims.tid
        AppName     = $claims.app_displayname
    }
}

function Get-IMAccessToken {
    <# Returns a valid token for the current connection, refreshing 5 minutes before expiry. Thread-safe. #>
    param([switch]$ForceRefresh)
    $c = $script:IMConnection
    if (-not $c) { throw 'Not connected. Connect to a tenant first (Connect-IMTenant).' }
    if (-not $ForceRefresh -and $c.Token -and $c.ExpiresOn -gt [DateTimeOffset]::UtcNow.AddMinutes(5)) { return $c.Token }
    [Threading.Monitor]::Enter($c.Lock)
    try {
        if (-not $ForceRefresh -and $c.Token -and $c.ExpiresOn -gt [DateTimeOffset]::UtcNow.AddMinutes(5)) { return $c.Token }
        $t = Request-IMToken -Connection $c
        $c.Token = $t.AccessToken; $c.ExpiresOn = $t.ExpiresOn; $c.Roles = $t.Roles
        Write-IMLog -Level Debug -Category 'Connection' -Message "Access token acquired, valid until $($t.ExpiresOn.LocalDateTime.ToString('T'))"
        $c.Token
    }
    finally { [Threading.Monitor]::Exit($c.Lock) }
}
#endregion

#region Connect / disconnect
function Connect-IMTenant {
    <#
    .SYNOPSIS
    Connects to a tenant with an app registration (client secret or certificate).
    .EXAMPLE
    Connect-IMTenant -ProfileName 'Contoso PROD'
    .EXAMPLE
    Connect-IMTenant -TenantId contoso.onmicrosoft.com -ClientId <guid> -CertificateThumbprint <thumbprint>
    #>
    [CmdletBinding(DefaultParameterSetName = 'Profile')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Profile', Position = 0)][string]$ProfileName,
        [Parameter(Mandatory, ParameterSetName = 'Secret')][Parameter(Mandatory, ParameterSetName = 'Certificate')][string]$TenantId,
        [Parameter(Mandatory, ParameterSetName = 'Secret')][Parameter(Mandatory, ParameterSetName = 'Certificate')][string]$ClientId,
        [Parameter(ParameterSetName = 'Secret')][securestring]$ClientSecret,
        [Parameter(ParameterSetName = 'Certificate')][string]$CertificateThumbprint,
        [Parameter(ParameterSetName = 'Certificate')][string]$CertificatePath,
        [Parameter(ParameterSetName = 'Certificate')][securestring]$CertificatePassword,
        [Parameter(ParameterSetName = 'Secret')][Parameter(ParameterSetName = 'Certificate')][ValidateSet('Global', 'USGov', 'USGovDoD', 'China')][string]$Cloud = 'Global',
        [Parameter(ParameterSetName = 'Secret')][Parameter(ParameterSetName = 'Certificate')][string]$Name
    )

    $prof = $null
    if ($PSCmdlet.ParameterSetName -eq 'Profile') {
        $prof = Get-IMConnectionProfile -Name $ProfileName | Select-Object -First 1
        if (-not $prof) { throw "No connection profile named '$ProfileName'. Create one in the app or with Save-IMConnectionProfile." }
        $TenantId = $prof.TenantId; $ClientId = $prof.ClientId; $Cloud = $prof.Cloud ?? 'Global'
        if ($prof.AuthType -eq 'Certificate') {
            $CertificateThumbprint = $prof.CertificateThumbprint; $CertificatePath = $prof.CertificatePath
            if ($prof.CertificatePassword) { $CertificatePassword = Unprotect-IMSecret $prof.CertificatePassword }
        }
        else {
            $ClientSecret = Unprotect-IMSecret $prof.Secret
        }
        $Name = $prof.Name
    }

    $authType = if ($CertificateThumbprint -or $CertificatePath) { 'Certificate' } else { 'Secret' }
    if ($authType -eq 'Secret' -and (-not $ClientSecret -or $ClientSecret.Length -eq 0)) {
        if ($env:IM_CLIENT_SECRET) { $ClientSecret = ConvertTo-SecureString $env:IM_CLIENT_SECRET -AsPlainText -Force }
        else { throw 'No client secret available. Enter the secret value in the connection profile.' }
    }

    $cloudInfo = $script:IMClouds[$Cloud]
    $conn = [hashtable]::Synchronized(@{
        Name = $Name ?? $TenantId; ProfileId = $prof.Id
        TenantId = $TenantId.Trim(); ClientId = $ClientId.Trim(); AuthType = $authType; Cloud = $Cloud
        LoginUrl = $cloudInfo.Login; GraphUrl = $cloudInfo.Graph; PortalUrl = $cloudInfo.Portal
        Secret = $ClientSecret; Certificate = $null
        Token = $null; ExpiresOn = [DateTimeOffset]::MinValue; Roles = @()
        Organization = $null; Lock = [object]::new(); ConnectedAt = Get-Date
    })
    if ($authType -eq 'Certificate') { $conn.Certificate = Get-IMCertificate -Thumbprint $CertificateThumbprint -Path $CertificatePath -Password $CertificatePassword }

    Write-IMLog -Category 'Connection' -Message "Connecting to '$($conn.Name)' (tenant $($conn.TenantId), $authType, $Cloud cloud)"
    try { $token = Request-IMToken -Connection $conn }
    catch {
        Write-IMLog -Level Error -Category 'Connection' -Message "Sign-in failed for '$($conn.Name)'" -ErrorRecord $_
        throw
    }
    $conn.Token = $token.AccessToken; $conn.ExpiresOn = $token.ExpiresOn; $conn.Roles = $token.Roles
    $conn.TenantId = $token.TenantId   # normalise domain names to the tenant GUID
    $script:IMConnection = $conn

    if ($conn.Roles.Count -eq 0) {
        Write-IMLog -Level Warning -Category 'Connection' -Message 'The token has no application permissions. Add Microsoft Graph application permissions to the app and grant admin consent.'
    }

    # Organization details (optional)
    try {
        $org = (Invoke-IMGraphRequest -Uri '/organization?$select=id,displayName,verifiedDomains' -Version 'v1.0' -NoLog).value | Select-Object -First 1
        $conn.Organization = [pscustomobject]@{
            Id = $org.id; DisplayName = $org.displayName
            DefaultDomain = ($org.verifiedDomains | Where-Object isDefault | Select-Object -First 1).name
            InitialDomain = ($org.verifiedDomains | Where-Object isInitial | Select-Object -First 1).name
        }
    }
    catch {
        $conn.Organization = [pscustomobject]@{ Id = $conn.TenantId; DisplayName = $prof.TenantName ?? $conn.TenantId; DefaultDomain = $null; InitialDomain = $null }
        Write-IMLog -Level Warning -Category 'Connection' -Message 'Could not read the organization name (needs Organization.Read.All). Continuing.'
    }

    if ($prof) {
        Update-IMProfileField -Id $prof.Id -Field 'LastConnected' -Value (Get-Date).ToString('o')
        if ($conn.Organization.DisplayName -and $conn.Organization.DisplayName -ne $conn.TenantId) { Update-IMProfileField -Id $prof.Id -Field 'TenantName' -Value $conn.Organization.DisplayName }
    }

    $missing = @(Get-IMPermissionReport | Where-Object { $_.Core -and -not $_.Granted })
    if ($missing.Count) {
        Write-IMLog -Level Warning -Category 'Connection' -Message "Missing recommended permissions: $($missing.Name -join ', ')"
    }
    Write-IMLog -Level Success -Category 'Connection' -Message "Connected to $($conn.Organization.DisplayName) ($($conn.TenantId)) as app '$($token.AppName)' with $($conn.Roles.Count) permissions"
    Get-IMConnection
}

function Get-IMConnection {
    $c = $script:IMConnection
    if (-not $c) { return $null }
    [pscustomobject]@{
        Name = $c.Name; TenantId = $c.TenantId; Organization = $c.Organization.DisplayName; Domain = $c.Organization.InitialDomain
        ClientId = $c.ClientId; AuthType = $c.AuthType; Cloud = $c.Cloud; Roles = $c.Roles; TokenExpires = $c.ExpiresOn.LocalDateTime
        ConnectedAt = $c.ConnectedAt; ProfileId = $c.ProfileId
    }
}

function Get-IMConnectionState { $script:IMConnection }
function Set-IMConnectionState { param([hashtable]$State) $script:IMConnection = $State }

function Disconnect-IMTenant {
    if ($script:IMConnection) {
        Write-IMLog -Category 'Connection' -Message "Disconnected from '$($script:IMConnection.Name)'"
        $script:IMConnection.Token = $null
    }
    $script:IMConnection = $null
    Clear-IMCache
}

function Test-IMConnectionProfile {
    <# Signs in with the given values without changing the current connection. Returns a result object for the UI. #>
    [CmdletBinding()]
    param(
        [string]$TenantId, [string]$ClientId, [ValidateSet('Secret', 'Certificate')][string]$AuthType = 'Secret',
        [securestring]$ClientSecret, [string]$CertificateThumbprint, [string]$CertificatePath, [securestring]$CertificatePassword,
        [string]$Cloud = 'Global'
    )
    $result = [pscustomobject]@{ Success = $false; Message = ''; Roles = @(); TenantId = $null; AppName = $null; Permissions = @() }
    try {
        $conn = @{ TenantId = $TenantId.Trim(); ClientId = $ClientId.Trim(); AuthType = $AuthType; LoginUrl = $script:IMClouds[$Cloud].Login; GraphUrl = $script:IMClouds[$Cloud].Graph; Secret = $ClientSecret }
        if ($AuthType -eq 'Certificate') { $conn.Certificate = Get-IMCertificate -Thumbprint $CertificateThumbprint -Path $CertificatePath -Password $CertificatePassword }
        $t = Request-IMToken -Connection $conn
        $result.Success = $true; $result.Roles = $t.Roles; $result.TenantId = $t.TenantId; $result.AppName = $t.AppName
        $result.Permissions = Get-IMPermissionReport -Roles $t.Roles
        $missingCore = @($result.Permissions | Where-Object { $_.Core -and -not $_.Granted })
        $result.Message = if ($t.Roles.Count -eq 0) { "Signed in as '$($t.AppName)', but the app has no Graph application permissions yet. Add them and grant admin consent." }
            elseif ($missingCore.Count) { "Signed in as '$($t.AppName)'. $($missingCore.Count) recommended permission(s) are missing; some object types will be unavailable." }
            else { "Signed in as '$($t.AppName)'. All core permissions are granted." }
        Write-IMLog -Category 'Connection' -Message "Connection test succeeded for app $ClientId in tenant $TenantId ($($t.Roles.Count) roles)"
    }
    catch {
        $result.Message = $_.Exception.Message
        Write-IMLog -Level Warning -Category 'Connection' -Message "Connection test failed for app $ClientId in tenant $TenantId" -ErrorRecord $_
    }
    $result
}

function Get-IMPermissionReport {
    param([string[]]$Roles = $script:IMConnection.Roles)
    foreach ($p in $script:IMPermissionCatalog) {
        $granted = $p.Name -in $Roles
        if (-not $granted -and $p.Name -like '*.Read.All') { $granted = ($p.Name -replace '\.Read\.All$', '.ReadWrite.All') -in $Roles }
        if (-not $granted -and $p.Name -eq 'Organization.Read.All') { $granted = 'Directory.Read.All' -in $Roles -or 'Directory.ReadWrite.All' -in $Roles }
        if (-not $granted -and $p.Name -eq 'Policy.Read.All') { $granted = 'Policy.ReadWrite.ConditionalAccess' -in $Roles }
        [pscustomobject]@{ Name = $p.Name; Granted = $granted; Core = $p.Core; Purpose = $p.Purpose }
    }
}

function Test-IMPermission {
    <# True if the current token has any of the given permissions (ReadWrite satisfies Read). #>
    param([string[]]$Permission, [switch]$Write)
    $roles = $script:IMConnection.Roles
    if (-not $roles -or -not $Permission) { return $true }
    foreach ($p in $Permission) {
        if ($p -in $roles) { return $true }
        if (-not $Write -and ($p -replace '\.ReadWrite\.', '.Read.') -in $roles) { return $true }
        if ($p -like '*.Read.All' -and ($p -replace '\.Read\.All$', '.ReadWrite.All') -in $roles) { return $true }
    }
    $false
}
#endregion

#region One-time setup: create an app registration for the user
function Start-IMDeviceCodeLogin {
    <# Step 1 of setup: returns the device code info to show to the user. #>
    param([ValidateSet('Global', 'USGov', 'USGovDoD', 'China')][string]$Cloud = 'Global', [string]$Tenant = 'organizations')
    $c = $script:IMClouds[$Cloud]
    $scopes = @('Application.ReadWrite.All', 'AppRoleAssignment.ReadWrite.All', 'Organization.Read.All') | ForEach-Object { "$($c.Graph)/$_" }
    $body = "client_id=$($script:IMSetupClientId)&scope=$([Uri]::EscapeDataString(($scopes + 'offline_access') -join ' '))"
    $resp = Invoke-IMHttp -Method POST -Uri "$($c.Login)/$Tenant/oauth2/v2.0/devicecode" -Body $body -ContentType 'application/x-www-form-urlencoded'
    if ($resp.StatusCode -ne 200) { throw (Get-IMFriendlyAuthError $resp.Content).Message }
    $j = ConvertFrom-IMJson $resp.Content
    [pscustomobject]@{ UserCode = $j.user_code; DeviceCode = $j.device_code; VerificationUri = $j.verification_uri; Message = $j.message
        Interval = [int]$j.interval; ExpiresAt = (Get-Date).AddSeconds([int]$j.expires_in); Cloud = $Cloud; Tenant = $Tenant }
}

function Wait-IMDeviceCodeLogin {
    <# Step 2 of setup: polls until the admin finished signing in. Returns a delegated token. #>
    param([Parameter(Mandatory)]$DeviceCode, [hashtable]$CancelFlag)
    $c = $script:IMClouds[$DeviceCode.Cloud]
    $interval = [math]::Max(5, $DeviceCode.Interval)
    while ((Get-Date) -lt $DeviceCode.ExpiresAt) {
        if ($CancelFlag -and $CancelFlag.CancelRequested) { throw 'Sign-in cancelled.' }
        Start-Sleep -Seconds $interval
        $body = "grant_type=urn:ietf:params:oauth:grant-type:device_code&client_id=$($script:IMSetupClientId)&device_code=$($DeviceCode.DeviceCode)"
        $resp = Invoke-IMHttp -Method POST -Uri "$($c.Login)/$($DeviceCode.Tenant)/oauth2/v2.0/token" -Body $body -ContentType 'application/x-www-form-urlencoded'
        $j = ConvertFrom-IMJson $resp.Content
        if ($resp.StatusCode -eq 200) { return $j.access_token }
        switch ($j.error) {
            'authorization_pending' { continue }
            'slow_down' { $interval += 5; continue }
            'authorization_declined' { throw 'Sign-in was declined.' }
            'expired_token' { throw 'The code expired. Start again.' }
            default { throw (Get-IMFriendlyAuthError $resp.Content).Message }
        }
    }
    throw 'The code expired before sign-in completed. Start again.'
}

function New-IMSelfSignedCertificate {
    <# Creates a 2-year RSA certificate in CurrentUser\My (with private key) and returns it. #>
    param([string]$Subject = 'CN=IntuneManager')
    $rsa = [Security.Cryptography.RSA]::Create(2048)
    $req = [Security.Cryptography.X509Certificates.CertificateRequest]::new($Subject, $rsa, [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $req.CertificateExtensions.Add([Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new('DigitalSignature', $false))
    $tmp = $req.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddYears(2))
    # Re-import as persisted key so it survives in the store
    $pwd = [guid]::NewGuid().ToString()
    $pfx = $tmp.Export('Pfx', $pwd)
    $flags = [Security.Cryptography.X509Certificates.X509KeyStorageFlags]'PersistKeySet, UserKeySet, Exportable'
    $cert = [Security.Cryptography.X509Certificates.X509Certificate2]::new($pfx, $pwd, $flags)
    $store = [Security.Cryptography.X509Certificates.X509Store]::new('My', 'CurrentUser')
    $store.Open('ReadWrite'); $store.Add($cert); $store.Close()
    $cert
}

function New-IMAppRegistration {
    <#
    .SYNOPSIS
    Creates an app registration with all needed Graph permissions, grants admin consent,
    adds a certificate or secret, waits until it works and saves a connection profile.
    Requires a delegated token from an admin (Start-IMDeviceCodeLogin + Wait-IMDeviceCodeLogin).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DelegatedToken,
        [string]$DisplayName = 'IntuneManager',
        [ValidateSet('Certificate', 'Secret')][string]$CredentialType = 'Certificate',
        [switch]$IncludeOptionalPermissions,
        [ValidateSet('Global', 'USGov', 'USGovDoD', 'China')][string]$Cloud = 'Global',
        [string]$ProfileName,
        [scriptblock]$OnStatus
    )
    $c = $script:IMClouds[$Cloud]
    $status = { param($m) Write-IMLog -Category 'Setup' -Message $m; if ($OnStatus) { & $OnStatus $m } }
    $call = {
        param($Method, $Path, $Body)
        $h = @{ Authorization = "Bearer $DelegatedToken" }
        $json = if ($null -ne $Body) { ConvertTo-IMJson $Body -Compress } else { $null }
        $r = Invoke-IMHttp -Method $Method -Uri "$($c.Graph)/v1.0$Path" -Headers $h -Body $json -ContentType 'application/json'
        if ($r.StatusCode -ge 400) {
            $e = try { (ConvertFrom-IMJson $r.Content).error } catch { $null }
            if ($r.StatusCode -eq 403) { throw "Access denied while calling $Path. Sign in with a Global Administrator, Privileged Role Administrator or Cloud Application Administrator account. ($($e.message))" }
            throw "$Method $Path failed ($($r.StatusCode)): $($e.message ?? $r.Content)"
        }
        if ($r.Content) { ConvertFrom-IMJson $r.Content }
    }

    $claims = ConvertFrom-IMJwt $DelegatedToken
    $tenantId = $claims.tid
    & $status "Signed in as $($claims.upn ?? $claims.unique_name) in tenant $tenantId"

    $wanted = @($script:IMPermissionCatalog | Where-Object { $_.Core -or $IncludeOptionalPermissions }).Name
    & $status 'Reading Microsoft Graph permission ids'
    $graphSp = (& $call GET "/servicePrincipals?`$filter=appId eq '$($script:IMGraphAppId)'&`$select=id,appRoles").value | Select-Object -First 1
    $roles = foreach ($w in $wanted) {
        $r = $graphSp.appRoles | Where-Object { $_.value -eq $w -and $_.allowedMemberTypes -contains 'Application' }
        if ($r) { $r } else { & $status "Permission $w is not available in this cloud; skipped" }
    }

    & $status "Creating app registration '$DisplayName'"
    $app = & $call POST '/applications' ([ordered]@{
        displayName = $DisplayName; signInAudience = 'AzureADMyOrg'
        notes = "Created by IntuneManager on $((Get-Date).ToString('yyyy-MM-dd')) for Intune export/import."
        requiredResourceAccess = @(@{ resourceAppId = $script:IMGraphAppId; resourceAccess = @($roles | ForEach-Object { @{ id = $_.id; type = 'Role' } }) })
    })
    & $status 'Creating service principal'
    $sp = $null
    for ($i = 0; $i -lt 6 -and -not $sp; $i++) {
        try { $sp = & $call POST '/servicePrincipals' @{ appId = $app.appId } } catch { Start-Sleep -Seconds 5 }
    }
    if (-not $sp) { throw 'Could not create the service principal for the new app.' }

    $secret = $null; $cert = $null; $expires = $null
    if ($CredentialType -eq 'Certificate') {
        & $status 'Creating a certificate in your personal certificate store'
        $cert = New-IMSelfSignedCertificate -Subject "CN=$DisplayName ($tenantId)"
        & $call PATCH "/applications/$($app.id)" @{ keyCredentials = @(@{ type = 'AsymmetricX509Cert'; usage = 'Verify'; key = [Convert]::ToBase64String($cert.RawData); displayName = $cert.Subject }) } | Out-Null
        $expires = $cert.NotAfter.ToString('o')
    }
    else {
        & $status 'Creating a client secret (valid 12 months)'
        $pw = & $call POST "/applications/$($app.id)/addPassword" @{ passwordCredential = @{ displayName = 'IntuneManager'; endDateTime = (Get-Date).ToUniversalTime().AddMonths(12).ToString('o') } }
        $secret = ConvertTo-SecureString $pw.secretText -AsPlainText -Force
        $expires = $pw.endDateTime
    }

    & $status "Granting admin consent for $(@($roles).Count) permissions"
    foreach ($r in $roles) {
        try { & $call POST "/servicePrincipals/$($sp.id)/appRoleAssignments" @{ principalId = $sp.id; resourceId = $graphSp.id; appRoleId = $r.id } | Out-Null }
        catch { if ($_.Exception.Message -notmatch 'already exists') { & $status "Could not grant $($r.value): $($_.Exception.Message)" } }
    }

    & $status 'Waiting for Entra ID to replicate the new app (this can take a minute)'
    $conn = @{ TenantId = $tenantId; ClientId = $app.appId; AuthType = $CredentialType; LoginUrl = $c.Login; GraphUrl = $c.Graph; Secret = $secret; Certificate = $cert }
    $ok = $false
    for ($i = 0; $i -lt 24; $i++) {
        try {
            $t = Request-IMToken -Connection $conn
            if ($t.Roles.Count -ge [math]::Max(1, @($roles).Count - 2)) { $ok = $true; break }
        }
        catch { }
        Start-Sleep -Seconds 10
    }
    if (-not $ok) { & $status 'The app was created but permissions have not replicated yet. Wait a few minutes before connecting.' }

    $name = $ProfileName ?? ($claims.tid)
    $org = try { (& $call GET '/organization?$select=displayName').value[0].displayName } catch { $null }
    if (-not $ProfileName -and $org) { $name = $org }
    $saveArgs = @{ Name = $name; TenantId = $tenantId; ClientId = $app.appId; AuthType = $CredentialType; Cloud = $Cloud; TenantName = $org; SecretExpires = $expires }
    if ($cert) { $saveArgs.CertificateThumbprint = $cert.Thumbprint }
    if ($secret) {
        if ($script:IMIsWindows) { $saveArgs.ClientSecret = $secret }
        else { & $status 'Secret not saved (only supported on Windows). Copy it now from the result.' }
    }
    $prof = Save-IMConnectionProfile @saveArgs
    & $status "Done. Profile '$name' saved."
    [pscustomobject]@{
        Profile = $prof; AppId = $app.appId; ObjectId = $app.id; TenantId = $tenantId
        CertificateThumbprint = $cert.Thumbprint; SecretExpires = $expires; Ready = $ok
        SecretText = if ($secret -and -not $script:IMIsWindows) { [Net.NetworkCredential]::new('', $secret).Password } else { $null }
    }
}
#endregion
