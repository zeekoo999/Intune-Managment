#region Native helpers
if (-not ('IntuneManager.JsonHelper' -as [type])) {
    $nativeSource = [IO.File]::ReadAllText((Join-Path $script:IMModuleRoot 'Core/Native.cs'))
    Add-Type -TypeDefinition $nativeSource -Language CSharp -ReferencedAssemblies @('System.Text.Json', 'System.Management.Automation', 'System.Collections', 'System.Runtime', 'System.Memory', 'System.ObjectModel', 'System.ComponentModel.Primitives') -ErrorAction Stop
}
#endregion

$script:IMIsWindows = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)

function Get-IMAppDataPath {
    <# Returns the per-user folder that holds settings, profiles and logs. #>
    [CmdletBinding()]
    param([string]$ChildPath)

    $base = if ($env:IM_APPDATA) { $env:IM_APPDATA }
            elseif ($script:IMIsWindows) { [Environment]::GetFolderPath('ApplicationData') }
            else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.config' }
    $path = Join-Path $base 'IntuneManager'
    if ($ChildPath) { $path = Join-Path $path $ChildPath }
    if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
    $path
}

function ConvertFrom-IMJson {
    <# Parses JSON into PSCustomObjects without turning date strings into DateTime. #>
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)][AllowEmptyString()][string]$Json)
    # Leading comma keeps top-level arrays intact through the pipeline
    process { , [IntuneManager.JsonHelper]::Parse($Json) }
}

function ConvertTo-IMJson {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)][AllowNull()]$InputObject, [switch]$Compress)
    process {
        if ($null -eq $InputObject) { return 'null' }
        ConvertTo-Json -InputObject $InputObject -Depth 100 -Compress:$Compress
    }
}

function Read-IMJsonFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw [System.IO.FileNotFoundException]::new("JSON file not found: $Path", $Path)
    }
    $text = [IO.File]::ReadAllText($Path)
    try { ConvertFrom-IMJson $text }
    catch { throw [System.FormatException]::new("Invalid JSON in '$Path': $($_.Exception.InnerException.Message ?? $_.Exception.Message)") }
}

function Write-IMJsonFile {
    <# Writes JSON atomically (temp file + move) so a crash never leaves a half-written export. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowNull()]$InputObject, [switch]$Raw)

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $content = if ($Raw) { [string]$InputObject } else { ConvertTo-IMJson $InputObject }
    $tmp = "$Path.$([guid]::NewGuid().ToString('N').Substring(0,8)).tmp"
    [IO.File]::WriteAllText($tmp, $content, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Copy-IMObject {
    <# Deep clone of a JSON-shaped object. #>
    param([AllowNull()]$InputObject)
    if ($null -eq $InputObject) { return $null }
    ConvertFrom-IMJson (ConvertTo-IMJson $InputObject -Compress)
}

function Test-IMProperty {
    param($InputObject, [string]$Name)
    $null -ne $InputObject -and $InputObject -is [psobject] -and $null -ne $InputObject.PSObject.Properties[$Name]
}

function Get-IMPropertyValue {
    param($InputObject, [string]$Name)
    if (Test-IMProperty $InputObject $Name) { $InputObject.PSObject.Properties[$Name].Value }
}

function Remove-IMProperty {
    param($InputObject, [string[]]$Name)
    if ($null -eq $InputObject -or $InputObject -isnot [psobject]) { return }
    foreach ($n in $Name) {
        $p = $InputObject.PSObject.Properties[$n]
        if ($p) { $InputObject.PSObject.Properties.Remove($p.Name) }
    }
}

function Set-IMProperty {
    param($InputObject, [string]$Name, $Value)
    if (Test-IMProperty $InputObject $Name) { $InputObject.PSObject.Properties[$Name].Value = $Value }
    else { $InputObject | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force }
}

function Get-IMSafeFileName {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Name, [int]$MaxLength = 120)
    $invalid = [IO.Path]::GetInvalidFileNameChars() + [char[]]'<>:"/\|?*'
    $sb = [Text.StringBuilder]::new()
    foreach ($c in $Name.ToCharArray()) { [void]$sb.Append($(if ($invalid -contains $c -or [char]::IsControl($c)) { '_' } else { $c })) }
    $result = $sb.ToString().Trim().TrimEnd('.')
    if ([string]::IsNullOrWhiteSpace($result)) { $result = 'Unnamed' }
    if ($result.Length -gt $MaxLength) { $result = $result.Substring(0, $MaxLength).TrimEnd() }
    # Reserved device names on Windows
    if ($result -match '^(CON|PRN|AUX|NUL|COM\d|LPT\d)$') { $result = "_$result" }
    $result
}

function Test-IMGuid {
    param([string]$Value)
    $g = [guid]::Empty
    [guid]::TryParse($Value, [ref]$g)
}

function Get-IMODataTypeName {
    <# '#microsoft.graph.windows10GeneralConfiguration' -> 'windows10GeneralConfiguration' #>
    param($InputObject)
    $t = Get-IMPropertyValue $InputObject '@odata.type'
    if ($t) { ($t -split '\.')[-1] }
}

function ConvertTo-IMODataString {
    <# Escapes a value for use inside an OData string literal. #>
    param([string]$Value)
    $Value.Replace("'", "''")
}

function Format-IMDuration {
    param([TimeSpan]$TimeSpan)
    if ($TimeSpan.TotalHours -ge 1) { return '{0:%h}h {0:%m}m {0:%s}s' -f $TimeSpan }
    if ($TimeSpan.TotalMinutes -ge 1) { return '{0:%m}m {0:%s}s' -f $TimeSpan }
    '{0:N1}s' -f $TimeSpan.TotalSeconds
}

function Get-IMFileHash {
    param([string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
