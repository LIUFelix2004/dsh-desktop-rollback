---
name: dsh-desktop-rollback
description: "Use when a DeepSeek Harness Desktop install must be rolled back to an earlier build, pinned against an accidental update, or its updater state diagnosed on Windows."
whenToUse: "The user wants to downgrade DSH Desktop, undo an update they did not intend, locate an older installer, or understand why the app keeps offering an update."
---

# DSH Desktop rollback

Roll back (or diagnose) a **Windows DeepSeek Harness Desktop** install. The app has no in-app downgrade path, so a rollback means reinstalling an older NSIS build over the current one.

## Scope

- Applies to the **desktop app** (`DeepSeek Harness.exe` with `resources\app.asar`).
- A `pnpm`/`npm` global `@deepseek-ai/dsh` install is a different shape: reinstall the wanted version with the package manager instead.
- macOS/Linux builds place `app-update.yml` inside the bundle and use different installers; the diagnosis below is Windows-specific.

## Critical constraint: you cannot finish this yourself

Any process you start lives in the same Windows **job object** as the app. Killing the app (`taskkill` / `Stop-Process`) closes that job and takes your script *and* its installer child with it, leaving a half-written install.

Verified dead ends on a stock install — do not retry them: `schtasks` and `Register-ScheduledTask` (access denied), WMI `Win32_Process.Create` (access denied), `CreateProcess` with `CREATE_BREAKAWAY_FROM_JOB` (ERROR_ACCESS_DENIED), `explorer.exe` as a launcher (not reachable from inside).

**Therefore:** generate the rollback script, then have the user launch it from Explorer (double-click). That process is outside the app's process tree and survives. Say this plainly; do not claim you ran the rollback.

See [references/mechanism.md](references/mechanism.md) for the updater internals and the evidence behind these limits.

## 1. Diagnose

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\diagnose.ps1
```

Prints JSON: install dir, running version, registry version, `app-update.yml` (provider/URL/channel), cached pending update, local installers found in Downloads/Desktop, and `$DSH_HOME` data sizes. Add `-NoNetwork` to skip the feed request.

Read it before touching anything. Two traps:

- **`FileVersion` of the exe is authoritative**, not the uninstall registry entry — the registry can lag a partial or interrupted update.
- **`allowDowngrade = false`** in the shell means the in-app updater refuses older builds; only a manual NSIS reinstall can go back.

## 2. Choose the target version

The feed publishes **only the newest build**; older installer URLs return 404. So a rollback is possible only if an older installer already exists on disk — typically the one the user originally ran from `Downloads`.

If `diagnose.ps1` finds no older installer, say so and stop: the version is not recoverable from the feed, and guessing URLs wastes the user's time.

## 3. Prepare

Use the `installDir` and installer path reported by step 1:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\new-rollback.ps1 `
  -Installer     "$env:USERPROFILE\Downloads\dsh-latest-windows-x64.exe" `
  -TargetDir     "<installDir from step 1>" `
  -ExpectVersion "<version of that installer>" `
  -OutDir        "$env:USERPROFILE\Desktop\dsh-rollback" `
  -BackupDir     "$env:USERPROFILE\Desktop\dsh-rollback\backup"
```

It checks the installer's Authenticode signature, backs up `$DSH_HOME` (`profiles`/`sessions`/`storages`, skipping `node_modules` symlink trees) with `robocopy`, and writes `rollback-<version>.cmd` + `rollback-<version>.ps1` into `OutDir`.

`-TargetDir` must be the **existing** install dir from step 1. The NSIS installer otherwise defaults to `%LOCALAPPDATA%\Programs`, silently giving the user two installations.

## 4. Hand off

Tell the user to double-click `rollback-<version>.cmd`. It closes the app, installs silently to `-TargetDir`, polls the exe until `FileVersion` matches, clears the newer build's `pending` cache, and restarts the app.

Then verify from the log the script writes beside itself (`rollback.log`): look for the final `installed version` line and any `version mismatch` warning. Confirm directly:

```powershell
(Get-Item '<TargetDir>\DeepSeek Harness.exe').VersionInfo.FileVersion
```

## Gotchas

| Symptom / setting | Consequence |
|---|---|
| `channel: nightly` in `app-update.yml` | Pre-release builds; `allowPrerelease` is on |
| `autoDownload=false`, `autoInstallOnAppQuit=false` | It will not re-upgrade by itself; a *manual* update check re-offers the newest build |
| `dshMandatoryUpdatePolicy` present | A server-side gate can block a version it considers too old — an old build may refuse to run |
| Profile/session data already migrated forward | The older build may not read it; the backup is the escape hatch |
| `profiles\node_modules` holds pnpm symlinks | Bulk copies fail there; both scripts exclude it — reinstall with `pnpm install` if the profile loads but misses packages |
| Installer cache holds one installer only | An install can replace `%LOCALAPPDATA%\<updaterCacheDirName>\installer.exe` with the build you just put down. To go back up, read the current `path` from `<feed>/<channel>.yml` and download it |
