@echo off
setlocal

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Please run this script as Administrator.
    echo Right-click this file and choose "Run as administrator".
    echo.
    pause
    exit /b 1
)

set /p "SourcePath=Directory to roll back, for example C:\Users\YourName\AppData\Local: "

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0AppDataMigrate.ps1" -SourcePath "%SourcePath%" -Rollback
set "ExitCode=%errorlevel%"

echo.
if not "%ExitCode%"=="0" (
    echo Rollback failed. Exit code: %ExitCode%
    pause
    exit /b %ExitCode%
)

echo Rollback completed.
pause
exit /b 0
