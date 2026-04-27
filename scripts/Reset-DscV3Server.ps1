#requires -Version 5.1
#requires -RunAsAdministrator
<#
.SYNOPSIS
    Wipe the local DSC v3 agent state on this server so it can be cleanly
    re-onboarded (or fully unenrolled).

.DESCRIPTION
    Stops the agent, unregisters the scheduled task that the bootstrap
    scripts create, and (optionally) removes the C:\ProgramData\DscV3
    state tree.

    Specifically:

      1. Unregisters the SYSTEM scheduled task 'DscV3-Apply' if present.
         This is the unified task name used by both the legacy git-mode
         bootstrap (Install-DscV3.ps1) and the dashboard mode
         (Register-DashboardAgent.ps1) — covers both.
      2. Removes the agent identity file (agent.config.json) so that
         re-running Register-DashboardAgent.ps1 doesn't need -Force.
      3. (-RemoveProgramData) deletes the entire C:\ProgramData\DscV3
         directory: cached repo clone, per-group state files, run logs,
         platform copy, installed runner binary. Use this for a true
         factory reset.

    NOT removed (these are baseline tools that survive an unenroll):
      - PowerShell 7 / dsc.exe / git installation
      - Custom DSC module (DscV3.RegFile) under
        $env:ProgramFiles\WindowsPowerShell\Modules
      - PSDscResources, Microsoft.WinGet.DSC modules

    Idempotent. Safe to run when nothing is installed.

.PARAMETER AgentConfig
    Path to the agent identity file to remove. Default
    C:\ProgramData\DscV3\agent.config.json.

.PARAMETER RemoveProgramData
    Also delete the entire C:\ProgramData\DscV3 directory.

.PARAMETER WhatIf
    Show planned changes without applying.

.EXAMPLE
    PS> .\Reset-DscV3Server.ps1
    Unregisters the scheduled task and removes agent.config.json. Keeps
    cached repo / state / runs.

.EXAMPLE
    PS> .\Reset-DscV3Server.ps1 -RemoveProgramData
    Full reset — wipes C:\ProgramData\DscV3.

.EXAMPLE
    PS> .\Reset-DscV3Server.ps1 -WhatIf
    Show what would change without applying.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $AgentConfig       = 'C:\ProgramData\DscV3\agent.config.json',
    [switch] $RemoveProgramData
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

function Write-Step([string] $message) {
    Write-Host ("==> {0}" -f $message) -ForegroundColor Cyan
}

# --- 1. Scheduled task ------------------------------------------------------
Write-Step "Looking for scheduled task 'DscV3-Apply'"
$task = Get-ScheduledTask -TaskName 'DscV3-Apply' -ErrorAction SilentlyContinue
if ($task) {
    $action = $task.Actions | Select-Object -First 1
    Write-Host ("    found: {0} {1}" -f $action.Execute, $action.Arguments)
    if ($PSCmdlet.ShouldProcess('DscV3-Apply', 'Unregister-ScheduledTask')) {
        Unregister-ScheduledTask -TaskName 'DscV3-Apply' -Confirm:$false
        Write-Host '    unregistered.'
    }
}
else {
    Write-Host '    not present.'
}

# --- 2. Agent identity ------------------------------------------------------
Write-Step 'Removing agent identity file'
if (Test-Path -LiteralPath $AgentConfig) {
    Write-Host ("    found: {0}" -f $AgentConfig)
    if ($PSCmdlet.ShouldProcess($AgentConfig, 'Remove-Item')) {
        Remove-Item -LiteralPath $AgentConfig -Force
        Write-Host '    removed.'
    }
}
else {
    Write-Host ("    not present: {0}" -f $AgentConfig)
}

# --- 3. Optional full wipe --------------------------------------------------
if ($RemoveProgramData) {
    Write-Step 'Removing C:\ProgramData\DscV3 (full reset)'
    $root = 'C:\ProgramData\DscV3'
    if (Test-Path -LiteralPath $root) {
        if ($PSCmdlet.ShouldProcess($root, 'Remove-Item -Recurse -Force')) {
            try {
                takeown.exe /F $root /R /D Y | Out-Null
                icacls.exe   $root /grant Administrators:F /T /Q | Out-Null
            }
            catch {
                Write-Warning ("Failed to relax ACL on {0}: {1}" -f $root, $_)
            }
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $root) {
                throw "Could not fully remove $root - files still present (something may be holding them open)."
            }
            Write-Host ("    wiped: {0}" -f $root)
        }
    }
    else {
        Write-Host ("    not present: {0}" -f $root)
    }
}
else {
    Write-Host @"

Note: state, runs, and the cached revision YAML under C:\ProgramData\DscV3
were retained. Pass -RemoveProgramData for a full wipe.
"@
}

Write-Host ''
Write-Step 'Reset complete'
Write-Host @"

To re-onboard this server to a dashboard:

    .\bootstrap\Install-DscV3.ps1                       # only if you used -RemoveProgramData
    .\bootstrap\Register-DashboardAgent.ps1 ``
        -DashboardUrl   '<https://your-dashboard>' ``
        -ProvisionToken '<token from the dashboard UI>'
"@
