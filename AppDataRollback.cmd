@echo off
setlocal

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo 请以管理员身份运行此脚本。
    echo 请右键单击此文件并选择“以管理员身份运行”。
    echo.
    pause
    exit /b 1
)

set /p "SourcePath=请输入要回滚的目录，例如 C:\Users\YourName\AppData\Local: "

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0AppDataMigrate.ps1" -SourcePath "%SourcePath%" -Rollback
set "ExitCode=%errorlevel%"

echo.
if not "%ExitCode%"=="0" (
    echo 回滚失败。退出码: %ExitCode%
    pause
    exit /b %ExitCode%
)

echo 回滚完成。
pause
exit /b 0
