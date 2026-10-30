# Diagnose a DeepSeek Harness Desktop install: layout, versions, updater state, local installers.
# Read-only. Emits JSON.
param(
    [switch]$NoNetwork,
    [string]$DshHome = ''
)

$ErrorActionPreference = 'Continue'

function Get-YamlFlat([string]$path) {
    $map = [ordered]@{}
    if (-not (Test-Path -LiteralPath $path)) { return $map }
    foreach ($line in Get-Content -LiteralPath $path -ErrorAction SilentlyContinue) {
        if ($line -match '^\s*([A-Za-z][\w-]*)\s*:\s*(.+?)\s*$') {
            $key = $Matches[1]
            $value = $Matches[2]
            if ($value.StartsWith("'") -and $value.EndsWith("'")) { $value = $value.Trim("'") }
            elseif ($value.StartsWith('"') -and $value.EndsWith('"')) { $value = $value.Trim('"') }
            $map[$key] = $value
        }
    }
    return $map
}

function Get-ExeVersion([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return (Get-Item -LiteralPath $path).VersionInfo.FileVersion
}

# --- install dir candidates ---
$candidates = New-Object System.Collections.Generic.List[string]

foreach ($p in @(Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue)) {
    try { if ($p.Path) { $candidates.Add((Split-Path -Parent $p.Path)) } } catch { }
}

foreach ($root in @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
    foreach ($key in @(Get-ChildItem $root -ErrorAction SilentlyContinue)) {
        $props = Get-ItemProperty $key.PSPath -ErrorAction SilentlyContinue
        if ($props.DisplayName -match 'DeepSeek Harness' -and $props.InstallLocation) {
            $candidates.Add($props.InstallLocation)
        }
    }
}

$candidates.Add((Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness'))
$candidates.Add((Join-Path $env:LOCALAPPDATA 'Programs\deepseek-harness'))
$candidates.Add('C:\Program Files\DeepSeek Harness')

$installs = @()
foreach ($dir in ($candidates | Select-Object -Unique)) {
    $exe = Join-Path $dir 'DeepSeek Harness.exe'
    if (-not (Test-Path -LiteralPath $exe)) { continue }
    $appUpdatePath = Join-Path $dir 'resources\app-update.yml'
    $yml = Get-YamlFlat $appUpdatePath
    $cacheName = if ($yml['updaterCacheDirName']) { $yml['updaterCacheDirName'] } else { '' }
    $cache = if ($cacheName) { Join-Path $env:LOCALAPPDATA $cacheName } else { '' }

    $pending = @()
    if ($cache) {
        $pdir = Join-Path $cache 'pending'
        if (Test-Path -LiteralPath (Join-Path $pdir 'update-info.json')) {
            $info = Get-Content -LiteralPath (Join-Path $pdir 'update-info.json') -Raw | ConvertFrom-Json
            $pending += [ordered]@{
                fileName = $info.fileName
                sha512   = $info.sha512
                present  = (Test-Path -LiteralPath (Join-Path $pdir $info.fileName))
            }
        }
    }

    $cacheInstallers = @()
    if ($cache -and (Test-Path -LiteralPath $cache)) {
        foreach ($f in @(Get-ChildItem -LiteralPath $cache -Filter '*.exe' -Force -ErrorAction SilentlyContinue)) {
            $cacheInstallers += [ordered]@{ path = $f.FullName; version = $f.VersionInfo.FileVersion; sizeMB = [math]::Round($f.Length / 1MB, 1) }
        }
    }

    $registryVersion = $null
    foreach ($root in @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall')) {
        foreach ($key in @(Get-ChildItem $root -ErrorAction SilentlyContinue)) {
            $props = Get-ItemProperty $key.PSPath -ErrorAction SilentlyContinue
            if ($props.DisplayName -match 'DeepSeek Harness' -and $props.InstallLocation -eq $dir) {
                $registryVersion = $props.DisplayVersion
            }
        }
    }

    $installs += [ordered]@{
        installDir      = $dir
        exeVersion      = Get-ExeVersion $exe
        registryVersion = $registryVersion
        appUpdate       = $yml
        updaterCache    = $cache
        pending         = $pending
        cacheInstallers = $cacheInstallers
    }
}

# --- local installers that could be rolled back to ---
$localInstallers = @()
$scanDirs = @(
    (Join-Path $env:USERPROFILE 'Downloads'),
    [Environment]::GetFolderPath('Desktop'),
    [Environment]::GetFolderPath('MyDocuments')
)
foreach ($d in ($scanDirs | Select-Object -Unique)) {
    if (-not (Test-Path -LiteralPath $d)) { continue }
    foreach ($f in @(Get-ChildItem -LiteralPath $d -Filter '*.exe' -Force -ErrorAction SilentlyContinue)) {
        $vi = $f.VersionInfo
        $isDsh = ($vi.FileDescription -match 'deepseek.*harness') -or ($f.Name -match 'dsh.*(windows|harness)|deepseek.*harness')
        if (-not $isDsh) { continue }
        $sig = (Get-AuthenticodeSignature -LiteralPath $f.FullName -ErrorAction SilentlyContinue).Status
        $localInstallers += [ordered]@{
            path     = $f.FullName
            version  = $vi.FileVersion
            sizeMB   = [math]::Round($f.Length / 1MB, 1)
            modified = $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
            signature = "$sig"
        }
    }
}

# --- feed latest ---
$feed = [ordered]@{ reached = $false }
if (-not $NoNetwork -and $installs.Count -gt 0) {
    $yml = $installs[0].appUpdate
    if ($yml['url'] -and $yml['channel']) {
        $feedUrl = ($yml['url'].TrimEnd('/')) + '/' + $yml['channel'] + '.yml'
        try {
            $resp = Invoke-WebRequest -Uri $feedUrl -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
            $body = $resp.Content
            $version = if ($body -match '(?m)^version:\s*(\S+)') { $Matches[1] } else { $null }
            $feed = [ordered]@{ reached = $true; url = $feedUrl; latestVersion = $version }
        } catch {
            $feed = [ordered]@{ reached = $false; url = $feedUrl; error = $_.Exception.Message }
        }
    }
}

# --- DSH home data ---
if (-not $DshHome) { $DshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' } }
$data = [ordered]@{ dshHome = $DshHome }
foreach ($sub in 'profiles', 'sessions', 'storages') {
    $p = Join-Path $DshHome $sub
    if (Test-Path -LiteralPath $p) {
        $m = Get-ChildItem -LiteralPath $p -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum
        $data[$sub] = [ordered]@{ files = $m.Count; sizeMB = [math]::Round($m.Sum / 1MB, 2) }
    }
}

[ordered]@{
    installs        = $installs
    localInstallers = $localInstallers
    feed            = $feed
    data            = $data
} | ConvertTo-Json -Depth 8
