#requires -Version 5.1
#requires -RunAsAdministrator
<#
.SYNOPSIS
    Change the identity that the DscV3-Apply scheduled task runs under.

.DESCRIPTION
    Run this on a Windows Server that has already been provisioned by the
    dsc-fleet dashboard. It changes the principal of the existing
    DscV3-Apply scheduled task without touching the agent.config.json
    or contacting the dashboard.

    Modes:
        -Credential <pscredential>          regular local or domain account
        -RunAsUser '<DOMAIN\name$>' -Gmsa   group Managed Service Account
        -SystemAccount                      revert to NT AUTHORITY\SYSTEM

    The credential plaintext is materialized in memory only at the moment
    Register-ScheduledTask is invoked, then the BSTR is zeroed. Windows
    stores the password as an LSA secret on this machine, DPAPI-protected
    with a machine-bound master key. The credential never leaves the box.

    The run-as account MUST be a member of local Administrators -- the
    runner installs PowerShell modules into Program Files, restarts
    services, writes HKLM, and otherwise operates as an admin agent.

.PARAMETER Credential
    PSCredential for a regular service account (local or domain user).

.PARAMETER RunAsUser
    Used with -Gmsa to specify the gMSA principal in the form DOMAIN\name$.

.PARAMETER Gmsa
    Switch indicating the account is a group Managed Service Account
    (no password supplied; Windows fetches it from AD).

.PARAMETER SystemAccount
    Switch to revert the task to NT AUTHORITY\SYSTEM.

.PARAMETER TaskName
    Name of the scheduled task to update. Default: DscV3-Apply.

.PARAMETER AgentConfig
    Path to the agent config JSON. Default: C:\ProgramData\DscV3\agent.config.json.

.PARAMETER VerifyMembership
    If set, fails if the run-as account is not a member of local
    Administrators. Default: on for password-backed and gMSA paths.

.EXAMPLE
    # Switch to a local service account; you'll be prompted for the password.
    PS> .\Set-DscFleetRunAsAccount.ps1 -Credential (Get-Credential .\dscagent)

.EXAMPLE
    # gMSA on a domain-joined box.
    PS> .\Set-DscFleetRunAsAccount.ps1 -RunAsUser 'CONTOSO\dscgmsa$' -Gmsa

.EXAMPLE
    # Revert to SYSTEM.
    PS> .\Set-DscFleetRunAsAccount.ps1 -SystemAccount
#>
[CmdletBinding(DefaultParameterSetName = 'Credential', SupportsShouldProcess)]
param(
    [Parameter(ParameterSetName = 'Credential', Mandatory)]
    [System.Management.Automation.PSCredential] $Credential,

    [Parameter(ParameterSetName = 'Gmsa', Mandatory)]
    [string] $RunAsUser,

    [Parameter(ParameterSetName = 'Gmsa', Mandatory)]
    [switch] $Gmsa,

    [Parameter(ParameterSetName = 'System', Mandatory)]
    [switch] $SystemAccount,

    [string] $TaskName    = 'DscV3-Apply',
    [string] $AgentConfig = 'C:\ProgramData\DscV3\agent.config.json',
    [switch] $VerifyMembership = $true
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

function Write-Step([string] $m) { Write-Host "==> $m" -ForegroundColor Cyan }

# --- Validate task exists ---------------------------------------------------
$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $existing) {
    throw "Scheduled task '$TaskName' not found. Provision the agent first via the dashboard."
}

# --- Resolve target identity from parameter set -----------------------------
switch ($PSCmdlet.ParameterSetName) {
    'System'     {
        $newUser     = 'NT AUTHORITY\SYSTEM'
        $kind        = 'system'
    }
    'Gmsa'       {
        $newUser     = $RunAsUser.Trim()
        $kind        = 'gmsa'
        if (-not $newUser.EndsWith('$')) {
            Write-Warning "RunAsUser '$newUser' does not end with '$' -- gMSAs are typically of the form DOMAIN\name$."
        }
    }
    'Credential' {
        $newUser     = $Credential.UserName
        $kind        = 'password'
    }
}

Write-Step "Switching $TaskName to run as: $newUser"

# --- Optional: verify local Administrators membership -----------------------
if ($VerifyMembership -and $kind -ne 'system') {
    try {
        $admins = Get-LocalGroupMember -Group 'Administrators' -ErrorAction Stop |
            Select-Object -ExpandProperty Name
        $match = $admins | Where-Object { $_ -ieq $newUser -or $_ -ilike "*\$($newUser.Split('\')[-1])" }
        if (-not $match) {
            Write-Warning "Run-as account '$newUser' does not appear in the local Administrators group on this machine."
            Write-Warning 'The runner needs admin privileges (writes Program Files, HKLM, services, modules).'
            Write-Warning 'Add the account to Administrators before this task fires, or pass -VerifyMembership:$false to bypass this check.'
            $confirm = Read-Host 'Continue anyway? [y/N]'
            if ($confirm -notmatch '^(y|yes)$') { throw 'Aborted by user.' }
        }
    } catch [System.UnauthorizedAccessException] {
        Write-Warning "Could not enumerate local Administrators: $($_.Exception.Message)"
    } catch {
        # Get-LocalGroupMember can fail for domain accounts in unusual setups; surface but continue.
        Write-Warning "Membership check skipped: $($_.Exception.Message)"
    }
}

# --- Capture current task definition pieces ---------------------------------
$action   = $existing.Actions
$trigger  = $existing.Triggers
$settings = $existing.Settings

# --- Re-register with the new identity --------------------------------------
$shouldDoit = $PSCmdlet.ShouldProcess($TaskName, "Re-register with identity '$newUser'")
if ($shouldDoit) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false

    switch ($kind) {
        'system' {
            $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
            Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
                -Principal $principal -Settings $settings -Force | Out-Null
        }
        'gmsa' {
            $principal = New-ScheduledTaskPrincipal -UserId $newUser -LogonType Password -RunLevel Highest
            Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
                -Principal $principal -Settings $settings -Force | Out-Null
        }
        'password' {
            $bstr  = [IntPtr]::Zero
            $plain = $null
            try {
                $bstr  = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Credential.Password)
                $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
                Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
                    -Settings $settings -User $newUser -Password $plain `
                    -RunLevel Highest -Force | Out-Null
            }
            finally {
                if ($bstr -ne [IntPtr]::Zero) {
                    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
                }
                $plain = $null
            }
        }
    }
}

# --- Verify RunLevel survived -----------------------------------------------
$updated = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
if ($updated.Principal.RunLevel -ne 'Highest') {
    throw "Updated task has RunLevel '$($updated.Principal.RunLevel)' -- expected 'Highest'."
}

# --- Grant agent.config.json read access to non-SYSTEM identities -----------
if ($kind -ne 'system' -and (Test-Path -LiteralPath $AgentConfig)) {
    try {
        $acl  = Get-Acl -LiteralPath $AgentConfig
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($newUser, 'Read', 'Allow')
        $acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $AgentConfig -AclObject $acl
        Write-Host "    granted Read on $AgentConfig to $newUser"
    } catch {
        Write-Warning "Could not grant Read on ${AgentConfig}: $_"
        Write-Warning 'If the run-as account is a local Administrator (required), it already has access via the Administrators ACE.'
    }
}

Write-Step 'Done.'
Write-Host @"

Task           : $TaskName
Run as         : $($updated.Principal.UserId)
Logon type     : $($updated.Principal.LogonType)
Run level      : $($updated.Principal.RunLevel)

Trigger an immediate run:
    Start-ScheduledTask -TaskName $TaskName

Tail the agent log:
    Get-WinEvent -LogName 'Microsoft-Windows-TaskScheduler/Operational' -MaxEvents 20 |
        Where-Object { `$_.Message -match '$TaskName' }

Caveats:
  - LSA-stored scheduled-task credentials are protected by Windows but should
    be considered recoverable by highly-privileged local compromise of LSASS.
    Prefer gMSA when feasible.
  - The run-as account needs the 'Log on as a batch job' (SeBatchLogonRight)
    user right. Local administrators have it by default, but domain GPO can
    override. If the task fails to start with 0x80070534, that's the cause.
"@
