[CmdletBinding()]
param(
    [switch]$ValidateOnly,
    [string]$UserRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ([string]::IsNullOrWhiteSpace($UserRoot)) {
    if (-not [string]::IsNullOrWhiteSpace($env:MINECRAFT_USER_ROOT)) { $UserRoot = $env:MINECRAFT_USER_ROOT }
    else {
        $leaf = Split-Path -Leaf $PSScriptRoot
        if ($leaf -match '(?i)-dev$') { $UserRoot = Join-Path (Split-Path -Parent $PSScriptRoot) ($leaf -replace '(?i)-dev$', '') }
        else { $UserRoot = $PSScriptRoot }
    }
}
$UserRoot = [IO.Path]::GetFullPath($UserRoot)
$runtimeRoot = Join-Path $UserRoot '.staging'
$receiptPath = Join-Path $runtimeRoot 'runtime-install.json'

function Resolve-Bds {
    if (Test-Path -LiteralPath $receiptPath -PathType Leaf) {
        $state = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
        if ($state.bds -and $state.bds.Root -and (Test-Path -LiteralPath (Join-Path $state.bds.Root 'bedrock_server.exe') -PathType Leaf)) { return $state.bds.Root }
    }
    $candidate = Get-ChildItem -LiteralPath $runtimeRoot -Directory -Filter 'bedrock-*' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        ForEach-Object { $path = Join-Path $_.FullName 'server'; if (Test-Path -LiteralPath (Join-Path $path 'bedrock_server.exe') -PathType Leaf) { $path } } |
        Select-Object -First 1
    if ($candidate) { return $candidate }
    throw 'BDS is not installed. Run Update.cmd first.'
}

function Start-Docker {
    $docker = Get-Command docker -ErrorAction SilentlyContinue
    if ($null -eq $docker) { throw 'Docker CLI is missing. Run Update.cmd first.' }
    $desktop = 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
    $ready = $false
    try { docker info *> $null; $ready = ($LASTEXITCODE -eq 0) } catch { $ready = $false }
    if (-not $ready) {
        if (Test-Path -LiteralPath $desktop -PathType Leaf) { Start-Process -FilePath $desktop -WindowStyle Hidden }
        for ($i = 0; $i -lt 60; $i++) {
            try { docker info *> $null; if ($LASTEXITCODE -eq 0) { Write-Host 'Docker is ready.' -ForegroundColor Green; return } } catch { }
            Start-Sleep -Seconds 2
        }
        throw 'Docker did not become ready within 120 seconds.'
    }
    Write-Host 'Docker is already running.' -ForegroundColor Green
}

$bdsDir = Resolve-Bds
$bdsExe = Join-Path $bdsDir 'bedrock_server.exe'
$properties = Join-Path $bdsDir 'server.properties'
if (-not (Test-Path -LiteralPath $properties -PathType Leaf)) { throw ('Missing BDS configuration: ' + $properties) }
if ($ValidateOnly) {
    if ($null -eq (Get-Command docker -ErrorAction SilentlyContinue)) { throw 'Docker CLI is missing. Run Update.cmd first.' }
    Write-Host ('VALIDATION OK: BDS files and Docker CLI are available at ' + $bdsDir + '. Docker and BDS were not started.') -ForegroundColor Green
    exit 0
}

Start-Docker
$logs = Join-Path $bdsDir 'logs'
New-Item -ItemType Directory -Path $logs -Force | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$stdout = Join-Path $logs ('manager-' + $stamp + '.stdout.log')
$stderr = $stdout + '.err'
$existing = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'bedrock_server.exe' -and $_.ExecutablePath -eq $bdsExe } | Select-Object -First 1
if ($existing) { throw ('BDS is already running with PID ' + $existing.ProcessId) }
$process = Start-Process -FilePath $bdsExe -WorkingDirectory $bdsDir -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
try {
    for ($i = 0; $i -lt 60; $i++) {
        $text = if (Test-Path -LiteralPath $stdout) { Get-Content -LiteralPath $stdout -Raw } else { '' }
        if ($text -match 'Server started\.') { break }
        if ($process.HasExited) { throw ('BDS exited before Server started. See ' + $stdout) }
        Start-Sleep -Seconds 1
    }
    $text = if (Test-Path -LiteralPath $stdout) { Get-Content -LiteralPath $stdout -Raw } else { '' }
    if ($text -notmatch 'Server started\.') { throw ('BDS did not report Server started. See ' + $stdout) }
    Write-Host 'START OK: BDS is running.' -ForegroundColor Green
    Write-Host 'Press Enter to stop this BDS process.'
    [void](Read-Host)
}
finally { if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } }
