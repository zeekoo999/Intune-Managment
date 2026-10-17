<#
.SYNOPSIS
Starts the IntuneManager desktop app.

.DESCRIPTION
Requires Windows and PowerShell 7.2 or later. Start with Start-IntuneManager.cmd, or:
    pwsh -STA -NoProfile -ExecutionPolicy Bypass -File .\Start-IntuneManager.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
try {
    if ($PSVersionTable.PSVersion -lt [version]'7.2') {
        throw "PowerShell 7.2 or later is required (this is $($PSVersionTable.PSVersion)). Install it from https://aka.ms/powershell and start Start-IntuneManager.cmd."
    }
    # Files downloaded from the internet are blocked by Windows; unblock this folder so the module can load
    if ($IsWindows) { Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -File | Unblock-File -ErrorAction SilentlyContinue }

    if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
        # WPF needs STA; restart ourselves in STA mode
        & (Join-Path $PSHOME 'pwsh.exe') -STA -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath
        return
    }
    Import-Module (Join-Path $PSScriptRoot 'IntuneManager.psd1') -Force
    Show-IMApp
}
catch {
    $msg = $_.Exception.Message
    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
        [System.Windows.MessageBox]::Show("IntuneManager could not start:`n`n$msg", 'IntuneManager', 'OK', 'Error') | Out-Null
    }
    catch { Write-Host "IntuneManager could not start: $msg" -ForegroundColor Red }
    $log = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'IntuneManager\startup-error.log'
    try { New-Item -ItemType Directory -Path (Split-Path $log) -Force | Out-Null; "$(Get-Date -Format o) $msg`n$($_.ScriptStackTrace)" | Add-Content -LiteralPath $log } catch { }
    exit 1
}
