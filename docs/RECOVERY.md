# 恢复手册

不要在真实 AppData 有程序运行时迁移或回滚。先结束使用该目录的应用并另行备份重要数据。

## 查看状态

以管理员身份运行：

```powershell
.\AppDataMigrate.ps1 -SourcePath 'C:\Users\Alice\AppData\Local' -Status
```

该命令只读取状态，不修改数据。

## 迁移失败

不要删除目标目录或 `.bak`。运行 `-Status` 并检查目标根目录下 `.AppDataMigrateState` 中清单记录的状态和 robocopy 日志。

- `Copying` / `Failed`：源目录通常仍在；目标可能是不完整副本，应保留以便检查。
- `SourceBackedUp`：如果源路径缺失而 `.bak` 存在，先确认 `.bak` 完整，再把它重命名回源路径；不要删除目标。
- `Linked`：源路径是 Junction，目标是当前数据，`.bak` 是迁移前的副本。

## 正常回滚

```powershell
.\AppDataMigrate.ps1 -SourcePath 'C:\Users\Alice\AppData\Local' -Rollback
```

回滚会把 D 盘当前内容复制为 `C:\...\Local.restore-<timestamp>`，验证成功后删除 Junction，并把该恢复目录改回原路径。旧 `.bak` 与 D 盘目标都会保留，因此回滚后的空间占用会暂时增加。

## 清理备份

确认迁移或回滚后的应用正常、并完成独立备份后，才运行：

```powershell
.\AppDataMigrate.ps1 -SourcePath 'C:\Users\Alice\AppData\Local' -Cleanup
```

该命令只删除与清单匹配的 `.bak`，不会删除 D 盘目标。目标删除功能尚未开放。

如果迁移时显式使用了 `-ScheduleBackupCleanup`，计划任务会在两天后调用同一清理流程；任务创建失败不会影响已完成的迁移。需要保留备份时，可在 Windows 任务计划程序中删除名称以 `AppDataMigrateCleanup_` 开头且与该迁移清单匹配的任务。
