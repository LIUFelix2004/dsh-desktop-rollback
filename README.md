<div align="center">

# dsh-desktop-rollback

**Roll back, pin, or diagnose a Windows DeepSeek Harness Desktop install, safely.**

English · [简体中文](README.zh-CN.md)

![platform](https://img.shields.io/badge/platform-Windows%2010%2F11-0078D6)
![powershell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207%2B-5391FE)
![type](https://img.shields.io/badge/type-DSH%20skill-6E56CF)
![license](https://img.shields.io/badge/license-MIT-green)

</div>

---

## Why this exists

DeepSeek Harness (DSH) Desktop gives you no way to downgrade from inside the app:

- The Electron shell sets `allowDowngrade = false`, so the in-app updater never moves to an older build.
- The update feed lists **only the newest build**. Older installer URLs return 404.
- If an agent tries to do the rollback itself, the install breaks halfway. Any process the agent starts runs inside the app's Windows **job object**, so when the script kills the app, it also kills itself and the installer it started.

This skill is a tested way through. It diagnoses the install, backs up your data, and generates a rollback script **that you double-click from Explorer**, so the reinstall runs outside the app's process tree and finishes.

## Features

| | |
|---|---|
| 🔍 **Read-only diagnosis** | Shows where the app is installed, the real version (from the exe, not the registry, which can lag), the update channel and feed, any update already downloaded, older installers still on disk, and how big your `$DSH_HOME` data is. Output is JSON. |
| 🔐 **Signature check** | Refuses an installer whose Authenticode signature is not `Valid`. |
| 💾 **Data backup** | Copies `profiles`, `sessions`, and `storages` with `robocopy` (skipping pnpm `node_modules` symlinks) and writes a `MANIFEST.txt` that includes the restore command. |
| 🖱️ **Double-click launcher** | Generates `rollback-<version>.cmd`. It closes the app, silently reinstalls into the **existing** folder, waits until the exe version matches, clears the newer build's downloaded update, and restarts the app. |
| 📝 **Readable failures** | Every step goes to `rollback.log`, so a failed run tells you why. |
| 📚 **Documented internals** | [`references/mechanism.md`](references/mechanism.md) records how the updater works and every launch method that was tried and failed. |

## Repository layout

```text
dsh-desktop-rollback/
├── SKILL.md                  # Skill entry: when it applies, hard limits, 4-step flow, gotchas table
├── README.md                 # This file (English)
├── README.zh-CN.md           # Chinese README
├── LICENSE                   # MIT
├── scripts/
│   ├── diagnose.ps1          # Read-only diagnosis, prints JSON
│   └── new-rollback.ps1      # Signature check + backup + generates the rollback launcher
└── references/
    └── mechanism.md          # Updater internals and why an agent can't finish the rollback itself
```

## Installation

Clone the repo into a skill folder that DSH scans. `SKILL.md` must sit directly in the cloned folder.

```powershell
# For all projects (current user)
git clone https://github.com/LIUFelix2004/dsh-desktop-rollback.git "$env:USERPROFILE\.dsh\skills\dsh-desktop-rollback"

# Or for the current project only
git clone https://github.com/LIUFelix2004/dsh-desktop-rollback.git ".dsh\skills\dsh-desktop-rollback"
```

DSH rescans skills from disk, so the skill appears in the next session without a restart. It needs the filesystem skill provider (`@deepseek-ai/dsh-skill-filesystem`), which comes with DSH.

## Usage

### Option A: ask the agent

> "Roll DSH Desktop back to the version before this update."
> "Why does DSH keep offering me an update?"

The agent loads the skill, runs the diagnosis, prepares the rollback, and then **asks you to double-click** the generated `.cmd`. It will not claim that it ran the rollback itself.

### Option B: run the scripts yourself

**1. Diagnose (read-only)**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\diagnose.ps1
# add -NoNetwork to skip the feed request
```

Key fields in the JSON:

| Field | Meaning |
|---|---|
| `installs[].installDir` | The install folder in use. Pass it as `-TargetDir` in step 2. |
| `installs[].exeVersion` | The version actually installed. **Trust this one.** |
| `installs[].registryVersion` | The version in the uninstall registry entry. It can lag behind. |
| `installs[].appUpdate` | Update provider, feed URL, and channel (for example `nightly`). |
| `installs[].pending` | An update that has been downloaded but not installed yet. |
| `localInstallers[]` | Installers found in Downloads and on the Desktop, with version and signature. |
| `feed.latestVersion` | The only version the feed currently offers. |
| `data` | File count and size of `profiles`, `sessions`, and `storages`. |

**2. Prepare the rollback**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\new-rollback.ps1 `
  -Installer     "$env:USERPROFILE\Downloads\dsh-latest-windows-x64.exe" `
  -TargetDir     "D:\Apps\DeepSeek Harness" `
  -ExpectVersion "0.2.1-rc.2" `
  -OutDir        "$env:USERPROFILE\Desktop\dsh-rollback"
```

| Parameter | Required | Description |
|---|---|---|
| `-Installer` | ✅ | The older installer you kept locally. Its signature must be valid. |
| `-TargetDir` | ✅ | The **existing** install folder from step 1. |
| `-ExpectVersion` | ✅ | The version you expect after the rollback. |
| `-OutDir` | ✅ | Where the launcher and backup are written. |
| `-BackupDir` | | Defaults to `<OutDir>\backup-<timestamp>`. |
| `-DshHome` | | Defaults to `$env:DSH_HOME`, or `~\.dsh` if that isn't set. |

**3. Double-click the generated `rollback-<version>.cmd` in Explorer**

**4. Verify**

```powershell
(Get-Item 'D:\Apps\DeepSeek Harness\DeepSeek Harness.exe').VersionInfo.FileVersion
```

Look for the final `installed version` line in `rollback.log` and check that there is no `version mismatch` warning.

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1, or PowerShell 7+
- The **desktop** DSH app. If you installed `dsh` globally with npm or pnpm, reinstall the version you want with that package manager instead.
- **The older installer must already be on your machine.** The feed keeps no history, so the version you want can't be downloaded again.

## Gotchas

| Symptom | What it means |
|---|---|
| `-TargetDir` is missing or wrong | NSIS installs to `%LOCALAPPDATA%\Programs` by default, and you end up with two copies of the app. |
| Exe version and registry version differ | An update was left half-done. Trust the exe. |
| `channel: nightly` | You are on pre-release builds (`allowPrerelease` is on). |
| It upgrades again later | It won't do that on its own (`autoDownload=false`). A manual "check for updates" will offer the newest build again. |
| The old version won't start | A server-side `dshMandatoryUpdatePolicy` can block versions it treats as too old. This can't be predicted offline. |
| The profile loads but packages are missing | `node_modules` was skipped during backup. Run `pnpm install` again. |

## Safety

- The rollback **closes the running app**. Unsaved work in a session is lost.
- The newer build may already have migrated your profile and session data. The backup is your way back:
  `robocopy "<BackupDir>" "$env:USERPROFILE\.dsh" /E`
- These scripts **download and run no third-party code**. The only binary involved is the official signed installer you already have.
- `diagnose.ps1` is read-only. Its only network call is one GET to the official feed, and `-NoNetwork` turns that off.

## Contributing

Issues and PRs are welcome, especially for new DSH versions or updater changes. Please include the relevant parts of `diagnose.ps1` output with private paths removed.

## License

[MIT](LICENSE)

> This is an unofficial community tool, not affiliated with DeepSeek. "DeepSeek" and "DeepSeek Harness" are trademarks of their respective owners.
