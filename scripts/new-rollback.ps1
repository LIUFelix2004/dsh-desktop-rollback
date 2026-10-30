# Prepare a Windows rollback for DeepSeek Harness Desktop.
# Backs up $DSH_HOME, then emits rollback-<version>.ps1 + .cmd for the user to launch from Explorer.
param(
    [Parameter(Mandatory = $true)][string]$Installer,
    [Parameter(Mandatory = $true)][string]$TargetDir,
    [Parameter(Mandatory = $true)][string]$ExpectVersion,
    [Parameter(Mandatory = $true)][string]$OutDir,
    [string]$BackupDir = '',
    [string]$DshHome = ''
)

$ErrorActionPreference = 'Stop'

function Info([string]$m) { Write-Host "[prep] $m" }

# --- validate ---
if (-not (Test-Path -LiteralPath $Installer)) { throw "installer not found: $Installer" }
$sig = Get-AuthenticodeSignature -LiteralPath $Installer
if ($sig.Status -ne 'Valid') { throw "installer signature is $($sig.Status), expected Valid" }
$installerVersion = (Get-Item -LiteralPath $Installer).VersionInfo.FileVersion
Info "installer: $Installer ($installerVersion, signed by $($sig.SignerCertificate.Subject.Split(',')[0]))"
if ($installerVersion -ne $ExpectVersion) {
    Info "WARNING: installer reports $installerVersion but -ExpectVersion is $ExpectVersion"
}

$exe = Join-Path $TargetDir 'DeepSeek Harness.exe'
if (-not (Test-Path -LiteralPath $exe)) { throw "no DeepSeek Harness.exe under $TargetDir" }
$currentVersion = (Get-Item -LiteralPath $exe).VersionInfo.FileVersion
Info "current install: $TargetDir ($currentVersion)"

if (-not $DshHome) { $DshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' } }

# --- backup ---
if (-not $BackupDir) { $BackupDir = Join-Path $OutDir ("backup-" + (Get-Date -Format 'yyyyMMdd-HHmmss')) }
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
foreach ($sub in 'profiles', 'sessions', 'storages') {
    $src = Join-Path $DshHome $sub
    if (-not (Test-Path -LiteralPath $src)) { Info "skip missing $src"; continue }
    $rc = Start-Process -FilePath robocopy.exe -ArgumentList @(
        "`"$src`"", "`"$(Join-Path $BackupDir $sub)`"", '/E', '/XD', 'node_modules', '/NFL', '/NDL', '/NJH', '/NJS', '/R:1', '/W:1'
    ) -Wait -PassThru -NoNewWindow
    if ($rc.ExitCode -ge 8) { throw "robocopy failed for $src (code $($rc.ExitCode))" }
    Info "backed up $sub (robocopy $($rc.ExitCode))"
}
Set-Content -LiteralPath (Join-Path $BackupDir 'MANIFEST.txt') -Encoding UTF8 -Value @(
    "created        : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
    "from version   : $currentVersion",
    "to version     : $ExpectVersion",
    "install dir    : $TargetDir",
    "installer      : $Installer",
    "restore        : robocopy `"$BackupDir`" `"$DshHome`" /E"
)

# --- emit launcher ---
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$stamp = $ExpectVersion -replace '[^A-Za-z0-9._-]', '_'
$ps1Path = Join-Path $OutDir "rollback-$stamp.ps1"
$cmdPath = Join-Path $OutDir "rollback-$stamp.cmd"

$template = @'
# Generated rollback: __FROM__ -> __EXPECT__
# Launched from Explorer so it survives the app's job object.
$ErrorActionPreference = 'Continue'
$Installer = '__INSTALLER__'
$Target    = '__TARGET__'
$Exe       = Join-Path $Target 'DeepSeek Harness.exe'
$Cache     = '__CACHE__'
$Want      = '__EXPECT__'
$Log       = Join-Path $PSScriptRoot 'rollback.log'

function Log([string]$m) {
    $l = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m
    Write-Host $l
    Add-Content -LiteralPath $Log -Value $l -Encoding UTF8
}
function Ver { if (Test-Path -LiteralPath $Exe) { return (Get-Item -LiteralPath $Exe).VersionInfo.FileVersion } return $null }

Log '=== rollback started ==='
Log "from: $(Ver)   to: $Want"

$sig = Get-AuthenticodeSignature -LiteralPath $Installer
if ($sig.Status -ne 'Valid') { Log "abort: signature $($sig.Status)"; Read-Host 'press Enter'; exit 1 }

foreach ($p in @(Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue)) {
    try { $p | Stop-Process -Force -ErrorAction Stop; Log "stopped pid $($p.Id)" } catch { Log "stop failed: $($_.Exception.Message)" }
}
for ($i = 0; $i -lt 40; $i++) {
    if (-not (Get-Process -Name 'DeepSeek Harness' -ErrorAction SilentlyContinue)) { break }
    Start-Sleep -Milliseconds 500
}
Start-Sleep -Seconds 2

Log "installing silently to $Target"
$sw = [Diagnostics.Stopwatch]::StartNew()
$proc = Start-Process -FilePath $Installer -ArgumentList '/S', "/D=$Target" -Wait -PassThru
$sw.Stop()
Log ("installer exit {0} in {1}s" -f $proc.ExitCode, [math]::Round($sw.Elapsed.TotalSeconds, 1))

$ver = $null
for ($i = 0; $i -lt 90; $i++) {
    $ver = Ver
    if ($ver -eq $Want) { break }
    Start-Sleep -Seconds 2
}
Log "installed version: $ver"

if ($ver -ne $Want) {
    Log "!! version mismatch - the installer may have used its default directory instead of $Target"
    Log '!! rerun the installer interactively and pick that directory'
} else {
    if ($Cache) {
        $pending = Join-Path $Cache 'pending'
        if (Test-Path -LiteralPath $pending) {
            Remove-Item -LiteralPath $pending -Recurse -Force -ErrorAction SilentlyContinue
            Log "cleared pending update: $pending"
        }
        $bm = Join-Path $Cache 'current.blockmap'
        if (Test-Path -LiteralPath $bm) { Remove-Item -LiteralPath $bm -Force -ErrorAction SilentlyContinue }
    }
}

if (Test-Path -LiteralPath $Exe) {
    Start-Process -FilePath $Exe -WorkingDirectory $Target
    Log 'app restarted'
}
Log '=== done ==='
Read-Host 'press Enter to close'
'@

$cacheDir = ''
$appUpdate = Join-Path $TargetDir 'resources\app-update.yml'
if (Test-Path -LiteralPath $appUpdate) {
    foreach ($line in Get-Content -LiteralPath $appUpdate) {
        if ($line -match '^\s*updaterCacheDirName\s*:\s*(.+?)\s*$') { $cacheDir = Join-Path $env:LOCALAPPDATA $Matches[1] }
    }
}

$body = $template.
    Replace('__INSTALLER__', $Installer).
    Replace('__TARGET__', $TargetDir).
    Replace('__EXPECT__', $ExpectVersion).
    Replace('__CACHE__', $cacheDir).
    Replace('__FROM__', $currentVersion)

[System.IO.File]::WriteAllText($ps1Path, $body, (New-Object System.Text.UTF8Encoding($true)))

$cmdBody = @"
@echo off
title DSH rollback $currentVersion -^> $ExpectVersion
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0$(Split-Path -Leaf $ps1Path)"
"@
[System.IO.File]::WriteAllText($cmdPath, $cmdBody, (New-Object System.Text.UTF8Encoding($false)))

[ordered]@{
    launcher = $cmdPath
    script   = $ps1Path
    backup   = $BackupDir
    from     = $currentVersion
    to       = $ExpectVersion
    next     = "Double-click $cmdPath"
} | ConvertTo-Json
