# dsh-desktop-rollback

A [DeepSeek Harness](https://github.com/deepseek-ai) **skill** for rolling a Windows DeepSeek Harness Desktop install back to an earlier build, or for diagnosing why it will not.

DSH Desktop has no in-app downgrade: the Electron shell sets `allowDowngrade = false`, and the update feed only ever publishes the newest build. Undoing an accidental update therefore means reinstalling an older NSIS build — and doing it without leaving the machine with a half-written install.

## What it does

- **Diagnoses** the install: which directory is actually running, the real version (the uninstall registry entry can lag), the update channel, what is cached, which older installers are still on disk, and how large `$DSH_HOME` is.
- **Prepares** the rollback: verifies the old installer's Authenticode signature, backs up `profiles` / `sessions` / `storages`, and generates a double-clickable `rollback-<version>.cmd`.
- **Explains the boundary**: a tool-run script cannot perform the rollback itself, because it shares a Windows job object with the app it has to kill. See [`references/mechanism.md`](references/mechanism.md).

## Install

Clone into a skill root that DSH scans (`dsh-skill-filesystem`), keeping the repository root as the bundle root — `SKILL.md` must sit directly inside the cloned directory:

```powershell
# user-wide, every project
git clone https://github.com/<you>/dsh-desktop-rollback.git "$env:USERPROFILE\.dsh\skills\dsh-desktop-rollback"

# or this project only
git clone https://github.com/<you>/dsh-desktop-rollback.git ".dsh\skills\dsh-desktop-rollback"
```

Skills are rescanned from disk, so it shows up in the next session catalog without a restart. Requires the filesystem skill provider (`@deepseek-ai/dsh-skill-filesystem`), which ships with DSH.

## Usage

Ask the agent to roll back or diagnose the install; it will load this skill. Or run the scripts yourself:

```powershell
# 1. read-only diagnosis (JSON)
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\diagnose.ps1

# 2. build the rollback launcher from a locally kept older installer
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\new-rollback.ps1 `
  -Installer     "$env:USERPROFILE\Downloads\dsh-latest-windows-x64.exe" `
  -TargetDir     "D:\Apps\DeepSeek Harness" `
  -ExpectVersion "0.2.1-rc.2" `
  -OutDir        "$env:USERPROFILE\Desktop\dsh-rollback"

# 3. double-click the generated rollback-0.2.1-rc.2.cmd
```

`new-rollback.ps1` writes `rollback.log` next to the script it generates and keeps going if the version does not land where expected, so a failed attempt is readable rather than silent.

## Requirements

- Windows 10/11, Windows PowerShell 5.1 or PowerShell 7+
- Desktop DSH (not a package-manager `dsh` CLI install)
- The older installer must already exist locally — the feed keeps no history

## Safety notes

- The rollback **closes the running app**; unsaved work in a session is lost.
- Profile and session data may have been migrated forward by the newer build. The backup the script takes is the way back.
- A server-side mandatory-update policy can still refuse to run a version it considers unsupported. That decision is not predictable offline.
- Nothing here downloads or executes code from third parties; the only binary involved is the official signed installer the user already has.

## License

MIT — see [LICENSE](LICENSE).
