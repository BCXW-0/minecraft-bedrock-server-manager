[CmdletBinding()]
param(
    [ValidatePattern('^(auto|[0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?)$')]
    [string]$Version = 'auto',
    [switch]$Force,
    [switch]$NonInteractive,
    [switch]$DryRun,
    [switch]$SkipDocker,
    [switch]$SkipBds,
    [switch]$SkipDependencies,
    [string]$UserRoot,
    [string]$InstallRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

$BdsBaseUrl = 'https://minecraft.azureedge.net/bin-win'
$FrpVersion = '0.71.0'
$FrpUrl = "https://github.com/fatedier/frp/releases/download/v$FrpVersion/frp_${FrpVersion}_windows_amd64.zip"
$OfficialDownloadPage = 'https://www.minecraft.net/en-us/download/server/bedrock'
$Catalog = @(
    [pscustomobject]@{ Version = '1.26.51.1'; Recommended = $true },
    [pscustomobject]@{ Version = '1.26.50.2'; Recommended = $false },
    [pscustomobject]@{ Version = '1.26.40.2'; Recommended = $false }
)

function Resolve-UserRoot {
    if (-not [string]::IsNullOrWhiteSpace($UserRoot)) { return [IO.Path]::GetFullPath($UserRoot) }
    if (-not [string]::IsNullOrWhiteSpace($env:MINECRAFT_USER_ROOT)) { return [IO.Path]::GetFullPath($env:MINECRAFT_USER_ROOT) }
    $leaf = Split-Path -Leaf $PSScriptRoot
    if ($leaf -match '(?i)-dev$') { return Join-Path (Split-Path -Parent $PSScriptRoot) ($leaf -replace '(?i)-dev$', '') }
    return [IO.Path]::GetFullPath($PSScriptRoot)
}

function Get-ReachableVersion {
    $fallback = $Catalog | Where-Object Recommended | Select-Object -First 1
    foreach ($item in @($Catalog | Sort-Object @{ Expression = { [version]$_.Version }; Descending = $true })) {
        $url = "$BdsBaseUrl/bedrock-server-$($item.Version).zip"
        try {
            $request = [Net.HttpWebRequest]::Create($url)
            $request.Method = 'HEAD'; $request.UserAgent = 'Minecraft-Bedrock-Server-Manager/1.0'; $request.Timeout = 15000
            $response = $request.GetResponse(); $response.Close(); return $item
        }
        catch { }
    }
    Write-Warning ('Official version probe was unavailable; using pinned recommendation ' + $fallback.Version + '.')
    return $fallback
}

function Select-Version {
    if ($Version -ne 'auto') { return [pscustomobject]@{ Version = $Version; Recommended = $false } }
    if ($NonInteractive) { return Get-ReachableVersion }
    Write-Host 'Minecraft Bedrock Dedicated Server versions:'
    for ($i = 0; $i -lt $Catalog.Count; $i++) {
        $label = if ($Catalog[$i].Recommended) { 'recommended' } else { 'compatible' }
        Write-Host ("  [{0}] {1} ({2})" -f ($i + 1), $Catalog[$i].Version, $label)
    }
    Write-Host '  [A] Detect the newest reachable stable version'
    $choice = Read-Host 'Choose a number, A, or a full version (Enter = recommended)'
    if ([string]::IsNullOrWhiteSpace($choice)) { return Get-ReachableVersion }
    if ($choice -match '^[0-9]+$' -and [int]$choice -ge 1 -and [int]$choice -le $Catalog.Count) { return $Catalog[[int]$choice - 1] }
    if ($choice -match '^(?i:a|auto)$') { return Get-ReachableVersion }
    if ($choice -match '^[0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?$') { return [pscustomobject]@{ Version = $choice; Recommended = $false } }
    throw 'Invalid version selection.'
}

function Ensure-Docker {
    if (Get-Command docker -ErrorAction SilentlyContinue) { Write-Host 'Docker CLI is available.' -ForegroundColor Green; return }
    if ($SkipDocker) { Write-Warning 'Docker installation was skipped.'; return }
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($null -eq $winget) { throw 'Docker is missing and winget is unavailable. Install Docker Desktop, then rerun Update.cmd.' }
    if ($DryRun) { Write-Host 'DRY RUN: would install Docker Desktop with winget.' -ForegroundColor Yellow; return }
    & $winget.Source install --id Docker.DockerDesktop -e --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) { throw ('Docker Desktop installation failed with exit code ' + $LASTEXITCODE) }
}

function Install-Bds([string]$SelectedVersion, [string]$RuntimeRoot) {
    $versionRoot = Join-Path $RuntimeRoot ('bedrock-' + $SelectedVersion)
    $serverRoot = Join-Path $versionRoot 'server'
    $exe = Join-Path $serverRoot 'bedrock_server.exe'
    $archive = Join-Path (Join-Path $RuntimeRoot '_downloads') ('bedrock-server-' + $SelectedVersion + '.zip')
    if ((Test-Path -LiteralPath $exe -PathType Leaf) -and -not $Force) { return [pscustomobject]@{ Version = $SelectedVersion; Root = $serverRoot; Archive = $archive; Sha256 = $null; Source = "$BdsBaseUrl/bedrock-server-$SelectedVersion.zip" } }
    if (Test-Path -LiteralPath $versionRoot) { throw ('Existing BDS installation is preserved: ' + $versionRoot + '. -Force cannot replace it. Back up the installation and choose a new, empty -InstallRoot to reinstall.') }
    $cache = Split-Path -Parent $archive; $temp = Join-Path $RuntimeRoot '_installing'
    New-Item -ItemType Directory -Path $cache, $temp -Force | Out-Null
    $part = $archive + '.part'; $url = "$BdsBaseUrl/bedrock-server-$SelectedVersion.zip"
    Write-Host ('Downloading BDS ' + $SelectedVersion + '...'); Invoke-WebRequest -Uri $url -OutFile $part -UseBasicParsing
    if ((Get-Item -LiteralPath $part).Length -lt 1MB) { throw 'Downloaded BDS archive is unexpectedly small.' }
    Move-Item -LiteralPath $part -Destination $archive -Force
    $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    $extract = Join-Path $temp ([guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $extract -Force | Out-Null
    try {
        Expand-Archive -LiteralPath $archive -DestinationPath $extract -Force
        $candidate = Get-ChildItem -LiteralPath $extract -Filter bedrock_server.exe -File -Recurse | Select-Object -First 1
        if ($null -eq $candidate) { throw 'BDS archive did not contain bedrock_server.exe.' }
        if (Test-Path -LiteralPath $versionRoot) { throw ('Install target appeared during download; preserved without changes: ' + $versionRoot) }
        New-Item -ItemType Directory -Path $serverRoot -Force | Out-Null
        Copy-Item -Path (Join-Path $candidate.Directory.FullName '*') -Destination $serverRoot -Recurse -Force
    }
    finally { Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue }
    return [pscustomobject]@{ Version = $SelectedVersion; Root = $serverRoot; Archive = $archive; Sha256 = $hash; Source = $url }
}

function Install-Frp([string]$RuntimeRoot) {
    $cache = Join-Path $RuntimeRoot '_downloads'; $versionRoot = Join-Path $RuntimeRoot ('frp-' + $FrpVersion)
    $existing = Get-ChildItem -LiteralPath $versionRoot -Filter frpc.exe -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($existing -and -not $Force) { return $existing.FullName }
    if (Test-Path -LiteralPath $versionRoot) { throw ('Existing FRP installation is preserved: ' + $versionRoot + '. -Force cannot replace it. Back up the installation and choose a new, empty -InstallRoot to reinstall.') }
    New-Item -ItemType Directory -Path $cache -Force | Out-Null
    $archive = Join-Path $cache ('frp_' + $FrpVersion + '_windows_amd64.zip'); $part = $archive + '.part'
    Write-Host ('Downloading FRP ' + $FrpVersion + '...'); Invoke-WebRequest -Uri $FrpUrl -OutFile $part -UseBasicParsing
    if ((Get-Item -LiteralPath $part).Length -lt 1MB) { throw 'Downloaded FRP archive is unexpectedly small.' }
    Move-Item -LiteralPath $part -Destination $archive -Force
    if (Test-Path -LiteralPath $versionRoot) { throw ('Install target appeared during download; preserved without changes: ' + $versionRoot) }
    New-Item -ItemType Directory -Path $versionRoot -Force | Out-Null; Expand-Archive -LiteralPath $archive -DestinationPath $versionRoot -Force
    $installed = Get-ChildItem -LiteralPath $versionRoot -Filter frpc.exe -File -Recurse | Select-Object -First 1
    if ($null -eq $installed) { throw 'FRP archive did not contain frpc.exe.' }
    return $installed.FullName
}

function Install-NodeDependencies([string]$RuntimeUserRoot) {
    $packageRoot = Join-Path $RuntimeUserRoot 'package'
    $packageJson = Join-Path $packageRoot 'package.json'
    if (-not (Test-Path -LiteralPath $packageJson -PathType Leaf)) {
        Write-Host 'No package/package.json found; Node dependencies are not part of this installation.'
        return $null
    }
    $npm = Get-Command npm -ErrorAction SilentlyContinue
    if ($null -eq $npm) { throw 'package/package.json exists but npm is unavailable. Install Node.js 24 or rerun with -SkipDependencies.' }
    if ($DryRun) { Write-Host ('DRY RUN: would install Node dependencies into ' + $packageRoot) -ForegroundColor Yellow; return $packageRoot }
    Push-Location $packageRoot
    try {
        $lock = Join-Path $packageRoot 'package-lock.json'
        if (Test-Path -LiteralPath $lock -PathType Leaf) { & $npm.Source ci --no-audit --no-fund }
        else { & $npm.Source install --no-audit --no-fund }
        if ($LASTEXITCODE -ne 0) { throw ('Node dependency installation failed with exit code ' + $LASTEXITCODE) }
    }
    finally { Pop-Location }
    return $packageRoot
}

$resolvedUserRoot = Resolve-UserRoot
if (-not (Test-Path -LiteralPath $resolvedUserRoot -PathType Container)) { throw ('User root does not exist: ' + $resolvedUserRoot) }
if ([string]::IsNullOrWhiteSpace($InstallRoot)) { $InstallRoot = Join-Path $resolvedUserRoot '.staging' } else { $InstallRoot = [IO.Path]::GetFullPath($InstallRoot) }
if (-not $DryRun) { New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null }
& (Join-Path $PSScriptRoot 'Admin.ps1') -Action Sync -Mode $(if ($DryRun) { 'Preview' } else { 'Apply' }) -UserRoot $resolvedUserRoot
Ensure-Docker
$selected = Select-Version
Write-Host ('Selected BDS version: ' + $selected.Version)
if ($DryRun) { Write-Host ('DRY RUN: runtime archives -> ' + $InstallRoot) -ForegroundColor Yellow; exit 0 }
$bds = if ($SkipBds) { $null } else { Install-Bds -SelectedVersion $selected.Version -RuntimeRoot $InstallRoot }
$frpc = if ($SkipBds) { $null } else { Install-Frp -RuntimeRoot $InstallRoot }
$nodeRoot = if ($SkipDependencies) { $null } else { Install-NodeDependencies -RuntimeUserRoot $resolvedUserRoot }
$configDir = Join-Path $resolvedUserRoot '.minecraft-manager'; New-Item -ItemType Directory -Path $configDir -Force | Out-Null
$configPath = Join-Path $configDir 'config.json'
if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    [pscustomobject]@{ schema = 1; relay = [pscustomobject]@{ enabled = $false; note = 'Configure relay credentials here; never commit this file.' }; server = [pscustomobject]@{ onlineMode = $true; allowList = $true } } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configPath -Encoding UTF8
}
$statePath = Join-Path $InstallRoot 'runtime-install.json'
[pscustomobject]@{ schema = 1; installedAtUtc = [DateTime]::UtcNow.ToString('o'); bds = $bds; frp = if ($frpc) { [pscustomobject]@{ version = $FrpVersion; executable = $frpc; source = $FrpUrl } } else { $null }; nodeDependencies = $nodeRoot; officialDownloadPage = $OfficialDownloadPage } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $statePath -Encoding UTF8
Write-Host ('UPDATE OK: runtime installed in ' + $InstallRoot) -ForegroundColor Green
Write-Host ('Configuration: ' + $configPath)
