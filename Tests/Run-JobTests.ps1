<#
  Tests the UI's background job infrastructure (runspace pool, bootstrap, cross-runspace import plan) without WPF.
  Run:  pwsh -File Tests/Run-JobTests.ps1
#>
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$work = Join-Path ([IO.Path]::GetTempPath()) ("imjob_" + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Path $work | Out-Null
$env:IM_APPDATA = $work
Import-Module (Join-Path $root 'IntuneManager.psd1') -Force

$result = & (Get-Module IntuneManager) {
    param($Root, $Work)
    $pass = 0; $fail = 0; $failures = @()
    $assert = { param($c, $n) if ($c) { $script:__p++; Write-Host "  ok   $n" -ForegroundColor Green } else { $script:__f++; $script:__fl += $n; Write-Host "  FAIL $n" -ForegroundColor Red } }
    $script:__p = 0; $script:__f = 0; $script:__fl = @()
    Initialize-IMLogging -Directory (Join-Path $Work 'logs') -MinimumLevel Debug -NoConsole
    $script:UI = @{ C = @{}; Jobs = $null; Pool = $null; ForegroundJob = $null }
    Initialize-IMJobPool

    function Wait-Jobs {
        $deadline = (Get-Date).AddMinutes(5)
        while ($script:UI.Jobs.Count -and (Get-Date) -lt $deadline) {
            foreach ($j in @($script:UI.Jobs)) { if ($j.Handle.IsCompleted) { [void]$script:UI.Jobs.Remove($j); Complete-IMJob $j } }
            Start-Sleep -Milliseconds 100
        }
    }
    $mock = Join-Path $Root 'Tests/MockGraph.ps1'
    $seed = @'
param($A, $Progress)
. $A.Mock
Set-IMTransport $script:MockTransport
$SRC = '11111111-1111-1111-1111-111111111111'; $TGT = '22222222-2222-2222-2222-222222222222'; $CLIENT = 'aaaaaaaa-0000-0000-0000-000000000001'
New-MockTenant -TenantId $SRC -Name 'Contoso' -ClientId $CLIENT -Secret 's3cret'
New-MockTenant -TenantId $TGT -Name 'Fabrikam' -ClientId $CLIENT -Secret 's3cret'
$g = Add-MockObject $SRC 'groups' @{ displayName = 'Pilot'; mailEnabled = $false; mailNickname = 'p'; securityEnabled = $true }
Add-MockObject $SRC 'deviceManagement/configurationPolicies' @{ name = 'Baseline'; platforms = 'windows10'; technologies = 'mdm'; settings = @(); assignments = @(@{ target = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = $g.id } }) } | Out-Null
Add-MockObject $SRC 'deviceManagement/deviceConfigurations' @{ '@odata.type' = '#microsoft.graph.windows10GeneralConfiguration'; displayName = 'General'; privacyAccessControls = @(@{ accessLevel = 'forceDeny'; dataCategory = 'camera' }); assignments = @() } | Out-Null
'@

    Write-Host "`n== Background jobs" -ForegroundColor Cyan
    $state = @{}
    # 1. Export inside a pooled runspace (connect there, like the UI does)
    Start-IMJob -Name 'export' -Arguments @{ Mock = $mock; Out = (Join-Path $Work 'exp') } -Context @{ S = $state } -Script ([scriptblock]::Create($seed + "`n" + @'
Connect-IMTenant -TenantId $SRC -ClientId $CLIENT -ClientSecret (ConvertTo-SecureString 's3cret' -AsPlainText -Force) | Out-Null
$Progress.Status = 'running'
Export-IMObjects -Path $A.Out -NoDateFolder -Progress $Progress
'@)) -OnComplete { param($r, $err, $job) $job.Context.S.Export = $r; $job.Context.S.ExportErr = $err } | Out-Null
    Wait-Jobs
    & $assert (-not $state.ExportErr -and $state.Export.Succeeded -ge 2) "export ran in a pooled runspace ($($state.Export.Succeeded) objects) $($state.ExportErr)"
    & $assert ((Get-IMLogState).Counters -and (Get-Content (Get-IMLogFilePath 'log') -Raw) -match 'Operation started') 'job wrote to the shared log files'
    $queued = Read-IMLogQueue -Max 5000
    & $assert ($queued.Count -gt 5) "job log entries reached the UI queue ($($queued.Count))"

    # 2. Plan built in THIS runspace, executed in a pooled runspace (hooks must be rebound)
    $plan = Get-IMImportPlan -Path $state.Export.ExportPath
    & $assert ($plan.Items.Count -ge 2) 'import plan built on the UI runspace'
    Start-IMJob -Name 'import' -Arguments @{ Mock = $mock; Plan = $plan } -Context @{ S = $state } -Script ([scriptblock]::Create($seed + "`n" + @'
Connect-IMTenant -TenantId $TGT -ClientId $CLIENT -ClientSecret (ConvertTo-SecureString 's3cret' -AsPlainText -Force) | Out-Null
$s = Import-IMObjects -Path $A.Plan.Root -Plan $A.Plan -Progress $Progress
$pol = Get-MockObjects $TGT 'deviceManagement/configurationPolicies' | Where-Object name -eq 'Baseline'
$grp = Get-MockObjects $TGT 'groups' | Where-Object displayName -eq 'Pilot'
$cfg = Get-MockObjects $TGT 'deviceManagement/deviceConfigurations' | Where-Object displayName -eq 'General'
[pscustomobject]@{ Summary = $s; Assigned = ($pol.assignments[0].target.groupId -eq $grp.id); PostHook = [bool]($cfg.__actions | Where-Object Action -eq 'windowsPrivacyAccessControls') }
'@)) -OnComplete { param($r, $err, $job) $job.Context.S.Import = $r; $job.Context.S.ImportErr = $err } | Out-Null
    Wait-Jobs
    & $assert (-not $state.ImportErr) "import job completed without error $($state.ImportErr)"
    & $assert ($state.Import.Summary.Failed -eq 0 -and $state.Import.Summary.Succeeded -ge 2) 'cross-runspace import succeeded'
    & $assert ($state.Import.Assigned) 'assignment remapped to the group created in the target'
    & $assert ($state.Import.PostHook) 'type hooks ran in the job runspace (privacy controls applied)'

    # 3. Errors in a job are reported to OnComplete, not thrown at the UI
    Start-IMJob -Name 'fails' -Context @{ S = $state } -Script { param($A, $Progress) throw 'Boom from job' } -OnComplete { param($r, $err, $job) $job.Context.S.FailErr = $err } | Out-Null
    Wait-Jobs
    & $assert ($state.FailErr -eq 'Boom from job') 'job exceptions are delivered as error text'

    # 4. Cancellation flag stops a running operation
    Start-IMJob -Name 'cancel' -Context @{ S = $state } -Script ([scriptblock]::Create(@'
param($A, $Progress)
$op = Start-IMOperation -Name 'CancelTest' -Progress $Progress
$n = 0
while (-not (Test-IMCancelled $op) -and $n -lt 200) { Start-Sleep -Milliseconds 50; $n++ }
$op.Cancelled
'@)) -OnComplete { param($r, $err, $job) $job.Context.S.Cancelled = $r } | Out-Null
    Start-Sleep -Milliseconds 400
    $script:UI.Jobs[0].Progress.CancelRequested = $true
    Wait-Jobs
    & $assert ($state.Cancelled -eq $true) 'cancel request reaches the running job'

    $script:UI.Pool.Close()
    [pscustomobject]@{ Pass = $script:__p; Fail = $script:__f; Failures = $script:__fl }
} $root $work

Write-Host "`n$($result.Pass) passed, $($result.Fail) failed" -ForegroundColor $(if ($result.Fail) { 'Red' } else { 'Green' })
$result.Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
exit $result.Fail
