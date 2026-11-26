@echo off
title PC Debloater
cd /d "%~dp0"

if not exist "%~dp0PC-Debloater.ps1" (
    echo.
    echo   Oops! PC-Debloater.ps1 is missing.
    echo.
    echo   You probably opened this straight from inside the .zip file.
    echo   Right-click the .zip, pick "Extract All", then open the new folder
    echo   and double-click "Run PC Debloater.bat" from there.
    echo.
    pause
    exit /b 1
)

echo Starting PC Debloater... click YES on the Windows pop-up.
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0PC-Debloater.ps1"
if errorlevel 1 (
    echo.
    echo   PC Debloater could not start. If you see a red error above,
    echo   take a screenshot and send it to the developer.
    echo.
    pause
)
