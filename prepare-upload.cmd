@echo off
setlocal
rem Let Windows PowerShell initialize its own module paths when launched from PowerShell 7.
set "PSModulePath="
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0prepare-upload.ps1" %*
set "uploadExitCode=%ERRORLEVEL%"
echo.
pause
exit /b %uploadExitCode%
