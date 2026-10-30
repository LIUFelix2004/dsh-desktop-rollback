<div align="center">

# dsh-desktop-rollback

**安全地回退、锁定或诊断 Windows 版 DeepSeek Harness Desktop。**

[English](README.md) · 简体中文

![platform](https://img.shields.io/badge/platform-Windows%2010%2F11-0078D6)
![powershell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207%2B-5391FE)
![type](https://img.shields.io/badge/type-DSH%20skill-6E56CF)
![license](https://img.shields.io/badge/license-MIT-green)

</div>

---

## 为什么需要它

DeepSeek Harness（DSH）桌面版**没有应用内降级**：

- Electron 外壳设置了 `allowDowngrade = false`，应用内更新器永远不会装回旧版本；
- 更新源**只发布最新一版**，旧安装包的地址都是 404；
- 让 Agent 自己执行回退会把安装弄坏一半：它启动的任何进程都和应用在同一个 Windows **作业对象（job object）**里，脚本一杀掉应用，就会连同自己和刚启动的安装程序一起被杀掉。

这个 skill 给出一条验证过的路径：先诊断、再备份数据，然后生成一个**由你在资源管理器里双击运行**的回退脚本。这样重装过程在应用的进程树之外运行，能完整跑完。

## 功能

| | |
|---|---|
| 🔍 **只读诊断** | 列出实际运行的安装目录、真实版本（以 exe 为准，注册表可能滞后）、更新通道和更新源、已下载待安装的更新、磁盘上残留的旧安装包，以及 `$DSH_HOME` 的数据大小。输出 JSON。 |
| 🔐 **签名校验** | 安装包的 Authenticode 签名不是 `Valid` 就拒绝执行。 |
| 💾 **数据备份** | 用 `robocopy` 备份 `profiles` / `sessions` / `storages`（跳过 pnpm 的 `node_modules` 符号链接），并写一份带恢复命令的 `MANIFEST.txt`。 |
| 🖱️ **双击启动器** | 生成 `rollback-<版本>.cmd`：关闭应用，静默重装到**原有**目录，等 exe 版本对上后清掉新版本已下载的更新，再重新启动应用。 |
| 📝 **失败可读** | 每一步都写进 `rollback.log`，失败了能看出原因。 |
| 📚 **机制有文档** | [`references/mechanism.md`](references/mechanism.md) 记录了更新器的内部机制，以及所有试过但失败的启动方式。 |

## 目录结构

```text
dsh-desktop-rollback/
├── SKILL.md                  # 技能入口：触发条件 / 硬约束 / 四步流程 / 坑位表
├── README.md                 # 英文说明
├── README.zh-CN.md           # 本文件（中文）
├── LICENSE                   # MIT
├── scripts/
│   ├── diagnose.ps1          # 只读诊断，输出 JSON
│   └── new-rollback.ps1      # 签名校验 + 备份 + 生成回退启动器
└── references/
    └── mechanism.md          # 更新器内部机制，以及 Agent 为什么不能自己完成回退
```

## 安装

把仓库克隆到 DSH 会扫描的技能目录。`SKILL.md` 必须直接放在克隆出来的目录里：

```powershell
# 当前用户的所有项目都能用
git clone https://github.com/LIUFelix2004/dsh-desktop-rollback.git "$env:USERPROFILE\.dsh\skills\dsh-desktop-rollback"

# 或者只给当前项目用
git clone https://github.com/LIUFelix2004/dsh-desktop-rollback.git ".dsh\skills\dsh-desktop-rollback"
```

DSH 会重新扫描磁盘上的技能，下一个会话就能看到，不用重启。需要文件系统技能提供器 `@deepseek-ai/dsh-skill-filesystem`，DSH 自带。

## 使用

### 方式 A：直接跟 Agent 说

> "把 DSH 桌面版回退到这次更新之前的版本。"
> "为什么 DSH 一直提示我更新？"

Agent 会加载这个 skill，先诊断、再准备回退，最后**请你双击**生成的 `.cmd`。它不会声称自己已经完成了回退。

### 方式 B：自己运行脚本

**1. 诊断（只读）**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\diagnose.ps1
# 加 -NoNetwork 可以跳过对更新源的请求
```

JSON 里的关键字段：

| 字段 | 含义 |
|---|---|
| `installs[].installDir` | 实际在用的安装目录，第 2 步填到 `-TargetDir` |
| `installs[].exeVersion` | 真正装着的版本，**以它为准** |
| `installs[].registryVersion` | 卸载注册表里记录的版本，可能滞后 |
| `installs[].appUpdate` | 更新源类型、地址和通道（比如 `nightly`） |
| `installs[].pending` | 已下载、还没安装的更新 |
| `localInstallers[]` | 在下载文件夹和桌面找到的安装包，附版本和签名 |
| `feed.latestVersion` | 更新源目前唯一提供的版本 |
| `data` | `profiles` / `sessions` / `storages` 的文件数和大小 |

**2. 准备回退**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\new-rollback.ps1 `
  -Installer     "$env:USERPROFILE\Downloads\dsh-latest-windows-x64.exe" `
  -TargetDir     "D:\Apps\DeepSeek Harness" `
  -ExpectVersion "0.2.1-rc.2" `
  -OutDir        "$env:USERPROFILE\Desktop\dsh-rollback"
```

| 参数 | 必填 | 说明 |
|---|---|---|
| `-Installer` | ✅ | 本地留着的旧版安装包，签名必须有效 |
| `-TargetDir` | ✅ | 第 1 步查到的**现有**安装目录 |
| `-ExpectVersion` | ✅ | 回退后应该是的版本 |
| `-OutDir` | ✅ | 启动器和备份的输出目录 |
| `-BackupDir` | | 默认是 `<OutDir>\backup-<时间戳>` |
| `-DshHome` | | 默认用 `$env:DSH_HOME`，没设就用 `~\.dsh` |

**3. 在资源管理器里双击生成的 `rollback-<版本>.cmd`**

**4. 验证**

```powershell
(Get-Item 'D:\Apps\DeepSeek Harness\DeepSeek Harness.exe').VersionInfo.FileVersion
```

在 `rollback.log` 里找最后一行 `installed version`，并确认没有 `version mismatch` 警告。

## 环境要求

- Windows 10 或 11
- Windows PowerShell 5.1，或 PowerShell 7 以上
- **桌面版** DSH。如果你是用 npm 或 pnpm 全局装的 `dsh`，直接用包管理器重装想要的版本就行
- **旧版安装包必须已经在你电脑上。** 更新源不保留历史版本，想要的版本没法重新下载

## 常见坑

| 现象 | 说明 |
|---|---|
| 没填或填错 `-TargetDir` | NSIS 默认装到 `%LOCALAPPDATA%\Programs`，结果电脑上有两份应用 |
| exe 版本和注册表版本不一致 | 上次更新只做了一半，以 exe 为准 |
| `channel: nightly` | 你在用预发布版（`allowPrerelease` 已开启） |
| 回退后又升级了 | 它不会自己升级（`autoDownload=false`），但手动点"检查更新"会再提供最新版 |
| 旧版本打不开 | 服务端的 `dshMandatoryUpdatePolicy` 可能拦截它认为太旧的版本，离线没法预判 |
| 配置能加载但缺包 | 备份时跳过了 `node_modules`，重新跑一次 `pnpm install` |

## 安全说明

- 回退会**关闭正在运行的应用**，会话里没保存的内容会丢；
- 新版本可能已经把你的配置和会话数据迁移成新格式，备份就是退路：
  `robocopy "<BackupDir>" "$env:USERPROFILE\.dsh" /E`
- 脚本**不会下载或运行任何第三方代码**，唯一用到的程序是你手上那个官方签名的安装包；
- `diagnose.ps1` 只读，唯一的网络请求是对官方更新源的一次 GET，加 `-NoNetwork` 就不发。

## 参与贡献

欢迎提 Issue 和 PR，尤其是 DSH 新版本或更新器有变化的情况。提交时请附上去掉了隐私路径的 `diagnose.ps1` 输出片段。

## 许可证

[MIT](LICENSE)

> 本项目是非官方社区工具，与 DeepSeek 没有关联。"DeepSeek" 和 "DeepSeek Harness" 是其各自所有者的商标。
