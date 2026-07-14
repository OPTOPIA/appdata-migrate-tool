# AppData 安全迁移工具

在 Windows 上把 C 盘用户目录复制到指定的 NTFS 目标盘，并以 NTFS Junction 保持原路径可用的 PowerShell 工具。

## 安全模型

迁移按以下顺序执行：复制 → 验证 → 源目录改名为 `.bak` → 创建 Junction。每次迁移会在目标根目录的 `.AppDataMigrateState` 创建清单和 robocopy 日志，供状态查询、回滚和清理校验使用。

回滚不会直接把旧 `.bak` 覆盖回去：它先将 D 盘的当前数据复制到新的恢复目录并验证，再移除 Junction。因此迁移后新增或修改的数据不会因正常回滚而丢失。回滚完成后，旧 `.bak` 和 D 盘目标会保留，等待人工确认后清理。

## 要求

- Windows PowerShell 5.1 或更高版本
- 以管理员身份运行
- 源目录位于 C 盘，目标卷为 NTFS
- 迁移期间关闭正在使用该目录的程序

`C:\Windows`、`C:\Program Files`、`C:\Program Files (x86)`、`C:\ProgramData`、`C:\Users\Default` 和 `C:\Users\Public` 被禁止操作。

## 使用方式

双击入口：

- `AppDataMigrate.cmd`：迁移
- `AppDataRollback.cmd`：回滚

或在管理员 PowerShell 中运行：

```powershell
# 先预览（不执行修改）
.\AppDataMigrate.ps1 -SourcePath 'C:\Users\Alice\AppData\Local' -WhatIf

# 迁移到默认目标 D:\C_Data_Redirect
.\AppDataMigrate.ps1 -SourcePath 'C:\Users\Alice\AppData\Local'

# 使用逐文件 SHA-256 强校验（大型目录会更慢）
.\AppDataMigrate.ps1 -SourcePath 'C:\Users\Alice\AppData\Local' -VerifyHash

# 指定其他 NTFS 目标根目录；-NonInteractive 仅适用于已审阅的自动化任务
.\AppDataMigrate.ps1 -SourcePath 'C:\Users\Alice\AppData\Local' -DestinationRoot 'E:\RedirectedData' -NonInteractive

# 查看状态（只读）
.\AppDataMigrate.ps1 -SourcePath 'C:\Users\Alice\AppData\Local' -Status

# 无损回滚（保留 D 盘目标和 .bak）
.\AppDataMigrate.ps1 -SourcePath 'C:\Users\Alice\AppData\Local' -Rollback

# 在确认应用正常、完成独立备份后删除 .bak
.\AppDataMigrate.ps1 -SourcePath 'C:\Users\Alice\AppData\Local' -Cleanup

# 只取消已登记的计划清理，保留 .bak
.\AppDataMigrate.ps1 -SourcePath 'C:\Users\Alice\AppData\Local' -Cleanup -CancelBackupCleanup

# 明确选择在两天后自动清理 .bak（仍受清单校验约束）
.\AppDataMigrate.ps1 -SourcePath 'C:\Users\Alice\AppData\Local' -ScheduleBackupCleanup
```

## 目录映射

```text
C:\Users\Alice\AppData\Local
  -> D:\C_Data_Redirect\Users\Alice\AppData\Local

C:\Users\Alice\AppData\Local.bak
  -> 迁移前备份（默认保留）
```

## 限制与注意事项

- 当前复制的元数据为数据、属性和时间戳（`/COPY:DAT`）；不复制 ACL、所有者或审计信息。
- 默认验证检查文件相对路径、数量、大小和最后写入时间；传入 `-VerifyHash` 可增加逐文件 SHA-256 校验，但大型目录会更慢。
- 默认不自动删除 `.bak`。只有显式传入 `-ScheduleBackupCleanup` 才会创建两天后执行的清理任务；任务仍受清单校验，并在完成后注销。
- `-Cleanup -RemoveDestination` 当前会明确拒绝执行；D 盘目标必须人工保留，直到有可验证的目标清理方案。
- 不要把此工具用于系统目录，也不要在没有独立备份的情况下处理唯一数据。

详细设计见 [docs/DESIGN.md](docs/DESIGN.md)，异常恢复步骤见 [docs/RECOVERY.md](docs/RECOVERY.md)，后续路线见 [DEVELOPMENT_PLAN.md](DEVELOPMENT_PLAN.md)。

## 许可证

本项目采用 [Apache License 2.0](LICENSE)。

## 退出码

| 退出码 | 含义 |
| --- | --- |
| 0 | 成功或 `-WhatIf` 未执行 |
| 1 | 未分类错误 |
| 2 | 权限、路径或文件系统前置条件错误 |
| 3 | 工具或可用空间前置条件错误 |
| 4 | 迁移状态、清单或安全边界错误 |
| 5 | robocopy 失败 |
| 6 | 复制验证失败 |
| 7 | 用户取消 |
