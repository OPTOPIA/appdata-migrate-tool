@echo off
REM 检查是否以管理员身份运行
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo 请以管理员身份运行此脚本！
    echo 右键点击此文件 -> 选择 "以管理员身份运行"
    echo.
    echo 说明：Windows 10/11 可能需要手动启用管理员选项
    pause
    exit /b
)

REM 提示用户输入要回滚的目录
set /p "SourcePath=请输入要回滚的目录路径 (例如: C:\Users\YourName\AppData\Local): "

REM 验证输入路径
if not exist "%SourcePath%" (
    echo ? 目录不存在: %SourcePath%
    echo 请确认路径是否正确（注意：不要包含末尾反斜杠）
    pause
    exit /b
)

REM 执行回滚脚本
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0AppDataMigrate.ps1" -SourcePath "%SourcePath%" -Rollback

REM 保持窗口打开，显示完成信息
echo.
echo ? 回滚流程已完成！请按任意键关闭窗口
pause