#requires -Version 5.1
#requires -RunAsAdministrator
<#
.SYNOPSIS
    Install all prerequisites for DSC v3 fleet management on a Windows Server.

.DESCRIPTION
    SYSTEM-context safe. Installs (idempotently):
      * winget (resolved by absolute path under C:\Program Files\WindowsApps)
      * PowerShell 7        (Microsoft.PowerShell)
      * DSC v3 CLI          (Microsoft.DSC, pinned)
      * Git for Windows     (Git.Git)
      * PSResourceGet       (NuGet provider trusted, PSGallery trusted, then Install-Module)

    All resolution uses absolute paths -- never relies on PATH being refreshed
    inside the current SYSTEM session.

    Emits a structured status object at the end so callers (Invoke-AzVMRunCommand,
    a remoting script, CI, etc.) can confirm "all green" with a single read.

.PARAMETER DscVersion
    Pinned dsc.exe winget version. Default 3.1.3.

.PARAMETER PwshVersion
    Optional pinned PowerShell 7 winget version. Empty = latest.

.PARAMETER GitVersion
    Optional pinned Git for Windows winget version. Empty = latest.

.PARAMETER SkipGit
    Skip git installation (e.g. when you'll stage the repo another way).

.OUTPUTS
    Hashtable / pscustomobject with one row per component plus a top-level
    AllInstalled boolean. Also written to C:\ProgramData\DscV3\prereq-status.json.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install-Prerequisites.ps1
#>
[CmdletBinding()]
param(
    [string] $DscVersion  = '3.1.3',
    [string] $PwshVersion = '',
    [string] $GitVersion  = '',
    [switch] $SkipGit
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$logRoot = 'C:\ProgramData\DscV3'
if (-not (Test-Path -LiteralPath $logRoot)) { New-Item -ItemType Directory -Path $logRoot -Force | Out-Null }
$logFile = Join-Path $logRoot 'prereq-install.log'

function Write-Step([string] $msg) {
    $line = "[{0:yyyy-MM-ddTHH:mm:ssZ}] ==> {1}" -f [DateTime]::UtcNow, $msg
    Write-Host $line -ForegroundColor Cyan
    Add-Content -LiteralPath $logFile -Value $line
}

function Write-Info([string] $msg) {
    $line = "[{0:yyyy-MM-ddTHH:mm:ssZ}]     {1}" -f [DateTime]::UtcNow, $msg
    Write-Host $line
    Add-Content -LiteralPath $logFile -Value $line
}

# ---------------------------------------------------------------------------
# Locate winget by absolute path (SYSTEM does not have it on PATH)
# ---------------------------------------------------------------------------
function Get-WingetPath {
    $candidate = Get-ChildItem -Path 'C:\Program Files\WindowsApps' `
        -Filter winget.exe -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match 'Microsoft\.DesktopAppInstaller_' } |
        Sort-Object { [version]($_.Directory.Name -replace '^Microsoft\.DesktopAppInstaller_([\d\.]+).*','$1') } -Descending |
        Select-Object -First 1 -ExpandProperty FullName
    return $candidate
}

function Install-WingetPackage {
    param(
        [Parameter(Mandatory)] [string] $Id,
        [string] $Version = ''
    )
    $winget = Get-WingetPath
    if (-not $winget) {
        throw "winget binary not found under C:\Program Files\WindowsApps. Install App Installer (Microsoft.DesktopAppInstaller) first."
    }
    $argsList = @(
        'install', '--id', $Id, '--exact', '--silent',
        '--accept-package-agreements', '--accept-source-agreements',
        '--scope', 'machine'
    )
    if ($Version) { $argsList += @('--version', $Version) }
    Write-Info "winget $($argsList -join ' ')"
    & $winget @argsList 2>&1 | ForEach-Object { Write-Info $_ }
    # winget exit codes: 0 = success, -1978335189 = no applicable update / already installed
    if ($LASTEXITCODE -notin 0, -1978335189) {
        throw "winget install $Id failed with exit code $LASTEXITCODE."
    }
}

# ---------------------------------------------------------------------------
# Component resolvers (absolute paths, post-install)
# ---------------------------------------------------------------------------
function Resolve-Pwsh {
    $candidates = @(
        'C:\Program Files\PowerShell\7\pwsh.exe',
        'C:\Program Files\PowerShell\7-preview\pwsh.exe'
    )
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    return (Get-Command pwsh -ErrorAction SilentlyContinue).Source
}

function Resolve-Dsc {
    $candidates = @(
        "$env:ProgramFiles\DSC\dsc.exe",
        "$env:LOCALAPPDATA\Microsoft\WinGet\Links\dsc.exe",
        "$env:ProgramFiles\WinGet\Links\dsc.exe"
    )
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    # Fall back to Get-ChildItem search across known winget targets
    $found = Get-ChildItem -Path 'C:\Program Files' -Filter dsc.exe -Recurse -ErrorAction SilentlyContinue |
                Select-Object -First 1 -ExpandProperty FullName
    if ($found) { return $found }
    return (Get-Command dsc -ErrorAction SilentlyContinue).Source
}

function Resolve-Git {
    $candidates = @(
        'C:\Program Files\Git\cmd\git.exe',
        'C:\Program Files\Git\bin\git.exe'
    )
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    return (Get-Command git -ErrorAction SilentlyContinue).Source
}

function Get-VersionSafe {
    param([string] $ExePath, [string[]] $Args = @('--version'))
    if (-not $ExePath -or -not (Test-Path -LiteralPath $ExePath)) { return $null }
    try {
        $out = (& $ExePath @Args) 2>&1 | Select-Object -First 1
        return ($out | Out-String).Trim()
    } catch {
        return "ERROR: $_"
    }
}

# ---------------------------------------------------------------------------
# 1. PowerShell 7
# ---------------------------------------------------------------------------
Write-Step 'PowerShell 7'
$pwsh = Resolve-Pwsh
if (-not $pwsh) {
    Install-WingetPackage -Id 'Microsoft.PowerShell' -Version $PwshVersion
    $pwsh = Resolve-Pwsh
} else {
    Write-Info "Already present at $pwsh"
}

# ---------------------------------------------------------------------------
# 2. DSC v3 CLI
# ---------------------------------------------------------------------------
Write-Step "DSC v3 CLI (target $DscVersion)"
$dsc = Resolve-Dsc
$dscCurrent = if ($dsc) { Get-VersionSafe -ExePath $dsc } else { $null }
$needDsc = $true
if ($dscCurrent) {
    $cleanVer = ($dscCurrent -replace '^dsc\s+','').Trim()
    if ($cleanVer -eq $DscVersion) {
        Write-Info "Already at pinned $DscVersion"
        $needDsc = $false
    } else {
        Write-Info "Found $cleanVer, will install pinned $DscVersion"
    }
}
if ($needDsc) {
    Install-WingetPackage -Id 'Microsoft.DSC' -Version $DscVersion
    $dsc = Resolve-Dsc
}

# ---------------------------------------------------------------------------
# 3. Git for Windows
# ---------------------------------------------------------------------------
$git = $null
if (-not $SkipGit) {
    Write-Step 'Git for Windows'
    $git = Resolve-Git
    if (-not $git) {
        Install-WingetPackage -Id 'Git.Git' -Version $GitVersion
        $git = Resolve-Git
    } else {
        Write-Info "Already present at $git"
    }
} else {
    Write-Step 'Git for Windows (skipped)'
}

# ---------------------------------------------------------------------------
# 4. PSResourceGet (PS 5.1 SYSTEM-safe install path)
# ---------------------------------------------------------------------------
Write-Step 'Microsoft.PowerShell.PSResourceGet'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
    Write-Info 'Installing NuGet PackageProvider'
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null
}
if ((Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue).InstallationPolicy -ne 'Trusted') {
    Write-Info 'Trusting PSGallery'
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
}
$psrg = Get-Module -ListAvailable Microsoft.PowerShell.PSResourceGet | Sort-Object Version -Descending | Select-Object -First 1
if (-not $psrg) {
    Install-Module Microsoft.PowerShell.PSResourceGet -Scope AllUsers -Force -AllowClobber
    $psrg = Get-Module -ListAvailable Microsoft.PowerShell.PSResourceGet | Sort-Object Version -Descending | Select-Object -First 1
} else {
    Write-Info "Already present (v$($psrg.Version))"
}

# ---------------------------------------------------------------------------
# Build status report
# ---------------------------------------------------------------------------
$status = [ordered]@{
    Timestamp     = [DateTime]::UtcNow.ToString('s') + 'Z'
    Host          = $env:COMPUTERNAME
    OS            = (Get-CimInstance Win32_OperatingSystem).Caption
    Components    = [ordered]@{
        Pwsh = [ordered]@{
            Required  = $true
            Installed = [bool]$pwsh
            Path      = $pwsh
            Version   = if ($pwsh) { Get-VersionSafe -ExePath $pwsh -Args @('-NoProfile','-Command','$PSVersionTable.PSVersion.ToString()') } else { $null }
        }
        Dsc = [ordered]@{
            Required  = $true
            Installed = [bool]$dsc
            Path      = $dsc
            Version   = if ($dsc) { (Get-VersionSafe -ExePath $dsc) -replace '^dsc\s+','' } else { $null }
            Pinned    = $DscVersion
        }
        Git = [ordered]@{
            Required  = (-not $SkipGit)
            Installed = [bool]$git
            Path      = $git
            Version   = if ($git) { (Get-VersionSafe -ExePath $git) -replace '^git version\s+','' } else { $null }
        }
        PSResourceGet = [ordered]@{
            Required  = $true
            Installed = [bool]$psrg
            Path      = if ($psrg) { $psrg.Path } else { $null }
            Version   = if ($psrg) { $psrg.Version.ToString() } else { $null }
        }
        Winget = [ordered]@{
            Required  = $true
            Installed = [bool](Get-WingetPath)
            Path      = (Get-WingetPath)
            Version   = if (Get-WingetPath) { (Get-VersionSafe -ExePath (Get-WingetPath)) } else { $null }
        }
    }
}

$missing = @()
foreach ($name in $status.Components.Keys) {
    $c = $status.Components[$name]
    if ($c.Required -and -not $c.Installed) { $missing += $name }
}
$status.AllInstalled = ($missing.Count -eq 0)
$status.Missing      = $missing

# Persist
$statusPath = Join-Path $logRoot 'prereq-status.json'
($status | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $statusPath -Encoding utf8

# Console summary
Write-Host ''
Write-Host '================ DSC v3 Prerequisites ================' -ForegroundColor Cyan
foreach ($name in $status.Components.Keys) {
    $c = $status.Components[$name]
    $mark = if ($c.Installed) { '[ OK ]' } elseif ($c.Required) { '[FAIL]' } else { '[skip]' }
    $color = if ($c.Installed) { 'Green' } elseif ($c.Required) { 'Red' } else { 'Yellow' }
    $ver = if ($c.Version) { " v$($c.Version)" } else { '' }
    Write-Host ("  {0}  {1,-15}{2}" -f $mark, $name, $ver) -ForegroundColor $color
    if ($c.Path) { Write-Host ("           {0}" -f $c.Path) -ForegroundColor DarkGray }
}
Write-Host ''
if ($status.AllInstalled) {
    Write-Host 'ALL PREREQUISITES INSTALLED.' -ForegroundColor Green
} else {
    Write-Host ("MISSING: {0}" -f ($missing -join ', ')) -ForegroundColor Red
}
Write-Host "Status JSON: $statusPath"
Write-Host '======================================================' -ForegroundColor Cyan

# Exit code reflects readiness
if (-not $status.AllInstalled) { exit 1 }
exit 0
