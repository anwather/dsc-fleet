# DscFleet.Logging.psm1
#
# Unified per-host log file used by every dsc-fleet bootstrap script and the
# scheduled-task runner. Single sink:
#
#   C:\ProgramData\DscV3\state\agent.log
#
# Goals:
#   * One place to look for everything: install, prereq, register, heartbeat,
#     assignments, run-as changes, removal.
#   * Compatible with both Windows PowerShell 5.1 and PowerShell 7.2+ (the
#     bootstrap runs in 5.1, the runner runs in 7.2).
#   * Concurrency-safe across processes via a named global mutex (the runner
#     fires every 60s and may overlap with ad-hoc invocations).
#   * Self-initializing: the state directory is created on first write so the
#     module works even if Install-DscV3 has not yet built the layout.
#   * Scrubs obvious secrets (bearer tokens, query-string tokens, password=)
#     before they touch disk.
#
# Public surface:
#   Write-DscFleetLog -Component <string> [-Level INFO|WARN|ERROR|DEBUG]
#                     -Message <string> [-NoConsole]
#
# Each script picks its own component label (e.g. Install, Prereq, Register,
# Runner, RunAs, Removal) so a single grep over agent.log filters by phase.

Set-StrictMode -Version 2.0

$script:DscFleetLogPath  = 'C:\ProgramData\DscV3\state\agent.log'
$script:DscFleetLogMaxMB = 5
$script:DscFleetLogKeep  = 2  # rotated copies: agent.log.1, agent.log.2

function Get-DscFleetLogMutex {
    # Local mutex (no Global\) is sufficient because the agent log is only
    # ever written from this machine's processes. Global\ requires
    # SeCreateGlobalPrivilege which SYSTEM has but is fragile under non-admin
    # contexts that may end up importing this module during diagnostics.
    if (-not (Get-Variable -Name 'DscFleetMutex' -Scope Script -ErrorAction SilentlyContinue)) {
        $createdNew = $false
        $script:DscFleetMutex = New-Object System.Threading.Mutex($false, 'Local\DscFleetAgentLog', [ref]$createdNew)
    }
    return $script:DscFleetMutex
}

function Invoke-DscFleetLogRotation {
    param([string] $LogPath)
    try {
        if (-not (Test-Path -LiteralPath $LogPath)) { return }
        $info = Get-Item -LiteralPath $LogPath -ErrorAction Stop
        if ($info.Length -lt ($script:DscFleetLogMaxMB * 1MB)) { return }
        # Shift agent.log.(N-1) -> agent.log.N, dropping the oldest.
        for ($i = $script:DscFleetLogKeep; $i -ge 1; $i--) {
            $src = if ($i -eq 1) { $LogPath } else { "$LogPath.$($i - 1)" }
            $dst = "$LogPath.$i"
            if (Test-Path -LiteralPath $src) {
                if (Test-Path -LiteralPath $dst) {
                    Remove-Item -LiteralPath $dst -Force -ErrorAction SilentlyContinue
                }
                Move-Item -LiteralPath $src -Destination $dst -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {
        # Rotation failure must never block logging.
    }
}

# Patterns scrubbed from message text before persisting. Conservative —
# unknown query-string tokens are nuked entirely; password= forms are
# masked. We never want a credential or single-use URL token sitting on
# every fleet member's disk.
$script:DscFleetRedactPatterns = @(
    @{ Pattern = '(?i)(Authorization\s*:\s*Bearer\s+)([A-Za-z0-9._\-+/=]+)';            Replacement = '$1<redacted>' }
    @{ Pattern = '(?i)(ProvisionToken[=:\s]+)([A-Za-z0-9._\-+/=]+)';                    Replacement = '$1<redacted>' }
    @{ Pattern = '(?i)(AgentApiKey[=:\s]+)([A-Za-z0-9._\-+/=]+)';                       Replacement = '$1<redacted>' }
    @{ Pattern = '(?i)(password[=:\s]+)(\S+)';                                          Replacement = '$1<redacted>' }
    @{ Pattern = '(?i)(/api/agents/runas/)([A-Za-z0-9._\-+/=]+)';                       Replacement = '$1<redacted>' }
    @{ Pattern = '(?i)([?&](?:token|access_token|provision_token|api_key)=)([^\s&]+)';  Replacement = '$1<redacted>' }
)

function Format-DscFleetLogMessage {
    param([string] $Message)
    if ([string]::IsNullOrEmpty($Message)) { return '' }
    $out = $Message
    foreach ($r in $script:DscFleetRedactPatterns) {
        $out = [System.Text.RegularExpressions.Regex]::Replace($out, $r.Pattern, $r.Replacement)
    }
    return $out
}

function Write-DscFleetLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Component,

        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')]
        [string] $Level = 'INFO',

        [Parameter(Mandatory, ValueFromPipeline = $true)]
        [AllowEmptyString()]
        [string] $Message,

        # Suppress the host write (file-only). Useful for high-volume DEBUG
        # lines we want persisted but not flooded into Run-Command stdout.
        [switch] $NoConsole
    )

    process {
        $sanitized = Format-DscFleetLogMessage -Message $Message
        $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        $line  = '{0} [{1}] [{2}] {3}' -f $stamp, $Component, $Level, $sanitized

        # Console first — Run-Command relies on Write-Host for stdout capture
        # and we never want a logging fault to swallow a visible line.
        if (-not $NoConsole) {
            $color = switch ($Level) {
                'ERROR' { 'Red' }
                'WARN'  { 'Yellow' }
                'DEBUG' { 'DarkGray' }
                default { $null }
            }
            if ($color) {
                Write-Host $line -ForegroundColor $color
            } else {
                Write-Host $line
            }
        }

        $mutex = $null
        $owned = $false
        try {
            $mutex = Get-DscFleetLogMutex
            try { $owned = $mutex.WaitOne(2000) } catch [System.Threading.AbandonedMutexException] { $owned = $true }

            $dir = Split-Path -Parent $script:DscFleetLogPath
            if (-not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
            Invoke-DscFleetLogRotation -LogPath $script:DscFleetLogPath
            # Add-Content gives us OS-level append semantics; the mutex
            # serializes our own size/rotation race window.
            Add-Content -LiteralPath $script:DscFleetLogPath -Value $line -Encoding UTF8
        } catch {
            # Logging must never throw out into the caller. Surface a single
            # marker on the console so the loss is at least visible.
            try { Write-Host "[DscFleet.Logging] write failed: $($_.Exception.Message)" -ForegroundColor DarkRed } catch { }
        } finally {
            if ($mutex -and $owned) {
                try { $mutex.ReleaseMutex() } catch { }
            }
        }
    }
}

Export-ModuleMember -Function 'Write-DscFleetLog'
