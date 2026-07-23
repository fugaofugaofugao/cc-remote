@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\install.ps1" -AddToPath
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" echo Install failed with exit code %RC%.
echo Press any key to close...
pause >nul
exit /b %RC%
