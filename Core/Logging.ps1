<#
  Logging
  - Text log (human readable) and JSONL log (structured, one JSON entry per line)
  - Daily files, size-based rollover, retention clean-up
  - Thread-safe: the same state object is shared with background runspaces
  - In-memory queue consumed by the UI log console
#>

$script:IMLevels = [ordered]@{ Trace = 0; Debug = 1; Info = 2; Success = 2; Warning = 3; Error = 4; Critical = 5 }

if (-not $script:IMLogState) {
    $script:IMLogState = [hashtable]::Synchronized(@{
        Directory      = $null
        MinimumLevel   = 'Info'
        MaxFileSizeMB  = 20
        RetentionDays  = 30
        SessionId      = [guid]::NewGuid().ToString('N').Substring(0, 8)
        Lock           = [object]::new()
        Queue          = [System.Collections.Concurrent.ConcurrentQueue[object]]::new()
        QueueLimit     = 20000
        Console        = $true
        Counters       = [hashtable]::Synchronized(@{ Warning = 0; Error = 0 })
        Initialized    = $false
    })
}

function Initialize-IMLogging {
    [CmdletBinding()]
    param(
        [string]$Directory = (Get-IMAppDataPath 'Logs'),
        [ValidateSet('Trace', 'Debug', 'Info', 'Warning', 'Error')][string]$MinimumLevel = 'Info',
        [int]$RetentionDays = 30,
        [int]$MaxFileSizeMB = 20,
        [switch]$NoConsole
    )
    if (-not (Test-Path -LiteralPath $Directory)) { New-Item -ItemType Directory -Path $Directory -Force | Out-Null }
    $script:IMLogState.Directory = (Resolve-Path -LiteralPath $Directory).Path
    $script:IMLogState.MinimumLevel = $MinimumLevel
    $script:IMLogState.RetentionDays = $RetentionDays
    $script:IMLogState.MaxFileSizeMB = $MaxFileSizeMB
    $script:IMLogState.Console = -not $NoConsole
    $script:IMLogState.Initialized = $true

    # Retention clean-up
    try {
        $cutoff = (Get-Date).AddDays(-$RetentionDays)
        Get-ChildItem -LiteralPath $script:IMLogState.Directory -File -Include '*.log', '*.jsonl' -Recurse -ErrorAction SilentlyContinue |
            Where-Object LastWriteTime -lt $cutoff | Remove-Item -Force -ErrorAction SilentlyContinue
    } catch { }

    Write-IMLog -Level Info -Category 'Session' -Message "Logging started (session $($script:IMLogState.SessionId), PowerShell $($PSVersionTable.PSVersion), $([Environment]::OSVersion.VersionString))"
}

function Get-IMLogState { $script:IMLogState }

function Set-IMLogState {
    <# Used by background runspaces so they log to the same files and UI queue. #>
    param([Parameter(Mandatory)][hashtable]$State)
    $script:IMLogState = $State
}

function Get-IMLogFilePath {
    param([ValidateSet('log', 'jsonl')][string]$Kind = 'log')
    if (-not $script:IMLogState.Directory) { return $null }
    $base = Join-Path $script:IMLogState.Directory ("IntuneManager_{0:yyyyMMdd}" -f (Get-Date))
    $path = "$base.$Kind"
    $i = 1
    while ((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path).Length -ge $script:IMLogState.MaxFileSizeMB * 1MB)) {
        $path = "${base}_$i.$Kind"; $i++
    }
    $path
}

function Get-IMExceptionInfo {
    param([Parameter(Mandatory)]$ErrorObject)
    $ex = if ($ErrorObject -is [System.Management.Automation.ErrorRecord]) { $ErrorObject.Exception } else { $ErrorObject }
    # Unwrap PowerShell wrapper exceptions to the meaningful one
    while ($ex -is [System.Management.Automation.MethodInvocationException] -and $ex.InnerException) { $ex = $ex.InnerException }

    $info = [ordered]@{ Type = $ex.GetType().FullName; Message = $ex.Message }
    if ($ex -is [IntuneManager.GraphException]) {
        $info.StatusCode = $ex.StatusCode
        $info.ErrorCode = $ex.ErrorCode
        $info.RequestId = $ex.RequestId
        $info.ClientRequestId = $ex.ClientRequestId
        $info.Method = $ex.Method
        $info.Url = $ex.Url
        $info.Attempts = $ex.Attempts
    }
    if ($ErrorObject -is [System.Management.Automation.ErrorRecord] -and $ErrorObject.InvocationInfo) {
        $info.Position = $ErrorObject.InvocationInfo.PositionMessage -replace '\s+', ' '
        $info.ScriptStack = $ErrorObject.ScriptStackTrace
    }
    if ($ex.InnerException) { $info.Inner = $ex.InnerException.Message }
    $info
}

function Write-IMLog {
    [CmdletBinding()]
    param(
        [ValidateSet('Trace', 'Debug', 'Info', 'Success', 'Warning', 'Error', 'Critical')][string]$Level = 'Info',
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Message,
        [string]$Category = 'General',
        [hashtable]$Data,
        $ErrorRecord,
        [string]$OperationId
    )

    $state = $script:IMLogState
    if ($script:IMLevels[$Level] -lt $script:IMLevels[$state.MinimumLevel]) { return }

    if ($Level -in 'Warning') { $state.Counters.Warning++ }
    if ($Level -in 'Error', 'Critical') { $state.Counters.Error++ }

    $now = [DateTimeOffset]::Now
    $entry = [ordered]@{
        Time        = $now.ToString('o')
        Level       = $Level
        Category    = $Category
        Message     = $Message
        Session     = $state.SessionId
        OperationId = $OperationId ?? $script:IMCurrentOperationId
        Thread      = [Threading.Thread]::CurrentThread.ManagedThreadId
    }
    if ($Data) { $entry.Data = $Data }
    if ($ErrorRecord) { $entry.Error = Get-IMExceptionInfo $ErrorRecord }

    # Text line
    $text = '{0:yyyy-MM-dd HH:mm:ss.fff} [{1,-8}] [{2}] {3}' -f $now, $Level.ToUpper(), $Category, $Message
    if ($entry.Error) {
        $e = $entry.Error
        $text += " | $($e.Type): $($e.Message)"
        if ($e.RequestId) { $text += " | request-id=$($e.RequestId) client-request-id=$($e.ClientRequestId)" }
        if ($Level -in 'Error', 'Critical' -and $e.ScriptStack) { $text += "`n    " + ($e.ScriptStack -replace "`n", "`n    ") }
    }

    if ($state.Directory) {
        [Threading.Monitor]::Enter($state.Lock)
        try {
            [IO.File]::AppendAllText((Get-IMLogFilePath 'log'), $text + [Environment]::NewLine, [Text.Encoding]::UTF8)
            [IO.File]::AppendAllText((Get-IMLogFilePath 'jsonl'), (ConvertTo-Json -InputObject $entry -Depth 6 -Compress) + [Environment]::NewLine, [Text.Encoding]::UTF8)
        }
        catch { }
        finally { [Threading.Monitor]::Exit($state.Lock) }
    }

    # UI queue (bounded)
    $state.Queue.Enqueue([pscustomobject]@{
        Time = $now.LocalDateTime; Level = $Level; Category = $Category; Message = $Message
        Detail = if ($entry.Error) { "$($entry.Error.Type): $($entry.Error.Message)$(if ($entry.Error.RequestId) { "`nrequest-id: $($entry.Error.RequestId)`nclient-request-id: $($entry.Error.ClientRequestId)" })" }
        OperationId = $entry.OperationId
    })
    $discard = $null
    while ($state.Queue.Count -gt $state.QueueLimit) { [void]$state.Queue.TryDequeue([ref]$discard) }

    if ($state.Console) {
        switch ($Level) {
            'Error' { Write-Host $text -ForegroundColor Red }
            'Critical' { Write-Host $text -ForegroundColor Red }
            'Warning' { Write-Host $text -ForegroundColor Yellow }
            'Success' { Write-Host $text -ForegroundColor Green }
            'Debug' { Write-Verbose $text }
            'Trace' { Write-Verbose $text }
            default { Write-Host $text }
        }
    }
}

function Read-IMLogQueue {
    <# Drains up to -Max pending entries for the UI. #>
    param([int]$Max = 500)
    $items = [System.Collections.Generic.List[object]]::new()
    $item = $null
    while ($items.Count -lt $Max -and $script:IMLogState.Queue.TryDequeue([ref]$item)) { $items.Add($item) }
    , $items.ToArray()
}

#region Operations: a unit of work (export, import, ...) with a result list and a report
class IMOperationResult {
    [string]$ObjectType
    [string]$Name
    [string]$Action        # Exported, Created, Updated, Replaced, Skipped, Failed, WouldCreate, ...
    [string]$Status        # Success, Warning, Failed, Skipped
    [string]$SourceId
    [string]$TargetId
    [string]$File
    [string]$Message
    [string]$RequestId
    [double]$Seconds
    [datetime]$Time
}

function Start-IMOperation {
    param([Parameter(Mandatory)][string]$Name, [hashtable]$Parameters, $Progress)
    $op = [pscustomobject]@{
        Id         = [guid]::NewGuid().ToString('N').Substring(0, 12)
        Name       = $Name
        Started    = Get-Date
        Ended      = $null
        Parameters = $Parameters
        Results    = [System.Collections.Generic.List[IMOperationResult]]::new()
        Progress   = $Progress
        Cancelled  = $false
        ReportPath = $null
    }
    $script:IMCurrentOperationId = $op.Id
    Write-IMLog -Category $Name -Message "Operation started ($($op.Id))" -Data $Parameters
    $op
}

function Add-IMOperationResult {
    param(
        [Parameter(Mandatory)]$Operation,
        [string]$ObjectType, [string]$Name, [string]$Action,
        [ValidateSet('Success', 'Warning', 'Failed', 'Skipped')][string]$Status = 'Success',
        [string]$SourceId, [string]$TargetId, [string]$File, [string]$Message, $ErrorRecord,
        [double]$Seconds
    )
    $r = [IMOperationResult]::new()
    $r.ObjectType = $ObjectType; $r.Name = $Name; $r.Action = $Action; $r.Status = $Status
    $r.SourceId = $SourceId; $r.TargetId = $TargetId; $r.File = $File; $r.Message = $Message
    $r.Seconds = [math]::Round($Seconds, 2); $r.Time = Get-Date
    if ($ErrorRecord) {
        $info = Get-IMExceptionInfo $ErrorRecord
        if (-not $r.Message) { $r.Message = $info.Message }
        $r.RequestId = $info.RequestId
    }
    [Threading.Monitor]::Enter($Operation.Results)
    try { $Operation.Results.Add($r) } finally { [Threading.Monitor]::Exit($Operation.Results) }

    $level = switch ($Status) { 'Failed' { 'Error' } 'Warning' { 'Warning' } 'Skipped' { 'Info' } default { 'Success' } }
    $msg = "$Action $ObjectType '$Name'"
    if ($Message) { $msg += " - $Message" }
    Write-IMLog -Level $level -Category $Operation.Name -Message $msg -ErrorRecord $ErrorRecord -OperationId $Operation.Id
    $r
}

function Complete-IMOperation {
    <# Writes the JSON + CSV report and logs a summary. Returns the summary object. #>
    param([Parameter(Mandatory)]$Operation, [string]$ReportDirectory)

    $Operation.Ended = Get-Date
    $results = $Operation.Results.ToArray()
    $summary = [ordered]@{
        Operation = $Operation.Name
        Id        = $Operation.Id
        Started   = $Operation.Started.ToString('o')
        Ended     = $Operation.Ended.ToString('o')
        Duration  = Format-IMDuration ($Operation.Ended - $Operation.Started)
        Cancelled = $Operation.Cancelled
        Total     = $results.Count
        Succeeded = @($results | Where-Object Status -eq 'Success').Count
        Warnings  = @($results | Where-Object Status -eq 'Warning').Count
        Skipped   = @($results | Where-Object Status -eq 'Skipped').Count
        Failed    = @($results | Where-Object Status -eq 'Failed').Count
    }

    if (-not $ReportDirectory) { $ReportDirectory = Join-Path ($script:IMLogState.Directory ?? (Get-IMAppDataPath 'Logs')) 'Reports' }
    try {
        if (-not (Test-Path -LiteralPath $ReportDirectory)) { New-Item -ItemType Directory -Path $ReportDirectory -Force | Out-Null }
        $baseName = '{0}_{1:yyyyMMdd_HHmmss}_{2}' -f $Operation.Name, $Operation.Started, $Operation.Id
        $jsonPath = Join-Path $ReportDirectory "$baseName.json"
        $report = [ordered]@{ Summary = $summary; Parameters = $Operation.Parameters; Results = $results }
        Write-IMJsonFile -Path $jsonPath -InputObject $report
        $results | Export-Csv -LiteralPath (Join-Path $ReportDirectory "$baseName.csv") -NoTypeInformation -Encoding utf8
        $Operation.ReportPath = $jsonPath
        $summary.Report = $jsonPath
    }
    catch { Write-IMLog -Level Warning -Category $Operation.Name -Message 'Could not write the operation report' -ErrorRecord $_ }

    $level = if ($summary.Failed -gt 0) { 'Warning' } else { 'Success' }
    Write-IMLog -Level $level -Category $Operation.Name -OperationId $Operation.Id -Message ("Operation finished in {0}: {1} succeeded, {2} warnings, {3} skipped, {4} failed{5}" -f `
        $summary.Duration, $summary.Succeeded, $summary.Warnings, $summary.Skipped, $summary.Failed, $(if ($Operation.Cancelled) { ' (cancelled)' }))
    $script:IMCurrentOperationId = $null
    [pscustomobject]$summary
}

function Update-IMProgress {
    <# Reports progress to the UI (shared hashtable) or to Write-Progress in console mode. #>
    param($Operation, [string]$Status, [int]$Current, [int]$Total, [string]$Item)
    $pct = if ($Total -gt 0) { [math]::Min(100, [int](($Current / $Total) * 100)) } else { -1 }
    $p = $Operation.Progress
    if ($p -is [hashtable]) {
        $p.Status = $Status; $p.Current = $Current; $p.Total = $Total; $p.Percent = $pct; $p.Item = $Item
        if ($p.CancelRequested) { $Operation.Cancelled = $true }
    }
    elseif ($script:IMLogState.Console) {
        Write-Progress -Activity $Operation.Name -Status "$Status $Item" -PercentComplete ([math]::Max(0, $pct))
    }
}

function Test-IMCancelled {
    param($Operation)
    if ($Operation.Progress -is [hashtable] -and $Operation.Progress.CancelRequested) { $Operation.Cancelled = $true }
    $Operation.Cancelled
}
#endregion
