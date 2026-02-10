

# AppData 安全迁移工具（支持一键回滚）

一套用于 **将 C 盘 AppData / 任意用户目录安全迁移到 D 盘** 的 PowerShell 工具，  
采用 **先复制 → 备份 → Junction 重定向 → 延迟清理** 的方式，**可随时回滚**。    

> #### 【需自行甄别文件夹是否可迁移】

---

## ✨ 功能特点

- ✅ **自动创建 NTFS Junction**，对程序完全透明
- ✅ **源目录 `.bak` 备份**，**两天后自动清理**
- ✅ **一键回滚**：1 秒恢复原始状态
- ✅ **自动校验**：管理员权限、路径合法性、系统目录
- ✅ **安全增强**：回滚前验证 `.bak` 不是 Junction（防止嵌套崩溃）
- ✅ **日志支持**：robocopy 操作自动记录日志（排查问题神兵利器）

---

## 📁 文件结构

```text
AppDataMigrate/
├─ AppDataMigrate.ps1      # 主迁移 / 回滚脚本（核心）
├─ AppDataMigrate.cmd      # 迁移脚本
├─ AppDataRollback.cmd     # 回滚脚本
└─ README.md               
```

---

## 🚀 使用方法

### 一、迁移目录（推荐方式）
1. **双击** `AppDataMigrate.cmd`
2. 按提示输入**完整路径**（例如：`C:\Users\YourName\AppData\Local`）
   - ✅ 正确格式：`C:\Users\YourName\AppData\Local`
   - ❌ 错误格式：`C:\Users\YourName\AppData\Local\`（末尾反斜杠）
3. 按脚本提示 **逐条确认** 每一步操作

> ✅ 迁移后效果：
> - 原路径（`C:\...`）变为 Junction（指向 D 盘）
> - 实际数据已迁移到 `D:\C_Data_Redirect\...`
> - 程序无需重新配置

---

### 二、回滚目录（恢复到 C 盘）
1. **双击** `AppDataRollback.cmd`
2. 按提示输入**相同目录路径**（例如：`C:\Users\YourName\AppData\Local`）
3. 按脚本提示 **逐条确认** 回滚操作

> ✅ 回滚后效果：
> - 原路径恢复为原始目录（不再指向 D 盘）
> - 源目录（C 盘）恢复
> - **D 盘迁移数据可选删除**（脚本会询问是否删除）

---

## 📌 迁移规则说明

| 类型 | 规则 | 示例 |
|------|------|------|
| ✅ **允许迁移** | 仅限用户数据目录 | `C:\Users\*\AppData``C:\Users\*\Documents` |
| ❌ **禁止迁移** | 系统核心目录 | `C:\Windows``C:\Program Files``C:\ProgramData` |
| 📂 **目标路径** | 统一位于 D 盘 | `D:\C_Data_Redirect\Users\YourName\AppData\Local` |
| 🧹 **清理机制** | 源目录重命名为 `.bak`2 天后自动清理 | `C:\Users\...\AppData` → `C:\Users\...\AppData.bak` |

---

## ⚠️ 重要注意事项（必读）

1. **必须管理员身份运行**：双击 `.cmd` 文件时，系统会自动检查权限
   - 若无管理员权限，会提示 "请以管理员身份运行"
2. **不要在程序运行中迁移**：如浏览器、微信等正在使用的目录
3. **`.bak` 备份已存在** → 脚本会自动终止，避免覆盖
4. **系统目录禁止迁移**：脚本会直接退出，不给确认
5. **回滚前确保程序未运行**：避免文件占用导致失败
6. **回滚后 D 盘数据**：脚本会询问是否删除（默认保留，需手动确认）

---

## 📝 为什么这个工具安全？

| 安全机制 | 实现方式 | 优势 |
|----------|----------|------|
| **系统目录硬禁止** | 直接退出（不给确认） | 防止迁移 `C:\ProgramData` 导致系统崩溃 |
| **三重确认** | 仅对高风险目录（如 ProgramData） | 避免用户误操作 |
| **备份机制** | 源目录重命名为 `.bak` | 2 天后自动清理，避免空间浪费 |
| **回滚验证** | 验证 `.bak` 不是 Junction | 防止 "Junction → Junction" 嵌套地狱 |
| **日志支持** | robocopy 自动记录日志 | 未来排查问题神兵利器 |

---

## 💡 使用示例

### ✅ 正确迁移（用户数据）
```text
1. 双击 AppDataMigrate.cmd
2. 输入路径：C:\Users\John\AppData\Local
3. 确认所有提示 → 迁移完成
```

### ❌ 禁止迁移（系统目录）
```text
1. 双击 AppDataMigrate.cmd
2. 输入路径：C:\ProgramData
3. 脚本立即退出：❌ 检测到硬禁止目录（C:\ProgramData）！
```

### ✅ 安全回滚
```text
1. 双击 AppDataRollback.cmd
2. 输入路径：C:\Users\John\AppData\Local
3. 确认回滚 → 1 秒恢复原始目录
4. 脚本询问：是否删除 D 盘数据？（输入 Y 删除）
```

---

## 📌 免责声明

> 本工具仅用于个人数据迁移优化，**不建议用于系统目录**。  
> 使用前请确认已理解 NTFS Junction 行为，并自行承担使用风险。  

---

## 💡 最后建议

1. **先用测试目录验证**（如 `C:\TestAppData`）→ 再操作真实数据
2. **不要直接迁移 AppData** → 先用 `C:\Users\用户名\AppData\Local` 测试
3. **回滚后删除 D 盘数据** → 保留数据可选，但建议删除以避免混淆
4. **查看 robocopy 日志** → 迁移失败时查看 `C:\Users\用户名\AppData\Local\Temp\robocopy_*.log`
