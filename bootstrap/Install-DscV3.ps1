#requires -Version 5.1
#requires -RunAsAdministrator
<#
.SYNOPSIS
    One-time bootstrap of a Windows Server for the dsc-fleet dashboard.

.DESCRIPTION
    Idempotent. Safe to re-run. Performs:
      1. Installs all prerequisites by calling Install-Prerequisites.ps1
         (PowerShell 7, dsc.exe, git, PSResourceGet).
      2. Creates the C:\ProgramData\DscV3 layout with locked-down ACL
         (SYSTEM + Administrators full; Users read).
      3. Clones (or refreshes) the *platform* repo (dsc-fleet) at $PlatformRef
         into C:\ProgramData\DscV3\platform and installs:
             * DscV3.RegFile module to the AllUsers module path
             * Invoke-DscRunner.ps1 to C:\ProgramData\DscV3\bin

    NOTE: This script does NOT clone any configs repo and does NOT create the
    DscV3-Apply scheduled task. Both responsibilities belong to
    Register-DashboardAgent.ps1, which is invoked next during provisioning
    with the dashboard URL + provision token. The runner is dashboard-only:
    configurations are pulled from the API per-cycle, not from a git repo.

    Layout:
      C:\ProgramData\DscV3\bin       installed runner script
      C:\ProgramData\DscV3\platform  checkout of dsc-fleet
      C:\ProgramData\DscV3\runs      local fallback run logs (JSON)
      C:\ProgramData\DscV3\state     per-cycle agent state files
      C:\ProgramData\DscV3\bootstrap copy of the bootstrap scripts (provision job)

.PARAMETER PlatformRepoUrl
    HTTPS URL of the platform repo (default: anwather/dsc-fleet on GitHub).

.PARAMETER PlatformRef
    Branch or tag of the platform repo. Use a release tag in production.

.PARAMETER DscVersion
    Pinned dsc.exe version. Default 3.1.3.

.PARAMETER GitToken
    Optional GitHub PAT for cloning a private platform repo.

.PARAMETER WhatIf
    Show planned changes without applying.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $PlatformRepoUrl = 'https://github.com/anwather/dsc-fleet.git',
    [string] $PlatformRef     = 'main',
    [string] $DscVersion      = '3.1.3',
    [string] $GitToken        = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$root = 'C:\ProgramData\DscV3'
$paths = @{
    Root     = $root
    Bin      = Join-Path $root 'bin'
    Platform = Join-Path $root 'platform'
    Runs     = Join-Path $root 'runs'
    State    = Join-Path $root 'state'
}

function Write-Step([string] $message) { Write-Host "==> $message" -ForegroundColor Cyan }

function Add-TokenToUrl([string] $url, [string] $token) {
    if (-not $token) { return $url }
    if ($url -notmatch '^https://') { return $url }
    return ($url -replace '^https://','https://oauth2:' + $token + '@')
}

# --- 1. Prerequisites --------------------------------------------------------
Write-Step 'Installing prerequisites (winget, pwsh, dsc, git, PSResourceGet)'
$prereq = Join-Path $PSScriptRoot 'Install-Prerequisites.ps1'
if (-not (Test-Path -LiteralPath $prereq)) {
    throw "Install-Prerequisites.ps1 not found alongside this script ($prereq)."
}
if ($PSCmdlet.ShouldProcess($prereq, "Run with -DscVersion $DscVersion")) {
    & $prereq -DscVersion $DscVersion
    if ($LASTEXITCODE -ne 0) { throw "Install-Prerequisites.ps1 reported missing components (exit $LASTEXITCODE). See C:\ProgramData\DscV3\prereq-status.json." }
}

$status = Get-Content -Raw -LiteralPath (Join-Path $root 'prereq-status.json') | ConvertFrom-Json
$pwshPath = $status.Components.Pwsh.Path
$gitPath  = $status.Components.Git.Path
if (-not $pwshPath) { throw 'pwsh path not resolved by prereq installer.' }
if (-not $gitPath)  { throw 'git path not resolved by prereq installer.' }

# --- 2. Layout ---------------------------------------------------------------
Write-Step "Creating layout under $root"
foreach ($p in $paths.Values) {
    if (-not (Test-Path -LiteralPath $p)) {
        if ($PSCmdlet.ShouldProcess($p, 'New-Item -ItemType Directory')) {
            New-Item -ItemType Directory -Path $p -Force | Out-Null
        }
    }
}
if ($PSCmdlet.ShouldProcess($root, 'Restrict ACL to SYSTEM + Administrators')) {
    $acl = Get-Acl -LiteralPath $root
    $acl.SetAccessRuleProtection($true, $false)
    $rules = @(
        New-Object System.Security.AccessControl.FileSystemAccessRule('SYSTEM',         'FullControl','ContainerInherit,ObjectInherit','None','Allow')
        New-Object System.Security.AccessControl.FileSystemAccessRule('Administrators', 'FullControl','ContainerInherit,ObjectInherit','None','Allow')
        New-Object System.Security.AccessControl.FileSystemAccessRule('Users',          'ReadAndExecute','ContainerInherit,ObjectInherit','None','Allow')
    )
    $acl.Access | ForEach-Object { [void]$acl.RemoveAccessRule($_) }
    $rules     | ForEach-Object { $acl.AddAccessRule($_) }
    Set-Acl -LiteralPath $root -AclObject $acl
}

# --- 3. Helper: clone or refresh a repo --------------------------------------
function Sync-GitRepo {
    param(
        [Parameter(Mandatory)] [string] $Url,
        [Parameter(Mandatory)] [string] $Ref,
        [Parameter(Mandatory)] [string] $Dest,
        [string] $Token = ''
    )
    $authedUrl = Add-TokenToUrl $Url $Token
    if (Test-Path -LiteralPath (Join-Path $Dest '.git')) {
        Write-Host "    refresh: $Dest"
        & $gitPath -C $Dest remote set-url origin $authedUrl | Out-Null
        & $gitPath -C $Dest fetch --tags --prune origin | Out-Host
        & $gitPath -C $Dest -c advice.detachedHead=false checkout --force $Ref | Out-Host
        $isTag = (& $gitPath -C $Dest tag --list $Ref)
        if (-not $isTag) {
            & $gitPath -C $Dest reset --hard "origin/$Ref" | Out-Host
        }
    } else {
        Write-Host "    clone : $Url ($Ref) -> $Dest"
        & $gitPath clone --quiet $authedUrl $Dest | Out-Host
        & $gitPath -C $Dest -c advice.detachedHead=false checkout --force $Ref | Out-Host
    }
    & $gitPath -C $Dest remote set-url origin $Url | Out-Null
}

# --- 4. Platform repo --------------------------------------------------------
Write-Step "Syncing platform repo $PlatformRepoUrl ($PlatformRef)"
if ($PSCmdlet.ShouldProcess($paths.Platform, 'Sync platform repo')) {
    Sync-GitRepo -Url $PlatformRepoUrl -Ref $PlatformRef -Dest $paths.Platform -Token $GitToken
}

# --- 5. Install module + runner from platform repo ---------------------------
Write-Step 'Installing DscV3.RegFile module to AllUsers module path'
$moduleSrc = Join-Path $paths.Platform 'modules\DscV3.RegFile'
$moduleDst = 'C:\Program Files\WindowsPowerShell\Modules\DscV3.RegFile'
if (-not (Test-Path -LiteralPath $moduleSrc)) { throw "Module source missing: $moduleSrc" }
if ($PSCmdlet.ShouldProcess($moduleDst, 'Replace module from platform checkout')) {
    if (Test-Path -LiteralPath $moduleDst) { Remove-Item -LiteralPath $moduleDst -Recurse -Force }
    Copy-Item -LiteralPath $moduleSrc -Destination $moduleDst -Recurse -Force
}
$ps7ModuleDst = 'C:\Program Files\PowerShell\Modules\DscV3.RegFile'
if (Test-Path 'C:\Program Files\PowerShell\Modules') {
    if ($PSCmdlet.ShouldProcess($ps7ModuleDst, 'Mirror module to PS7 AllUsers path')) {
        if (Test-Path -LiteralPath $ps7ModuleDst) { Remove-Item -LiteralPath $ps7ModuleDst -Recurse -Force }
        Copy-Item -LiteralPath $moduleSrc -Destination $ps7ModuleDst -Recurse -Force
    }
}
foreach ($legacy in @(
    'C:\Program Files\WindowsPowerShell\Modules\DscV3.Discovery'
    'C:\Program Files\PowerShell\Modules\DscV3.Discovery'
)) {
    if (Test-Path -LiteralPath $legacy) {
        Write-Host "    removing legacy module: $legacy"
        Remove-Item -LiteralPath $legacy -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Step "Installing runner to $($paths.Bin)"
$runnerSrc = Join-Path $paths.Platform 'bootstrap\Invoke-DscRunner.ps1'
$runnerDst = Join-Path $paths.Bin     'Invoke-DscRunner.ps1'
if (-not (Test-Path -LiteralPath $runnerSrc)) { throw "Runner source missing: $runnerSrc" }
if ($PSCmdlet.ShouldProcess($runnerDst, 'Copy runner')) {
    Copy-Item -LiteralPath $runnerSrc -Destination $runnerDst -Force
}

$cache = "$env:LOCALAPPDATA\dsc\PSAdapterCache.json"
if (Test-Path -LiteralPath $cache) { Remove-Item -LiteralPath $cache -Force }

# --- 6. Remove any pre-existing DscV3-Apply task -----------------------------
# Earlier versions of this script registered a git-mode scheduled task here.
# Dashboard provisioning hands ownership of the task to
# Register-DashboardAgent.ps1, so we proactively unregister any existing one
# to make sure the dashboard re-registration is the only definition that
# survives.
$existing = Get-ScheduledTask -TaskName 'DscV3-Apply' -ErrorAction SilentlyContinue
if ($existing) {
    if ($PSCmdlet.ShouldProcess('DscV3-Apply', 'Unregister legacy scheduled task (will be re-created by Register-DashboardAgent)')) {
        Unregister-ScheduledTask -TaskName 'DscV3-Apply' -Confirm:$false
    }
}

# --- 7. Remove any stale legacy git-mode configs checkout --------------------
$legacyRepo = Join-Path $root 'repo'
if (Test-Path -LiteralPath $legacyRepo) {
    if ($PSCmdlet.ShouldProcess($legacyRepo, 'Remove legacy configs checkout')) {
        Remove-Item -LiteralPath $legacyRepo -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Step 'Install-DscV3 complete'
Write-Host @"

Next:
    Register-DashboardAgent.ps1 -DashboardUrl <url> -ProvisionToken <token>
    (the dashboard provisioning job invokes that script automatically)

"@