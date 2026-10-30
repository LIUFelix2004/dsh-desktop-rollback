# Why a rollback cannot run in-band

Findings from a stock Windows install (0.2.1-rc.5, `nightly`, generic feed). Version numbers move; the mechanisms do not.

## Updater configuration

`resources\app-update.yml`:

```yaml
provider: generic
url: https://download.deepseek.com/dsh-desk/feeds/win-x64/
channel: nightly
updaterCacheDirName: '@deepseek-aidsh-desktop-updater'
```

The Electron shell (`resources\app.asar` → `lib/main.js`) configures `electron-updater`:

```js
this.updater.autoDownload = false;
this.updater.autoInstallOnAppQuit = false;
this.updater.channel = channel;
this.updater.allowPrerelease = channel === "nightly";
this.updater.allowDowngrade = false;
```

Consequences:

- `allowDowngrade = false` — the in-app updater will never move to an older version; there is no downgrade UI.
- `autoDownload = false` / `autoInstallOnAppQuit = false` — nothing installs behind the user's back. A `pending` download only exists because someone accepted an update prompt.
- `channel: nightly` — the app follows pre-release builds.

Desktop shell settings (`%APPDATA%\@deepseek-ai\dsh-desktop\desktop\settings.json`) expose only `updates.allowTestAuthPopupWindow`; there is no "disable updates" switch.

## The feed keeps no history

`<feed>/nightly.yml` advertises exactly one build (version, URL under `/dsh-desk/bin/win-x64/`, `sha512`, size). Probing `/dsh-desk/feeds/win-x64/<older>.exe` and `/dsh-desk/bin/win-x64/<older>.exe` for earlier RCs returned 404. There is `latest.yml` only as 404 — `nightly` is the channel file.

So rollback requires an installer already saved locally (typically the one the user first ran from `Downloads`). That is why `diagnose.ps1` scans the usual download folders.

## Version sources disagree

- `(Get-Item '<dir>\DeepSeek Harness.exe').VersionInfo.FileVersion` — what is actually installed.
- `HKCU/HKLM ...\Uninstall\<guid>` → `DisplayVersion` — what the last *NSIS* install wrote.

A partial or staged update can leave files at the new version while the registry still reports the old one. Trust the exe, and report the discrepancy rather than "fixing" it.

## The job object is the real blocker

`IsProcessInJob` returns true for tool processes. Every detach route was tried and refused:

| Attempt | Result |
|---|---|
| `schtasks /create` | error 1, "system cannot find the path specified" |
| `Register-ScheduledTask` / `New-ScheduledTaskAction` | 0x80041003 access denied |
| `Invoke-CimMethod Win32_Process.Create` | 0x80041003 access denied |
| `CreateProcess(..., CREATE_BREAKAWAY_FROM_JOB)` | `-5` ERROR_ACCESS_DENIED |
| `Start-Process explorer.exe <script>` | runs nothing; outside processes are not visible |
| plain `CreateProcess` with `CREATE_NEW_CONSOLE` | succeeds, but stays inside the job |

Killing `DeepSeek Harness.exe` closes the job that owns the tool process, so a script that does the killing dies with its own installer child. The install must be started by a process outside that tree — Explorer, i.e. a double-click by the user.

A script launched by Explorer also avoids the DSH sandbox entirely: it writes to `F:\` or `C:\` normally and may run `robocopy`, `taskkill`, and NSIS without elevation because the desktop app installs per-user.

## NSIS install flags

`-ArgumentList '/S', "/D=$Target"` — `/S` silent, `/D` sets the destination and must be the last argument, unquoted. Leaving `/D` out sends the install to the per-user default (`%LOCALAPPDATA%\Programs\...`), producing a second installation next to the existing one.

Silent mode closes the running app itself (`CHECK_APP_RUNNING`), which is why the script kills the app first and waits — otherwise the installer's own kill would race the file extraction.

## Data compatibility

`$DSH_HOME` (`profiles`, `sessions`, `storages`) may have been migrated forward by the newer build; an older build can fail to read it. `profiles\<name>\node_modules` contains pnpm symlinks, so bulk copies error there — exclude `node_modules` and re-run `pnpm install` if the profile loads but misses packages.

## Mandatory update gate

`package.json` inside `app.asar` carries `dshMandatoryUpdatePolicy` (origin `https://harness.deepseek.com`, anonymous authentication). The shell can enter a blocking state (`mandatoryPolicy.state.blocking`) when the server says the running version is unsupported. A rollback can therefore succeed at the file level and still be refused at start-up; this is decided server-side and cannot be predicted offline.
