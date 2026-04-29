# Runner loop

This document describes the agent-side runtime: the per-cycle heartbeat,
the assignment poll, the apply path, the run-result POST, the unified
log file, and the difference between a scheduled-task launch and an
interactive launch.

The runner is a single PowerShell 7.2+ script:

```
C:\ProgramData\DscV3\bin\Invoke-DscRunner.ps1   (installed)
C:\Source\dsc-fleet\bootstrap\Invoke-DscRunner.ps1   (source)
```

It is paired with a logging module:

```
C:\ProgramData\DscV3\bin\DscFleet.Logging.psm1    (installed)
C:\Source\dsc-fleet\bootstrap\DscFleet.Logging.psm1   (source)
```

Both are dropped onto the box by `bootstrap\Install-DscV3.ps1`.

## One invocation = one cycle

The runner is **not** a long-lived daemon. The `DscV3-Apply` scheduled
task launches `pwsh.exe -File Invoke-DscRunner.ps1 -Mode Dashboard`
once per minute (configurable at registration time via
`-ScheduleEverySeconds`), and a single invocation goes through one
heartbeat → poll → apply pass and exits. There is no loop inside the
process.

This keeps every cycle a clean process, gets us free crash recovery
(the next minute starts a new `pwsh.exe`), and means the only state
that crosses cycles is the on-disk state directory.

### Per-invocation lock

The first thing the runner does is acquire
`C:\ProgramData\DscV3\state\runner.lock` (a JSON file containing the
current `$PID` + UTC start time). If the file already exists and is
younger than 60 minutes, the runner logs a `WARN` and returns —
overlapping cycles never happen. A stale lock (older than 60 minutes,
typically because a previous run was killed mid-apply) is logged and
overridden. The lock is removed in a `finally` block.

## Heartbeat

```
POST /api/agents/<agentId>/heartbeat
Authorization: Bearer <agentApiKey>
Content-Type: application/json
```

Cadence: once per cycle, immediately after the lock is acquired and
before any assignments are processed. With the default
`-ScheduleEverySeconds 60` registration, that's once a minute.

Body:

```json
{
  "osCaption":     "Microsoft Windows Server 2022 Datacenter",
  "osVersion":     "10.0.20348",
  "dscExeVersion": "dsc 3.1.3",
  "agentVersion":  "0.1.0-dashboard",
  "modules": [
    { "name": "DscV3.RegFile", "version": "0.3.0" },
    { "name": "PSDscResources", "version": "..." }
  ],
  "serverTime": "2025-01-15T12:34:56.7890123Z"
}
```

The module list is built by `Get-InstalledModuleList`, which merges
two sources (in order, deduplicated by name):

1. `Get-InstalledPSResource` from `Microsoft.PowerShell.PSResourceGet`,
   for both `AllUsers` and `CurrentUser` scopes — preferred because it
   carries scope info.
2. `Get-Module -ListAvailable` — picks up modules dropped into
   `$env:PSModulePath` that PSResourceGet hasn't indexed.

If the heartbeat fails, the runner logs `WARN heartbeat failed: <reason>`
and proceeds to assignment polling anyway. A failed heartbeat does not
abort the cycle — the dashboard will simply mark the server as
`stale` after its own timeout.

After a module install (see "prereq reconciliation" below) the runner
re-sends the heartbeat in the same cycle so the dashboard sees the
updated `server_modules` row before evaluating prereq the next time.

## Assignment poll

```
GET /api/agents/<agentId>/assignments
Authorization: Bearer <agentApiKey>
If-None-Match: "<cached etag>"   (when present)
```

The runner uses ETag-conditional GET to avoid re-downloading an
unchanged assignment list. The cache lives at:

```
C:\ProgramData\DscV3\state\assignments.etag         # last ETag value
C:\ProgramData\DscV3\state\assignments.items.json   # last full payload
```

Two response paths:

* **`200 OK`** — write the new ETag, persist the items array, then
  iterate.
* **`304 Not Modified`** — the dashboard says the assignment list is
  unchanged. The runner replays the cached `assignments.items.json`
  array and re-evaluates `nextDueAt` against the wall clock anyway —
  it does NOT skip the cycle, because a previously-not-due assignment
  may have become due since the last 200.

The response shape is `{ assignments: [...], serverTime, pollIntervalSeconds }`.
For each assignment:

| Field             | Meaning                                                                    |
|-------------------|----------------------------------------------------------------------------|
| `assignmentId`    | Stable id; quoted back in heartbeats and run results.                      |
| `generation`      | Incremented by the dashboard whenever the assignment definition changes.   |
| `lifecycleState`  | `active` (apply normally) or `removing` (POST a removal-ack and skip).     |
| `prereqStatus`    | `ready` (apply) or anything else (try to install missing modules; skip).   |
| `requiredModules` | `[ { name, minVersion? } ]` — modules the assignment needs.                |
| `revisionId`      | Revision of the configuration to apply.                                    |
| `sourceSha256`    | SHA256 of the YAML body — verified after fetch.                            |
| `nextDueAt`       | UTC timestamp; the runner skips assignments whose `nextDueAt` is in future.|

### Prereq reconciliation

If `prereqStatus != 'ready'` and `requiredModules` is non-empty, the
runner calls `Install-RequiredModules` which, per missing module:

* Bootstraps `Microsoft.PowerShell.PSResourceGet` if absent
  (`Install-Module ... -Scope AllUsers -Force -AllowClobber`).
* Trusts PSGallery in PSResourceGet's repo store.
* Calls `Install-PSResource -Name <m> -Scope AllUsers -TrustRepository
  -AcceptLicense [-Version <minVersion>]`.

Then re-heartbeats so the dashboard sees the new module list and can
flip `prereqStatus` to `ready` for the next cycle. The current cycle
skips the assignment.

### Per-cycle cap

`-MaxAssignmentsPerCycle <N>` truncates the items list to N. Default
`0` = no cap. Used to throttle a host that has been re-hydrated with
hundreds of stale assignments.

## Apply path

For each `active`, `prereqStatus=ready` assignment whose `nextDueAt` is
in the past (or always, when the runner is invoked with `-Now`):

1. **Fetch + cache the YAML.** `Get-RevisionYaml` checks
   `C:\ProgramData\DscV3\state\revisions\<revisionId>.dsc.yaml`. If
   the cached file's SHA256 already matches `sourceSha256`, it's used.
   Otherwise the runner calls
   `GET /api/agents/<agentId>/revisions/<revisionId>`, writes the body,
   recomputes the hash, and **throws if the hash does not match the
   assignment's `sourceSha256`** (rejecting tampering or a stale
   replay).
2. **Invoke `dsc.exe`.** `Invoke-DscApply` runs:

   ```powershell
   dsc config set --file <yamlPath> --output-format json 2>&1 | Out-String
   ```

   The runner captures both stdout and stderr (merged) and the
   `$LASTEXITCODE`. The path to `dsc.exe` is resolved once at the top
   of the cycle via `Get-Command dsc`; if it is not on PATH the runner
   throws.

3. **Build the result body.**

   ```json
   {
     "assignmentId":    "...",
     "generation":      1,
     "runId":           "<new guid>",
     "revisionId":      "...",
     "exitCode":        0,
     "hadErrors":       false,
     "inDesiredState":  true,
     "durationMs":      4321,
     "startedAt":       "2025-01-15T12:34:56.7890123Z",
     "finishedAt":      "2025-01-15T12:35:01.1100456Z",
     "dscOutput":       { "raw": "<combined stdout+stderr from dsc.exe>" }
   }
   ```

   `hadErrors` is `exitCode != 0`; `inDesiredState` is `!hadErrors`.
   The full combined output is shipped in `dscOutput.raw` — the
   dashboard parses it server-side rather than the agent trying to
   interpret it.

4. **Persist locally.** The same JSON is written to
   `C:\ProgramData\DscV3\runs\<runId>.json` so the result survives
   even if the POST fails.

5. **POST to the dashboard.**

   ```
   POST /api/agents/<agentId>/results
   Authorization: Bearer <agentApiKey>
   Content-Type: application/json
   ```

   `Send-RunResult` swallows transport errors and logs a `WARN`. The
   local copy under `runs\` is the authoritative record on the agent
   side.

### Removal acknowledgement

If `lifecycleState == 'removing'`, the runner skips the apply and
instead calls:

```
POST /api/agents/<agentId>/removal-ack
{ "assignmentId": "...", "generation": N, "success": true,
  "message": "removal acknowledged (no uninstall handler implemented)" }
```

The runner does NOT attempt to undo the configuration today — the ack
is enough to let the dashboard archive the assignment row.

## Run-as credential handling

The agent itself does not handle a per-assignment "run-as" credential
— the entire DSC apply runs under the scheduled task's principal
(SYSTEM, a gMSA, or a password-backed local/domain admin set at
registration time, see `agent-bootstrap.md`).

The credential plaintext is materialised in memory only at the moment
`Register-ScheduledTask -Password <plain>` is called, then the BSTR is
zero-freed in a `finally`. Windows persists it as an LSA secret on
this machine. From the runner's perspective:

* No file under `C:\ProgramData\DscV3\` ever contains a password — not
  `agent.config.json`, not `runs\*.json`, not `state\agent.log`.
* The runner never reads or decrypts the LSA secret. Windows hands it
  the token at process start.
* When a reprovisioning flow rotates the credential, the new
  `Register-DashboardAgent.ps1` invocation re-fetches it via the
  `-CredentialUrl` one-time URL, materialises it just long enough to
  call `Register-ScheduledTask`, and zeroes it. The runner has no
  participation in that handshake — it simply gets relaunched under
  the new principal on the next minute boundary.

## Unified log file

All bootstrap scripts and the runner share one log sink, written via
`DscFleet.Logging.psm1`:

```
C:\ProgramData\DscV3\state\agent.log
```

### Format

```
2025-01-15T12:34:56.789Z [Runner] [INFO] heartbeat ok (12 module(s) reported, ...)
2025-01-15T12:34:57.012Z [Runner] [WARN] assignments fetch failed: ...
2025-01-15T12:34:57.234Z [Install] [INFO] ==> Installing prerequisites
```

Format: `<utc>Z [<Component>] [<LEVEL>] <message>`. `Component` labels
in use: `Install`, `Prereq`, `Register`, `Runner`, `RunAs`. `LEVEL` is
one of `DEBUG`, `INFO`, `WARN`, `ERROR`.

A single `grep` over `agent.log` filters by phase. The runner uses
`Write-RunnerLog` (a thin wrapper that picks `Component=Runner` and
falls back to `Write-Host` if the logging module is missing — relevant
during a mid-upgrade window).

### One file per host

There is intentionally **one log per host**, not one file per run.
The previous "one file per run" model produced thousands of tiny files
that nobody could correlate; the unified file is grep-friendly and
always reflects the latest state of the agent.

Per-run output from `dsc.exe` is preserved separately in
`C:\ProgramData\DscV3\runs\<runId>.json` (the `dscOutput.raw` field).

### Concurrency

Writes are serialised with a local named mutex
(`Local\DscFleetAgentLog`). `Add-Content` provides the OS-level append;
the mutex serialises the size check + rotation race window. Mutex
acquisition has a 2-second timeout; abandoned-mutex exceptions are
treated as "lock acquired" (the previous owner crashed mid-write).

### Routing

* Console — every line is also `Write-Host`'d, coloured by level
  (red/yellow/dark-gray for ERROR/WARN/DEBUG, default for INFO). This
  matters because the bootstrap chain often runs under
  `Invoke-AzVMRunCommand`, which captures stdout — losing the host
  write would lose the install transcript.
* `-NoConsole` switch — file-only, used for high-volume DEBUG that
  shouldn't flood Run-Command stdout.
* If the file write itself fails, the module emits one `[DscFleet.Logging]
  write failed:` marker on the console and returns. **Logging never
  throws back into the caller** — a logging fault never aborts a
  heartbeat or an apply.

### Retention / rotation

* Max single file size: **5 MB** (`$DscFleetLogMaxMB`).
* Rotated copies kept: **2** (`$DscFleetLogKeep`) — `agent.log.1` and
  `agent.log.2`. Older copies are dropped.
* Rotation runs lazily, inside the mutex, before each append. A
  rotation failure is silently ignored — never blocks logging.

### Secret scrubbing

Lines are passed through `Format-DscFleetLogMessage` which redacts:

* `Authorization: Bearer <token>` → `Authorization: Bearer <redacted>`
* `ProvisionToken=<...>`, `AgentApiKey=<...>`, `password=<...>`
* `/api/agents/runas/<token>` (the one-time credential URLs)
* `?token=`, `?access_token=`, `?provision_token=`, `?api_key=` query
  string forms

This is conservative — bearer tokens and one-time URLs would otherwise
end up on every fleet member's disk after the bootstrap chain runs.

## Scheduled-task launch vs interactive launch

Both invoke the same script, but a few things differ:

| Aspect            | Scheduled task (`DscV3-Apply`)                                    | Interactive (operator)                                  |
|-------------------|-------------------------------------------------------------------|---------------------------------------------------------|
| Principal        | SYSTEM (default), gMSA, or password-backed admin (set at register)| The interactive operator's logon (must be admin)        |
| Trigger          | `New-ScheduledTaskTrigger -Once -At today+1m -RepetitionInterval` | None — one shot                                         |
| Cadence          | Every `-ScheduleEverySeconds` (default 60)                        | Once                                                    |
| `-Mode`          | `Dashboard` (the only valid value today)                          | `Dashboard`                                             |
| Working directory| `C:\Windows\system32`                                             | Wherever the operator launched                          |
| `$PSScriptRoot`  | `C:\ProgramData\DscV3\bin` (so the logging module is found)       | Same — the runner is always run from its install path  |
| `-Now`           | Not passed — assignments respect `nextDueAt`                      | Optionally passed to bypass `nextDueAt` for ad-hoc apply|
| Lock behaviour   | Subject to 60-min lock window; concurrent task starts are dropped | Same lock — operator runs while a task run is in flight will exit early |

### Manual cycle (operator)

```powershell
# Apply everything immediately, ignoring nextDueAt:
& 'C:\ProgramData\DscV3\bin\Invoke-DscRunner.ps1' `
    -Mode Dashboard `
    -AgentConfig 'C:\ProgramData\DscV3\agent.config.json' `
    -Now

# Tail the unified log while it runs:
Get-Content -LiteralPath 'C:\ProgramData\DscV3\state\agent.log' -Tail 50 -Wait
```

### Force the scheduled task to fire now

```powershell
Start-ScheduledTask -TaskName DscV3-Apply
Get-ScheduledTaskInfo -TaskName DscV3-Apply
```

### Inspect the per-run output

```powershell
Get-ChildItem C:\ProgramData\DscV3\runs |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 5

Get-Content -Raw 'C:\ProgramData\DscV3\runs\<runId>.json' |
    ConvertFrom-Json |
    Select-Object assignmentId, exitCode, hadErrors, durationMs,
                  @{n='dscOutput';e={$_.dscOutput.raw.Substring(0,500)}}
```
