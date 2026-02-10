<#
AppDataMigrate.ps1
用途：
- 将 C 盘指定目录迁移至 D:\C_Data_Redirect
- 使用 NTFS Junction 保持路径不变
- 支持一键回滚
警告：
- 请勿迁移 Windows / Program Files
- ProgramData 为高风险目录
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$SourcePath,
    [switch]$Rollback
)

function Confirm-Action($msg) {
    Write-Host ""
    Write-Host $msg -ForegroundColor Yellow
    $ans = Read-Host "输入 Y 继续，N 取消"
    if ($ans -notin @("Y","y")) {
        Write-Host "? 用户取消，操作终止" -ForegroundColor Red
        exit 1
    }
}

# ====== 关键修复 1：管理员权限检查 ======
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "? 需要以管理员身份运行脚本！请右键选择 '以管理员身份运行'" -ForegroundColor Red
    exit 1
}

# ====== 修复 1：先检查路径存在再 Resolve-Path ======
if (-not (Test-Path $SourcePath)) {
    Write-Host "? 源目录不存在" -ForegroundColor Red
    exit 1
}
$SourcePath = (Resolve-Path $SourcePath).Path

# ====== 回滚模式处理 ======
if ($Rollback) {
    Write-Host "==== 回滚模式 ====" -ForegroundColor Cyan
    Write-Host "回滚目录：" $SourcePath

    # ====== 修复 2：必须先检查备份存在性 ======
    $BakPath = "$SourcePath.bak"
    
    # ? 修复点：先检查路径是否存在（避免 Get-Item 异常）
    if (-not (Test-Path $BakPath)) {
        Write-Host "? 备份路径不存在（$BakPath），无法回滚" -ForegroundColor Red
        exit 1
    }

    # ? 修复点：再验证 .bak 不是 Junction
    $bakItem = Get-Item $BakPath
    if ($bakItem.LinkType) {
        Write-Host "? 备份目录是 Junction（$BakPath），拒绝回滚（结构异常）" -ForegroundColor Red
        Write-Host "请手动清理 .bak 目录后重试" -ForegroundColor Yellow
        exit 1
    }

    # 检查是否是 junction
    $item = Get-Item $SourcePath
    if (-not $item.LinkType) {
        Write-Host "? 源目录不是 Junction（无法回滚）" -ForegroundColor Red
        Write-Host "请确认：您是否已正确迁移？" -ForegroundColor Yellow
        exit 1
    }

    Confirm-Action "确认回滚？这将删除 Junction 并恢复原始目录"

    # 删除 junction
    Remove-Item -Force -Recurse $SourcePath

    # 恢复原始目录
    Rename-Item $BakPath $SourcePath

    Write-Host "? 回滚成功！原始目录已恢复：$SourcePath" -ForegroundColor Green

    # ====== 新增：回滚后询问是否删除 D 盘数据 ======
    $relative = $SourcePath.Replace("C:\","")
    $TargetPath = Join-Path "D:\C_Data_Redirect" $relative

    if (Test-Path $TargetPath) {
        Confirm-Action "是否要删除 D 盘上的迁移数据（$TargetPath）？"
        Remove-Item -Recurse -Force $TargetPath
        Write-Host "? 已删除 D 盘数据：$TargetPath" -ForegroundColor Green
    } else {
        Write-Host "?? D 盘目标路径不存在（$TargetPath），无需删除" -ForegroundColor Cyan
    }

    exit 0
}

# ====== 原有迁移逻辑（从这里开始） ======
Write-Host "==== AppData 安全迁移脚本 ====" -ForegroundColor Cyan
Write-Host "源目录：" $SourcePath

# 1?? 基础校验（已包含路径存在性检查）
if (-not (Test-Path $SourcePath)) {
    Write-Host "? 源目录不存在" -ForegroundColor Red
    exit 1
}

# ====== 关键修复 2：验证源路径必须是目录 ======
if (-not (Test-Path $SourcePath -PathType Container)) {
    Write-Host "? 源路径不是目录（请提供文件夹路径）" -ForegroundColor Red
    exit 1
}

# ====== 关键修复 3：验证源路径必须在 C 盘 ======
if (-not $SourcePath.StartsWith("C:\", [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-Host "? 源路径必须位于 C 盘（如 C:\Users\...）" -ForegroundColor Red
    exit 1
}

# ====== 关键优化 1：系统目录检查 ======
$HardForbiddenDirs = @(
    "C:\Windows",
    "C:\Program Files",
    "C:\Program Files (x86)"
)
$StrongWarningDirs = @(
    "C:\ProgramData"
)

$sourcePathLower = $SourcePath.ToLower()

# 检查硬禁止目录（直接退出）
foreach ($dir in $HardForbiddenDirs) {
    $dirLower = $dir.ToLower()
    if ($sourcePathLower -like "$dirLower*") {
        Write-Host ""
        Write-Host "? 检测到硬禁止目录（$SourcePath）！" -ForegroundColor Red
        Write-Host "? 请勿迁移系统核心目录（Windows/Program Files）" -ForegroundColor Red
        Write-Host "? 操作已终止" -ForegroundColor Red
        exit 1
    }
}

# 检查强警告目录（三重确认）
foreach ($dir in $StrongWarningDirs) {
    $dirLower = $dir.ToLower()
    if ($sourcePathLower -like "$dirLower*") {
        Write-Host ""
        Write-Host "?? 检测到 ProgramData 目录（$SourcePath）！" -ForegroundColor Yellow
        Write-Host "?? ProgramData 包含系统服务配置（Defender/Docker/WSL等）" -ForegroundColor Red
        Write-Host "?? 迁移可能导致服务启动失败！" -ForegroundColor Red
        Write-Host "?? 请确认：您确定要迁移 ProgramData 吗？" -ForegroundColor Red
        $ans = Read-Host "输入 Y 确认，N 取消"
        if ($ans -notin @("Y","y")) { exit 1 }
        
        Write-Host "?? 请再次确认：您确定要迁移 ProgramData 吗？" -ForegroundColor Red
        $ans = Read-Host "输入 Y 确认，N 取消"
        if ($ans -notin @("Y","y")) { exit 1 }
        
        Write-Host "?? 最后一次确认：您确定要迁移 ProgramData 吗？" -ForegroundColor Red
        $ans = Read-Host "输入 Y 确认，N 取消"
        if ($ans -notin @("Y","y")) { exit 1 }
        
        Write-Host "? 已确认迁移 ProgramData（高风险操作）" -ForegroundColor Yellow
        break
    }
}

# ====== 原有代码（从这里开始不变） ======
$item = Get-Item $SourcePath
if ($item.LinkType) {
    Write-Host "? 源目录已经是 Junction / Link，拒绝操作" -ForegroundColor Red
    exit 1
}

# 2?? 计算目标路径
$relative = $SourcePath.Replace("C:\","")
$TargetPath = Join-Path "D:\C_Data_Redirect" $relative
$BakPath = "$SourcePath.bak"

Write-Host ""
Write-Host "? 迁移计划：" -ForegroundColor Green
Write-Host "C 盘：" $SourcePath
Write-Host "D 盘：" $TargetPath
Write-Host "备份：" $BakPath

Confirm-Action "确认以上迁移路径？"

# 3?? 创建目标目录
Confirm-Action "是否创建目标目录？"
New-Item -ItemType Directory -Force -Path $TargetPath | Out-Null

# 4?? 复制数据（路径含空格安全处理 + 返回码提示）
Confirm-Action "是否开始复制数据？（robocopy）"
robocopy "$SourcePath" "$TargetPath" /E /COPY:DAT /R:1 /W:1
if ($LASTEXITCODE -ge 8) {
    Write-Host "? robocopy 失败（返回码：$LASTEXITCODE）" -ForegroundColor Red
    exit 1
}

# 5?? 重命名源目录
Confirm-Action "是否将源目录重命名为 .bak？"
if (Test-Path $BakPath) {
    Write-Host "? 备份路径已存在（$BakPath），可能之前迁移未清理" -ForegroundColor Red
    Write-Host "请手动清理或重命名后重试" -ForegroundColor Yellow
    exit 1
}
Rename-Item $SourcePath (Split-Path $BakPath -Leaf)

# 6?? 创建 junction
Confirm-Action "是否创建 NTFS Junction？"
cmd /c mklink /J "$SourcePath" "$TargetPath"

# 7?? 验证
$link = (Get-Item $SourcePath).LinkType
if ($link -ne "Junction") {
    Write-Host "? Junction 验证失败" -ForegroundColor Red
    exit 1
}
Write-Host "? Junction 创建成功" -ForegroundColor Green
Write-Host "? 指向：$TargetPath" -ForegroundColor Green

# 8?? 创建 2 天后清理任务
Confirm-Action "是否创建 2 天后自动清理 .bak 的计划任务？"

$taskName = "CleanupBak_$(Get-Date -Format yyyyMMdd_HHmmss)"
$action = "Remove-Item -Recurse -Force `"$BakPath`""
$time = (Get-Date).AddDays(2)

schtasks /create /sc once /st $time.ToString("HH:mm") /sd $time.ToString("yyyy/MM/dd") /tn $taskName /tr "powershell -NoProfile -Command `"$action`"" /ru SYSTEM /f

Write-Host "? 已创建清理任务：$taskName（两天后执行）" -ForegroundColor Cyan
Write-Host "? 全流程完成" -ForegroundColor Green