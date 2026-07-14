# 设计说明

## 数据不变量

1. 在迁移切换前，源目录和目标目录都必须通过复制验证。
2. 在回滚切换前，目标目录必须已复制到新的恢复目录并通过验证。
3. 任何失败都至少保留一份完整数据；脚本不根据猜测删除目标或备份。
4. 删除 `.bak` 必须有路径匹配的迁移清单、显式确认和 `ShouldProcess` 批准。
5. 清单存储于 `<DestinationRoot>\.AppDataMigrateState`，不写入迁移后的用户目录。

## 状态机

```text
Preflight -> Copying -> Verified -> SourceBackedUp -> Linked
               |          |             |
               +--------> Failed <------+

Linked -> RollbackCopying -> RollbackVerified -> RolledBack
                 |                 |
                 +-> RollbackFailed+
```

`Failed` 和 `RollbackFailed` 是保全状态，不是自动恢复的许可。使用 `-Status` 检查数据位置，再决定人工恢复或后续专用恢复命令。

## 清单

每个源路径按 SHA-256 标识生成一个 JSON 清单，记录源、目标、备份、状态、日志路径和时间。所有回滚、清理操作都必须验证清单中的三个路径与本次命令完全一致（忽略大小写）。

清理开始前会先将清单置为 `BackupCleaning`，然后才删除 `.bak`；若中断，状态与文件是否存在可帮助定位结果。计划任务注册与清单写入也采用补偿：清单写入失败时注销刚创建的任务。

## 复制与验证

复制采用 `robocopy /E /COPY:DAT /DCOPY:DAT /XJ /R:1 /W:1`。退出码 0–7 被视为非致命结果，8 及以上为失败。默认验证比较文件数、总字节数，以及每个源文件在目标中的相对路径、大小和最后写入时间；传入 `-VerifyHash` 会逐文件计算 SHA-256，而不会把文件内容整体读入内存。

## 集成验证

GitHub Actions 的 Windows runner 在 `C:\AppDataMigrateToolTests` 中运行隔离的真实 NTFS 集成测试。它验证 Junction 创建、目标数据可见、迁移后新增文件在回滚后仍存在、`.bak` 与目标默认保留，以及清理仅删除清单绑定的 `.bak`。测试使用固定的专用根目录，并在 `finally` 中清理它；不得将真实用户路径用于此测试。

集成测试还使用隐藏的 `-FaultInjectionStage BeforeJunction` 钩子模拟 Junction 创建前失败，验证脚本会恢复源目录并保留复制目标。该参数仅用于自动化测试，正常操作不得使用。

集成测试还会独占锁定一个测试文件并尝试迁移，验证 robocopy 失败时源目录和锁定文件仍完整保留。这是错误路径的保护性测试，不会重试或删除真实用户文件。
