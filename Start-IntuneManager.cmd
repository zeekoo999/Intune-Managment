@echo off
rem Starts IntuneManager with PowerShell 7 (pwsh). Install PowerShell 7 from https://aka.ms/powershell if needed.
where pwsh >nul 2>nul
if errorlevel 1 (
    echo PowerShell 7 ^(pwsh^) was not found. Install it from https://aka.ms/powershell and try again.
    pause
    exit /b 1
)
start "" pwsh -STA -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0Start-IntuneManager.ps1"
