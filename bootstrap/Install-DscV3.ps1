#requires -Version 5.1
#requires -RunAsAdministrator
<#
.SYNOPSIS
    One-time bootstrap of a Windows Server for the dsc-fleet management system.

.DESCRIPTION
    Idempotent. Safe to re-run. Performs:
      1. Installs all prerequisites by calling Install-Prerequisites.ps1
         (PowerShell 7, dsc.exe, git, PSResourceGet).
      2. Clones (or refreshes) the *platform* repo (dsc-fleet) at $PlatformRef
         and installs:
             * DscV3.Discovery module to the AllUsers module path
             * Invoke-DscRunner.ps1 to C:\ProgramData\DscV3\bin
      3. Clones the *configs* repo (dsc-fleet-configs) at $ConfigsRef into
         C:\ProgramData\DscV3\repo. The runner refreshes this on each cycle.
      4. Registers a SYSTEM scheduled task (DscV3-Apply) that invokes the
         installed runner every 30 min with up to 30 min jitter.

    Layout (lock-down: only SYSTEM + Administrators write):
      C:\ProgramData\DscV3\bin       — installed runner script
      C:\ProgramData\DscV3\platform  — checkout of dsc-fleet (read-only after install)
      C:\ProgramData\DscV3\repo      — live checkout of dsc-fleet-configs
      C:\ProgramData\DscV3\runs      — local fallback run logs (JSON)
      C:\ProgramData\DscV3\state     — per-group cadence state files

.PARAMETER PlatformRepoUrl
    HTTPS URL of the platform repo (default: anwather/dsc-fleet on GitHub).

.PARAMETER PlatformRef
    Branch or tag of the platform repo. Use a release tag in production.

.PARAMETER ConfigsRepoUrl
    HTTPS URL of the configs repo (default: anwather/dsc-fleet-configs on GitHub).

.PARAMETER ConfigsRef
    Branch or tag of the configs repo. Configs change frequently — 'main' is
    fine here; the runner re-fetches each cycle.

.PARAMETER ReportingEndpoint
    HTTPS URL of the Azure Function ingest endpoint. Empty disables remote reporting.

.PARAMETER DscVersion
    Pinned dsc.exe version. Default 3.1.3.

.PARAMETER ScheduleStart
    Start-of-day for the scheduled task (HH:mm). Repetition is every 30 min.

.PARAMETER GitToken
    Optional GitHub PAT for cloning private repos. Embedded into HTTPS URL as
    https://oauth2:<token>@github.com/... and stripped from the on-disk remote.

.PARAMETER WhatIf
    Show planned changes without applying.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $PlatformRepoUrl   = 'https://github.com/anwather/dsc-fleet.git',
    [string] $PlatformRef       = 'main',
    [string] $ConfigsRepoUrl    = 'https://github.com/anwather/dsc-fleet-configs.git',
    [string] $ConfigsRef        = 'main',
    [string] $ReportingEndpoint = '',
    [string] $DscVersion        = '3.1.3',
    [string] $ScheduleStart     = '03:00',
    [string] $GitToken          = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$root = 'C:\ProgramData\DscV3'
$paths = @{
    Root     = $root
    Bin      = Join-Path $root 'bin'
    Platform = Join-Path $root 'platform'
    Repo     = Join-Path $root 'repo'
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

# Resolve absolute tool paths from the prereq status file (SYSTEM has no PATH refresh)
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
    # Strip token from on-disk remote (always store the public URL there)
    & $gitPath -C $Dest remote set-url origin $Url | Out-Null
}

# --- 4. Platform repo --------------------------------------------------------
Write-Step "Syncing platform repo $PlatformRepoUrl ($PlatformRef)"
if ($PSCmdlet.ShouldProcess($paths.Platform, 'Sync platform repo')) {
    Sync-GitRepo -Url $PlatformRepoUrl -Ref $PlatformRef -Dest $paths.Platform -Token $GitToken
}

# --- 5. Install module + runner from platform repo ---------------------------
Write-Step 'Installing DscV3.Discovery module to AllUsers module path'
$moduleSrc = Join-Path $paths.Platform 'modules\DscV3.Discovery'
$moduleDst = 'C:\Program Files\WindowsPowerShell\Modules\DscV3.Discovery'
if (-not (Test-Path -LiteralPath $moduleSrc)) { throw "Module source missing: $moduleSrc" }
if ($PSCmdlet.ShouldProcess($moduleDst, 'Replace module from platform checkout')) {
    if (Test-Path -LiteralPath $moduleDst) { Remove-Item -LiteralPath $moduleDst -Recurse -Force }
    Copy-Item -LiteralPath $moduleSrc -Destination $moduleDst -Recurse -Force
}
# Same module also available to PS7 sessions via PSModulePath, but we make it
# explicit by mirroring to the PS7 AllUsers path too.
$ps7ModuleDst = 'C:\Program Files\PowerShell\Modules\DscV3.Discovery'
if (Test-Path 'C:\Program Files\PowerShell\Modules') {
    if ($PSCmdlet.ShouldProcess($ps7ModuleDst, 'Mirror module to PS7 AllUsers path')) {
        if (Test-Path -LiteralPath $ps7ModuleDst) { Remove-Item -LiteralPath $ps7ModuleDst -Recurse -Force }
        Copy-Item -LiteralPath $moduleSrc -Destination $ps7ModuleDst -Recurse -Force
    }
}

Write-Step "Installing runner to $($paths.Bin)"
$runnerSrc = Join-Path $paths.Platform 'bootstrap\Invoke-DscRunner.ps1'
$runnerDst = Join-Path $paths.Bin     'Invoke-DscRunner.ps1'
if (-not (Test-Path -LiteralPath $runnerSrc)) { throw "Runner source missing: $runnerSrc" }
if ($PSCmdlet.ShouldProcess($runnerDst, 'Copy runner')) {
    Copy-Item -LiteralPath $runnerSrc -Destination $runnerDst -Force
}

# Refresh DSC PowerShell adapter cache so new module shows up immediately.
$cache = "$env:LOCALAPPDATA\dsc\PSAdapterCache.json"
if (Test-Path -LiteralPath $cache) { Remove-Item -LiteralPath $cache -Force }

# --- 6. Configs repo ---------------------------------------------------------
Write-Step "Syncing configs repo $ConfigsRepoUrl ($ConfigsRef)"
if ($PSCmdlet.ShouldProcess($paths.Repo, 'Sync configs repo')) {
    Sync-GitRepo -Url $ConfigsRepoUrl -Ref $ConfigsRef -Dest $paths.Repo -Token $GitToken
}

# --- 7. Scheduled task -------------------------------------------------------
Write-Step 'Registering scheduled task DscV3-Apply'
$taskName  = 'DscV3-Apply'
$argList   = @(
    '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',
    '-File',  "`"$runnerDst`"",
    '-RepoRoot', "`"$($paths.Repo)`"",
    '-StateRoot',"`"$($paths.State)`"",
    '-RunsRoot', "`"$($paths.Runs)`"",
    '-ConfigsRepoUrl', $ConfigsRepoUrl,
    '-ConfigsRef',     $ConfigsRef
) -join ' '
if ($ReportingEndpoint) { $argList += " -ReportingEndpoint `"$ReportingEndpoint`"" }

$action    = New-ScheduledTaskAction -Execute $pwshPath -Argument $argList
$trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date $ScheduleStart) `
               -RepetitionInterval (New-TimeSpan -Minutes 30)
$trigger.RandomDelay = (New-TimeSpan -Minutes 30).ToString()
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                -StartWhenAvailable -MultipleInstances IgnoreNew `
                -ExecutionTimeLimit (New-TimeSpan -Hours 2)

if ($PSCmdlet.ShouldProcess($taskName, 'Register-ScheduledTask')) {
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force | Out-Null
}

Write-Step 'Bootstrap complete'
Write-Host @"

Next:
    Start-ScheduledTask -TaskName $taskName            # run immediately
    Get-ScheduledTaskInfo -TaskName $taskName          # last run details
    Get-ChildItem $($paths.Runs) | Sort LastWriteTime  # local run logs

"@
