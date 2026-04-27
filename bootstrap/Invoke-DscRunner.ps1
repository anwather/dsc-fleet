#requires -Version 7.2
<#
.SYNOPSIS
    Apply the DSC v3 configuration documents that target this server.

.DESCRIPTION
    Designed to be invoked by the SYSTEM-context scheduled task created by
    bootstrap/Install-DscV3.ps1 — but also runnable interactively for ad-hoc
    enforcement and validation.

    Flow per invocation:
      1. git fetch + checkout the configured ref (skipped with -NoFetch).
      2. Load assignments/assignments.json + validate against schema.json.
      3. Resolve which groups this server belongs to (Arc tag / AD / hostname).
      4. For each applicable group, check cadence vs <StateRoot>\<group>.json.
      5. Expand globbed config paths and run dsc config <set|test> against each.
      6. Capture each run's JSON, write to <RunsRoot>\<run-id>.json, and POST
         to ReportingEndpoint (if configured).
      7. Update the per-group state file with lastRunUtc.

.PARAMETER RepoRoot
    Path to the cloned configs repo. Default: C:\ProgramData\DscV3\repo.

.PARAMETER StateRoot
    Where per-group state files live. Default: C:\ProgramData\DscV3\state.

.PARAMETER RunsRoot
    Where per-run JSON output is captured. Default: C:\ProgramData\DscV3\runs.

.PARAMETER ReportingEndpoint
    HTTPS URL accepting POSTs of run JSON. Empty string disables remote reporting.

.PARAMETER OnlyGroup
    Restrict execution to a single named group, ignoring membership rules.
    Useful for ad-hoc remediation.

.PARAMETER Now
    Bypass cadence gating — run every applicable group immediately.

.PARAMETER NoFetch
    Skip 'git fetch'. Useful in tests / offline.

.PARAMETER ValidateOnly
    Validate assignments.json against the schema and exit. No DSC execution.

.PARAMETER ForceMode
    Override the per-group mode ('set' or 'test'). Use 'test' for a dry run
    across the whole fleet.
#>
[CmdletBinding()]
param(
    [string]   $RepoRoot          = 'C:\ProgramData\DscV3\repo',
    [string]   $StateRoot         = 'C:\ProgramData\DscV3\state',
    [string]   $RunsRoot          = 'C:\ProgramData\DscV3\runs',
    [string]   $ReportingEndpoint = '',
    [string]   $ConfigsRepoUrl    = '',
    [string]   $ConfigsRef        = 'main',
    [string]   $OnlyGroup         = '',
    [switch]   $Now,
    [switch]   $NoFetch,
    [switch]   $ValidateOnly,
    [ValidateSet('','set','test')] [string] $ForceMode = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

# --- helpers -----------------------------------------------------------------

function Write-RunnerLog {
    param([Parameter(Mandatory, Position = 0)] [string] $Message, [string] $Level = 'INFO')
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK'), $Level, $Message
    Write-Host $line
}

function Get-ArcTag {
    # The Connected Machine agent exposes tags via IMDS. On a non-Arc box
    # the endpoint won't respond; treat as empty.
    try {
        $resp = Invoke-RestMethod -TimeoutSec 3 -Headers @{ Metadata = 'true' } `
            -Uri 'http://169.254.169.254/metadata/instance?api-version=2021-02-01'
        $tagText = $resp.compute.tagsList ?? @()
        $h = @{}
        foreach ($t in $tagText) { $h[$t.name] = [string]$t.value }
        # Azure VMs (not Arc) also respond to IMDS, which is fine — same shape.
        return $h
    } catch {
        return @{}
    }
}

function Test-AdGroupMembership {
    param([string] $GroupSamName)
    # Computer SID-based check via .NET — works in domain context, returns
    # $false outside a domain.
    try {
        $null = [System.DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain().Name
        $searcher = [System.DirectoryServices.DirectorySearcher]::new()
        $searcher.Filter = "(&(objectClass=computer)(name=$env:COMPUTERNAME))"
        $me = $searcher.FindOne()
        if (-not $me) { return $false }
        $memberOf = $me.Properties['memberof']
        foreach ($dn in $memberOf) {
            if ($dn -match "^CN=$([regex]::Escape($GroupSamName)),") { return $true }
        }
        return $false
    } catch {
        Write-RunnerLog -Level 'DEBUG' -Message "AD lookup for '$GroupSamName' failed: $_"
        return $false
    }
}

function Test-MembershipRule {
    param([hashtable] $Rule, [hashtable] $ArcTags)
    switch ($Rule.type) {
        'all'      { return $true }
        'hostname' { return $env:COMPUTERNAME -match $Rule.pattern }
        'arcTag'   {
            if (-not $ArcTags.ContainsKey($Rule.key)) { return $false }
            return $ArcTags[$Rule.key] -ieq $Rule.value
        }
        'adGroup'  { return Test-AdGroupMembership -GroupSamName $Rule.value }
        default    { throw "Unknown membership rule type '$($Rule.type)'." }
    }
}

# Convert an assignments.json schedule string into a TimeSpan minimum interval.
function Get-CadenceInterval {
    param([string] $Schedule)
    if ($Schedule -eq 'OnDemand') { return [timespan]::MaxValue }
    if ($Schedule -eq 'Hourly')   { return [timespan]::FromHours(1) }
    if ($Schedule -match '^Every(\d+)Hours$')   { return [timespan]::FromHours([int]$Matches[1]) }
    if ($Schedule -match '^Every(\d+)Minutes$') { return [timespan]::FromMinutes([int]$Matches[1]) }
    if ($Schedule -match '^Daily (\d{2}):(\d{2})$') { return [timespan]::FromHours(23.5) }
    throw "Unsupported schedule '$Schedule'."
}

function Test-DailyWindowReached {
    param([string] $Schedule, [datetime] $LastRunUtc)
    if ($Schedule -notmatch '^Daily (\d{2}):(\d{2})$') { return $true }
    $hh = [int]$Matches[1]; $mm = [int]$Matches[2]
    $todayLocal = (Get-Date).Date.AddHours($hh).AddMinutes($mm)
    $nowLocal   = Get-Date
    if ($nowLocal -lt $todayLocal) { return $false }
    return $LastRunUtc.ToLocalTime() -lt $todayLocal
}

function Get-PerGroupState {
    param([string] $StateRoot, [string] $Group)
    $path = Join-Path $StateRoot "$Group.json"
    if (Test-Path -LiteralPath $path) {
        return (Get-Content -Raw -LiteralPath $path | ConvertFrom-Json -AsHashtable)
    }
    return @{ lastRunUtc = '1970-01-01T00:00:00Z'; lastResult = 'never' }
}

function Set-PerGroupState {
    param([string] $StateRoot, [string] $Group, [string] $Result)
    if (-not (Test-Path -LiteralPath $StateRoot)) { New-Item -ItemType Directory -Path $StateRoot -Force | Out-Null }
    $payload = @{
        lastRunUtc = (Get-Date).ToUniversalTime().ToString('o')
        lastResult = $Result
    }
    $path = Join-Path $StateRoot "$Group.json"
    $payload | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding UTF8
}

function Test-CadenceDue {
    param([string] $Schedule, [datetime] $LastRunUtc)
    if ($Schedule -eq 'OnDemand') { return $false }
    if ($Schedule -like 'Daily *') { return Test-DailyWindowReached -Schedule $Schedule -LastRunUtc $LastRunUtc }
    $interval = Get-CadenceInterval -Schedule $Schedule
    return ((Get-Date).ToUniversalTime() - $LastRunUtc) -ge $interval
}

function Send-RunReport {
    param([string] $Endpoint, [hashtable] $Payload)
    if (-not $Endpoint) { return }
    try {
        Invoke-RestMethod -Uri $Endpoint -Method Post -TimeoutSec 30 `
            -ContentType 'application/json' `
            -Body ($Payload | ConvertTo-Json -Depth 20) | Out-Null
    } catch {
        Write-RunnerLog -Level 'WARN' -Message "Reporting POST failed: $_"
    }
}

# --- 1. Optionally fetch + checkout ------------------------------------------

if (-not $NoFetch) {
    $haveRepo = Test-Path (Join-Path $RepoRoot '.git')
    if (-not $haveRepo -and $ConfigsRepoUrl) {
        Write-RunnerLog "Cloning $ConfigsRepoUrl ($ConfigsRef) into $RepoRoot"
        if (-not (Test-Path $RepoRoot)) { New-Item -ItemType Directory -Path $RepoRoot -Force | Out-Null }
        & git clone --quiet $ConfigsRepoUrl $RepoRoot 2>&1 | Out-Null
        & git -C $RepoRoot -c advice.detachedHead=false checkout --force $ConfigsRef 2>&1 | Out-Null
    } elseif ($haveRepo) {
        Write-RunnerLog "git fetch in $RepoRoot"
        & git -C $RepoRoot fetch --tags --prune origin 2>&1 | Out-Null
        if ($ConfigsRef) {
            & git -C $RepoRoot -c advice.detachedHead=false checkout --force $ConfigsRef 2>&1 | Out-Null
        }
        $head = (& git -C $RepoRoot rev-parse --abbrev-ref HEAD).Trim()
        if ($head -ne 'HEAD') {
            & git -C $RepoRoot reset --hard "origin/$head" 2>&1 | Out-Null
        }
    }
}

# --- 2. Load + validate assignments ------------------------------------------

$assignmentsPath = Join-Path $RepoRoot 'assignments\assignments.json'
$schemaPath      = Join-Path $RepoRoot 'assignments\schema.json'
if (-not (Test-Path -LiteralPath $assignmentsPath)) { throw "assignments.json not found at $assignmentsPath" }
$assignments = Get-Content -Raw -LiteralPath $assignmentsPath | ConvertFrom-Json -AsHashtable

if (Test-Path -LiteralPath $schemaPath) {
    try {
        # Test-Json with -SchemaFile is available in PS 7.2+.
        $null = Test-Json -Json (Get-Content -Raw -LiteralPath $assignmentsPath) -SchemaFile $schemaPath -ErrorAction Stop
    } catch {
        throw "assignments.json failed schema validation: $_"
    }
}
if ($ValidateOnly) {
    Write-RunnerLog 'assignments.json is valid.'
    return
}

# --- 3. Resolve membership ---------------------------------------------------

$arcTags = Get-ArcTag
$applicableGroups = @()
if ($OnlyGroup) {
    if (-not $assignments.groups.ContainsKey($OnlyGroup)) { throw "Unknown group '$OnlyGroup'." }
    $applicableGroups += $OnlyGroup
} else {
    foreach ($group in $assignments.groups.Keys) {
        $rules = $assignments.membership[$group]
        if (-not $rules) { continue }
        foreach ($rule in $rules) {
            if (Test-MembershipRule -Rule $rule -ArcTags $arcTags) { $applicableGroups += $group; break }
        }
    }
}
Write-RunnerLog "Applicable groups: $($applicableGroups -join ', ')"

# --- 4. + 5. + 6. + 7. -------------------------------------------------------

if (-not (Test-Path -LiteralPath $RunsRoot)) { New-Item -ItemType Directory -Path $RunsRoot -Force | Out-Null }
$dsc = (Get-Command dsc).Source

foreach ($group in $applicableGroups) {
    $groupSpec = $assignments.groups[$group]
    $state     = Get-PerGroupState -StateRoot $StateRoot -Group $group
    $lastRunUtc = [datetime]::Parse($state.lastRunUtc, $null, [System.Globalization.DateTimeStyles]::AssumeUniversal)

    if (-not $Now -and -not (Test-CadenceDue -Schedule $groupSpec.schedule -LastRunUtc $lastRunUtc)) {
        Write-RunnerLog "Group '$group' not yet due (schedule=$($groupSpec.schedule), lastRunUtc=$($state.lastRunUtc)) — skipping."
        continue
    }

    $mode = if ($ForceMode) { $ForceMode } else { ($groupSpec.mode ?? 'set') }
    $verb = if ($mode -eq 'test') { 'test' } else { 'set' }

    # Expand globs relative to RepoRoot.
    $configFiles = foreach ($pattern in $groupSpec.configs) {
        $full = Join-Path $RepoRoot $pattern
        if ($full -match '[\*\?]') {
            Get-ChildItem -Path $full -ErrorAction SilentlyContinue
        } elseif (Test-Path -LiteralPath $full) {
            Get-Item -LiteralPath $full
        }
    }
    if (-not $configFiles) {
        Write-RunnerLog -Level 'WARN' -Message "Group '$group' resolved to zero config files — skipping."
        continue
    }

    $groupResult = 'ok'
    foreach ($cfg in $configFiles) {
        $runId = "{0:yyyyMMdd-HHmmss}-{1}-{2}" -f (Get-Date), $group, ($cfg.BaseName -replace '\.dsc$','')
        Write-RunnerLog "Running 'dsc config $verb' on $($cfg.FullName) (group=$group, mode=$mode, runId=$runId)"
        $start = Get-Date
        $output = & $dsc config $verb --file $cfg.FullName --output-format json 2>&1 | Out-String
        $exit   = $LASTEXITCODE
        $payload = @{
            runId     = $runId
            host      = $env:COMPUTERNAME
            os        = (Get-CimInstance Win32_OperatingSystem).Caption
            arcTags   = $arcTags
            group     = $group
            config    = $cfg.FullName.Substring($RepoRoot.Length).TrimStart('\','/')
            mode      = $mode
            verb      = $verb
            startUtc  = $start.ToUniversalTime().ToString('o')
            endUtc    = (Get-Date).ToUniversalTime().ToString('o')
            exitCode  = $exit
            success   = ($exit -eq 0)
            dscOutput = $output
        }
        $jsonPath = Join-Path $RunsRoot "$runId.json"
        $payload | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

        Send-RunReport -Endpoint $ReportingEndpoint -Payload $payload

        if ($exit -ne 0) {
            $groupResult = 'failed'
            Write-RunnerLog -Level 'ERROR' -Message "dsc exited $exit for $($cfg.Name) — see $jsonPath"
        }
    }
    Set-PerGroupState -StateRoot $StateRoot -Group $group -Result $groupResult
    Write-RunnerLog "Group '$group' result: $groupResult"
}
