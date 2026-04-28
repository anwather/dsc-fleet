#requires -Version 7.2
<#
.SYNOPSIS
    Dashboard-mode runner: pull assignments from dsc-fleet-dashboard, apply
    each one, POST results back.

.DESCRIPTION
    Designed to be invoked by the SYSTEM-context scheduled task created by
    bootstrap/Register-DashboardAgent.ps1 -- also runnable interactively for
    ad-hoc enforcement and debugging.

    Flow per invocation:
      1. Acquire C:\ProgramData\DscV3\state\runner.lock (skip overlapping
         runs).
      2. POST /api/agents/{id}/heartbeat.
      3. GET  /api/agents/{id}/assignments (cached via ETag).
      4. For each due assignment:
           - GET /api/configs/{id}/revisions/{rev} -- cached to disk.
           - dsc config set -- <yaml>.
           - POST /api/agents/{id}/runs with the result JSON.

    The dashboard owns scheduling (nextDueAt, intervalMinutes, removal state);
    the runner just enforces what the API says is due now.

.PARAMETER Mode
    Reserved for back-compat with older scheduled tasks. Always Dashboard.

.PARAMETER StateRoot
    Per-cycle state files (lock, ETag cache, revision cache).
    Default: C:\ProgramData\DscV3\state.

.PARAMETER RunsRoot
    Local fallback copies of run JSON. Default: C:\ProgramData\DscV3\runs.

.PARAMETER AgentConfig
    Path to agent.config.json (DashboardUrl + AgentId + AgentApiKey).
    Default: C:\ProgramData\DscV3\agent.config.json.

.PARAMETER MaxAssignmentsPerCycle
    0 = no cap. Otherwise process at most N assignments per invocation.

.PARAMETER Now
    Bypass per-assignment nextDueAt gating -- apply every assignment now.
#>
[CmdletBinding()]
param(
    [ValidateSet('Dashboard')]
    [string]   $Mode                   = 'Dashboard',
    [string]   $StateRoot              = 'C:\ProgramData\DscV3\state',
    [string]   $RunsRoot               = 'C:\ProgramData\DscV3\runs',
    [string]   $AgentConfig            = 'C:\ProgramData\DscV3\agent.config.json',
    [int]      $MaxAssignmentsPerCycle = 0,
    [switch]   $Now
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

function Write-RunnerLog {
    param([Parameter(Mandatory, Position = 0)] [string] $Message, [string] $Level = 'INFO')
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK'), $Level, $Message
    Write-Host $line
}

# ============================================================================
# Dashboard-mode entrypoint -- agent ↔ dsc-fleet-dashboard wire protocol.
# ============================================================================
if ($Mode -eq 'Dashboard') {

    # --- Lock file (skip overlapping runs) -----------------------------------
    if (-not (Test-Path -LiteralPath $StateRoot)) { New-Item -ItemType Directory -Path $StateRoot -Force | Out-Null }
    $lockPath = Join-Path $StateRoot 'runner.lock'
    if (Test-Path -LiteralPath $lockPath) {
        $lockAge = (Get-Date) - (Get-Item -LiteralPath $lockPath).LastWriteTime
        if ($lockAge -lt [TimeSpan]::FromMinutes(60)) {
            Write-RunnerLog -Level 'WARN' -Message "Lock file fresh ($([int]$lockAge.TotalMinutes) min) -- exiting."
            return
        }
        Write-RunnerLog -Level 'WARN' -Message "Stale lock found (age $([int]$lockAge.TotalMinutes) min) -- overriding."
        Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
    }
    @{ pid = $PID; startedUtc = (Get-Date).ToUniversalTime().ToString('o') } |
        ConvertTo-Json | Set-Content -LiteralPath $lockPath -Encoding UTF8

    try {
        if (-not (Test-Path -LiteralPath $AgentConfig)) { throw "Agent config not found: $AgentConfig" }
        $cfg = Get-Content -Raw -LiteralPath $AgentConfig | ConvertFrom-Json
        foreach ($key in 'DashboardUrl','AgentId','AgentApiKey') {
            if (-not $cfg.PSObject.Properties.Name.Contains($key)) { throw "Agent config missing '$key'." }
        }
        $base    = $cfg.DashboardUrl.TrimEnd('/')
        $agentId = $cfg.AgentId
        $headers = @{ 'Authorization' = "Bearer $($cfg.AgentApiKey)"; 'Accept' = 'application/json' }
        $etagCachePath = Join-Path $StateRoot 'assignments.etag'
        $itemsCachePath = Join-Path $StateRoot 'assignments.items.json'
        $revCacheDir   = Join-Path $StateRoot 'revisions'
        if (-not (Test-Path -LiteralPath $revCacheDir)) { New-Item -ItemType Directory -Path $revCacheDir -Force | Out-Null }
        if (-not (Test-Path -LiteralPath $RunsRoot))    { New-Item -ItemType Directory -Path $RunsRoot    -Force | Out-Null }

        # Resolve dsc once.
        $dsc = (Get-Command dsc -ErrorAction SilentlyContinue)?.Source
        if (-not $dsc) { throw "dsc.exe not on PATH." }

        function Invoke-Dashboard {
            param([Parameter(Mandatory)][string] $Method,
                  [Parameter(Mandatory)][string] $Path,
                  $Body = $null,
                  [hashtable] $ExtraHeaders = @{})
            $url = "$base$Path"
            $h   = $headers.Clone()
            foreach ($k in $ExtraHeaders.Keys) { $h[$k] = $ExtraHeaders[$k] }
            $params = @{ Method = $Method; Uri = $url; Headers = $h; TimeoutSec = 60 }
            if ($null -ne $Body) {
                $params.ContentType = 'application/json'
                $params.Body = ($Body | ConvertTo-Json -Depth 20 -Compress)
            }
            return Invoke-RestMethod @params
        }

        function Get-InstalledModuleList {
            $hash = [ordered]@{}
            # Source 1: PSResourceGet (preferred, has scope info)
            try {
                Import-Module Microsoft.PowerShell.PSResourceGet -ErrorAction Stop
                foreach ($scope in 'AllUsers','CurrentUser') {
                    try {
                        $rows = Get-InstalledPSResource -Scope $scope -ErrorAction SilentlyContinue
                        foreach ($r in $rows) {
                            if ($r.Name -and -not $hash.Contains($r.Name)) {
                                $hash[$r.Name] = @{ name = $r.Name; version = $r.Version.ToString() }
                            }
                        }
                    } catch { Write-RunnerLog -Level 'DEBUG' -Message "Get-InstalledPSResource $scope failed: $_" }
                }
            } catch { Write-RunnerLog -Level 'DEBUG' -Message "PSResourceGet import failed: $_" }
            # Source 2: Get-Module -ListAvailable -- belt-and-suspenders, picks up
            # modules dropped into $env:PSModulePath that PSResourceGet doesn't index.
            try {
                $rows = Get-Module -ListAvailable -ErrorAction SilentlyContinue |
                    Group-Object Name |
                    ForEach-Object { $_.Group | Sort-Object Version -Descending | Select-Object -First 1 }
                foreach ($r in $rows) {
                    if ($r.Name -and -not $hash.Contains($r.Name)) {
                        $hash[$r.Name] = @{ name = $r.Name; version = $r.Version.ToString() }
                    }
                }
            } catch { Write-RunnerLog -Level 'DEBUG' -Message "Get-Module -ListAvailable failed: $_" }
            return @($hash.Values)
        }

        function Send-Heartbeat {
            $os = $null
            try { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop } catch { Write-RunnerLog -Level 'DEBUG' -Message "Win32_OperatingSystem query failed: $_" }
            $dscVer = $null
            try { $dscVer = (& $dsc --version 2>&1 | Out-String).Trim() } catch { Write-RunnerLog -Level 'DEBUG' -Message "dsc --version failed: $_" }
            $mods = @(Get-InstalledModuleList)
            if ($null -eq $mods) { $mods = @() }
            $body = @{
                osCaption    = ${os}?.Caption
                osVersion    = ${os}?.Version
                dscExeVersion = $dscVer
                agentVersion = '0.1.0-dashboard'
                modules      = [object[]]$mods
                serverTime   = (Get-Date).ToUniversalTime().ToString('o')
            }
            try {
                $resp = Invoke-Dashboard -Method POST -Path "/api/agents/$agentId/heartbeat" -Body $body
                Write-RunnerLog "heartbeat ok ($($mods.Count) module(s) reported, server time $($resp.serverTime), poll $($resp.pollIntervalSeconds)s)"
            } catch {
                Write-RunnerLog -Level 'WARN' -Message "heartbeat failed: $_"
            }
        }

        function Get-AssignmentList {
            $h = @{}
            if (Test-Path -LiteralPath $etagCachePath) {
                $h['If-None-Match'] = (Get-Content -Raw -LiteralPath $etagCachePath).Trim()
            }
            try {
                $resp = Invoke-WebRequest -Method GET -Uri "$base/api/agents/$agentId/assignments" `
                    -Headers ($headers + $h) -TimeoutSec 60 -SkipHttpErrorCheck
            } catch {
                Write-RunnerLog -Level 'WARN' -Message "assignments fetch failed: $_"
                return $null
            }
            if ($resp.StatusCode -eq 304) {
                Write-RunnerLog 'assignments: 304 Not Modified (replaying cached list)'
                $cachedItems = @()
                if (Test-Path -LiteralPath $itemsCachePath) {
                    try {
                        $cachedItems = @((Get-Content -Raw -LiteralPath $itemsCachePath | ConvertFrom-Json))
                    } catch {
                        Write-RunnerLog -Level 'WARN' -Message "items cache unreadable: $_"
                    }
                }
                return @{ NotModified = $true; Items = $cachedItems }
            }
            if ($resp.StatusCode -ne 200) {
                Write-RunnerLog -Level 'WARN' -Message "assignments: HTTP $($resp.StatusCode)"
                return $null
            }
            $etag = $resp.Headers['ETag']
            if ($etag) {
                if ($etag -is [array]) { $etag = $etag[0] }
                $etag | Set-Content -LiteralPath $etagCachePath -Encoding UTF8 -NoNewline
            }
            $data = $resp.Content | ConvertFrom-Json
            # Cache the items array so a subsequent 304 can still re-evaluate
            # due-ness against the wall clock instead of skipping the cycle.
            try {
                $data.assignments | ConvertTo-Json -Depth 20 |
                    Set-Content -LiteralPath $itemsCachePath -Encoding UTF8
            } catch {
                Write-RunnerLog -Level 'WARN' -Message "items cache write failed: $_"
            }
            return @{ NotModified = $false; Items = @($data.assignments); ServerTime = $data.serverTime; PollSeconds = $data.pollIntervalSeconds }
        }

        function Get-RevisionYaml {
            param([string] $RevisionId, [string] $ExpectedSha256)
            $cached = Join-Path $revCacheDir "$RevisionId.dsc.yaml"
            if (Test-Path -LiteralPath $cached) {
                $existing = Get-FileHash -LiteralPath $cached -Algorithm SHA256
                if ($existing.Hash.ToLowerInvariant() -eq $ExpectedSha256.ToLowerInvariant()) { return $cached }
                Remove-Item -LiteralPath $cached -Force
            }
            $resp = Invoke-Dashboard -Method GET -Path "/api/agents/$agentId/revisions/$RevisionId"
            $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($resp.yamlBody)
            [System.IO.File]::WriteAllBytes($cached, $bytes)
            $check = (Get-FileHash -LiteralPath $cached -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($check -ne $ExpectedSha256.ToLowerInvariant()) {
                Remove-Item -LiteralPath $cached -Force -ErrorAction SilentlyContinue
                throw "sha256 mismatch for revision $RevisionId (got $check, expected $ExpectedSha256)"
            }
            return $cached
        }

        function Invoke-DscApply {
            param([string] $YamlPath, [string] $Verb)
            $output = & $dsc config $Verb --file $YamlPath --output-format json 2>&1 | Out-String
            return @{ ExitCode = $LASTEXITCODE; Output = $output }
        }

        function Test-ModuleInstalled {
            param([string] $Name, [string] $MinVersion)
            try {
                $candidates = Get-Module -ListAvailable -Name $Name -ErrorAction SilentlyContinue
                if (-not $candidates) { return $false }
                if ([string]::IsNullOrWhiteSpace($MinVersion)) { return $true }
                $min = [version]$MinVersion
                foreach ($c in $candidates) { if (([version]$c.Version) -ge $min) { return $true } }
                return $false
            } catch { return $false }
        }

        function Install-RequiredModules {
            param([object[]] $Required)
            if (-not $Required -or $Required.Count -eq 0) { return $false }
            $installed = $false
            try {
                if (-not (Get-Module -ListAvailable -Name Microsoft.PowerShell.PSResourceGet)) {
                    Write-RunnerLog 'installing PSResourceGet (prereq for module installs)'
                    Install-Module Microsoft.PowerShell.PSResourceGet -Scope AllUsers -Force -AllowClobber -ErrorAction Stop
                }
                Import-Module Microsoft.PowerShell.PSResourceGet -Force -ErrorAction Stop
                if (-not (Get-PSResourceRepository -Name PSGallery -ErrorAction SilentlyContinue)) {
                    Register-PSResourceRepository -PSGallery -Trusted -ErrorAction SilentlyContinue
                } else {
                    Set-PSResourceRepository -Name PSGallery -Trusted -ErrorAction SilentlyContinue
                }
            } catch {
                Write-RunnerLog -Level 'WARN' -Message "PSResourceGet bootstrap failed: $_"
                return $false
            }
            foreach ($m in $Required) {
                $name = $m.name
                $minV = $null
                if ($m.PSObject.Properties.Name -contains 'minVersion') { $minV = $m.minVersion }
                if (Test-ModuleInstalled -Name $name -MinVersion $minV) { continue }
                try {
                    $args = @{ Name = $name; Scope = 'AllUsers'; TrustRepository = $true; AcceptLicense = $true; ErrorAction = 'Stop' }
                    if (-not [string]::IsNullOrWhiteSpace($minV)) { $args.Version = $minV }
                    Write-RunnerLog "install module $name$(if ($minV) { " v$minV" })"
                    Install-PSResource @args
                    $installed = $true
                } catch {
                    Write-RunnerLog -Level 'WARN' -Message "install $name failed: $_"
                }
            }
            return $installed
        }

        function Send-RunResult {
            param([hashtable] $Body)
            try {
                Invoke-Dashboard -Method POST -Path "/api/agents/$agentId/results" -Body $Body | Out-Null
            } catch {
                Write-RunnerLog -Level 'WARN' -Message "POST /results failed: $_"
            }
        }

        function Send-RemovalAck {
            param([string] $AssignmentId, [int] $Generation, [bool] $Success, [string] $Message = '')
            try {
                $body = @{ assignmentId = $AssignmentId; generation = $Generation; success = $Success; message = $Message }
                Invoke-Dashboard -Method POST -Path "/api/agents/$agentId/removal-ack" -Body $body | Out-Null
            } catch {
                Write-RunnerLog -Level 'WARN' -Message "POST /removal-ack failed: $_"
            }
        }

        # --- Cycle ----------------------------------------------------------
        Send-Heartbeat
        $assignmentResp = Get-AssignmentList
        if ($null -eq $assignmentResp) {
            Write-RunnerLog -Level 'WARN' -Message 'no assignment payload -- exiting cycle'
            return
        }
        if ($assignmentResp.NotModified) {
            $items = $assignmentResp.Items
            if (-not $items -or $items.Count -eq 0) { return }
            # fall through and re-evaluate due-ness against the wall clock
        } else {
            $items = $assignmentResp.Items
        }
        if ($MaxAssignmentsPerCycle -gt 0 -and $items.Count -gt $MaxAssignmentsPerCycle) {
            $items = $items[0..($MaxAssignmentsPerCycle - 1)]
        }

        foreach ($a in $items) {
            try {
                if ($a.lifecycleState -eq 'removing') {
                    Write-RunnerLog "removing assignment $($a.assignmentId) (config $($a.configId))"
                    Send-RemovalAck -AssignmentId $a.assignmentId -Generation $a.generation -Success $true `
                        -Message 'removal acknowledged (no uninstall handler implemented)'
                    continue
                }
                if ($a.lifecycleState -ne 'active') { continue }
                if ($a.prereqStatus -ne 'ready') {
                    $reqMods = @()
                    if ($a.PSObject.Properties.Name -contains 'requiredModules' -and $a.requiredModules) {
                        $reqMods = @($a.requiredModules)
                    }
                    if ($reqMods.Count -gt 0) {
                        Write-RunnerLog "prereq=$($a.prereqStatus) for $($a.assignmentId) -- ensuring $($reqMods.Count) module(s) installed"
                        Install-RequiredModules -Required $reqMods | Out-Null
                        # Always re-heartbeat so the dashboard sees the latest module
                        # list and reconciles prereq even if the module was already
                        # present locally (heartbeat is the only place server_modules
                        # is updated).
                        Write-RunnerLog 're-sending heartbeat so dashboard can reconcile prereq'
                        Send-Heartbeat
                    } else {
                        Write-RunnerLog "skip $($a.assignmentId): prereq=$($a.prereqStatus)"
                    }
                    continue
                }
                if (-not $a.revisionId) {
                    Write-RunnerLog -Level 'WARN' -Message "skip $($a.assignmentId): no revisionId"
                    continue
                }
                $nextDue = $null
                if ($a.nextDueAt) { $nextDue = [datetime]::Parse($a.nextDueAt, $null, [System.Globalization.DateTimeStyles]::RoundtripKind) }
                if (-not $Now -and $nextDue -and (Get-Date).ToUniversalTime() -lt $nextDue) {
                    Write-RunnerLog "skip $($a.assignmentId): next due $($a.nextDueAt)"
                    continue
                }
                Write-RunnerLog "apply $($a.assignmentId) (rev $($a.revisionId), gen $($a.generation))"
                $yamlPath = Get-RevisionYaml -RevisionId $a.revisionId -ExpectedSha256 $a.sourceSha256
                $start = Get-Date
                $runId = [guid]::NewGuid().ToString()
                $result = Invoke-DscApply -YamlPath $yamlPath -Verb 'set'
                $end = Get-Date
                $hadErrors = $result.ExitCode -ne 0
                $inDesired = -not $hadErrors
                $body = @{
                    assignmentId    = $a.assignmentId
                    generation      = $a.generation
                    runId           = $runId
                    revisionId      = $a.revisionId
                    exitCode        = $result.ExitCode
                    hadErrors       = $hadErrors
                    inDesiredState  = $inDesired
                    durationMs      = [int]($end - $start).TotalMilliseconds
                    startedAt       = $start.ToUniversalTime().ToString('o')
                    finishedAt      = $end.ToUniversalTime().ToString('o')
                    dscOutput       = @{ raw = $result.Output }
                }
                # Local capture too.
                $jsonPath = Join-Path $RunsRoot "$runId.json"
                $body | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
                Send-RunResult -Body $body
            } catch {
                Write-RunnerLog -Level 'ERROR' -Message "assignment $($a.assignmentId) failed: $_"
            }
        }
    } finally {
        Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
    }
    return
}
