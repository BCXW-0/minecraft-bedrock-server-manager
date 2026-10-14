[CmdletBinding()]
param(
    [ValidateSet('Sync', 'Validate', 'Status')]
    [string]$Action = 'Status',
    [ValidateSet('Preview', 'Apply')]
    [string]$Mode = 'Preview',
    [string]$UserRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$DevRoot = (Resolve-Path -LiteralPath $PSScriptRoot).Path.TrimEnd('\')
if ([string]::IsNullOrWhiteSpace($UserRoot)) {
    $leaf = Split-Path -Leaf $DevRoot
    if ($leaf -match '(?i)-dev$') {
        $UserRoot = Join-Path (Split-Path -Parent $DevRoot) ($leaf -replace '(?i)-dev$', '')
    }
    else {
        throw 'Pass -UserRoot when Admin.ps1 is not inside a *-Dev directory.'
    }
}
$UserRoot = [IO.Path]::GetFullPath($UserRoot).TrimEnd('\')
if ($DevRoot.Equals($UserRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Development and user roots must differ.' }
if (-not (Test-Path -LiteralPath $UserRoot -PathType Container)) { throw ('User root does not exist: ' + $UserRoot) }

$RootFiles = @('Update.ps1', 'Update.cmd', 'Start.ps1', 'Start.cmd', 'Admin.ps1', 'Admin.cmd', 'MANUAL.md', '.gitignore')
$TreeRoots = @('deploy', 'package', 'TrueIPGetter-Release')
$ExcludedNames = @('.git', 'node_modules', '__pycache__')
$ExcludedExtensions = @('.dll', '.exe', '.pdb', '.zip', '.tgz', '.gz', '.log', '.err', '.out', '.pyc')

function Test-Excluded([IO.FileInfo]$File) {
    foreach ($name in $ExcludedNames) {
        if ($File.FullName -split '\\' -contains $name) { return $true }
    }
    return $ExcludedExtensions -contains $File.Extension.ToLowerInvariant()
}

function Get-Mapping {
    $paths = New-Object 'System.Collections.Generic.List[string]'
    foreach ($name in $RootFiles) {
        $source = Join-Path $DevRoot $name
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw ('Missing development file: ' + $name) }
        [void]$paths.Add($name)
    }
    foreach ($tree in $TreeRoots) {
        $sourceRoot = Join-Path $DevRoot $tree
        if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) { throw ('Missing development directory: ' + $tree) }
        foreach ($file in Get-ChildItem -LiteralPath $sourceRoot -Recurse -File -Force) {
            if (-not (Test-Excluded $file)) { [void]$paths.Add($file.FullName.Substring($DevRoot.Length + 1)) }
        }
    }
    return @($paths | Sort-Object -Unique)
}

function Invoke-Sync {
    $changed = 0
    foreach ($relative in Get-Mapping) {
        $source = Join-Path $DevRoot $relative
        $destination = Join-Path $UserRoot $relative
        $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
        $destinationHash = if (Test-Path -LiteralPath $destination -PathType Leaf) { (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash } else { $null }
        if ($sourceHash -eq $destinationHash) { continue }
        $changed++
        if ($Mode -eq 'Preview') { Write-Host ('CHANGE ' + $relative) -ForegroundColor Yellow; continue }
        $destinationDir = Split-Path -Parent $destination
        [void][IO.Directory]::CreateDirectory($destinationDir)
        Copy-Item -LiteralPath $source -Destination $destination -Force
        if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ne $sourceHash) { throw ('Hash mismatch after copy: ' + $relative) }
        Write-Host ('COPIED ' + $relative) -ForegroundColor Green
    }
    if ($changed -eq 0) { Write-Host 'SYNC OK: core files are already identical.' -ForegroundColor Green }
    elseif ($Mode -eq 'Preview') { Write-Host ('PREVIEW: ' + $changed + ' file(s) would be copied.') -ForegroundColor Yellow }
    else { Write-Host ('SYNC OK: ' + $changed + ' file(s) copied and verified.') -ForegroundColor Green }
}

function Invoke-Validate {
    $required = @('Update.ps1', 'Start.ps1', 'Admin.ps1', 'MANUAL.md')
    foreach ($name in $required) { if (-not (Test-Path -LiteralPath (Join-Path $DevRoot $name) -PathType Leaf)) { throw ('Missing required entrypoint: ' + $name) } }
    $unexpected = @(Get-ChildItem -LiteralPath $DevRoot -File | Where-Object { $RootFiles -notcontains $_.Name } | Select-Object -ExpandProperty Name)
    if ($unexpected.Count -gt 0) { throw ('Unexpected root files: ' + ($unexpected -join ', ')) }
    foreach ($runtimeName in @('.staging', 'bds_downloads', 'staging_bds_smoke')) {
        if (Test-Path -LiteralPath (Join-Path $DevRoot $runtimeName)) { throw ('Runtime content must stay out of development zone: ' + $runtimeName) }
    }
    Write-Host 'VALIDATION OK: development zone contains only canonical root files and source trees.' -ForegroundColor Green
}

function Invoke-Status {
    $receipt = Join-Path (Join-Path $UserRoot '.staging') 'runtime-install.json'
    Write-Host ('Development zone: ' + $DevRoot)
    Write-Host ('User zone: ' + $UserRoot)
    Write-Host ('Docker CLI: ' + [bool](Get-Command docker -ErrorAction SilentlyContinue))
    if (Test-Path -LiteralPath $receipt -PathType Leaf) {
        $state = Get-Content -LiteralPath $receipt -Raw | ConvertFrom-Json
        if ($state.bds) {
            Write-Host ('Installed BDS: ' + $state.bds.version)
            Write-Host ('BDS path: ' + $state.bds.root)
        }
        else { Write-Host 'Installed BDS: skipped or not installed.' -ForegroundColor Yellow }
        if ($state.nodeDependencies) { Write-Host ('Node dependencies: ' + $state.nodeDependencies) }
    }
    else { Write-Host 'Installed BDS: no runtime receipt found.' -ForegroundColor Yellow }
}

switch ($Action) {
    'Sync' { Invoke-Sync }
    'Validate' { Invoke-Validate }
    'Status' { Invoke-Status }
}
