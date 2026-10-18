<#
  Microsoft Graph client
  - One shared HttpClient (connection pooling, system proxy, gzip)
  - Retries: 429 / 503 / 504 / 502 / 500 / network errors, honours Retry-After, exponential backoff + jitter
  - Non-idempotent requests (POST) are only retried when the service guarantees nothing was processed (429/503)
  - 401 -> token refresh and one retry
  - Typed errors (IntuneManager.GraphException) with request-id / client-request-id for support cases
  - Paging (@odata.nextLink) and JSON $batch (20 per call) with per-item retry
  - Injectable transport for offline tests ($script:IMTransport)
#>

$script:IMTransport = $null
$script:IMHttpClient = $null
$script:IMCache = [hashtable]::Synchronized(@{})
$script:IMUserAgent = 'IntuneManager/1.0 (PowerShell)'

function Get-IMHttpClient {
    if (-not $script:IMHttpClient) {
        $handler = [System.Net.Http.SocketsHttpHandler]::new()
        $handler.AutomaticDecompression = [System.Net.DecompressionMethods]'GZip, Deflate'
        $handler.PooledConnectionLifetime = [TimeSpan]::FromMinutes(2)
        $handler.MaxConnectionsPerServer = 16
        $handler.UseProxy = $true
        $handler.DefaultProxyCredentials = [System.Net.CredentialCache]::DefaultCredentials
        $client = [System.Net.Http.HttpClient]::new($handler)
        $client.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan   # per-request timeout handled with a CancellationToken
        $script:IMHttpClient = $client
    }
    $script:IMHttpClient
}

function Set-IMTransport {
    <# Replace the HTTP transport (tests). The scriptblock receives a hashtable and returns @{StatusCode; Headers; Content}. #>
    param([scriptblock]$Transport)
    $script:IMTransport = $Transport
}

function Invoke-IMHttp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [hashtable]$Headers,
        [string]$Body,
        [byte[]]$BinaryBody,
        [string]$ContentType = 'application/json',
        [int]$TimeoutSeconds = 100,
        [switch]$AsBytes
    )
    if ($script:IMTransport) {
        return & $script:IMTransport @{ Method = $Method.ToUpperInvariant(); Uri = $Uri; Headers = $Headers; Body = $Body; BinaryBody = $BinaryBody; ContentType = $ContentType }
    }

    $client = Get-IMHttpClient
    $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($Method.ToUpperInvariant()), $Uri)
    $req.Headers.TryAddWithoutValidation('User-Agent', $script:IMUserAgent) | Out-Null
    if ($Headers) { foreach ($k in $Headers.Keys) { $req.Headers.TryAddWithoutValidation($k, [string]$Headers[$k]) | Out-Null } }
    if ($null -ne $BinaryBody) {
        $req.Content = [System.Net.Http.ByteArrayContent]::new($BinaryBody)
        $req.Content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse($ContentType)
    }
    elseif ($PSBoundParameters.ContainsKey('Body') -and $null -ne $Body) {
        $req.Content = [System.Net.Http.StringContent]::new($Body, [Text.Encoding]::UTF8)
        $req.Content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse("$ContentType; charset=utf-8")
    }
    $cts = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSeconds))
    try {
        $resp = $client.SendAsync($req, $cts.Token).GetAwaiter().GetResult()
        $h = @{}
        foreach ($kv in $resp.Headers) { $h[$kv.Key.ToLowerInvariant()] = ($kv.Value -join ',') }
        if ($resp.Content) { foreach ($kv in $resp.Content.Headers) { $h[$kv.Key.ToLowerInvariant()] = ($kv.Value -join ',') } }
        $content = if ($AsBytes) { $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult() } else { $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult() }
        [pscustomobject]@{ StatusCode = [int]$resp.StatusCode; Headers = $h; Content = $content }
    }
    catch [System.Threading.Tasks.TaskCanceledException] {
        throw [System.TimeoutException]::new("The request timed out after $TimeoutSeconds seconds: $Method $Uri")
    }
    catch {
        $inner = $_.Exception
        while ($inner.InnerException) { $inner = $inner.InnerException }
        throw [System.Net.Http.HttpRequestException]::new("Network error calling $Method $Uri : $($inner.Message)", $_.Exception)
    }
    finally { $req.Dispose(); $cts.Dispose() }
}

function Resolve-IMGraphUri {
    param([Parameter(Mandatory)][string]$Uri, [string]$Version)
    if ($Uri -match '^https?://') { return $Uri }
    if (-not $script:IMConnection) { throw 'Not connected. Connect to a tenant first.' }
    if (-not $Version) { $Version = Get-IMSetting 'GraphApiVersion' }
    $path = $Uri.TrimStart('/')
    # Encode spaces and quotes in the query part only
    $q = $path.IndexOf('?')
    if ($q -ge 0) { $path = $path.Substring(0, $q) + ($path.Substring($q) -replace ' ', '%20' -replace "#", '%23') }
    "$($script:IMConnection.GraphUrl)/$Version/$path"
}

function Get-IMRetryDelay {
    param([int]$Attempt, [hashtable]$Headers)
    if ($Headers -and $Headers['retry-after']) {
        $ra = $Headers['retry-after']; $sec = 0
        if ([int]::TryParse($ra, [ref]$sec)) { return [math]::Min([math]::Max($sec, 1), 300) }
        $d = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse($ra, [ref]$d)) { return [math]::Min([math]::Max(($d - [DateTimeOffset]::UtcNow).TotalSeconds, 1), 300) }
    }
    $base = [math]::Min([math]::Pow(2, $Attempt), 60)
    $base + (Get-Random -Minimum 0.0 -Maximum 1.0)
}

function New-IMGraphException {
    param($Method, $Url, $Response, [int]$Attempts, [string]$ClientRequestId)
    $err = $null
    try { $err = (ConvertFrom-IMJson $Response.Content).error } catch { }
    $status = $Response.StatusCode
    $code = $err.code
    $msg = $err.message
    # Some Intune errors nest JSON in message ("{ "_version": 3, "Message": "..."}")
    if ($msg -and $msg.TrimStart().StartsWith('{')) {
        try { $inner = ConvertFrom-IMJson $msg; if ($inner.Message) { $msg = ($inner.Message -split ' - Operation ID')[0] } } catch { }
    }
    if (-not $msg) { $msg = if ($Response.Content) { $Response.Content.Substring(0, [math]::Min(500, $Response.Content.Length)) } else { "HTTP $status" } }
    $friendly = switch ($status) {
        400 { "Graph rejected the request: $msg" }
        401 { "Not authorised (401). The token is invalid or expired. $msg" }
        403 { "Access denied (403). The app is missing a permission for this API, or a scope tag/RBAC limits it. $msg" }
        404 { "Not found (404). $msg" }
        409 { "Conflict (409). An object with the same key already exists. $msg" }
        429 { "Throttled by Graph (429) and retries were exhausted. $msg" }
        default { "Graph returned $status. $msg" }
    }
    $ex = [IntuneManager.GraphException]::new($friendly)
    $ex.StatusCode = $status; $ex.ErrorCode = $code; $ex.GraphMessage = $msg
    $ex.RequestId = $Response.Headers['request-id'] ?? $err.innerError.'request-id'
    $ex.ClientRequestId = $Response.Headers['client-request-id'] ?? $ClientRequestId
    $ex.Method = $Method; $ex.Url = $Url; $ex.ResponseBody = $Response.Content; $ex.Attempts = $Attempts
    $ex.IsTransient = $status -in 429, 500, 502, 503, 504
    $ex
}

function Invoke-IMGraphRequest {
    <#
    .SYNOPSIS
    Calls Microsoft Graph with retries, token refresh and typed errors.
    .PARAMETER Uri   Relative ('/deviceManagement/...') or absolute URL.
    .PARAMETER All   Follow @odata.nextLink and return all items of a collection.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Uri,
        [ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE')][string]$Method = 'GET',
        $Body,
        [string]$Version,
        [hashtable]$Headers,
        [switch]$All,
        [switch]$IgnoreNotFound,
        [switch]$NoLog,
        [int]$MaxRetries = -1,
        [switch]$Raw,
        [switch]$AsBytes,
        [byte[]]$BinaryBody,
        [string]$ContentType = 'application/json'
    )
    $url = Resolve-IMGraphUri -Uri $Uri -Version $Version
    if ($MaxRetries -lt 0) { $MaxRetries = [int](Get-IMSetting 'MaxRetries') }
    $timeout = [int](Get-IMSetting 'RequestTimeoutSeconds')
    $bodyText = if ($null -eq $Body) { $null } elseif ($Body -is [string]) { $Body } else { ConvertTo-IMJson $Body -Compress }
    $idempotent = $Method -in 'GET', 'PUT', 'DELETE'

    $items = [System.Collections.Generic.List[object]]::new()
    $nextUrl = $url
    $page = 0
    do {
        $page++
        $attempt = 0; $refreshed = $false; $result = $null
        while ($true) {
            $attempt++
            $clientRequestId = [guid]::NewGuid().ToString()
            $h = @{ Authorization = "Bearer $(Get-IMAccessToken)"; 'client-request-id' = $clientRequestId; 'return-client-request-id' = 'true' }
            if ($Headers) { foreach ($k in $Headers.Keys) { $h[$k] = $Headers[$k] } }
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $resp = $null; $netError = $null
            try {
                $httpArgs = @{ Method = $Method; Uri = $nextUrl; Headers = $h; TimeoutSeconds = $timeout; ContentType = $ContentType }
                if ($null -ne $BinaryBody) { $httpArgs.BinaryBody = $BinaryBody } elseif ($null -ne $bodyText) { $httpArgs.Body = $bodyText }
                if ($AsBytes) { $httpArgs.AsBytes = $true }
                $resp = Invoke-IMHttp @httpArgs
            }
            catch { $netError = $_ }
            $sw.Stop()

            if ($netError) {
                # Network failure: safe to retry GET/PUT/DELETE; POST/PATCH may have been applied
                if (($idempotent -or $Method -eq 'PATCH') -and $attempt -le $MaxRetries) {
                    $delay = Get-IMRetryDelay -Attempt $attempt
                    Write-IMLog -Level Warning -Category 'Graph' -Message "$Method $nextUrl network error, retry $attempt/$MaxRetries in $([math]::Round($delay,1))s: $($netError.Exception.Message)"
                    Start-Sleep -Milliseconds ([int]($delay * 1000)); continue
                }
                Write-IMLog -Level Error -Category 'Graph' -Message "$Method $nextUrl failed (network)" -ErrorRecord $netError
                throw $netError
            }

            if (-not $NoLog) { Write-IMLog -Level Trace -Category 'Graph' -Message "$Method $nextUrl -> $($resp.StatusCode) ($($sw.ElapsedMilliseconds) ms)" }

            if ($resp.StatusCode -lt 300) { break }

            if ($resp.StatusCode -eq 401 -and -not $refreshed) {
                $refreshed = $true
                Write-IMLog -Level Debug -Category 'Graph' -Message 'Received 401, refreshing the access token'
                Get-IMAccessToken -ForceRefresh | Out-Null
                continue
            }
            if ($resp.StatusCode -eq 404 -and $IgnoreNotFound) { return $null }

            $retryable = if ($idempotent) { $resp.StatusCode -in 429, 500, 502, 503, 504 } else { $resp.StatusCode -in 429, 503 }
            if ($retryable -and $attempt -le $MaxRetries) {
                $delay = Get-IMRetryDelay -Attempt $attempt -Headers $resp.Headers
                $what = if ($resp.StatusCode -eq 429) { 'Throttled' } else { "Server error $($resp.StatusCode)" }
                Write-IMLog -Level Warning -Category 'Graph' -Message "$what on $Method $nextUrl, retry $attempt/$MaxRetries in $([math]::Round($delay,1))s (request-id $($resp.Headers['request-id']))"
                Start-Sleep -Milliseconds ([int]($delay * 1000)); continue
            }

            $ex = New-IMGraphException -Method $Method -Url $nextUrl -Response $resp -Attempts $attempt -ClientRequestId $clientRequestId
            if (-not $NoLog -and -not ($resp.StatusCode -eq 404 -and $IgnoreNotFound)) {
                Write-IMLog -Level Debug -Category 'Graph' -Message "$Method $nextUrl -> $($resp.StatusCode) $($ex.ErrorCode) request-id=$($ex.RequestId)" -Data @{ Body = $bodyText }
            }
            throw $ex
        }

        if ($Raw) { return $resp }
        if ([string]::IsNullOrWhiteSpace($resp.Content)) { return $null }
        $result = ConvertFrom-IMJson $resp.Content
        if (-not $All) { return $result }
        if (Test-IMProperty $result 'value') { foreach ($i in @($result.value)) { $items.Add($i) } }
        else { $items.Add($result) }
        $nextUrl = Get-IMPropertyValue $result '@odata.nextLink'
    } while ($nextUrl -and $page -lt 10000)

    , $items.ToArray()
}

function Get-IMGraphCollection {
    <# Convenience: all items of a collection as an array. #>
    param([Parameter(Mandatory, Position = 0)][string]$Uri, [string]$Version, [switch]$IgnoreNotFound, [hashtable]$Headers)
    # Items are written to the pipeline one by one (normal PowerShell behaviour); wrap in @() for a guaranteed array
    $r = Invoke-IMGraphRequest -Uri $Uri -All -Version $Version -IgnoreNotFound:$IgnoreNotFound -Headers $Headers
    if ($null -ne $r) { $r }
}

function Invoke-IMGraphBatch {
    <#
    .SYNOPSIS
    Sends requests through /$batch (20 per call). Throttled items are retried.
    .PARAMETER Requests  Objects with id, method, url (relative to version), optional body.
    .OUTPUTS Hashtable: id -> @{ Status; Body; Error }
    #>
    param([Parameter(Mandatory)][object[]]$Requests, [string]$Version, [int]$MaxRetries = -1)
    if ($MaxRetries -lt 0) { $MaxRetries = [int](Get-IMSetting 'MaxRetries') }
    $size = [math]::Min(20, [math]::Max(1, [int](Get-IMSetting 'BatchSize')))
    $results = @{}
    $pending = [System.Collections.Generic.List[object]]::new()
    foreach ($r in $Requests) { $pending.Add($r) }
    $round = 0
    while ($pending.Count -gt 0 -and $round -le $MaxRetries) {
        $round++
        $retry = [System.Collections.Generic.List[object]]::new()
        $maxDelay = 0
        for ($i = 0; $i -lt $pending.Count; $i += $size) {
            $chunk = $pending.GetRange($i, [math]::Min($size, $pending.Count - $i))
            $payload = @{ requests = @($chunk | ForEach-Object {
                $req = [ordered]@{ id = [string]$_.id; method = ($_.method ?? 'GET'); url = ('/' + ([string]$_.url).TrimStart('/')) }
                if ($null -ne $_.body) { $req.body = $_.body; $req.headers = @{ 'Content-Type' = 'application/json' } }
                $req
            }) }
            $resp = Invoke-IMGraphRequest -Uri '/$batch' -Method POST -Body $payload -Version $Version
            foreach ($item in @($resp.responses)) {
                $status = [int]$item.status
                if ($status -in 429, 503, 504 -and $round -le $MaxRetries) {
                    $src = $chunk | Where-Object { [string]$_.id -eq [string]$item.id } | Select-Object -First 1
                    if ($src -and ($src.method ?? 'GET') -eq 'GET') {
                        $retry.Add($src)
                        $ra = 0; [int]::TryParse([string]$item.headers.'Retry-After', [ref]$ra) | Out-Null
                        $maxDelay = [math]::Max($maxDelay, [math]::Max($ra, (Get-IMRetryDelay -Attempt $round)))
                        continue
                    }
                }
                $results[[string]$item.id] = [pscustomobject]@{
                    Status = $status; Body = $item.body
                    Error  = if ($status -ge 400) { "$status $($item.body.error.code): $($item.body.error.message)" } else { $null }
                }
            }
        }
        $pending = $retry
        if ($pending.Count -gt 0) {
            Write-IMLog -Level Warning -Category 'Graph' -Message "Batch: $($pending.Count) request(s) throttled, retrying in $([math]::Round($maxDelay,1))s"
            Start-Sleep -Milliseconds ([int]($maxDelay * 1000))
        }
    }
    foreach ($p in $pending) { $results[[string]$p.id] = [pscustomobject]@{ Status = 429; Body = $null; Error = 'Throttled; retries exhausted' } }
    $results
}

#region Small cache for lookups (groups, filters, templates)
function Get-IMCached {
    param([string]$Key, [scriptblock]$Factory)
    if ($script:IMCache.ContainsKey($Key)) { return $script:IMCache[$Key] }
    $v = & $Factory
    $script:IMCache[$Key] = $v
    $v
}
function Clear-IMCache { $script:IMCache.Clear() }
#endregion
