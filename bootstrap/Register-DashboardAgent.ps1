#requires -Version 5.1
#requires -RunAsAdministrator
<#
.SYNOPSIS
    Register this Windows Server with a dsc-fleet-dashboard instance and
    reconfigure the local DscV3-Apply scheduled task to run in dashboard mode.

.DESCRIPTION
    POSTs to /api/agents/register with a one-time provision token, persists
    the issued agentId + agentApiKey to C:\ProgramData\DscV3\agent.config.json
    (ACL: SYSTEM + Administrators full control; Users no access), and
    re-registers the scheduled task to invoke Invoke-DscRunner.ps1 with
    -Mode Dashboard.

    Idempotent: if agent.config.json already exists and the token matches a
    server already registered for this VM, the script will refuse to re-register
    unless -Force is passed.

.PARAMETER DashboardUrl
    Base URL of the dashboard (e.g. https://dsc-fleet.contoso.com). No trailing slash.

.PARAMETER ProvisionToken
    Single-use token issued by POST /api/servers/:id/provision-token.

.PARAMETER AgentConfig
    Where to persist the agent config. Default C:\ProgramData\DscV3\agent.config.json.

.PARAMETER RunnerScript
    Path to the installed Invoke-DscRunner.ps1. Default C:\ProgramData\DscV3\bin\Invoke-DscRunner.ps1.

.PARAMETER ScheduleEverySeconds
    How often the agent polls. Default 60.

.PARAMETER RunAsUser
    Optional. Identity the DscV3-Apply scheduled task should run under.
    Examples:
        ''                       (default) -> NT AUTHORITY\SYSTEM
        'NT AUTHORITY\SYSTEM'    SYSTEM (explicit)
        '.\dscagent'             local Administrator account
        'CONTOSO\dscagent'       domain user
        'CONTOSO\dscgmsa$'       group Managed Service Account (also pass -RunAsGmsa)
    The account MUST be a member of local Administrators (the runner installs
    PS modules under Program Files, restarts services, writes HKLM, etc.).

.PARAMETER RunAsPassword
    SecureString. Required when -RunAsUser is set to a regular account
    (not SYSTEM, NetworkService, LocalService, or a gMSA).
    The plaintext is materialized only at the moment Register-ScheduledTask
    is called, then zeroed. Windows stores the credential as an LSA secret
    on this machine -- DPAPI-protected with a machine-bound master key.

.PARAMETER RunAsGmsa
    Switch. Indicates -RunAsUser refers to a group Managed Service Account
    (no password; Windows fetches it from AD). Requires the VM to be domain
    joined and the gMSA installed via Install-ADServiceAccount.

.PARAMETER Force
    Overwrite an existing agent.config.json.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $DashboardUrl,
    [Parameter(Mandatory)] [string] $ProvisionToken,
    [string]       $AgentConfig          = 'C:\ProgramData\DscV3\agent.config.json',
    [string]       $RunnerScript         = 'C:\ProgramData\DscV3\bin\Invoke-DscRunner.ps1',
    [int]          $ScheduleEverySeconds = 60,
    [string]       $RunAsUser            = '',
    [SecureString] $RunAsPassword,
    [switch]       $RunAsGmsa,
    [switch]       $Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

function Write-Step([string] $m) { Write-Host "==> $m" -ForegroundColor Cyan }

if ((Test-Path -LiteralPath $AgentConfig) -and -not $Force) {
    throw "Agent config already exists at $AgentConfig — pass -Force to overwrite."
}
if (-not (Test-Path -LiteralPath $RunnerScript)) {
    throw "Runner script not found at $RunnerScript — run Install-DscV3.ps1 first."
}

$base = $DashboardUrl.TrimEnd('/')

# --- 1. Register with dashboard ---------------------------------------------
Write-Step "Registering with $base"
$os = Get-CimInstance Win32_OperatingSystem
$body = @{
    provisionToken = $ProvisionToken
    hostname       = $env:COMPUTERNAME
    osCaption      = $os.Caption
    osVersion      = $os.Version
    agentVersion   = '0.1.0-dashboard'
} | ConvertTo-Json -Compress

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$resp = Invoke-RestMethod -Method POST -Uri "$base/api/agents/register" `
    -ContentType 'application/json' -Body $body -TimeoutSec 60

if (-not $resp.agentId -or -not $resp.agentApiKey) {
    throw "Register response missing agentId / agentApiKey: $($resp | ConvertTo-Json -Compress)"
}

# --- 2. Persist agent.config.json with restrictive ACL ----------------------
Write-Step "Writing $AgentConfig"
$configDir = Split-Path -Path $AgentConfig -Parent
if (-not (Test-Path -LiteralPath $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }

$configObj = [pscustomobject]@{
    DashboardUrl   = $base
    AgentId        = $resp.agentId
    AgentApiKey    = $resp.agentApiKey
    RegisteredUtc  = (Get-Date).ToUniversalTime().ToString('o')
    Hostname       = $env:COMPUTERNAME
}
$configObj | ConvertTo-Json | Set-Content -LiteralPath $AgentConfig -Encoding UTF8

# Tight ACL: SYSTEM + Administrators full, Users denied (inherit off).
$acl = Get-Acl -LiteralPath $AgentConfig
$acl.SetAccessRuleProtection($true, $false)
$acl.Access | ForEach-Object { [void]$acl.RemoveAccessRule($_) }
$rules = @(
    New-Object System.Security.AccessControl.FileSystemAccessRule('SYSTEM',         'FullControl','Allow')
    New-Object System.Security.AccessControl.FileSystemAccessRule('Administrators', 'FullControl','Allow')
)
foreach ($r in $rules) { $acl.AddAccessRule($r) }
Set-Acl -LiteralPath $AgentConfig -AclObject $acl

# --- 3. Re-register scheduled task with -Mode Dashboard ---------------------
Write-Step 'Reconfiguring scheduled task DscV3-Apply for dashboard mode'
$taskName = 'DscV3-Apply'
$pwshPath = (Get-Command pwsh).Source

$argList = @(
    '-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass',
    '-File',  "`"$RunnerScript`"",
    '-Mode',  'Dashboard',
    '-AgentConfig', "`"$AgentConfig`""
) -join ' '

$action    = New-ScheduledTaskAction -Execute $pwshPath -Argument $argList
$trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddMinutes(1) `
                -RepetitionInterval (New-TimeSpan -Seconds $ScheduleEverySeconds)
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                -StartWhenAvailable -MultipleInstances IgnoreNew `
                -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

# --- 3a. Resolve run-as identity --------------------------------------------
$builtIn = @('NT AUTHORITY\SYSTEM','SYSTEM','NT AUTHORITY\NetworkService','NetworkService','NT AUTHORITY\LocalService','LocalService')
$normalisedRunAs = if ($RunAsUser) { $RunAsUser.Trim() } else { '' }
$useSystem      = (-not $normalisedRunAs) -or ($normalisedRunAs -in $builtIn)
$useGmsa        = -not $useSystem -and $RunAsGmsa.IsPresent
$usePasswordAcct = -not $useSystem -and -not $useGmsa

if ($usePasswordAcct -and -not $RunAsPassword) {
    throw "RunAsPassword (SecureString) is required when -RunAsUser ('$normalisedRunAs') is a regular account. Pass -RunAsGmsa for a group Managed Service Account."
}
if ($useGmsa -and -not $normalisedRunAs.EndsWith('$')) {
    Write-Warning "RunAsGmsa specified but '$normalisedRunAs' does not end with '$' -- gMSAs are typically of the form DOMAIN\name$"
}

if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

if ($useSystem) {
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force | Out-Null
    Write-Host "    run as: NT AUTHORITY\SYSTEM"
}
elseif ($useGmsa) {
    $principal = New-ScheduledTaskPrincipal -UserId $normalisedRunAs -LogonType Password -RunLevel Highest
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force | Out-Null
    Write-Host "    run as: $normalisedRunAs (gMSA)"
}
else {
    # Regular password-backed account. Materialize the plaintext only inside try/finally.
    $bstr  = [IntPtr]::Zero
    $plain = $null
    try {
        $bstr  = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($RunAsPassword)
        $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
            -Settings $settings -User $normalisedRunAs -Password $plain `
            -RunLevel Highest -Force | Out-Null
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
        $plain = $null
    }
    Write-Host "    run as: $normalisedRunAs (password-backed; credential held in LSA secret store)"
}

# --- 3b. Verify RunLevel Highest survived registration ----------------------
$registered = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
if ($registered.Principal.RunLevel -ne 'Highest') {
    throw "Registered task DscV3-Apply has RunLevel '$($registered.Principal.RunLevel)' -- expected 'Highest'. Registration was rejected."
}

# --- 3c. Grant the run-as account read access to agent.config.json ----------
# (already SYSTEM + Administrators FullControl; if the account is a local admin
# this is a no-op, but explicit ACE keeps it working if admin membership ever
# changes.)
if ($usePasswordAcct -or $useGmsa) {
    try {
        $acl2 = Get-Acl -LiteralPath $AgentConfig
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($normalisedRunAs, 'Read', 'Allow')
        $acl2.AddAccessRule($rule)
        Set-Acl -LiteralPath $AgentConfig -AclObject $acl2
        Write-Host "    granted Read on $AgentConfig to $normalisedRunAs"
    } catch {
        Write-Warning "Could not grant Read ACL on $AgentConfig to ${normalisedRunAs}: $_"
        Write-Warning 'Ensure the run-as account is a member of local Administrators (required for the runner regardless).'
    }
}

# --- 4. Initial heartbeat to flip server.status -> ready --------------------
Write-Step 'Sending initial heartbeat'
$heartbeatBody = @{
    osCaption    = $os.Caption
    osVersion    = $os.Version
    agentVersion = '0.1.0-dashboard'
    modules      = @()
    serverTime   = (Get-Date).ToUniversalTime().ToString('o')
} | ConvertTo-Json -Compress

try {
    Invoke-RestMethod -Method POST -Uri "$base/api/agents/$($resp.agentId)/heartbeat" `
        -Headers @{ 'Authorization' = "Bearer $($resp.agentApiKey)" } `
        -ContentType 'application/json' -Body $heartbeatBody -TimeoutSec 30 | Out-Null
    Write-Host 'Initial heartbeat OK.'
} catch {
    Write-Warning "Initial heartbeat failed (will retry from scheduled task): $_"
}

Write-Step 'Registration complete'
Write-Host @"

Dashboard       : $base
Agent ID        : $($resp.agentId)
Config file     : $AgentConfig
Scheduled task  : $taskName  (every $ScheduleEverySeconds s)

Manual run:
    & `"$RunnerScript`" -Mode Dashboard -AgentConfig `"$AgentConfig`"
"@
