<#
  IntuneManager WPF application.
  - All Graph work runs in a background runspace pool (Start-IMJob); the UI thread only updates controls.
  - A DispatcherTimer drains the shared log queue, updates progress and completes jobs.
  - Every event handler runs through Invoke-IMSafe so errors are shown and logged instead of crashing the app.
#>

$script:UI = $null

#region Infrastructure
function Import-IMXaml {
    param([Parameter(Mandatory)][string]$Path)
    $text = [IO.File]::ReadAllText($Path)
    $root = [Windows.Markup.XamlReader]::Parse($text)
    $controls = @{}
    foreach ($m in [regex]::Matches($text, 'x:Name="([^"]+)"')) {
        $n = $m.Groups[1].Value
        $o = $root.FindName($n)
        if ($o) { $controls[$n] = $o }
    }
    [pscustomobject]@{ Root = $root; C = $controls }
}

function Invoke-IMSafe {
    param([Parameter(Mandatory)][scriptblock]$Action)
    try { & $Action }
    catch {
        Write-IMLog -Level Error -Category 'UI' -Message "Unexpected error: $($_.Exception.Message)" -ErrorRecord $_
        Show-IMToast -Title 'Something went wrong' -Text $_.Exception.Message -Kind Error
    }
}

function Set-IMTheme {
    param([ValidateSet('Dark', 'Light')][string]$Theme)
    $palettes = @{
        Dark  = @{ Bg = '#17171C'; Surface = '#1F1F26'; SurfaceAlt = '#26262F'; Hover = '#2D2D37'; Line = '#33333D'; Text = '#ECECF1'; Muted = '#9C9CAA'
                   Accent = '#7C74FF'; AccentHover = '#8F88FF'; AccentText = '#FFFFFF'; AccentSoft = '#2E2B55'; Success = '#3FB27F'; Warning = '#E3A82B'; Danger = '#F0616D'; Info = '#5AA9F7'; Backdrop = '#99000000' }
        Light = @{ Bg = '#F5F5F8'; Surface = '#FFFFFF'; SurfaceAlt = '#F0F0F4'; Hover = '#E9E9EF'; Line = '#E0E0E7'; Text = '#1B1B21'; Muted = '#6A6A78'
                   Accent = '#4F46E5'; AccentHover = '#4338CA'; AccentText = '#FFFFFF'; AccentSoft = '#E6E4FF'; Success = '#16A34A'; Warning = '#B7791F'; Danger = '#DC2626'; Info = '#2563EB'; Backdrop = '#66000000' }
    }
    $res = [System.Windows.Application]::Current.Resources
    foreach ($kv in $palettes[$Theme].GetEnumerator()) {
        $brush = [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString($kv.Value))
        $brush.Freeze()
        $res[$kv.Key] = $brush
    }
    $script:UI.Theme = $Theme
    if ($script:UI.C.ThemeButton) { $script:UI.C.ThemeButton.Content = if ($Theme -eq 'Dark') { [string][char]0xE706 } else { [string][char]0xE708 } }
}

function Show-IMToast {
    param([string]$Title, [string]$Text, [ValidateSet('Success', 'Info', 'Warning', 'Error')][string]$Kind = 'Success', [string]$ActionText, [scriptblock]$Action, [int]$Seconds = 6)
    $c = $script:UI.C
    if (-not $c) { return }
    $c.ToastTitle.Text = $Title
    $c.ToastText.Text = $Text
    $c.ToastText.Visibility = if ($Text) { 'Visible' } else { 'Collapsed' }
    $glyph = @{ Success = 0xE73E; Info = 0xE946; Warning = 0xE7BA; Error = 0xEA39 }[$Kind]
    $c.ToastIcon.Text = [string][char]$glyph
    $c.ToastIcon.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, @{ Success = 'Success'; Info = 'Info'; Warning = 'Warning'; Error = 'Danger' }[$Kind])
    if ($ActionText -and $Action) { $c.ToastAction.Content = $ActionText; $c.ToastAction.Visibility = 'Visible'; $script:UI.ToastAction = $Action }
    else { $c.ToastAction.Visibility = 'Collapsed'; $script:UI.ToastAction = $null }
    $c.Toast.Visibility = 'Visible'
    $script:UI.ToastUntil = (Get-Date).AddSeconds($(if ($Kind -eq 'Error') { [math]::Max($Seconds, 10) } else { $Seconds }))
}

function Set-IMStatus { param([string]$Text) if ($script:UI.C) { $script:UI.C.StatusText.Text = $Text } }

function Select-IMFolder {
    param([string]$Description = 'Select a folder', [string]$Initial)
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    $d = [System.Windows.Forms.FolderBrowserDialog]::new()
    $d.Description = $Description
    $d.UseDescriptionForTitle = $true
    if ($Initial -and (Test-Path -LiteralPath $Initial)) { $d.SelectedPath = $Initial }
    if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $d.SelectedPath } else { $null }
}

function Open-IMPath {
    param([string]$Path, [switch]$Select)
    if (-not $Path) { return }
    if ($Select -and (Test-Path -LiteralPath $Path -PathType Leaf)) { Start-Process explorer.exe "/select,`"$Path`"" }
    else { Start-Process $Path }
}
#endregion

#region Background jobs
function Initialize-IMJobPool {
    $iss = [Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $iss.ImportPSModule((Join-Path $script:IMModuleRoot 'IntuneManager.psd1'))
    if ($script:IMIsWindows) { try { $iss.ExecutionPolicy = [Microsoft.PowerShell.ExecutionPolicy]::Bypass } catch { } }
    $pool = [runspacefactory]::CreateRunspacePool(1, 4, $iss, $Host)
    $pool.Open()
    $script:UI.Pool = $pool
    $script:UI.Jobs = [Collections.Generic.List[object]]::new()
}

$script:IMJobBootstrap = {
    param($LogState, $Connection, $Settings, $Progress, $UserScript, $A)
    $global:ErrorActionPreference = 'Stop'   # any error ends the job and is reported to the UI
    $m = Get-Module IntuneManager
    & $m {
        param($l, $c, $s)
        Set-IMLogState $l; Set-IMConnectionState $c; Set-IMSettingsSnapshot $s
        # Pooled runspaces are reused: never let cached lookups from one tenant leak into another
        if ($script:IMLastTenant -ne $c.TenantId) { Clear-IMCache; $script:IMLastTenant = $c.TenantId }
    } $LogState $Connection $Settings
    $sb = [scriptblock]::Create($UserScript)
    & $m $sb $A $Progress
}

function Start-IMJob {
    <#
      Runs -Script (a scriptblock, executed inside the module scope in a background runspace).
      The script receives ($A, $Progress). OnComplete receives ($Result, $ErrorText, $Job) on the UI thread.
      -Foreground shows the operation bar with progress and Cancel.
    #>
    param([string]$Name, [scriptblock]$Script, [hashtable]$Arguments = @{}, [scriptblock]$OnComplete, [hashtable]$Context = @{}, [switch]$Foreground)
    $progress = [hashtable]::Synchronized(@{ Status = $Name; Current = 0; Total = 0; Percent = -1; Item = ''; CancelRequested = $false; Lines = [Collections.Concurrent.ConcurrentQueue[string]]::new() })
    $ps = [powershell]::Create()
    $ps.RunspacePool = $script:UI.Pool
    [void]$ps.AddScript($script:IMJobBootstrap.ToString())
    [void]$ps.AddArgument((Get-IMLogState)).AddArgument((Get-IMConnectionState)).AddArgument((Get-IMSettings)).AddArgument($progress).AddArgument($Script.ToString()).AddArgument($Arguments)
    $job = [pscustomobject]@{ Name = $Name; PS = $ps; Handle = $ps.BeginInvoke(); Progress = $progress; OnComplete = $OnComplete; Context = $Context; Foreground = [bool]$Foreground; Started = Get-Date }
    $script:UI.Jobs.Add($job)
    if ($Foreground) {
        $script:UI.ForegroundJob = $job
        $c = $script:UI.C
        $c.OpBar.Visibility = 'Visible'; $c.OpStatus.Text = $Name; $c.OpItem.Text = ''; $c.OpCount.Text = ''
        $c.OpProgress.IsIndeterminate = $true; $c.OpCancel.IsEnabled = $true
        Update-IMCommandState
    }
    $job
}

function Complete-IMJob {
    param($Job)
    $result = $null; $err = $null
    try {
        $result = $Job.PS.EndInvoke($Job.Handle)
        if ((-not $result -or $result.Count -eq 0) -and $Job.PS.Streams.Error.Count) { $err = ($Job.PS.Streams.Error | Select-Object -Last 1).Exception.Message }
    }
    catch {
        $inner = $_.Exception; while ($inner.InnerException) { $inner = $inner.InnerException }
        $err = $inner.Message
    }
    finally { $Job.PS.Dispose() }
    if ($err) { Write-IMLog -Level Error -Category $Job.Name -Message $err }
    if ($Job.Foreground) {
        $script:UI.ForegroundJob = $null
        $script:UI.C.OpBar.Visibility = 'Collapsed'
        Update-IMCommandState
    }
    if ($Job.OnComplete) {
        $value = if ($null -ne $result -and $result.Count -eq 1) { $result[0] } elseif ($null -ne $result) { @($result) } else { $null }
        Invoke-IMSafe { & $Job.OnComplete $value $err $Job }
    }
}

$script:IMLogGlyphs = @{ Error = 0xEA39; Critical = 0xEA39; Warning = 0xE7BA; Success = 0xE73E; Debug = 0xEBE8; Info = 0xE946 }

function Invoke-IMTick {
    $ui = $script:UI
    # Logs
    $entries = Read-IMLogQueue -Max 400
    if ($entries.Count) {
        foreach ($e in $entries) {
            if ($e.Level -in 'Trace') { continue }
            $code = $script:IMLogGlyphs[[string]$e.Level]; if (-not $code) { $code = 0xE946 }
            $row = [IntuneManager.LogRow]@{ Time = $e.Time.ToString('HH:mm:ss'); Level = $e.Level; Category = $e.Category; Message = $e.Message; Detail = $e.Detail; Glyph = [string][char]$code }
            $ui.AllLogs.Add($row)
            if (Test-IMLogFilter $row) { $ui.LogRows.Add($row) }
        }
        while ($ui.AllLogs.Count -gt 5000) { $ui.AllLogs.RemoveAt(0) }
        while ($ui.LogRows.Count -gt 3000) { $ui.LogRows.RemoveAt(0) }
        if ($ui.LogRows.Count) { $ui.C.LogGrid.ScrollIntoView($ui.LogRows[$ui.LogRows.Count - 1]) }
        $cnt = (Get-IMLogState).Counters
        $ui.C.StatusWarnings.Text = if ($cnt.Warning) { "$($cnt.Warning) warning(s)" } else { '' }
        $ui.C.StatusErrors.Text = if ($cnt.Error) { "$($cnt.Error) error(s)" } else { '' }
    }
    # Jobs
    foreach ($job in @($ui.Jobs)) {
        if ($job.Handle.IsCompleted) { [void]$ui.Jobs.Remove($job); Complete-IMJob $job; continue }
        if ($job.Foreground) {
            $p = $job.Progress
            $ui.C.OpStatus.Text = $p.Status
            $ui.C.OpItem.Text = $p.Item
            if ($p.Percent -ge 0 -and $p.Total -gt 0) { $ui.C.OpProgress.IsIndeterminate = $false; $ui.C.OpProgress.Value = $p.Percent; $ui.C.OpCount.Text = "$($p.Current) / $($p.Total)" }
            else { $ui.C.OpProgress.IsIndeterminate = $true; $ui.C.OpCount.Text = Format-IMDuration ((Get-Date) - $job.Started) }
        }
        if ($job.Context.OnLines) { $line = $null; while ($job.Progress.Lines.TryDequeue([ref]$line)) { Invoke-IMSafe { & $job.Context.OnLines $line } } }
    }
    # Toast
    if ($ui.ToastUntil -and (Get-Date) -gt $ui.ToastUntil) { $ui.C.Toast.Visibility = 'Collapsed'; $ui.ToastUntil = $null }
}

function Test-IMLogFilter {
    param($Row)
    switch ($script:UI.LogFilter) {
        'Warning' { $Row.Level -in 'Warning', 'Error', 'Critical' }
        'Error' { $Row.Level -in 'Error', 'Critical' }
        default { $Row.Level -ne 'Debug' -or (Get-IMSetting 'LogLevel') -in 'Debug', 'Trace' }
    }
}

function Update-IMLogView {
    $ui = $script:UI
    $ui.LogRows.Clear()
    foreach ($r in $ui.AllLogs) { if (Test-IMLogFilter $r) { $ui.LogRows.Add($r) } }
}
#endregion

#region Overlay panels
function Get-IMPanel {
    param([string]$Name)
    if (-not $script:UI.Panels.ContainsKey($Name)) {
        $p = Import-IMXaml (Join-Path $script:IMModuleRoot "UI/Panels/$Name.xaml")
        $script:UI.Panels[$Name] = $p
        $init = "Initialize-IM$Name"
        if (Get-Command $init -ErrorAction SilentlyContinue) { & $init $p }
    }
    $script:UI.Panels[$Name]
}

function Show-IMPanel {
    param([string]$Name)
    $p = Get-IMPanel $Name
    $script:UI.C.OverlayContent.Content = $p.Root
    $script:UI.C.OverlayHost.Visibility = 'Visible'
    $script:UI.OpenPanel = $Name
    $p
}

function Hide-IMPanel {
    $script:UI.C.OverlayHost.Visibility = 'Collapsed'
    $script:UI.C.OverlayContent.Content = $null
    $script:UI.OpenPanel = $null
}

function Show-IMConfirm {
    <# Modal confirm inside the window. OnOk receives the input text. #>
    param([string]$Title, [string]$Text, [string]$OkText = 'OK', [switch]$Danger, [string]$InputLabel, [string]$InputDefault, [string]$RequireText, [scriptblock]$OnOk, [hashtable]$Context)
    $p = Get-IMPanel 'ConfirmPanel'
    $c = $p.C
    $c.ConfTitle.Text = $Title; $c.ConfText.Text = $Text; $c.ConfOk.Content = $OkText
    $c.ConfOk.Style = $script:UI.Window.FindResource($(if ($Danger) { 'DangerBtn' } else { 'AccentBtn' }))
    $c.ConfIcon.Visibility = if ($Danger) { 'Visible' } else { 'Collapsed' }
    if ($InputLabel) { $c.ConfInputPanel.Visibility = 'Visible'; $c.ConfInputLabel.Text = $InputLabel; $c.ConfInput.Text = $InputDefault }
    else { $c.ConfInputPanel.Visibility = 'Collapsed' }
    $script:UI.Confirm = @{ OnOk = $OnOk; RequireText = $RequireText; Context = $Context; Return = $script:UI.OpenPanel }
    $c.ConfOk.IsEnabled = -not $RequireText
    Show-IMPanel 'ConfirmPanel' | Out-Null
    if ($InputLabel) { $c.ConfInput.Focus() | Out-Null; $c.ConfInput.SelectAll() }
}

function Initialize-IMConfirmPanel {
    param($p)
    $c = $p.C
    $c.ConfInput.Add_TextChanged({ Invoke-IMSafe {
        $req = $script:UI.Confirm.RequireText
        if ($req) { $script:UI.Panels.ConfirmPanel.C.ConfOk.IsEnabled = $script:UI.Panels.ConfirmPanel.C.ConfInput.Text -ceq $req }
    } })
    $c.ConfCancel.Add_Click({ Hide-IMPanel })
    $c.ConfOk.Add_Click({ Invoke-IMSafe {
        $conf = $script:UI.Confirm
        $text = $script:UI.Panels.ConfirmPanel.C.ConfInput.Text
        Hide-IMPanel
        if ($conf.OnOk) { & $conf.OnOk $text $conf.Context }
    } })
}
#endregion

#region Connection state
function Update-IMConnectionView {
    $c = $script:UI.C
    $conn = Get-IMConnection
    if ($conn) {
        $c.TenantName.Text = $conn.Organization
        $c.TenantSub.Text = "$($conn.Name) · $($conn.AuthType)"
        $c.TenantDot.SetResourceReference([Windows.Shapes.Shape]::FillProperty, 'Success')
        $c.HomeDisconnected.Visibility = 'Collapsed'; $c.HomeConnected.Visibility = 'Visible'
        $c.HomeTenantTitle.Text = $conn.Organization
        $c.HomeTenantSub.Text = "Tenant $($conn.TenantId) · $(if ($conn.Domain) { "$($conn.Domain) · " })app $($conn.ClientId) · $($conn.Cloud) cloud"
        $perm = [Collections.ObjectModel.ObservableCollection[object]]::new()
        foreach ($p in (Get-IMPermissionReport)) {
            $perm.Add([IntuneManager.ProfileRow]@{ Name = $p.Name; AuthType = [string][char]$(if ($p.Granted) { 0xE73E } else { 0xE711 })
                Warning = $(if ($p.Granted) { '#3FB27F' } elseif ($p.Core) { '#F0616D' } else { '#9C9CAA' }); Detail = $p.Purpose })
        }
        $c.PermissionList.ItemsSource = $perm
        Set-IMStatus "Connected to $($conn.Organization)"
    }
    else {
        $c.TenantName.Text = 'Not connected'; $c.TenantSub.Text = 'Click to connect'
        $c.TenantDot.SetResourceReference([Windows.Shapes.Shape]::FillProperty, 'Muted')
        $c.HomeDisconnected.Visibility = 'Visible'; $c.HomeConnected.Visibility = 'Collapsed'
        Set-IMStatus 'Not connected'
    }
    Update-IMHomeProfiles
    Update-IMCommandState
}

function Get-IMProfileRows {
    foreach ($p in (Get-IMConnectionProfile)) {
        $warn = $null
        if ($p.SecretExpires) {
            $exp = [datetime]::MinValue
            if ([datetime]::TryParse($p.SecretExpires, [ref]$exp)) {
                $days = [int]($exp - (Get-Date)).TotalDays
                if ($days -lt 0) { $warn = "Credential expired on $($exp.ToString('d'))" } elseif ($days -lt 30) { $warn = "Credential expires in $days day(s)" }
            }
        }
        $last = if ($p.LastConnected) { try { "last used $(([datetime]$p.LastConnected).ToString('g'))" } catch { '' } } else { 'never used' }
        [IntuneManager.ProfileRow]@{ Id = $p.Id; Name = $p.Name; Tenant = ($p.TenantName ?? $p.TenantId); AuthType = $p.AuthType
            Detail = "$(if ($p.AuthType -eq 'Certificate') { 'Certificate' } else { 'Client secret' }) · $last"; Warning = $warn; Tag = $p }
    }
}

function Update-IMHomeProfiles {
    $rows = @(Get-IMProfileRows)
    $script:UI.C.HomeProfiles.ItemsSource = $rows
    $script:UI.C.HomeNoProfiles.Visibility = if ($rows.Count) { 'Collapsed' } else { 'Visible' }
}

function Connect-IMProfileAsync {
    param([string]$ProfileId, [scriptblock]$OnDone)
    $prof = Get-IMConnectionProfile -Name $ProfileId | Select-Object -First 1
    Set-IMStatus "Connecting to $($prof.Name)..."
    # Connect on the UI runspace's module state through a job, then adopt the connection object
    Start-IMJob -Name "Connecting to $($prof.Name)" -Foreground -Arguments @{ Id = $ProfileId } -Context @{ OnDone = $OnDone } -Script {
        param($A, $Progress)
        Connect-IMTenant -ProfileName $A.Id | Out-Null
        Get-IMConnectionState
    } -OnComplete {
        param($r, $err, $job)
        if ($err) {
            Show-IMToast -Title 'Could not connect' -Text $err -Kind Error
            if ($job.Context.OnDone) { & $job.Context.OnDone $false $err }
            return
        }
        Set-IMConnectionState $r
        Clear-IMCache
        $script:UI.ObjectCache = @{}
        Set-IMSetting 'LastProfile' $r.ProfileId
        Update-IMConnectionView
        Update-IMNavigation
        Show-IMHome
        Show-IMToast -Title "Connected to $($r.Organization.DisplayName)" -Text "$($r.Roles.Count) application permission(s) granted."
        if ($job.Context.OnDone) { & $job.Context.OnDone $true $null }
    } | Out-Null
}
#endregion

#region Navigation & object pages
function Update-IMNavigation {
    $filter = $script:UI.C.NavFilter.Text
    $items = [Collections.ObjectModel.ObservableCollection[object]]::new()
    foreach ($s in (Get-IMObjectTypeSections)) {
        $types = @($s.Types | Where-Object { -not $filter -or $_.Title -like "*$filter*" -or $s.Section -like "*$filter*" })
        if (-not $types.Count) { continue }
        $items.Add([IntuneManager.NavItem]@{ Id = "hdr:$($s.Section)"; Title = $s.Section.ToUpperInvariant(); IsHeader = $true })
        foreach ($t in $types) {
            $count = if ($script:UI.ObjectCache.ContainsKey($t.Id)) { [string]@($script:UI.ObjectCache[$t.Id]).Count } else { '' }
            $items.Add([IntuneManager.NavItem]@{ Id = $t.Id; Title = $t.Title; Glyph = [string]$t.Icon; Section = $s.Section; Count = $count; Tag = $t })
        }
    }
    $script:UI.NavUpdating = $true
    $script:UI.C.NavList.ItemsSource = $items
    if ($script:UI.CurrentType) { $script:UI.C.NavList.SelectedItem = $items | Where-Object Id -eq $script:UI.CurrentType.Id | Select-Object -First 1 }
    $script:UI.NavUpdating = $false
}

function Show-IMHome {
    $c = $script:UI.C
    $c.HomePage.Visibility = 'Visible'; $c.ObjectsPage.Visibility = 'Collapsed'
    $script:UI.CurrentType = $null
    $script:UI.NavUpdating = $true; $c.NavList.SelectedItem = $null; $script:UI.NavUpdating = $false
    Update-IMRecent
}

function ConvertTo-IMObjectRow {
    param($Type, $Item)
    $kind = if ($Item.templateReference.templateDisplayName) { $Item.templateReference.templateDisplayName }
            elseif ($Item.'@odata.type') { (($Item.'@odata.type' -split '\.')[-1]) -creplace '([a-z])([A-Z])', '$1 $2' } else { '' }
    $mod = $Item.lastModifiedDateTime ?? $Item.modifiedDateTime ?? $Item.createdDateTime
    $modText = if ($mod) { try { ([datetime]$mod).ToLocalTime().ToString('yyyy-MM-dd HH:mm') } catch { [string]$mod } } else { '' }
    [IntuneManager.ObjectRow]@{
        Name = Get-IMObjectName $Type $Item; Description = $Item.description; Kind = $kind
        Platform = [string]($Item.platforms ?? $Item.platform ?? ''); Modified = $modText
        Assigned = if ($null -ne $Item.isAssigned) { if ($Item.isAssigned) { 'Yes' } else { 'No' } } else { '' }
        Id = [string]$Item.id; Tag = $Item
    }
}

function Show-IMObjectType {
    param($Type, [switch]$Refresh)
    $c = $script:UI.C
    $script:UI.CurrentType = $Type
    $c.HomePage.Visibility = 'Collapsed'; $c.ObjectsPage.Visibility = 'Visible'; $c.DetailPane.Visibility = 'Collapsed'
    $c.ObjectsTitle.Text = $Type.Title
    $c.ObjectsSub.Text = (@($Type.Description, $Type.Notes) | Where-Object { $_ }) -join ' '
    if (-not $c.ObjectsSub.Text) { $c.ObjectsSub.Text = "Graph: $($Type.Api)" }
    $c.ObjSearch.Text = ''
    $c.ObjSelectAll.IsChecked = $false
    if (-not (Get-IMConnection)) {
        $script:UI.Rows.Clear(); $c.ObjEmpty.Visibility = 'Visible'; $c.ObjEmptyText.Text = 'Connect to a tenant to see objects.'
        return
    }
    if (-not $Refresh -and $script:UI.ObjectCache.ContainsKey($Type.Id)) { Set-IMObjectRows $Type $script:UI.ObjectCache[$Type.Id]; return }
    if (-not (Test-IMPermission $Type.Permission)) {
        $script:UI.Rows.Clear(); $c.ObjEmpty.Visibility = 'Visible'; $c.ObjEmptyText.Text = "The app needs the $($Type.Permission) permission for this object type."
        return
    }
    $script:UI.Rows.Clear(); $c.ObjEmpty.Visibility = 'Collapsed'; $c.ObjLoading.Visibility = 'Visible'
    Start-IMJob -Name "Loading $($Type.Title)" -Arguments @{ Type = $Type.Id } -Context @{ Type = $Type } -Script {
        param($A, $Progress)
        @(Get-IMObjectList -Type $A.Type)
    } -OnComplete {
        param($r, $err, $job)
        $script:UI.C.ObjLoading.Visibility = 'Collapsed'
        $t = $job.Context.Type
        if ($err) {
            if ($script:UI.CurrentType.Id -eq $t.Id) { $script:UI.C.ObjEmpty.Visibility = 'Visible'; $script:UI.C.ObjEmptyText.Text = $err }
            return
        }
        $items = @($r | Where-Object { $_ })
        $script:UI.ObjectCache[$t.Id] = $items
        if ($script:UI.CurrentType.Id -eq $t.Id) { Set-IMObjectRows $t $items }
        Update-IMNavCount $t.Id $items.Count
    } | Out-Null
}

function Update-IMNavCount {
    param([string]$TypeId, [int]$Count)
    $item = $script:UI.C.NavList.ItemsSource | Where-Object Id -eq $TypeId | Select-Object -First 1
    if ($item) { $item.Count = [string]$Count; $script:UI.C.NavList.Items.Refresh() }
}

function Set-IMObjectRows {
    param($Type, $Items)
    $rows = $script:UI.Rows
    $grid = $script:UI.C.ObjectGrid
    $grid.ItemsSource = $null
    $rows.Clear()
    foreach ($i in ($Items | Sort-Object { Get-IMObjectName $Type $_ })) { $rows.Add((ConvertTo-IMObjectRow $Type $i)) }
    $grid.ItemsSource = $rows
    $script:UI.C.ObjEmpty.Visibility = if ($rows.Count) { 'Collapsed' } else { 'Visible' }
    $script:UI.C.ObjEmptyText.Text = 'No objects of this type in the tenant.'
    $script:UI.C.ObjectsSub.Text = "$($rows.Count) object(s)$(if ($Type.Notes) { ' · ' + $Type.Notes })"
    Update-IMCommandState
}

function Get-IMSelectedRows {
    $sel = @($script:UI.Rows | Where-Object Selected)
    if (-not $sel.Count) { $sel = @($script:UI.C.ObjectGrid.SelectedItems) }
    $sel
}

function Show-IMDetail {
    param($Row)
    $c = $script:UI.C
    if (-not $Row) { $c.DetailPane.Visibility = 'Collapsed'; return }
    $type = $script:UI.CurrentType
    $c.DetailPane.Visibility = 'Visible'
    $c.DetailTitle.Text = $Row.Name; $c.DetailSub.Text = "$($Row.Kind)  ·  $($Row.Id)"
    $c.DetailJson.Text = ''; $c.DetailLoading.Visibility = 'Visible'
    $script:UI.DetailToken = [guid]::NewGuid().ToString()
    Start-IMJob -Name 'Reading object' -Arguments @{ Type = $type.Id; Item = $Row.Tag } -Context @{ Token = $script:UI.DetailToken } -Script {
        param($A, $Progress)
        $o = Get-IMObject -Type $A.Type -Item $A.Item
        ConvertTo-IMJson $o
    } -OnComplete {
        param($r, $err, $job)
        if ($job.Context.Token -ne $script:UI.DetailToken) { return }
        $script:UI.C.DetailLoading.Visibility = 'Collapsed'
        $script:UI.C.DetailJson.Text = if ($err) { "Could not read the object:`n$err" } else { [string]$r }
    } | Out-Null
}

function Update-IMCommandState {
    $c = $script:UI.C
    $connected = [bool](Get-IMConnection)
    $busy = [bool]$script:UI.ForegroundJob
    $type = $script:UI.CurrentType
    foreach ($n in 'ObjRefresh', 'ObjExport', 'ObjCompare', 'ObjDocs', 'TileExport', 'TileCompare', 'TileDocs') { $c[$n].IsEnabled = $connected -and -not $busy }
    $c.ObjImport.IsEnabled = $connected -and -not $busy -and $type.CanImport
    $c.TileImport.IsEnabled = $connected -and -not $busy
    $c.ObjCopy.IsEnabled = $connected -and -not $busy -and $type.CanCopy
    $c.ObjDelete.IsEnabled = $connected -and -not $busy -and $type.CanDelete
}
#endregion

#region Recent operations
function Get-IMRecentPath { Join-Path (Get-IMAppDataPath) 'recent.json' }

function Add-IMRecent {
    param([string]$Action, [string]$Message, [string]$Report, [string]$Folder)
    $list = @()
    $p = Get-IMRecentPath
    if (Test-Path -LiteralPath $p) { try { $list = @(Read-IMJsonFile $p) } catch { } }
    $list = @([pscustomobject]@{ Time = (Get-Date).ToString('yyyy-MM-dd HH:mm'); Action = $Action; Message = $Message; Report = $Report; Folder = $Folder }) + $list | Select-Object -First 30
    Write-IMJsonFile $p @($list)
    Update-IMRecent
}

function Update-IMRecent {
    $p = Get-IMRecentPath
    $rows = if (Test-Path -LiteralPath $p) { try { @(Read-IMJsonFile $p) | ForEach-Object { [IntuneManager.ResultRow]@{ Time = $_.Time; Action = $_.Action; Message = $_.Message; File = ($_.Report ?? $_.Folder) } } } catch { @() } } else { @() }
    $script:UI.C.RecentGrid.ItemsSource = @($rows)
    $script:UI.C.RecentEmpty.Visibility = if (@($rows).Count) { 'Collapsed' } else { 'Visible' }
}

function Format-IMSummary {
    param($S)
    $parts = @("$($S.Succeeded) succeeded")
    if ($S.Warnings) { $parts += "$($S.Warnings) with warnings" }
    if ($S.Skipped) { $parts += "$($S.Skipped) skipped" }
    if ($S.Failed) { $parts += "$($S.Failed) failed" }
    "$($parts -join ', ') in $($S.Duration)$(if ($S.Cancelled) { ' (cancelled)' })"
}
#endregion

#region Connect panel
function Initialize-IMConnectPanel {
    param($p)
    $c = $p.C
    $c.ConnCloud.ItemsSource = @('Global', 'USGov', 'USGovDoD', 'China'); $c.ConnCloud.SelectedIndex = 0
    $c.SetupCloud.ItemsSource = @('Global', 'USGov', 'USGovDoD', 'China'); $c.SetupCloud.SelectedIndex = 0
    $script:UI.SetupLines = [Collections.ObjectModel.ObservableCollection[string]]::new()
    $c.SetupLog.ItemsSource = $script:UI.SetupLines

    $c.ConnClose.Add_Click({ Hide-IMPanel })
    $c.TabExisting.Add_Checked({ Invoke-IMSafe { Set-IMConnectTab 'Existing' } })
    $c.TabSetup.Add_Checked({ Invoke-IMSafe { Set-IMConnectTab 'Setup' } })
    $c.ConnAuthSecret.Add_Checked({ $pc = $script:UI.Panels.ConnectPanel.C; $pc.SecretPanel.Visibility = 'Visible'; $pc.CertPanel.Visibility = 'Collapsed' })
    $c.ConnAuthCert.Add_Checked({ $pc = $script:UI.Panels.ConnectPanel.C; $pc.SecretPanel.Visibility = 'Collapsed'; $pc.CertPanel.Visibility = 'Visible' })
    $c.ConnAdvanced.Add_Checked({ $script:UI.Panels.ConnectPanel.C.AdvancedPanel.Visibility = 'Visible' })
    $c.ConnAdvanced.Add_Unchecked({ $script:UI.Panels.ConnectPanel.C.AdvancedPanel.Visibility = 'Collapsed' })
    $c.ConnCertRefresh.Add_Click({ Invoke-IMSafe { Update-IMCertificateList } })
    $c.ConnPfxBrowse.Add_Click({ Invoke-IMSafe {
        $d = [Microsoft.Win32.OpenFileDialog]::new(); $d.Filter = 'Certificate with private key (*.pfx;*.p12)|*.pfx;*.p12'
        if ($d.ShowDialog()) { $script:UI.Panels.ConnectPanel.C.ConnPfxPath.Text = $d.FileName }
    } })
    $c.ConnPaste.Add_Click({ Invoke-IMSafe { Invoke-IMPasteFromEntra } })
    $c.ConnTenant.Add_TextChanged({ Invoke-IMSafe { Test-IMConnectForm | Out-Null } })
    $c.ConnClient.Add_TextChanged({ Invoke-IMSafe { Test-IMConnectForm | Out-Null } })
    $c.ConnSecret.Add_PasswordChanged({ Invoke-IMSafe { Test-IMConnectForm | Out-Null } })
    $c.ProfileList.Add_SelectionChanged({ Invoke-IMSafe { Set-IMConnectForm $script:UI.Panels.ConnectPanel.C.ProfileList.SelectedItem } })
    $c.ProfileList.Add_MouseDoubleClick({ Invoke-IMSafe {
        $sel = $script:UI.Panels.ConnectPanel.C.ProfileList.SelectedItem
        if ($sel) { Hide-IMPanel; Connect-IMProfileAsync -ProfileId $sel.Id }
    } })
    $c.ProfileNew.Add_Click({ Invoke-IMSafe { $script:UI.Panels.ConnectPanel.C.ProfileList.SelectedItem = $null; Set-IMConnectForm $null } })
    $c.ProfileDelete.Add_Click({ Invoke-IMSafe {
        $sel = $script:UI.Panels.ConnectPanel.C.ProfileList.SelectedItem
        if (-not $sel) { return }
        Show-IMConfirm -Title "Delete '$($sel.Name)'?" -Text 'The saved connection is removed from this computer. The app registration in Entra ID is not changed.' -OkText 'Delete' -Danger -Context @{ Id = $sel.Id } -OnOk {
            param($t, $ctx) Remove-IMConnectionProfile -Name $ctx.Id; Show-IMConnectPanel; Update-IMHomeProfiles
        }
    } })
    $c.ConnTest.Add_Click({ Invoke-IMSafe { Invoke-IMConnectionTest } })
    $c.ConnSave.Add_Click({ Invoke-IMSafe { if (Save-IMConnectForm) { Show-IMToast -Title 'Connection saved'; Update-IMProfileList } } })
    $c.ConnConnect.Add_Click({ Invoke-IMSafe {
        $prof = Save-IMConnectForm
        if (-not $prof) { return }
        $pc = $script:UI.Panels.ConnectPanel.C
        $pc.ConnBusy.Visibility = 'Visible'; $pc.FormButtons.IsEnabled = $false
        Connect-IMProfileAsync -ProfileId $prof.Id -OnDone {
            param($ok, $err)
            $pc = $script:UI.Panels.ConnectPanel.C
            $pc.ConnBusy.Visibility = 'Collapsed'; $pc.FormButtons.IsEnabled = $true
            if ($ok) { Hide-IMPanel } else { Show-IMConnectResult $false $err @() }
        }
    } })
    # Setup assistant
    $c.SetupStart.Add_Click({ Invoke-IMSafe { Start-IMSetupAssistant } })
    $c.SetupCancel.Add_Click({ Invoke-IMSafe { if ($script:UI.SetupJob) { $script:UI.SetupJob.Progress.CancelRequested = $true } } })
    $c.SetupOpen.Add_Click({ Invoke-IMSafe {
        $pc = $script:UI.Panels.ConnectPanel.C
        [System.Windows.Clipboard]::SetText($pc.SetupCode.Text)
        Start-Process $script:UI.SetupUri
    } })
    $c.SetupConnect.Add_Click({ Invoke-IMSafe { Hide-IMPanel; Connect-IMProfileAsync -ProfileId $script:UI.SetupProfileId } })
}

function Set-IMConnectTab {
    param([ValidateSet('Existing', 'Setup')][string]$Tab)
    $c = $script:UI.Panels.ConnectPanel.C
    $existing = $Tab -eq 'Existing'
    $c.FormPanel.Visibility = if ($existing) { 'Visible' } else { 'Collapsed' }
    $c.FormButtons.Visibility = if ($existing) { 'Visible' } else { 'Collapsed' }
    $c.SetupPanel.Visibility = if ($existing) { 'Collapsed' } else { 'Visible' }
    $c.SetupButtons.Visibility = if ($existing) { 'Collapsed' } else { 'Visible' }
}

function Show-IMConnectPanel {
    param([switch]$Setup)
    $p = Show-IMPanel 'ConnectPanel'
    Update-IMProfileList
    Update-IMCertificateList
    if ($Setup) { $p.C.TabSetup.IsChecked = $true } else { $p.C.TabExisting.IsChecked = $true }
    if (-not $p.C.ProfileList.SelectedItem) { Set-IMConnectForm $null }
}

function Update-IMProfileList {
    $c = $script:UI.Panels.ConnectPanel.C
    $rows = @(Get-IMProfileRows)
    $c.ProfileList.ItemsSource = $rows
    $c.ProfileEmpty.Visibility = if ($rows.Count) { 'Collapsed' } else { 'Visible' }
    $current = (Get-IMConnection).ProfileId ?? (Get-IMSetting 'LastProfile')
    $sel = $rows | Where-Object Id -eq $current | Select-Object -First 1
    if ($sel) { $c.ProfileList.SelectedItem = $sel }
}

function Update-IMCertificateList {
    $c = $script:UI.Panels.ConnectPanel.C
    $list = @(Get-IMCertificateList)
    $c.ConnCertList.ItemsSource = $list
    $thumb = $script:UI.EditingProfile.CertificateThumbprint
    if ($thumb) { $c.ConnCertList.SelectedItem = $list | Where-Object Thumbprint -eq $thumb | Select-Object -First 1 }
}

function Set-IMConnectForm {
    param($Row)
    $c = $script:UI.Panels.ConnectPanel.C
    $prof = $Row.Tag
    $script:UI.EditingProfile = $prof
    $c.ConnName.Text = $prof.Name ?? ''
    $c.ConnTenant.Text = $prof.TenantId ?? ''
    $c.ConnClient.Text = $prof.ClientId ?? ''
    $c.ConnSecret.Password = ''
    $c.ConnPfxPath.Text = $prof.CertificatePath ?? ''
    $c.ConnPfxPassword.Password = ''
    $c.ConnCloud.SelectedItem = $prof.Cloud ?? 'Global'
    if ($prof.AuthType -eq 'Secret') { $c.ConnAuthSecret.IsChecked = $true } else { $c.ConnAuthCert.IsChecked = $true }
    $list = @($c.ConnCertList.ItemsSource)
    $c.ConnCertList.SelectedItem = if ($prof.CertificateThumbprint) { $list | Where-Object Thumbprint -eq $prof.CertificateThumbprint | Select-Object -First 1 } else { $null }
    $c.ConnResult.Visibility = 'Collapsed'
    Test-IMConnectForm | Out-Null
}

function Test-IMConnectForm {
    <# Live validation with helpful hints. Returns $true when the form can be used. #>
    $c = $script:UI.Panels.ConnectPanel.C
    $ok = $true
    $t = $c.ConnTenant.Text.Trim()
    if (-not $t) { $c.ConnTenantHint.Text = 'Directory (tenant) ID, or a domain like contoso.onmicrosoft.com'; $c.ConnTenantHint.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'Muted'); $ok = $false }
    elseif ((Test-IMGuid $t) -or $t -match '^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$') { $c.ConnTenantHint.Text = ''; }
    else { $c.ConnTenantHint.Text = 'Use the tenant GUID or a verified domain name.'; $c.ConnTenantHint.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'Danger'); $ok = $false }

    $id = $c.ConnClient.Text.Trim()
    if (-not $id) { $c.ConnClientHint.Text = 'Found on the app registration Overview page.'; $c.ConnClientHint.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'Muted'); $ok = $false }
    elseif (-not (Test-IMGuid $id)) { $c.ConnClientHint.Text = 'The client ID is a GUID, like 1b2c3d4e-....'; $c.ConnClientHint.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'Danger'); $ok = $false }
    elseif ($id -eq $t) { $c.ConnClientHint.Text = 'This is the same as the tenant ID; copy the Application (client) ID instead.'; $c.ConnClientHint.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'Warning') }
    else { $c.ConnClientHint.Text = '' }

    if ($c.ConnAuthSecret.IsChecked) {
        $s = $c.ConnSecret.Password
        $c.ConnSecretHint.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'Muted')
        if (-not $s) {
            $c.ConnSecretHint.Text = if ($script:UI.EditingProfile.Secret) { 'A secret is saved for this connection. Leave empty to keep it.' } else { 'Paste the secret VALUE shown once when the secret was created (not the Secret ID).' }
            if (-not $script:UI.EditingProfile.Secret) { $ok = $false }
        }
        elseif (Test-IMGuid $s.Trim()) { $c.ConnSecretHint.Text = 'This looks like the Secret ID. Paste the secret Value instead (about 40 characters, often containing ~).'; $c.ConnSecretHint.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'Danger') }
        else { $c.ConnSecretHint.Text = 'The secret is encrypted for your Windows account (DPAPI) when saved.' }
    }
    $ok
}

function Invoke-IMPasteFromEntra {
    $c = $script:UI.Panels.ConnectPanel.C
    $text = [System.Windows.Clipboard]::GetText()
    if (-not $text) { Show-IMToast -Title 'The clipboard is empty' -Text 'Copy the Overview page of the app registration first (Ctrl+A, Ctrl+C).' -Kind Info; return }
    $g = '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})'
    $found = @()
    if ($text -match "Application \(client\) ID\W*$g") { $c.ConnClient.Text = $Matches[1]; $found += 'client ID' }
    if ($text -match "Directory \(tenant\) ID\W*$g") { $c.ConnTenant.Text = $Matches[1]; $found += 'tenant ID' }
    if ($text -match 'Display name\s*:?\s*\r?\n?\s*([^\r\n]+)' -and -not $c.ConnName.Text) { $c.ConnName.Text = $Matches[1].Trim(); $found += 'name' }
    if (-not $found.Count) {
        $guids = @([regex]::Matches($text, $g) | ForEach-Object Value | Select-Object -Unique)
        if ($guids.Count -eq 1 -and -not $c.ConnClient.Text) { $c.ConnClient.Text = $guids[0]; $found += 'client ID' }
    }
    if ($found.Count) { Show-IMToast -Title "Filled in $($found -join ', ')" -Kind Success }
    else { Show-IMToast -Title 'No IDs found on the clipboard' -Text "Copy the app registration's Overview page, which shows 'Application (client) ID' and 'Directory (tenant) ID'." -Kind Warning }
}

function Get-IMConnectFormValues {
    $c = $script:UI.Panels.ConnectPanel.C
    $v = @{ TenantId = $c.ConnTenant.Text.Trim(); ClientId = $c.ConnClient.Text.Trim(); Cloud = [string]($c.ConnCloud.SelectedItem ?? 'Global') }
    if ($c.ConnAuthSecret.IsChecked) {
        $v.AuthType = 'Secret'
        if ($c.ConnSecret.SecurePassword.Length) { $v.ClientSecret = $c.ConnSecret.SecurePassword.Copy() }
        elseif ($script:UI.EditingProfile.Secret -and $script:UI.EditingProfile.ClientId -eq $v.ClientId) { $v.ClientSecret = Unprotect-IMSecret $script:UI.EditingProfile.Secret }
    }
    else {
        $v.AuthType = 'Certificate'
        if ($c.ConnPfxPath.Text) { $v.CertificatePath = $c.ConnPfxPath.Text.Trim(); if ($c.ConnPfxPassword.SecurePassword.Length) { $v.CertificatePassword = $c.ConnPfxPassword.SecurePassword.Copy() } elseif ($script:UI.EditingProfile.CertificatePassword) { $v.CertificatePassword = Unprotect-IMSecret $script:UI.EditingProfile.CertificatePassword } }
        elseif ($c.ConnCertList.SelectedItem) { $v.CertificateThumbprint = $c.ConnCertList.SelectedItem.Thumbprint }
    }
    $v
}

function Save-IMConnectForm {
    $c = $script:UI.Panels.ConnectPanel.C
    if (-not (Test-IMConnectForm)) { Show-IMToast -Title 'Check the highlighted fields' -Kind Warning; return $null }
    $v = Get-IMConnectFormValues
    if ($v.AuthType -eq 'Certificate' -and -not $v.CertificateThumbprint -and -not $v.CertificatePath) { Show-IMToast -Title 'Choose a certificate' -Text 'Pick one from the list or browse to a .pfx file.' -Kind Warning; return $null }
    $name = $c.ConnName.Text.Trim()
    if (-not $name) { $name = $v.TenantId; $c.ConnName.Text = $name }
    $saveArgs = @{ Name = $name; TenantId = $v.TenantId; ClientId = $v.ClientId; AuthType = $v.AuthType; Cloud = $v.Cloud }
    if ($script:UI.EditingProfile.Id) { $saveArgs.Id = $script:UI.EditingProfile.Id }
    if ($c.ConnSecret.SecurePassword.Length) { $saveArgs.ClientSecret = $c.ConnSecret.SecurePassword.Copy() }
    if ($v.CertificateThumbprint) { $saveArgs.CertificateThumbprint = $v.CertificateThumbprint }
    if ($v.CertificatePath) { $saveArgs.CertificatePath = $v.CertificatePath }
    if ($c.ConnPfxPassword.SecurePassword.Length) { $saveArgs.CertificatePassword = $c.ConnPfxPassword.SecurePassword.Copy() }
    $prof = Save-IMConnectionProfile @saveArgs
    $script:UI.EditingProfile = $prof
    Update-IMHomeProfiles
    $prof
}

function Show-IMConnectResult {
    param([bool]$Ok, [string]$Message, $Permissions)
    $c = $script:UI.Panels.ConnectPanel.C
    $c.ConnResult.Visibility = 'Visible'
    $c.ConnResultText.Text = $Message
    $c.ConnResultIcon.Text = [string][char]$(if ($Ok) { 0xE73E } else { 0xEA39 })
    $c.ConnResultIcon.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, $(if ($Ok) { 'Success' } else { 'Danger' }))
    $rows = foreach ($p in @($Permissions)) {
        if (-not $p) { continue }
        [IntuneManager.ProfileRow]@{ Name = $p.Name; Tenant = $(if ($p.Granted) { '' } elseif ($p.Core) { ' - missing' } else { ' - optional' })
            AuthType = [string][char]$(if ($p.Granted) { 0xE73E } else { 0xE711 }); Warning = $(if ($p.Granted) { '#3FB27F' } elseif ($p.Core) { '#F0616D' } else { '#9C9CAA' }); Detail = $p.Purpose }
    }
    $c.ConnPerms.ItemsSource = @($rows)
}

function Invoke-IMConnectionTest {
    $c = $script:UI.Panels.ConnectPanel.C
    if (-not (Test-IMConnectForm)) { Show-IMToast -Title 'Check the highlighted fields' -Kind Warning; return }
    $v = Get-IMConnectFormValues
    $c.ConnBusy.Text = 'Testing...'; $c.ConnBusy.Visibility = 'Visible'; $c.FormButtons.IsEnabled = $false
    Start-IMJob -Name 'Testing connection' -Arguments $v -Script {
        param($A, $Progress)
        Test-IMConnectionProfile @A
    } -OnComplete {
        param($r, $err, $job)
        $c = $script:UI.Panels.ConnectPanel.C
        $c.ConnBusy.Visibility = 'Collapsed'; $c.ConnBusy.Text = 'Signing in...'; $c.FormButtons.IsEnabled = $true
        if ($err) { Show-IMConnectResult $false $err @(); return }
        Show-IMConnectResult $r.Success $r.Message $r.Permissions
    } | Out-Null
}

function Start-IMSetupAssistant {
    $c = $script:UI.Panels.ConnectPanel.C
    $script:UI.SetupLines.Clear()
    $c.SetupError.Text = ''
    $c.SetupStart.Visibility = 'Collapsed'; $c.SetupCancel.Visibility = 'Visible'; $c.SetupConnect.Visibility = 'Collapsed'
    $c.SetupProgress.Visibility = 'Visible'
    $setupArgs = @{ Cloud = [string]$c.SetupCloud.SelectedItem; Name = $c.SetupName.Text.Trim(); Credential = $(if ($c.SetupSecret.IsChecked) { 'Secret' } else { 'Certificate' }); Optional = [bool]$c.SetupOptional.IsChecked }
    if (-not $setupArgs.Name) { $setupArgs.Name = 'IntuneManager' }
    $script:UI.SetupLines.Add('Requesting a sign-in code')
    Start-IMJob -Name 'Starting sign-in' -Arguments $setupArgs -Context $setupArgs -Script {
        param($A, $Progress)
        Start-IMDeviceCodeLogin -Cloud $A.Cloud
    } -OnComplete {
        param($code, $err, $job)
        $c = $script:UI.Panels.ConnectPanel.C
        if ($err) { $c.SetupError.Text = $err; Reset-IMSetupButtons; return }
        $c.SetupCodePanel.Visibility = 'Visible'
        $c.SetupCode.Text = $code.UserCode
        $script:UI.SetupUri = $code.VerificationUri
        $script:UI.SetupLines.Add("Waiting for sign-in at $($code.VerificationUri)")
        $a = $job.Context.Clone(); $a.Code = $code
        $script:UI.SetupJob = Start-IMJob -Name 'Creating app registration' -Arguments $a -Context @{ OnLines = { param($l) $script:UI.SetupLines.Add($l) } } -Script {
            param($A, $Progress)
            $token = Wait-IMDeviceCodeLogin -DeviceCode $A.Code -CancelFlag $Progress
            $Progress.Lines.Enqueue('Signed in')
            $status = { param($m) $Progress.Lines.Enqueue($m) }.GetNewClosure()
            New-IMAppRegistration -DelegatedToken $token -DisplayName $A.Name -CredentialType $A.Credential -IncludeOptionalPermissions:$A.Optional -Cloud $A.Cloud -OnStatus $status
        } -OnComplete {
            param($r, $err, $job)
            $c = $script:UI.Panels.ConnectPanel.C
            $c.SetupProgress.Visibility = 'Collapsed'; $c.SetupCodePanel.Visibility = 'Collapsed'
            $script:UI.SetupJob = $null
            if ($err) { $c.SetupError.Text = $err; Reset-IMSetupButtons; return }
            $script:UI.SetupProfileId = $r.Profile.Id
            if ($r.SecretText) { $script:UI.SetupLines.Add("Client secret (copy it now, it is shown once): $($r.SecretText)") }
            if (-not $r.Ready) { $script:UI.SetupLines.Add('Permissions are still replicating. If connecting fails, wait a few minutes and try again.') }
            $c.SetupCancel.Visibility = 'Collapsed'; $c.SetupConnect.Visibility = 'Visible'
            Update-IMProfileList; Update-IMHomeProfiles
            Show-IMToast -Title 'App registration created' -Text "Profile '$($r.Profile.Name)' is ready."
        }
    } | Out-Null
}

function Reset-IMSetupButtons {
    $c = $script:UI.Panels.ConnectPanel.C
    $c.SetupStart.Visibility = 'Visible'; $c.SetupCancel.Visibility = 'Collapsed'; $c.SetupProgress.Visibility = 'Collapsed'; $c.SetupCodePanel.Visibility = 'Collapsed'
}
#endregion

#region Export panel
function Initialize-IMExportPanel {
    param($p)
    $c = $p.C
    $c.ExpClose.Add_Click({ Hide-IMPanel }); $c.ExpCancel.Add_Click({ Hide-IMPanel })
    $c.ExpBrowse.Add_Click({ Invoke-IMSafe { $f = Select-IMFolder 'Export folder' $script:UI.Panels.ExportPanel.C.ExpPath.Text; if ($f) { $script:UI.Panels.ExportPanel.C.ExpPath.Text = $f } } })
    $c.ExpSelAll.Add_Click({ foreach ($r in $script:UI.ExportTypes) { $r.Selected = $true }; Update-IMExportCount })
    $c.ExpSelNone.Add_Click({ foreach ($r in $script:UI.ExportTypes) { $r.Selected = $false }; Update-IMExportCount })
    $c.ExpScopeTypes.Add_Checked({ $pc = $script:UI.Panels.ExportPanel.C; $pc.ExpTypesPanel.Visibility = 'Visible'; $pc.ExpSelectedPanel.Visibility = 'Collapsed' })
    $c.ExpScopeSelected.Add_Checked({ $pc = $script:UI.Panels.ExportPanel.C; $pc.ExpTypesPanel.Visibility = 'Collapsed'; $pc.ExpSelectedPanel.Visibility = 'Visible' })
    $c.ExpPath.Add_TextChanged({ Invoke-IMSafe { Update-IMExportPathHint } })
    $c.ExpDateFolder.Add_Click({ Invoke-IMSafe { Update-IMExportPathHint } })
    $c.ExpStart.Add_Click({ Invoke-IMSafe { Start-IMExportFromPanel } })
}

function Update-IMExportCount {
    $n = @($script:UI.ExportTypes | Where-Object Selected).Count
    $script:UI.Panels.ExportPanel.C.ExpTypeCount.Text = "$n of $(@($script:UI.ExportTypes).Count) selected"
}

function Update-IMExportPathHint {
    $c = $script:UI.Panels.ExportPanel.C
    $conn = Get-IMConnection
    $c.ExpPathHint.Text = if ($c.ExpPath.Text -and $c.ExpDateFolder.IsChecked) { "Files go to $(Join-Path (Join-Path $c.ExpPath.Text (Get-IMSafeFileName ($conn.Organization ?? 'tenant'))) (Get-Date -Format 'yyyy-MM-dd_HHmm'))" } else { '' }
}

function Show-IMExportPanel {
    param([switch]$FromObjectsPage)
    $p = Show-IMPanel 'ExportPanel'
    $c = $p.C
    $conn = Get-IMConnection
    $c.ExpSub.Text = "From $($conn.Organization)"
    if (-not $c.ExpPath.Text) { $c.ExpPath.Text = (Get-IMSetting 'LastExportPath') ?? (Get-IMSetting 'ExportRoot') }
    if (-not $c.ExpPath.Text) { $c.ExpPath.Text = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'IntuneManager Exports' }
    $c.ExpAssign.IsChecked = [bool](Get-IMSetting 'ExportAssignments')
    $c.ExpDateFolder.IsChecked = [bool](Get-IMSetting 'AddDateFolder')
    $c.ExpAddId.IsChecked = [bool](Get-IMSetting 'AddObjectIdToFileName')
    $c.ExpAppContent.IsChecked = [bool](Get-IMSetting 'ExportAppContent')
    $current = $script:UI.CurrentType
    $script:UI.ExportTypes = [Collections.ObjectModel.ObservableCollection[object]]::new()
    foreach ($t in (Get-IMObjectType)) {
        $ok = Test-IMPermission $t.Permission
        $sel = if ($FromObjectsPage -and $current) { $t.Id -eq $current.Id } else { $ok }
        $script:UI.ExportTypes.Add([IntuneManager.ObjectRow]@{ Selected = $sel -and $ok; Name = $t.Title; Kind = $(if ($ok) { '' } else { '(no permission)' }); Description = "$($t.Section) · $($t.Api)"; Id = $t.Id; Tag = $t })
    }
    $c.ExpTypeList.ItemsSource = $script:UI.ExportTypes
    foreach ($r in $script:UI.ExportTypes) { $r.add_PropertyChanged({ Update-IMExportCount }) }
    Update-IMExportCount
    $selected = if ($FromObjectsPage) { @($script:UI.Rows | Where-Object Selected) } else { @() }
    if ($selected.Count) {
        $c.ExpScopeSelected.IsEnabled = $true; $c.ExpScopeSelected.IsChecked = $true
        $c.ExpSelectedText.Text = "$($selected.Count) selected $($current.Title): " + (($selected | Select-Object -First 8 | ForEach-Object Name) -join ', ') + $(if ($selected.Count -gt 8) { ', ...' })
    }
    else { $c.ExpScopeTypes.IsChecked = $true; $c.ExpScopeSelected.IsEnabled = $false }
    Update-IMExportPathHint
}

function Start-IMExportFromPanel {
    $c = $script:UI.Panels.ExportPanel.C
    $path = $c.ExpPath.Text.Trim()
    if (-not $path) { Show-IMToast -Title 'Choose an export folder' -Kind Warning; return }
    Set-IMSetting 'LastExportPath' $path -NoSave
    Set-IMSetting 'AddObjectIdToFileName' ([bool]$c.ExpAddId.IsChecked) -NoSave
    Set-IMSetting 'ExportAppContent' ([bool]$c.ExpAppContent.IsChecked) -NoSave
    Set-IMSetting 'AddDateFolder' ([bool]$c.ExpDateFolder.IsChecked)
    $a = @{ Path = $path; Assign = [bool]$c.ExpAssign.IsChecked; NoDate = -not $c.ExpDateFolder.IsChecked }
    if ($c.ExpScopeSelected.IsChecked) {
        $a.Selection = @{ $script:UI.CurrentType.Id = @($script:UI.Rows | Where-Object Selected | ForEach-Object Tag) }
    }
    else {
        $a.Types = @($script:UI.ExportTypes | Where-Object Selected | ForEach-Object Id)
        if (-not $a.Types.Count) { Show-IMToast -Title 'Select at least one object type' -Kind Warning; return }
    }
    Hide-IMPanel
    Start-IMJob -Name 'Exporting' -Foreground -Arguments $a -Script {
        param($A, $Progress)
        $p = @{ Path = $A.Path; IncludeAssignments = $A.Assign; NoDateFolder = $A.NoDate; Progress = $Progress }
        if ($A.Selection) { $p.Selection = $A.Selection } else { $p.ObjectType = $A.Types }
        Export-IMObjects @p
    } -OnComplete {
        param($r, $err, $job)
        if ($err) { Show-IMToast -Title 'Export failed' -Text $err -Kind Error; return }
        $msg = Format-IMSummary $r
        Add-IMRecent -Action 'Export' -Message $msg -Report $r.Report -Folder $r.ExportPath
        $script:UI.LastExportPath = $r.ExportPath
        Show-IMToast -Title $(if ($r.Failed) { 'Export finished with errors' } else { 'Export complete' }) -Text $msg -Kind $(if ($r.Failed) { 'Warning' } else { 'Success' }) -ActionText 'Open folder' -Action { Open-IMPath $script:UI.LastExportPath } -Seconds 12
    } | Out-Null
}
#endregion

#region Import panel
function Initialize-IMImportPanel {
    param($p)
    $c = $p.C
    $c.ImpConflict.ItemsSource = @(
        [pscustomobject]@{ Id = 'Skip'; Name = 'Skip it'; Hint = 'Keep the existing object. Its id is still used for references from other imported objects.' }
        [pscustomobject]@{ Id = 'Update'; Name = 'Update it'; Hint = 'Overwrite the settings of the existing object and replace its assignments.' }
        [pscustomobject]@{ Id = 'Rename'; Name = 'Import a renamed copy'; Hint = 'Create a new object with a suffix, e.g. "(Imported)".' }
        [pscustomobject]@{ Id = 'Replace'; Name = 'Delete and recreate'; Hint = 'Delete the existing object, then import. The object gets a new id.' }
        [pscustomobject]@{ Id = 'Duplicate'; Name = 'Import anyway (duplicate)'; Hint = 'Always create a new object with the same name.' }
    )
    $c.ImpCaState.ItemsSource = @(
        [pscustomobject]@{ Id = 'disabled'; Name = 'Off (recommended)' }
        [pscustomobject]@{ Id = 'enabledForReportingButNotEnforced'; Name = 'Report-only' }
        [pscustomobject]@{ Id = 'enabled'; Name = 'On, as exported' }
    )
    $c.ImpCaState.SelectedIndex = 0
    $c.ImpConflict.Add_SelectionChanged({ $pc = $script:UI.Panels.ImportPanel.C; $pc.ImpConflictHint.Text = $pc.ImpConflict.SelectedItem.Hint })
    $c.ImpClose.Add_Click({ Hide-IMPanel })
    $c.ImpBrowse.Add_Click({ Invoke-IMSafe { $f = Select-IMFolder 'Folder with an export' $script:UI.Panels.ImportPanel.C.ImpPath.Text; if ($f) { $script:UI.Panels.ImportPanel.C.ImpPath.Text = $f; Start-IMImportLoad } } })
    $c.ImpLoad.Add_Click({ Invoke-IMSafe { Start-IMImportLoad } })
    $c.ImpPath.Add_KeyDown({ if ($_.Key -eq 'Return') { Invoke-IMSafe { Start-IMImportLoad } } })
    $c.ImpSelAll.Add_Click({ Invoke-IMSafe { Set-IMPlanSelection { param($r) $r.Status -ne 'Invalid' -and (Test-IMPlanFilter $r) } $true } })
    $c.ImpSelNone.Add_Click({ Invoke-IMSafe { Set-IMPlanSelection { param($r) Test-IMPlanFilter $r } $false } })
    $c.ImpFilter.Add_TextChanged({ Invoke-IMSafe { [Windows.Data.CollectionViewSource]::GetDefaultView($script:UI.PlanRows).Refresh() } })
    $c.ImpPreview.Add_Click({ Invoke-IMSafe { Start-IMImportRun -WhatIf } })
    $c.ImpStart.Add_Click({ Invoke-IMSafe {
        $n = @($script:UI.PlanRows | Where-Object Selected).Count
        $pc = $script:UI.Panels.ImportPanel.C
        $mode = $pc.ImpConflict.SelectedItem
        $danger = $mode.Id -eq 'Replace'
        Show-IMConfirm -Title "Import $n object(s) into $((Get-IMConnection).Organization)?" -Text "Existing objects with the same name: $($mode.Name.ToLower()). $(if ($danger) { 'Existing objects are DELETED before re-creating them. Type REPLACE to confirm.' } else { 'A report is saved when the import finishes.' })" `
            -OkText 'Import' -Danger:$danger -InputLabel $(if ($danger) { 'Type REPLACE' }) -RequireText $(if ($danger) { 'REPLACE' }) -OnOk { Show-IMPanel 'ImportPanel' | Out-Null; Start-IMImportRun }
    } })
    $c.ImpRetry.Add_Click({ Invoke-IMSafe {
        $script:UI.SuspendSummary = $true
        try { foreach ($r in $script:UI.PlanRows) { $r.Selected = $r.Status -eq 'Failed' } } finally { $script:UI.SuspendSummary = $false }
        Update-IMImportSummary
        Start-IMImportRun
    } })
    $c.ImpReport.Add_Click({ Invoke-IMSafe { if ($script:UI.ImportReport) { Open-IMPath ([IO.Path]::ChangeExtension($script:UI.ImportReport, '.csv')) } } })
    $script:UI.PlanRows = [Collections.ObjectModel.ObservableCollection[object]]::new()
    $c.ImpGrid.ItemsSource = $script:UI.PlanRows
    [Windows.Data.CollectionViewSource]::GetDefaultView($script:UI.PlanRows).Filter = [Predicate[object]]{ param($r) Test-IMPlanFilter $r }
}

function Set-IMPlanSelection {
    param([scriptblock]$Where, [bool]$Value)
    $script:UI.SuspendSummary = $true
    try { foreach ($r in $script:UI.PlanRows) { if (& $Where $r) { $r.Selected = $Value } } }
    finally { $script:UI.SuspendSummary = $false }
    Update-IMImportSummary
}

function Test-IMPlanFilter {
    param($Row)
    $f = $script:UI.Panels.ImportPanel.C.ImpFilter.Text
    -not $f -or $Row.Name -like "*$f*" -or $Row.TypeTitle -like "*$f*" -or $Row.Status -like "*$f*"
}

function Show-IMImportPanel {
    param([string]$TypeId)
    $p = Show-IMPanel 'ImportPanel'
    $c = $p.C
    $conn = Get-IMConnection
    $c.ImpSub.Text = "Into $($conn.Organization)"
    $c.ImpConflict.SelectedValue = Get-IMSetting 'ConflictAction'
    $c.ImpAssign.IsChecked = [bool](Get-IMSetting 'ImportAssignments')
    $c.ImpScopeTags.IsChecked = [bool](Get-IMSetting 'ImportScopeTags')
    $c.ImpCreateGroups.IsChecked = [bool](Get-IMSetting 'CreateMissingGroups')
    $script:UI.ImportTypeFilter = $TypeId
    if (-not $c.ImpPath.Text) { $c.ImpPath.Text = $script:UI.LastExportPath ?? (Get-IMSetting 'LastImportPath') }
    if ($c.ImpPath.Text -and -not $script:UI.PlanRows.Count) { Start-IMImportLoad }
    elseif ($TypeId) { $script:UI.ImportTypeFilterValue = $TypeId; Set-IMPlanSelection { param($r) $true } $false; Set-IMPlanSelection { param($r) $r.Tag.TypeId -eq $script:UI.ImportTypeFilterValue -and $r.Status -ne 'Invalid' } $true }
}

function Start-IMImportLoad {
    $c = $script:UI.Panels.ImportPanel.C
    $path = $c.ImpPath.Text.Trim()
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { Show-IMToast -Title 'Folder not found' -Text $path -Kind Warning; return }
    Set-IMSetting 'LastImportPath' $path
    $c.ImpEmpty.Visibility = 'Collapsed'
    $script:UI.PlanRows.Clear()
    $c.ImpSummary.Text = 'Reading and validating files...'
    Start-IMJob -Name 'Reading export' -Arguments @{ Path = $path } -Script {
        param($A, $Progress)
        $plan = Get-IMImportPlan -Path $A.Path
        $mig = Join-Path $plan.Root 'MigrationTable.json'
        $info = [ordered]@{ Root = $plan.Root; Tenant = $plan.Manifest.Organization; TenantId = $plan.Manifest.TenantId; Exported = $plan.Manifest.ExportedAt; HasMigration = Test-Path -LiteralPath $mig }
        if (-not $info.TenantId -and $info.HasMigration) { $mt = Read-IMJsonFile $mig; $info.TenantId = $mt.TenantId; $info.Tenant = $mt.Organization }
        [pscustomobject]@{ Plan = $plan; Info = [pscustomobject]$info }
    } -OnComplete {
        param($r, $err, $job)
        $c = $script:UI.Panels.ImportPanel.C
        if ($err) { $c.ImpSummary.Text = $err; $c.ImpEmpty.Visibility = 'Visible'; return }
        $script:UI.ImportPlan = $r.Plan
        $typeFilter = $script:UI.ImportTypeFilter
        $script:UI.SuspendSummary = $true
        $c.ImpGrid.ItemsSource = $null
        foreach ($i in $r.Plan.Items) {
            $row = [IntuneManager.PlanRow]@{ TypeTitle = $i.Type.Title; Name = $i.Name; Order = $i.Order; Assignments = $i.AssignmentCount; File = $i.File; Tag = $i
                Status = $(if ($i.Valid) { '' } else { 'Invalid' }); Message = $(if ($i.Valid) { if ($i.Modified) { 'Edited after export' } else { '' } } else { $i.Error }) }
            $row.Selected = $i.Valid -and (-not $typeFilter -or $i.TypeId -eq $typeFilter)
            $row.add_PropertyChanged({ param($s, $e) if ($e.PropertyName -eq 'Selected') { Update-IMImportSummary } })
            $script:UI.PlanRows.Add($row)
        }
        $c.ImpGrid.ItemsSource = $script:UI.PlanRows
        $script:UI.SuspendSummary = $false
        $info = $r.Info
        $conn = Get-IMConnection
        $same = $info.TenantId -and $info.TenantId -eq $conn.TenantId
        $c.ImpSourceInfo.Visibility = 'Visible'
        $c.ImpSourceText.Text = "From $(if ($info.Tenant) { $info.Tenant } else { 'unknown tenant' })$(if ($info.Exported) { ", exported $(([datetime]$info.Exported).ToString('g'))" }). " +
            $(if ($same) { 'Same tenant: ids are kept.' } elseif ($info.HasMigration) { 'Different tenant: groups, filters and other references are mapped by name.' } else { 'No migration table: group assignments cannot be mapped to another tenant.' })
        $c.ImpEmpty.Visibility = if ($script:UI.PlanRows.Count) { 'Collapsed' } else { 'Visible' }
        $c.ImpRetry.Visibility = 'Collapsed'; $c.ImpReport.Visibility = 'Collapsed'
        Update-IMImportSummary
    } | Out-Null
}

function Update-IMImportSummary {
    if ($script:UI.SuspendSummary) { return }
    $c = $script:UI.Panels.ImportPanel.C
    $rows = @($script:UI.PlanRows)
    $sel = @($rows | Where-Object Selected)
    $invalid = @($rows | Where-Object Status -eq 'Invalid').Count
    $types = @($sel | ForEach-Object TypeTitle | Select-Object -Unique).Count
    $c.ImpSummary.Text = "$($sel.Count) of $($rows.Count) object(s) selected across $types type(s)$(if ($invalid) { "; $invalid invalid file(s) will be skipped" }). Objects import in dependency order (#)."
    $c.ImpPreview.IsEnabled = $sel.Count -gt 0 -and -not $script:UI.ForegroundJob
    $c.ImpStart.IsEnabled = $sel.Count -gt 0 -and -not $script:UI.ForegroundJob
}

function Start-IMImportRun {
    param([switch]$WhatIf)
    $c = $script:UI.Panels.ImportPanel.C
    $plan = $script:UI.ImportPlan
    $selectedFiles = [Collections.Generic.HashSet[string]]::new([string[]]@($script:UI.PlanRows | Where-Object Selected | ForEach-Object File))
    foreach ($i in $plan.Items) { $i.Selected = $selectedFiles.Contains($i.File) }
    foreach ($r in $script:UI.PlanRows) { if ($r.Selected) { $r.Status = ''; $r.Message = $(if ($WhatIf) { 'Checking...' } else { 'Waiting...' }) } }
    $opts = @{ ConflictAction = [string]$c.ImpConflict.SelectedValue; ImportAssignments = [bool]$c.ImpAssign.IsChecked; ImportScopeTags = [bool]$c.ImpScopeTags.IsChecked
        CreateMissingGroups = [bool]$c.ImpCreateGroups.IsChecked; NamePrefix = $c.ImpPrefix.Text; ConditionalAccessState = [string]$c.ImpCaState.SelectedValue }
    Set-IMSetting 'ConflictAction' $opts.ConflictAction -NoSave
    Set-IMSetting 'ImportAssignments' $opts.ImportAssignments -NoSave
    Set-IMSetting 'ImportScopeTags' $opts.ImportScopeTags -NoSave
    Set-IMSetting 'CreateMissingGroups' $opts.CreateMissingGroups
    $c.ImpPreview.IsEnabled = $false; $c.ImpStart.IsEnabled = $false
    Start-IMJob -Name $(if ($WhatIf) { 'Previewing import' } else { 'Importing' }) -Foreground -Arguments @{ Plan = $plan; Options = $opts; WhatIf = [bool]$WhatIf } -Context @{ WhatIf = [bool]$WhatIf } -Script {
        param($A, $Progress)
        $o = $A.Options
        $s = Import-IMObjects -Path $A.Plan.Root -Plan $A.Plan -Progress $Progress -WhatIf:$A.WhatIf -ConflictAction $o.ConflictAction -ImportAssignments $o.ImportAssignments `
            -ImportScopeTags $o.ImportScopeTags -CreateMissingGroups $o.CreateMissingGroups -NamePrefix $o.NamePrefix -ConditionalAccessState $o.ConditionalAccessState
        $report = Read-IMJsonFile $s.Report
        [pscustomobject]@{ Summary = $s; Results = @($report.Results) }
    } -OnComplete {
        param($r, $err, $job)
        $c = $script:UI.Panels.ImportPanel.C
        if ($err) { Show-IMToast -Title 'Import stopped' -Text $err -Kind Error; Update-IMImportSummary; return }
        $byFile = @{}
        foreach ($res in $r.Results) { if ($res.File -and $res.ObjectType -ne 'Group') { $byFile[$res.File] = $res } }
        foreach ($row in $script:UI.PlanRows) {
            if (-not $row.Selected) { continue }
            $res = $byFile[$row.File]
            if (-not $res) { $row.Status = 'Skipped'; $row.Message = 'Not processed (cancelled or stopped).'; continue }
            $row.Status = $res.Status
            $action = switch -Wildcard ($res.Action) { 'WouldCreate' { 'Will create' } 'WouldUpdate' { 'Will update' } 'WouldReplace' { 'Will delete and recreate' } default { $res.Action } }
            $row.Message = (@($action, $res.Message) | Where-Object { $_ }) -join ' · '
        }
        $s = $r.Summary
        $script:UI.ImportReport = $s.Report
        $c.ImpReport.Visibility = 'Visible'
        $c.ImpRetry.Visibility = if (-not $job.Context.WhatIf -and $s.Failed) { 'Visible' } else { 'Collapsed' }
        $groups = @($r.Results | Where-Object { $_.ObjectType -eq 'Group' })
        $msg = Format-IMSummary $s
        if ($groups.Count) { $msg += ". Groups $(if ($job.Context.WhatIf) { 'to create' } else { 'created' }): $(($groups.Name) -join ', ')" }
        $c.ImpSummary.Text = $msg
        Update-IMImportSummary
        $c.ImpSummary.Text = $msg
        if ($job.Context.WhatIf) { Show-IMToast -Title 'Preview complete - nothing was changed' -Text $msg -Kind Info }
        else {
            Add-IMRecent -Action 'Import' -Message $msg -Report $s.Report
            $script:UI.ObjectCache = @{}
            Show-IMToast -Title $(if ($s.Failed) { 'Import finished with errors' } else { 'Import complete' }) -Text $msg -Kind $(if ($s.Failed) { 'Warning' } else { 'Success' })
        }
    } | Out-Null
}
#endregion

#region Compare panel
function Initialize-IMComparePanel {
    param($p)
    $c = $p.C
    $c.CmpClose.Add_Click({ Hide-IMPanel })
    $c.CmpModeTenant.Add_Checked({ $script:UI.Panels.ComparePanel.C.CmpDiffRow.Visibility = 'Collapsed' })
    $c.CmpModeExports.Add_Checked({ $script:UI.Panels.ComparePanel.C.CmpDiffRow.Visibility = 'Visible' })
    $c.CmpRefBrowse.Add_Click({ Invoke-IMSafe { $f = Select-IMFolder 'Reference export' $script:UI.Panels.ComparePanel.C.CmpRef.Text; if ($f) { $script:UI.Panels.ComparePanel.C.CmpRef.Text = $f } } })
    $c.CmpDiffBrowse.Add_Click({ Invoke-IMSafe { $f = Select-IMFolder 'Export to compare' $script:UI.Panels.ComparePanel.C.CmpDiff.Text; if ($f) { $script:UI.Panels.ComparePanel.C.CmpDiff.Text = $f } } })
    $c.CmpShowAll.Add_Checked({ Update-IMCompareView }); $c.CmpShowChanged.Add_Checked({ Update-IMCompareView })
    $c.CmpGrid.Add_SelectionChanged({ Invoke-IMSafe {
        $pc = $script:UI.Panels.ComparePanel.C
        $sel = $pc.CmpGrid.SelectedItem
        $diffs = @($sel.Differences)
        $pc.CmpDiffGrid.ItemsSource = $diffs
        $pc.CmpDiffEmpty.Visibility = if ($diffs.Count) { 'Collapsed' } else { 'Visible' }
        $pc.CmpDiffEmpty.Text = if ($sel) { switch ($sel.Status) { 'Identical' { 'No differences.' } 'OnlyInReference' { 'Exists only in the reference.' } 'OnlyInDifference' { 'Exists only in the compared side.' } default { '' } } } else { 'Select a changed object to see its differences.' }
    } })
    $c.CmpRun.Add_Click({ Invoke-IMSafe { Start-IMCompareRun } })
    $c.CmpSaveHtml.Add_Click({ Invoke-IMSafe { Save-IMCompare 'Html' } })
    $c.CmpSaveCsv.Add_Click({ Invoke-IMSafe { Save-IMCompare 'Csv' } })
}

function Show-IMComparePanel {
    $p = Show-IMPanel 'ComparePanel'
    $c = $p.C
    if (-not $c.CmpRef.Text) { $c.CmpRef.Text = $script:UI.LastExportPath ?? (Get-IMSetting 'LastImportPath') }
    $c.CmpOnlyType.IsEnabled = [bool]$script:UI.CurrentType
    $c.CmpOnlyType.IsChecked = [bool]$script:UI.CurrentType
    $c.CmpOnlyType.Content = if ($script:UI.CurrentType) { "Only $($script:UI.CurrentType.Title)" } else { 'Only the current object type' }
    $c.CmpModeTenant.IsEnabled = [bool](Get-IMConnection)
    if (-not (Get-IMConnection)) { $c.CmpModeExports.IsChecked = $true }
}

function Start-IMCompareRun {
    $c = $script:UI.Panels.ComparePanel.C
    $a = @{ Ref = $c.CmpRef.Text.Trim(); Diff = $c.CmpDiff.Text.Trim(); Live = [bool]$c.CmpModeTenant.IsChecked; Ignore = [bool]$c.CmpIgnoreAssign.IsChecked
        Types = if ($c.CmpOnlyType.IsChecked -and $script:UI.CurrentType) { @($script:UI.CurrentType.Id) } else { @('*') } }
    if (-not (Test-Path -LiteralPath $a.Ref)) { Show-IMToast -Title 'Reference folder not found' -Kind Warning; return }
    if (-not $a.Live -and -not (Test-Path -LiteralPath $a.Diff)) { Show-IMToast -Title 'Folder to compare not found' -Kind Warning; return }
    $c.CmpRun.IsEnabled = $false
    $c.CmpSummary.Text = 'Comparing...'
    $script:UI.CompareLabels = @{ Ref = (Split-Path $a.Ref -Leaf); Diff = $(if ($a.Live) { (Get-IMConnection).Organization } else { Split-Path $a.Diff -Leaf }) }
    Start-IMJob -Name 'Comparing' -Foreground -Arguments $a -Script {
        param($A, $Progress)
        if ($A.Live) { Compare-IMObjects -ReferencePath $A.Ref -ObjectType $A.Types -IgnoreAssignments:$A.Ignore -Progress $Progress }
        else { Compare-IMExports -ReferencePath $A.Ref -DifferencePath $A.Diff -ObjectType $A.Types -IgnoreAssignments:$A.Ignore -Progress $Progress }
    } -OnComplete {
        param($r, $err, $job)
        $c = $script:UI.Panels.ComparePanel.C
        $c.CmpRun.IsEnabled = $true
        if ($err) { $c.CmpSummary.Text = $err; return }
        $labels = @{ Identical = 'Identical'; Different = 'Changed'; OnlyInReference = 'Missing'; OnlyInDifference = 'Added' }
        $script:UI.CompareResult = @(foreach ($x in @($r)) { if ($x) { $x | Add-Member -NotePropertyName StatusText -NotePropertyValue $labels[$x.Status] -Force -PassThru } })
        $res = $script:UI.CompareResult
        $c.CmpSummary.Text = "{0} compared: {1} changed, {2} missing, {3} added, {4} identical." -f $res.Count, @($res | Where-Object Status -eq 'Different').Count, @($res | Where-Object Status -eq 'OnlyInReference').Count, @($res | Where-Object Status -eq 'OnlyInDifference').Count, @($res | Where-Object Status -eq 'Identical').Count
        $c.CmpDiffGrid.Columns[1].Header = $script:UI.CompareLabels.Ref
        $c.CmpDiffGrid.Columns[2].Header = $script:UI.CompareLabels.Diff
        $c.CmpSaveHtml.IsEnabled = $true; $c.CmpSaveCsv.IsEnabled = $true
        Update-IMCompareView
    } | Out-Null
}

function Update-IMCompareView {
    $c = $script:UI.Panels.ComparePanel.C
    $all = @($script:UI.CompareResult)
    $c.CmpGrid.ItemsSource = if ($c.CmpShowAll.IsChecked) { $all } else { @($all | Where-Object Status -ne 'Identical') }
}

function Save-IMCompare {
    param([string]$Format)
    $d = [Microsoft.Win32.SaveFileDialog]::new()
    $d.FileName = "Compare_$(Get-Date -Format 'yyyyMMdd_HHmm').$($Format.ToLower())"
    $d.Filter = if ($Format -eq 'Html') { 'HTML (*.html)|*.html' } else { 'CSV (*.csv)|*.csv' }
    if (-not $d.ShowDialog()) { return }
    $path = Export-IMCompareReport -Result $script:UI.CompareResult -Path $d.FileName -Format $Format -ReferenceLabel $script:UI.CompareLabels.Ref -DifferenceLabel $script:UI.CompareLabels.Diff
    Show-IMToast -Title 'Report saved' -Text $path -ActionText 'Open' -Action { Open-IMPath $script:UI.LastSavedFile }
    $script:UI.LastSavedFile = $path
}
#endregion

#region Documentation panel
function Initialize-IMDocsPanel {
    param($p)
    $c = $p.C
    $c.DocClose.Add_Click({ Hide-IMPanel }); $c.DocCancel.Add_Click({ Hide-IMPanel })
    $c.DocLive.Add_Checked({ $script:UI.Panels.DocsPanel.C.DocPathRow.Visibility = 'Collapsed' })
    $c.DocExport.Add_Checked({ $script:UI.Panels.DocsPanel.C.DocPathRow.Visibility = 'Visible' })
    $c.DocPathBrowse.Add_Click({ Invoke-IMSafe { $f = Select-IMFolder 'Export folder' $script:UI.Panels.DocsPanel.C.DocPath.Text; if ($f) { $script:UI.Panels.DocsPanel.C.DocPath.Text = $f } } })
    $c.DocOutBrowse.Add_Click({ Invoke-IMSafe { $f = Select-IMFolder 'Save documentation to' $script:UI.Panels.DocsPanel.C.DocOut.Text; if ($f) { $script:UI.Panels.DocsPanel.C.DocOut.Text = $f } } })
    $c.DocStart.Add_Click({ Invoke-IMSafe { Start-IMDocsRun } })
}

function Show-IMDocsPanel {
    $p = Show-IMPanel 'DocsPanel'
    $c = $p.C
    $connected = [bool](Get-IMConnection)
    $c.DocLive.IsEnabled = $connected
    if (-not $connected) { $c.DocExport.IsChecked = $true }
    if (-not $c.DocPath.Text) { $c.DocPath.Text = $script:UI.LastExportPath ?? (Get-IMSetting 'LastImportPath') }
    if (-not $c.DocOut.Text) { $c.DocOut.Text = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'IntuneManager Documentation' }
    $c.DocOnlyType.IsEnabled = [bool]$script:UI.CurrentType
    $c.DocOnlyType.IsChecked = [bool]$script:UI.CurrentType
    $c.DocOnlyType.Content = if ($script:UI.CurrentType) { "Only $($script:UI.CurrentType.Title)" } else { 'Only the current object type' }
    $c.DocResolve.IsEnabled = $connected
}

function Start-IMDocsRun {
    $c = $script:UI.Panels.DocsPanel.C
    $fmt = foreach ($f in 'Html', 'Word', 'Markdown', 'Csv', 'Json') { if ($c["DocFmt$f"].IsChecked) { $f } }
    $a = @{ Live = [bool]$c.DocLive.IsChecked; Path = $c.DocPath.Text.Trim(); Out = $c.DocOut.Text.Trim(); Format = $fmt; NoResolve = -not $c.DocResolve.IsChecked -or -not (Get-IMConnection)
        Types = if ($c.DocOnlyType.IsChecked -and $script:UI.CurrentType) { @($script:UI.CurrentType.Id) } else { @('*') } }
    if (-not $a.Live -and -not (Test-Path -LiteralPath $a.Path)) { Show-IMToast -Title 'Export folder not found' -Kind Warning; return }
    if (-not $a.Out) { Show-IMToast -Title 'Choose where to save' -Kind Warning; return }
    $open = [bool]$c.DocOpen.IsChecked
    Hide-IMPanel
    Start-IMJob -Name 'Creating documentation' -Foreground -Arguments $a -Context @{ Open = $open } -Script {
        param($A, $Progress)
        $p = @{ Format = $A.Format; OutputPath = $A.Out; ObjectType = $A.Types; NoNameResolution = $A.NoResolve; Progress = $Progress }
        if ($A.Live) { $p.Live = $true } else { $p.Path = $A.Path }
        New-IMDocumentation @p
    } -OnComplete {
        param($r, $err, $job)
        if ($err) { Show-IMToast -Title 'Documentation failed' -Text $err -Kind Error; return }
        $script:UI.LastSavedFile = [string]$r
        Add-IMRecent -Action 'Document' -Message ([IO.Path]::GetFileName($r)) -Report $r
        if ($job.Context.Open) { Open-IMPath $r }
        Show-IMToast -Title 'Documentation created' -Text $r -ActionText 'Show in folder' -Action { Open-IMPath $script:UI.LastSavedFile -Select }
    } | Out-Null
}
#endregion

#region Settings panel
function Initialize-IMSettingsPanel {
    param($p)
    $c = $p.C
    $c.SetGraphVer.ItemsSource = @('beta', 'v1.0')
    $c.SetLogLevel.ItemsSource = @('Debug', 'Info', 'Warning', 'Error')
    $c.SetClose.Add_Click({ Hide-IMPanel }); $c.SetCancel.Add_Click({ Hide-IMPanel })
    $c.SetDark.Add_Checked({ Set-IMTheme 'Dark' }); $c.SetLight.Add_Checked({ Set-IMTheme 'Light' })
    $c.SetExportBrowse.Add_Click({ Invoke-IMSafe { $f = Select-IMFolder 'Default export folder'; if ($f) { $script:UI.Panels.SettingsPanel.C.SetExportRoot.Text = $f } } })
    $c.SetLogBrowse.Add_Click({ Invoke-IMSafe { $f = Select-IMFolder 'Log folder'; if ($f) { $script:UI.Panels.SettingsPanel.C.SetLogDir.Text = $f } } })
    $c.SetSave.Add_Click({ Invoke-IMSafe { Save-IMSettingsPanel } })
}

function Show-IMSettingsPanel {
    $p = Show-IMPanel 'SettingsPanel'
    $c = $p.C
    $s = Get-IMSettings
    if ($script:UI.Theme -eq 'Light') { $c.SetLight.IsChecked = $true } else { $c.SetDark.IsChecked = $true }
    $c.SetGraphVer.SelectedItem = $s.GraphApiVersion
    $c.SetRetries.Text = [string]$s.MaxRetries
    $c.SetTimeout.Text = [string]$s.RequestTimeoutSeconds
    $c.SetExportRoot.Text = $s.ExportRoot
    $c.SetContinue.IsChecked = [bool]$s.ContinueOnError
    $c.SetSuffix.Text = $s.RenameSuffix
    $c.SetLogLevel.SelectedItem = $s.LogLevel
    $c.SetRetention.Text = [string]$s.LogRetentionDays
    $c.SetLogDir.Text = if ($s.LogDirectory) { $s.LogDirectory } else { (Get-IMLogState).Directory }
}

function Save-IMSettingsPanel {
    $c = $script:UI.Panels.SettingsPanel.C
    $int = { param($t, $min, $max, $name) $v = 0; if (-not [int]::TryParse($t, [ref]$v) -or $v -lt $min -or $v -gt $max) { throw "$name must be a number between $min and $max." }; $v }
    $retries = & $int $c.SetRetries.Text 0 15 'Retries'
    $timeout = & $int $c.SetTimeout.Text 10 1800 'Timeout'
    $retention = & $int $c.SetRetention.Text 1 3650 'Log retention'
    Set-IMSetting 'Theme' $script:UI.Theme -NoSave
    Set-IMSetting 'GraphApiVersion' ([string]$c.SetGraphVer.SelectedItem) -NoSave
    Set-IMSetting 'MaxRetries' $retries -NoSave
    Set-IMSetting 'RequestTimeoutSeconds' $timeout -NoSave
    Set-IMSetting 'ExportRoot' $c.SetExportRoot.Text.Trim() -NoSave
    Set-IMSetting 'ContinueOnError' ([bool]$c.SetContinue.IsChecked) -NoSave
    Set-IMSetting 'RenameSuffix' $c.SetSuffix.Text -NoSave
    Set-IMSetting 'LogLevel' ([string]$c.SetLogLevel.SelectedItem) -NoSave
    Set-IMSetting 'LogRetentionDays' $retention -NoSave
    $dir = $c.SetLogDir.Text.Trim()
    Set-IMSetting 'LogDirectory' $(if ($dir -eq (Get-IMAppDataPath 'Logs')) { '' } else { $dir })
    Initialize-IMLogging -Directory $(if ($dir) { $dir } else { Get-IMAppDataPath 'Logs' }) -MinimumLevel (Get-IMSetting 'LogLevel') -RetentionDays $retention -NoConsole
    Hide-IMPanel
    Show-IMToast -Title 'Settings saved'
}
#endregion

#region Main window
function Show-IMApp {
    <#
    .SYNOPSIS
    Starts the IntuneManager desktop app (Windows, PowerShell 7).
    #>
    [CmdletBinding()]
    param()
    if (-not $script:IMIsWindows) { throw 'The desktop app needs Windows. On other platforms use the cmdlets (Get-Command -Module IntuneManager).' }
    if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') { throw 'The app must run in an STA thread. Start it with Start-IntuneManager.cmd or: pwsh -STA -File Start-IntuneManager.ps1' }
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml, System.Windows.Forms

    $settings = Get-IMSettings
    $logDir = if ($settings.LogDirectory) { $settings.LogDirectory } else { Get-IMAppDataPath 'Logs' }
    Initialize-IMLogging -Directory $logDir -MinimumLevel $settings.LogLevel -RetentionDays $settings.LogRetentionDays -NoConsole

    $app = [System.Windows.Application]::Current
    if (-not $app) { $app = [System.Windows.Application]::new(); $app.ShutdownMode = 'OnMainWindowClose' }
    $app.Resources.MergedDictionaries.Add([Windows.Markup.XamlReader]::Parse([IO.File]::ReadAllText((Join-Path $script:IMModuleRoot 'UI/Theme.xaml'))))
    $app.add_DispatcherUnhandledException({
        param($s, $e)
        Write-IMLog -Level Error -Category 'UI' -Message "Unhandled UI error: $($e.Exception.Message)" -ErrorRecord $e.Exception
        Show-IMToast -Title 'Unexpected error' -Text $e.Exception.Message -Kind Error
        $e.Handled = $true
    })

    $main = Import-IMXaml (Join-Path $script:IMModuleRoot 'UI/MainWindow.xaml')
    $script:UI = @{
        Window = $main.Root; C = $main.C; Panels = @{}; Theme = 'Dark'; Jobs = $null; Pool = $null; ForegroundJob = $null
        Rows = [Collections.ObjectModel.ObservableCollection[object]]::new()
        LogRows = [Collections.ObjectModel.ObservableCollection[object]]::new(); AllLogs = [Collections.Generic.List[object]]::new(); LogFilter = 'All'
        ObjectCache = @{}; CurrentType = $null; OpenPanel = $null
    }
    $c = $script:UI.C
    $w = $script:UI.Window
    $w.Title = "IntuneManager $script:IMToolVersion"
    try { $w.Icon = [Windows.Media.Imaging.BitmapFrame]::Create([Uri]::new((Join-Path $script:IMModuleRoot 'UI/IntuneManager.ico'))) } catch { }
    Set-IMTheme $(if ($settings.Theme -eq 'Light') { 'Light' } else { 'Dark' })
    Initialize-IMJobPool

    $c.ObjectGrid.ItemsSource = $script:UI.Rows
    $c.LogGrid.ItemsSource = $script:UI.LogRows
    [Windows.Data.CollectionViewSource]::GetDefaultView($script:UI.Rows).Filter = [Predicate[object]]{
        param($r)
        $q = $script:UI.C.ObjSearch.Text
        -not $q -or $r.Name -like "*$q*" -or $r.Kind -like "*$q*" -or $r.Description -like "*$q*" -or $r.Id -eq $q
    }

    # Window chrome
    $c.MinButton.Add_Click({ $script:UI.Window.WindowState = 'Minimized' })
    $c.MaxButton.Add_Click({ $script:UI.Window.WindowState = if ($script:UI.Window.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' } })
    $c.CloseButton.Add_Click({ $script:UI.Window.Close() })
    $w.Add_StateChanged({
        $max = $script:UI.Window.WindowState -eq 'Maximized'
        $script:UI.C.RootGrid.Margin = if ($max) { [Windows.Thickness]::new(7) } else { [Windows.Thickness]::new(0) }
        $script:UI.C.MaxButton.Content = [string][char]$(if ($max) { 0xE923 } else { 0xE922 })
    })
    $w.Add_Closing({
        param($s, $e)
        if ($script:UI.ForegroundJob) {
            $r = [System.Windows.MessageBox]::Show('An operation is still running. Cancel it and close?', 'IntuneManager', 'YesNo', 'Warning')
            if ($r -ne 'Yes') { $e.Cancel = $true; return }
            $script:UI.ForegroundJob.Progress.CancelRequested = $true
        }
        Save-IMSettings
        Write-IMLog -Category 'Session' -Message 'Application closed'
    })
    $w.Add_KeyDown({
        param($s, $e)
        Invoke-IMSafe {
            $ctrl = [Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Control
            if ($e.Key -eq 'Escape' -and $script:UI.OpenPanel -and -not $script:UI.ForegroundJob) { Hide-IMPanel; $e.Handled = $true }
            elseif ($e.Key -eq 'F5' -and $script:UI.CurrentType -and (Get-IMConnection)) { Show-IMObjectType $script:UI.CurrentType -Refresh; $e.Handled = $true }
            elseif ($ctrl -and $e.Key -eq 'E' -and (Get-IMConnection)) { Show-IMExportPanel -FromObjectsPage:([bool]$script:UI.CurrentType); $e.Handled = $true }
            elseif ($ctrl -and $e.Key -eq 'I' -and (Get-IMConnection)) { Show-IMImportPanel -TypeId $script:UI.CurrentType.Id; $e.Handled = $true }
            elseif ($ctrl -and $e.Key -eq 'F' -and $script:UI.CurrentType) { $script:UI.C.ObjSearch.Focus() | Out-Null; $e.Handled = $true }
        }
    })

    # Top bar
    $c.TenantButton.Add_Click({ Invoke-IMSafe { Show-IMConnectPanel } })
    $c.ThemeButton.Add_Click({ Invoke-IMSafe { Set-IMTheme $(if ($script:UI.Theme -eq 'Dark') { 'Light' } else { 'Dark' }); Set-IMSetting 'Theme' $script:UI.Theme } })
    $c.SettingsButton.Add_Click({ Invoke-IMSafe { Show-IMSettingsPanel } })

    # Navigation
    $c.HomeButton.Add_Click({ Invoke-IMSafe { Show-IMHome } })
    $c.NavFilter.Add_TextChanged({ Invoke-IMSafe { Update-IMNavigation } })
    $c.NavList.Add_SelectionChanged({ Invoke-IMSafe {
        if ($script:UI.NavUpdating) { return }
        $item = $script:UI.C.NavList.SelectedItem
        if ($item -and -not $item.IsHeader) { Show-IMObjectType $item.Tag }
    } })

    # Home
    $c.HomeConnectButton.Add_Click({ Invoke-IMSafe { Show-IMConnectPanel } })
    $c.HomeSetupButton.Add_Click({ Invoke-IMSafe { Show-IMConnectPanel -Setup } })
    $c.HomeProfiles.AddHandler([Windows.Controls.Button]::ClickEvent, [Windows.RoutedEventHandler]{
        param($s, $e)
        Invoke-IMSafe { $id = $e.OriginalSource.Tag; if ($id) { Connect-IMProfileAsync -ProfileId $id } }
    })
    $c.TileExport.Add_Click({ Invoke-IMSafe { Show-IMExportPanel } })
    $c.TileImport.Add_Click({ Invoke-IMSafe { Show-IMImportPanel } })
    $c.TileCompare.Add_Click({ Invoke-IMSafe { Show-IMComparePanel } })
    $c.TileDocs.Add_Click({ Invoke-IMSafe { Show-IMDocsPanel } })
    $c.OpenReportsButton.Add_Click({ Invoke-IMSafe { Open-IMPath (Join-Path (Get-IMLogState).Directory 'Reports') } })
    $c.RecentGrid.Add_MouseDoubleClick({ Invoke-IMSafe {
        $f = $script:UI.C.RecentGrid.SelectedItem.File
        if ($f -and (Test-Path -LiteralPath $f)) { if ($f -like '*.json') { $csv = [IO.Path]::ChangeExtension($f, '.csv'); if (Test-Path -LiteralPath $csv) { $f = $csv } }; Open-IMPath $f }
    } })

    # Objects page
    $c.ObjRefresh.Add_Click({ Invoke-IMSafe { Show-IMObjectType $script:UI.CurrentType -Refresh } })
    $c.ObjSearch.Add_TextChanged({ Invoke-IMSafe { [Windows.Data.CollectionViewSource]::GetDefaultView($script:UI.Rows).Refresh() } })
    $c.ObjSelectAll.Add_Click({ Invoke-IMSafe {
        $on = [bool]$script:UI.C.ObjSelectAll.IsChecked
        foreach ($r in [Windows.Data.CollectionViewSource]::GetDefaultView($script:UI.Rows)) { $r.Selected = $on }
    } })
    $c.ObjectGrid.Add_SelectionChanged({ Invoke-IMSafe {
        $g = $script:UI.C.ObjectGrid
        if ($g.SelectedItems.Count -eq 1) { Show-IMDetail $g.SelectedItem }
    } })
    $c.DetailClose.Add_Click({ $script:UI.C.DetailPane.Visibility = 'Collapsed' })
    $c.DetailCopyJson.Add_Click({ Invoke-IMSafe { if ($script:UI.C.DetailJson.Text) { [System.Windows.Clipboard]::SetText($script:UI.C.DetailJson.Text); Show-IMToast -Title 'JSON copied' } } })
    $c.DetailSaveJson.Add_Click({ Invoke-IMSafe {
        $d = [Microsoft.Win32.SaveFileDialog]::new(); $d.Filter = 'JSON (*.json)|*.json'; $d.FileName = (Get-IMSafeFileName $script:UI.C.DetailTitle.Text) + '.json'
        if ($d.ShowDialog()) { [IO.File]::WriteAllText($d.FileName, $script:UI.C.DetailJson.Text, [Text.UTF8Encoding]::new($false)); Show-IMToast -Title 'Saved' -Text $d.FileName }
    } })
    $c.DetailPortal.Add_Click({ Invoke-IMSafe { Start-Process ((Get-IMConnectionState).PortalUrl ?? 'https://intune.microsoft.com') } })
    $c.ObjExport.Add_Click({ Invoke-IMSafe { Show-IMExportPanel -FromObjectsPage } })
    $c.ObjImport.Add_Click({ Invoke-IMSafe { Show-IMImportPanel -TypeId $script:UI.CurrentType.Id } })
    $c.ObjCompare.Add_Click({ Invoke-IMSafe { Show-IMComparePanel } })
    $c.ObjDocs.Add_Click({ Invoke-IMSafe { Show-IMDocsPanel } })
    $c.ObjCopy.Add_Click({ Invoke-IMSafe {
        $sel = @(Get-IMSelectedRows)
        if ($sel.Count -ne 1) { Show-IMToast -Title 'Select one object to copy' -Kind Info; return }
        Show-IMConfirm -Title "Copy '$($sel[0].Name)'" -Text 'Creates a copy with the same settings and scope tags. Assignments are not copied.' -OkText 'Copy' -InputLabel 'Name of the copy' -InputDefault "$($sel[0].Name) - Copy" -Context @{ Row = $sel[0]; Type = $script:UI.CurrentType } -OnOk {
            param($name, $ctx)
            if (-not $name.Trim()) { Show-IMToast -Title 'Enter a name' -Kind Warning; return }
            Start-IMJob -Name "Copying $($ctx.Row.Name)" -Foreground -Arguments @{ Type = $ctx.Type.Id; Item = $ctx.Row.Tag; Name = $name.Trim() } -Context $ctx -Script {
                param($A, $Progress) New-IMObjectCopy -Type $A.Type -Item $A.Item -NewName $A.Name
            } -OnComplete {
                param($r, $err, $job)
                if ($err) { Show-IMToast -Title 'Copy failed' -Text $err -Kind Error; return }
                Show-IMToast -Title 'Copy created' -Text $r.Name
                Show-IMObjectType $job.Context.Type -Refresh
            } | Out-Null
        }
    } })
    $c.ObjDelete.Add_Click({ Invoke-IMSafe {
        $sel = @(Get-IMSelectedRows)
        if (-not $sel.Count) { Show-IMToast -Title 'Select the objects to delete' -Kind Info; return }
        $names = (($sel | Select-Object -First 6 | ForEach-Object { "• $($_.Name)" }) -join "`n") + $(if ($sel.Count -gt 6) { "`n• ... and $($sel.Count - 6) more" })
        Show-IMConfirm -Title "Delete $($sel.Count) object(s) from $((Get-IMConnection).Organization)?" -Text "$names`n`nThis cannot be undone. Consider exporting them first." -OkText 'Delete' -Danger `
            -InputLabel 'Type DELETE to confirm' -RequireText 'DELETE' -Context @{ Items = @($sel.Tag); Type = $script:UI.CurrentType } -OnOk {
            param($t, $ctx)
            Start-IMJob -Name 'Deleting' -Foreground -Arguments @{ Type = $ctx.Type.Id; Items = $ctx.Items } -Context $ctx -Script {
                param($A, $Progress) Remove-IMObjects -Type $A.Type -Items $A.Items -Progress $Progress
            } -OnComplete {
                param($r, $err, $job)
                if ($err) { Show-IMToast -Title 'Delete failed' -Text $err -Kind Error; return }
                $msg = Format-IMSummary $r
                Add-IMRecent -Action 'Delete' -Message $msg -Report $r.Report
                Show-IMToast -Title 'Delete finished' -Text $msg -Kind $(if ($r.Failed) { 'Warning' } else { 'Success' })
                Show-IMObjectType $job.Context.Type -Refresh
            } | Out-Null
        }
    } })

    # Operation bar, log panel, toast
    $c.OpCancel.Add_Click({ Invoke-IMSafe { if ($script:UI.ForegroundJob) { $script:UI.ForegroundJob.Progress.CancelRequested = $true; $script:UI.C.OpCancel.IsEnabled = $false; $script:UI.C.OpStatus.Text = 'Cancelling after the current object...' } } })
    $c.LogToggle.Add_Click({
        $lp = $script:UI.C.LogPanel
        $lp.Visibility = if ($lp.Visibility -eq 'Visible') { 'Collapsed' } else { 'Visible' }
        $script:UI.C.LogToggle.Content = if ($lp.Visibility -eq 'Visible') { 'Hide log' } else { 'Show log' }
        Set-IMSetting 'ShowLogPanel' ($lp.Visibility -eq 'Visible')
    })
    if (-not $settings.ShowLogPanel) { $c.LogPanel.Visibility = 'Collapsed'; $c.LogToggle.Content = 'Show log' }
    $c.LogAll.Add_Checked({ $script:UI.LogFilter = 'All'; Update-IMLogView })
    $c.LogWarn.Add_Checked({ $script:UI.LogFilter = 'Warning'; Update-IMLogView })
    $c.LogErr.Add_Checked({ $script:UI.LogFilter = 'Error'; Update-IMLogView })
    $c.LogClear.Add_Click({ $script:UI.LogRows.Clear(); $script:UI.AllLogs.Clear() })
    $c.LogOpen.Add_Click({ Invoke-IMSafe { Open-IMPath (Get-IMLogState).Directory } })
    $c.LogCopy.Add_Click({ Invoke-IMSafe {
        $items = @($script:UI.C.LogGrid.SelectedItems); if (-not $items.Count) { $items = @($script:UI.LogRows) }
        [System.Windows.Clipboard]::SetText((($items | ForEach-Object { "$($_.Time) [$($_.Level)] [$($_.Category)] $($_.Message)$(if ($_.Detail) { " | $($_.Detail -replace "`n", ' ')" })" }) -join "`r`n"))
        Show-IMToast -Title "$($items.Count) log line(s) copied"
    } })
    $c.ToastAction.Add_Click({ Invoke-IMSafe { $a = $script:UI.ToastAction; $script:UI.C.Toast.Visibility = 'Collapsed'; if ($a) { & $a } } })
    $c.Toast.Add_MouseLeftButtonUp({ $script:UI.C.Toast.Visibility = 'Collapsed' })

    # Timer
    $timer = [Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds(150)
    $timer.Add_Tick({ try { Invoke-IMTick } catch { } })
    $timer.Start()
    $script:UI.Timer = $timer

    Update-IMNavigation
    Update-IMConnectionView
    Show-IMHome
    Write-IMLog -Category 'Session' -Message "IntuneManager $script:IMToolVersion started"

    # Reconnect to the last used profile automatically
    $last = Get-IMSetting 'LastProfile'
    if ($last -and (Get-IMConnectionProfile -Name $last)) { $w.Add_ContentRendered({ Invoke-IMSafe { if (-not (Get-IMConnection)) { Connect-IMProfileAsync -ProfileId (Get-IMSetting 'LastProfile') } } }) }

    [void]$app.Run($w)
    $timer.Stop()
    try { $script:UI.Pool.Close(); $script:UI.Pool.Dispose() } catch { }
}
#endregion
