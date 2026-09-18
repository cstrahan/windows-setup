@echo off
rem Entry point: runs bootstrap.ps1 regardless of the machine's PowerShell execution policy.
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0bootstrap.ps1" %*
exit /b %ERRORLEVEL%
