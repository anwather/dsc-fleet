# Agent bootstrap

This document describes how a Windows Server is turned into a `dsc-fleet`
agent: which scripts run, in what order, what they install, and how the
re-provision flow differs from the first run.

All scripts live under `C:\Source\dsc-fleet\bootstrap\` in the platform repo
and are intended to be invoked by the dashboard's provisioning job (typically
via `Invoke-AzVMRunCommand` or an equivalent SYSTEM-context remoting path).

## Invocation order

Provisioning runs three scripts, in this order:

1. `bootstrap\Install-Prerequisites.ps1` — direct-download install of the
   base toolchain.
2. `bootstrap\Install-DscV3.ps1` — lays down the agent file system layout,
   installs the `DscV3.RegFile` module and the runner, then deletes the
   ephemeral platform clone.
3. `bootstrap\Register-DashboardAgent.ps1` — joins the agent to a specific
   dashboard, persists `agent.config.json`, and (re)creates the
   `DscV3-Apply` scheduled task in dashboard mode.

`Install-DscV3.ps1` calls `Install-Prerequisites.ps1` itself, so for an
end-to-end fresh install you only need to invoke `Install-DscV3.ps1`
followed by `Register-DashboardAgent.ps1`. Re-running `Install-DscV3.ps1`
without `Register-DashboardAgent.ps1` is supported (and idempotent), but
it deliberately does NOT recreate the scheduled task — that is owned by
the dashboard registration step.

`bootstrap\Set-DscFleetRunAsAccount.ps1` is an out-of-band utility for
changing the principal on an already-provisioned agent and is not part of
the bootstrap chain.

## `Install-Prerequisites.ps1`

PowerShell 5.1 + RunAsAdministrator. SYSTEM-context safe. Installs
everything via direct downloads from official upstream sources — `winget`
is intentionally not on the dependency path (App Installer must be primed
interactively on a fresh server, and is missing on WS2019).

### Components

| Component                                    | Source                                                     | Install location                                     |
|----------------------------------------------|------------------------------------------------------------|------------------------------------------------------|
| PowerShell 7 LTS                             | MSI from `github.com/PowerShell/PowerShell` releases       | `C:\Program Files\PowerShell\7\pwsh.exe`             |
| Visual C++ 2015–2022 x64 Runtime             | `https://aka.ms/vs/17/release/vc_redist.x64.exe`           | `C:\Windows\System32\VCRUNTIME140.dll`               |
| DSC v3 CLI (`dsc.exe`)                       | Zip from `github.com/PowerShell/DSC` (pinned tag)          | `C:\Program Files\DSC\dsc.exe` (added to machine PATH) |
| Git for Windows                              | Self-extracting installer from `github.com/git-for-windows`| `C:\Program Files\Git\cmd\git.exe`                   |
| `Microsoft.PowerShell.PSResourceGet`         | PSGallery via `Install-Module` (TLS 1.2 forced)            | AllUsers module path                                 |
| `Microsoft.WinGet.DSC` (DSC v3 resource)     | PSGallery via `Install-PSResource`                         | `C:\Program Files\WindowsPowerShell\Modules`         |
| `PSDscResources`                             | PSGallery via `Install-PSResource`                         | `C:\Program Files\WindowsPowerShell\Modules`         |
| `winget` (detection only)                    | n/a — recorded for diagnostics                             | n/a                                                  |

The VC++ runtime install only fires when `dsc` itself needs to be installed
(detected via `C:\Windows\System32\VCRUNTIME140.dll`).

### Parameters

```powershell
.\Install-Prerequisites.ps1 `
    -DscVersion  '3.1.3' `   # pinned DSC v3 release; default 3.1.3
    -PwshVersion ''       `   # empty = auto-detect latest LTS via GitHub API
    -GitVersion  ''       `   # empty = auto-detect latest stable via GitHub API
    -SkipGit                  # optional — skip git install
```

### Outputs

* Console summary (`[ OK ] / [FAIL] / [skip]` per component).
* JSON status persisted to `C:\ProgramData\DscV3\prereq-status.json`.
* Exit code `0` if `AllInstalled` is true, else `1`.

The status file is consumed by `Install-DscV3.ps1` to resolve absolute
paths to `pwsh.exe` and `git.exe` without trusting that PATH was
refreshed inside the SYSTEM session.

### Idempotency

Each component is gated by an absolute-path probe before it is installed.
Re-running the script on a fully-provisioned host is a no-op:

* PowerShell 7 — present if `C:\Program Files\PowerShell\7\pwsh.exe` exists.
* `dsc.exe` — present if a binary exists under `C:\Program Files\DSC\` AND
  its reported `--version` matches the pinned `-DscVersion`. A version
  mismatch triggers a re-install (overwrite copy into `C:\Program Files\DSC`).
* Git — present if `C:\Program Files\Git\cmd\git.exe` exists.
* `PSResourceGet` and the gallery modules — present if a versioned subdirectory
  exists under `C:\Program Files\(WindowsPowerShell|PowerShell)\Modules\<Name>\`.
  The module probe goes straight to the file system because PS 5.1 caches
  `Get-Module -ListAvailable` and would otherwise lie about a freshly
  installed module.

## `Install-DscV3.ps1`

PowerShell 5.1 + RunAsAdministrator. The script that actually creates the
agent layout on disk. It supports `-WhatIf`.

### What it does

1. Calls `Install-Prerequisites.ps1` (and aborts on non-zero exit).
2. Creates `C:\ProgramData\DscV3\{bin,runs,state}` and locks the ACL down
   to `SYSTEM` + `Administrators` (FullControl) and `Users` (read-only).
3. Shallow-clones the platform repo (default
   `https://github.com/anwather/dsc-fleet.git` at `main`) into a temp
   directory. The clone is **ephemeral** — it is deleted in a `finally`
   block before the script returns. No git history is left on the box.
4. Copies out exactly the artifacts the agent needs:
   * `modules\DscV3.RegFile\` → `C:\Program Files\WindowsPowerShell\Modules\DscV3.RegFile\`
     and (mirrored) `C:\Program Files\PowerShell\Modules\DscV3.RegFile\`.
   * `bootstrap\Invoke-DscRunner.ps1` → `C:\ProgramData\DscV3\bin\Invoke-DscRunner.ps1`.
   * `bootstrap\DscFleet.Logging.psm1` → `C:\ProgramData\DscV3\bin\DscFleet.Logging.psm1`.
5. Removes legacy artifacts left over from previous installer revisions:
   `DscV3.Discovery` modules, `C:\ProgramData\DscV3\repo\` (legacy git-mode
   configs checkout), and `C:\ProgramData\DscV3\platform\` (legacy persistent
   platform checkout).
6. Unregisters any pre-existing `DscV3-Apply` scheduled task (it will be
   re-created with the right arguments by `Register-DashboardAgent.ps1`).
7. Writes `C:\ProgramData\DscV3\state\install.json` with the resolved
   commit SHA, ref, dsc version and timestamp — the only audit trail of
   "what is on the box" once the clone is gone.
8. Deletes `$env:LOCALAPPDATA\dsc\PSAdapterCache.json` so the adapter
   re-scans for the freshly-installed module.

### Parameters

```powershell
.\Install-DscV3.ps1 `
    -PlatformRepoUrl 'https://github.com/anwather/dsc-fleet.git' `
    -PlatformRef     'main'        `   # use a release tag in production
    -DscVersion      '3.1.3'       `
    -GitToken        ''                # PAT for a private platform repo (optional)
```

### Disk layout

```
C:\ProgramData\DscV3\
├── bin\
│   ├── Invoke-DscRunner.ps1
│   └── DscFleet.Logging.psm1
├── runs\                    # local fallback copies of run JSON
├── state\
│   ├── install.json         # commit SHA + timestamp of last install
│   ├── agent.log            # unified log sink (created on first write)
│   ├── runner.lock          # per-cycle lock file
│   ├── assignments.etag     # ETag cache for /api/agents/.../assignments
│   ├── assignments.items.json  # cached assignment list for 304 replays
│   └── revisions\           # SHA-validated YAML cache (per-revision)
├── prereq-status.json       # written by Install-Prerequisites.ps1
└── agent.config.json        # written by Register-DashboardAgent.ps1
```

### Idempotency

Re-runnable. Module and runner copies always overwrite, the manifest is
always rewritten with a fresh timestamp/commit, the ephemeral clone is
always cleaned up. The legacy-cleanup steps are best-effort
(`-ErrorAction SilentlyContinue`).

## `Register-DashboardAgent.ps1`

PowerShell 5.1 + RunAsAdministrator. Joins the agent to a specific
dashboard and (re)creates the scheduled task that drives the runner loop.

### What it does

1. `POST /api/agents/register` with the one-time `-ProvisionToken`,
   hostname, OS caption, OS version. The dashboard responds with an
   `agentId` and `agentApiKey`.
2. Persists `C:\ProgramData\DscV3\agent.config.json` containing
   `DashboardUrl`, `AgentId`, `AgentApiKey`, `Hostname`,
   `RegisteredUtc`. The ACL is reset to inheritance-off, with explicit
   `SYSTEM` + `Administrators` `FullControl` ACEs only — `Users` is
   denied implicitly.
3. Resolves the run-as identity (see "Run-as resolution" below).
4. Unregisters any existing `DscV3-Apply` task, then registers a fresh
   one that runs `pwsh.exe -File <runner> -Mode Dashboard -AgentConfig <cfg>`
   on a 1-minute-from-now `-Once` trigger with a `-RepetitionInterval`
   of `-ScheduleEverySeconds` (default 60s). The task is registered with
   `RunLevel Highest` and the script throws if that does not survive
   registration.
5. If the run-as account is non-SYSTEM, grants it `Read` on
   `agent.config.json` (it should already have access via the
   Administrators ACE — the explicit ACE is belt-and-braces).
6. `POST /api/agents/<agentId>/heartbeat` once with a synchronous
   payload to flip `server.status` to `ready` immediately rather than
   waiting up to 60s for the first scheduled run.

### Parameters

```powershell
.\Register-DashboardAgent.ps1 `
    -DashboardUrl   'https://dsc-fleet.contoso.com' `
    -ProvisionToken '<single-use token>'            `
    -AgentConfig    'C:\ProgramData\DscV3\agent.config.json' `
    -RunnerScript   'C:\ProgramData\DscV3\bin\Invoke-DscRunner.ps1' `
    -ScheduleEverySeconds 60 `
    -RunAsUser     ''                          `   # SYSTEM if blank
    -RunAsPassword $null                       `   # SecureString for password accts
    -RunAsGmsa                                 `   # switch — gMSA without password
    -CredentialUrl 'https://.../agents/runas/<token>' `   # one-time fetch URL
    -Force                                          # overwrite agent.config.json
```

If `agent.config.json` already exists the script refuses to run unless
`-Force` is passed.

### Run-as resolution

The script picks an identity in this order:

1. If `-CredentialUrl` is set, `POST` to it with
   `Authorization: Bearer $ProvisionToken`. The response shape is
   `{ username, kind, password? }` where `kind` is `password` or `gmsa`.
   The URL is single-use; the dashboard scrubs the encrypted material
   from its database after a successful read. `-CredentialUrl` wins
   over inline `-RunAsUser` / `-RunAsPassword`.
2. Otherwise, use the inline `-RunAsUser` / `-RunAsPassword` /
   `-RunAsGmsa` parameters.
3. Otherwise (or if `-RunAsUser` is one of `''`, `NT AUTHORITY\SYSTEM`,
   `SYSTEM`, `NT AUTHORITY\NetworkService`, `NetworkService`,
   `NT AUTHORITY\LocalService`, `LocalService`), register the task as
   `SYSTEM`.

For password-backed accounts the SecureString is materialized into a
`BSTR`, handed to `Register-ScheduledTask -Password`, then
`ZeroFreeBSTR`'d in a `finally`. Windows persists it as an LSA secret on
the local machine — the credential never leaves the box. The run-as
account MUST be a member of local `Administrators` (the runner installs
modules into Program Files, restarts services, writes HKLM, etc.).

### Idempotency

The script throws if `agent.config.json` exists and `-Force` is not
passed (initial provisioning). With `-Force`, it always rewrites the
config, always unregisters and recreates the scheduled task, and always
sends an initial heartbeat. The dashboard side is also idempotent:
re-registering the same hostname against the same `serverId` is a
supported flow (see reprovisioning below).

## Re-provisioning flow

The dashboard can re-issue a provisioning URL for an already-known
server (for example after a host rebuild, a rotation of the run-as
credential, or a move to a different dashboard environment). The agent
side of that flow is the same script — `Register-DashboardAgent.ps1` —
invoked with `-Force`.

### What changes vs initial provisioning

| Aspect                          | Initial                                      | Reprovision                                                    |
|---------------------------------|----------------------------------------------|----------------------------------------------------------------|
| `agent.config.json`             | Created                                      | **Rewritten** with the new `agentId` / `agentApiKey`           |
| Scheduled task `DscV3-Apply`    | Created                                      | Unregistered and recreated                                     |
| `-Force` switch                 | Not required                                 | **Required** (the script refuses to overwrite without it)      |
| Provision token                 | Single-use, freshly minted                   | Single-use, freshly minted (a new one each reprovision)        |
| `-CredentialUrl`                | Optional                                     | **Required if a run-as credential is involved** (see below)    |
| State directory                 | Created from scratch                         | Preserved — assignment cache, install.json, agent.log retained |

The dashboard is responsible for revoking the previous `agentApiKey` on
its side once the new registration's first heartbeat arrives — the agent
just overwrites its local copy.

### Mandatory credential re-prompt (security fix)

The reprovision URL **always carries a fresh `-CredentialUrl` if the
target task is meant to run under a non-SYSTEM identity**, even if the
dashboard already has the credential on file from the initial
provisioning. The agent's behaviour is:

* If `-CredentialUrl` is supplied, the script `POST`s to that URL with
  the new `-ProvisionToken` to fetch `{ username, kind, password? }`.
  This is the only acceptable source of a password for a reprovision —
  the agent never re-uses a cached LSA secret and never assumes the
  existing scheduled-task principal is correct.
* If the dashboard intentionally elides `-CredentialUrl` (i.e. it is
  reprovisioning a known-SYSTEM agent), the script registers the task as
  `SYSTEM` and proceeds. It does NOT silently inherit the previous
  password-backed principal.

The dashboard-side change that makes this possible is that the
encrypted password material is **scrubbed from the database after a
successful read of `-CredentialUrl`**. The next reprovision must mint a
new credential URL backed by either (a) a freshly captured password, or
(b) a gMSA enrollment that needs no password. There is no path that
silently reuses the old ciphertext.

This closes a class of bugs where an operator could re-issue a
provisioning URL, the agent would happily re-register with the
dashboard, but the scheduled task would stay pinned to whatever stale
identity was in place — including, in the worst case, an account whose
password had been rotated out from under us.

### Operator workflow

```powershell
# On the dashboard: mint a new provision token + (optional) credential URL.
# The dashboard returns:
#   ProvisionToken : <single-use>
#   CredentialUrl  : https://.../api/agents/runas/<single-use>   (if non-SYSTEM)

# On the agent:
& 'C:\ProgramData\DscV3\bin\..\..\bootstrap\Register-DashboardAgent.ps1' `
    -DashboardUrl   'https://dsc-fleet.contoso.com' `
    -ProvisionToken '<single-use token>' `
    -CredentialUrl  'https://dsc-fleet.contoso.com/api/agents/runas/<single-use>' `
    -Force
```

After this returns the new `agentId` is recorded in `agent.config.json`,
the new heartbeat has been delivered, and the next scheduled-task run
(within 60s) will pick up assignments under the dashboard's new identity
for this server.
