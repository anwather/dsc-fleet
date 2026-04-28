# dsc-fleet

The **platform** repo for managing DSC v3 across a fleet of Windows Servers
(Azure VM + Arc). Pairs with:

- **[anwather/dsc-fleet-dashboard](https://github.com/anwather/dsc-fleet-dashboard)** —
  the self-hostable dashboard that stores configs, schedules runs, and
  collects per-server compliance results. The runner in this repo is the
  agent that talks to it.

## How it works

1. The dashboard stores `.dsc.yaml` documents (configs) and assigns them to
   servers.
2. `bootstrap/Install-DscV3.ps1` lays down PowerShell 7, the DSC v3 CLI,
   the `DscV3.RegFile` module, and the runner script on a target server.
3. `bootstrap/Register-DashboardAgent.ps1` registers the server with the
   dashboard (single-use provision token) and creates the scheduled
   task `DscV3-Apply` that invokes the runner every minute. Default
   identity is `SYSTEM`; can be switched to a local/domain account or
   gMSA — see [Run-as identity](#run-as-identity-optional).
4. Each cycle the runner pulls due assignments, applies them with
   `dsc config set`, and POSTs the result back. Pause/resume/remove all
   happen from the dashboard UI.

## What's where

| Path             | Purpose                                                                         |
| ---------------- | ------------------------------------------------------------------------------- |
| `bootstrap/`     | `Install-Prerequisites.ps1`, `Install-DscV3.ps1`, `Invoke-DscRunner.ps1`, `Register-DashboardAgent.ps1`. |
| `modules/`       | `DscV3.RegFile` — single custom class-based DSC v3 resource (`RegFile`).        |
| `schemas/`       | Cached DSC v3 JSON schemas for offline validation in CI.                        |
| `tests/`         | Pester tests (sync verify, schema, parse).                                      |
| `docs/`          | `pilot-rollout.md` — staged rollout plan.                                       |
| `.github/`       | CI: lint + Pester + sync verify; on-tag release zips.                           |

## Resource model

The platform deliberately keeps custom code to the absolute minimum. One
custom resource is shipped because nothing equivalent exists upstream:

| Resource                                                          | Source                              | Adapter                               |
| ----------------------------------------------------------------- | ----------------------------------- | ------------------------------------- |
| `DscV3.RegFile/RegFile`                                           | This repo (`modules/DscV3.RegFile`) | `Microsoft.DSC/PowerShell`            |
| `Microsoft.WinGet.DSC/WinGetPackage`                              | PSGallery (`Microsoft.WinGet.DSC`)  | `Microsoft.DSC/PowerShell`            |
| `PSDscResources/*` (MsiPackage, Script, ...)                      | PSGallery (`PSDscResources`)        | `Microsoft.Windows/WindowsPowerShell` |
| `PSDesiredStateConfiguration/*` (Service, PSModule, PSRepository) | In-box PowerShell 5.1               | `Microsoft.Windows/WindowsPowerShell` |
| `Microsoft.Windows/Registry`                                      | DSC v3 CLI (built-in)               | none                                  |

Both PSGallery modules are installed by `Install-Prerequisites.ps1` to the
AllUsers scope so they are picked up by the WindowsPowerShell adapter under
SYSTEM.

## Supported OS

The bootstrap targets **Windows Server 2019, 2022, and 2025 (x64 only)**.
PowerShell 5.1 is the only baseline requirement on the target machine —
PowerShell 7, the DSC v3 CLI, and Git for Windows are pulled directly from
their official GitHub release artifacts (MSI / zip / Inno installer).

> **WS2019 caveat**: winget does not ship on Server 2019. Configurations
> using `Microsoft.WinGet.DSC/WinGetPackage` will fail there — use
> `PSDscResources/MsiPackage` instead, or filter by OS.

## Onboarding a server

Prerequisites: a running [dsc-fleet-dashboard](https://github.com/anwather/dsc-fleet-dashboard)
instance and a target Windows Server you can reach as Admin (locally or
via `Invoke-AzVMRunCommand`).

### 1. Lay down the runtime

Run as Admin on the target server:

```powershell
.\bootstrap\Install-DscV3.ps1 `
    -PlatformRepoUrl 'https://github.com/anwather/dsc-fleet.git' `
    -PlatformRef     'main'
```

This installs prerequisites (pwsh 7, dsc.exe, git, PSResourceGet,
`Microsoft.WinGet.DSC`, `PSDscResources`), drops the `DscV3.RegFile`
module into the AllUsers module path, and copies `Invoke-DscRunner.ps1`
to `C:\ProgramData\DscV3\bin\`. It does **not** create the scheduled
task — that happens in step 3 with the dashboard credentials in hand.

### 2. Add the server in the dashboard

In the dashboard UI: **Add Server** → fill subscription / resource group
/ VM name → save → click **Provision** to receive a one-time provision
token + the server's UUID.

### 3. Register the agent

From an Admin shell on the target server (or via `Invoke-AzVMRunCommand`):

```powershell
.\bootstrap\Register-DashboardAgent.ps1 `
    -DashboardUrl    'https://dsc-fleet.example.com' `
    -ProvisionToken  '<token from UI>' `
    -ServerId        '<server uuid from UI>'
```

This calls `POST /api/agents/register`, writes
`C:\ProgramData\DscV3\agent.config.json` (SYSTEM + Administrators ACL),
and creates the scheduled task `DscV3-Apply` that runs every minute.
By default the task runs as `NT AUTHORITY\SYSTEM`. The runner then polls
the dashboard, applies due assignments, and POSTs the results back.

### Run-as identity (optional)

The default `SYSTEM` identity is fine for most scenarios. For workloads
where SYSTEM is brittle (notably winget package installs — winget under
SYSTEM cannot enumerate user-scope installs and fails on archive extract
in some package shapes), the agent task can run under a different
identity:

| Identity         | When                                        | Storage                      |
| ---------------- | ------------------------------------------- | ---------------------------- |
| `SYSTEM`         | Default. Most resource types, no AD.        | n/a                          |
| Local admin acct | winget installs, MSI/EXE that need profile. | LSA secret store (machine)   |
| Domain user      | Domain-joined, simple network access.       | LSA secret store (machine)   |
| **gMSA**         | **Recommended for domain-joined boxes.**    | AD-managed (rotated by KDS)  |

The run-as identity **must be a local Administrator** on the VM — the
runner installs PowerShell modules under `Program Files`, restarts
services, writes `HKLM`, etc.

#### Set the identity at provision time

`Register-DashboardAgent.ps1` accepts run-as parameters. Run on the
target box (after `Install-DscV3.ps1`):

```powershell
# Local or domain user (you'll be prompted for the password securely)
$pw = Read-Host 'Password' -AsSecureString
.\bootstrap\Register-DashboardAgent.ps1 `
    -DashboardUrl   'https://dsc-fleet.example.com' `
    -ProvisionToken '<token>' `
    -RunAsUser      'CONTOSO\dscagent' `
    -RunAsPassword  $pw

# gMSA (no password)
.\bootstrap\Register-DashboardAgent.ps1 `
    -DashboardUrl   'https://dsc-fleet.example.com' `
    -ProvisionToken '<token>' `
    -RunAsUser      'CONTOSO\dscgmsa$' `
    -RunAsGmsa
```

The plaintext is materialized only at the `Register-ScheduledTask`
call, then the BSTR is zeroed. Windows stores the credential as an LSA
secret on the local machine (DPAPI-protected with a machine-bound
master key). The dashboard never sees the password.

#### Change the identity after provisioning

Use the retrofit helper. Runs locally; nothing transits the network:

```powershell
# Switch to a service account
.\bootstrap\Set-DscFleetRunAsAccount.ps1 -Credential (Get-Credential .\dscagent)

# Switch to a gMSA
.\bootstrap\Set-DscFleetRunAsAccount.ps1 -RunAsUser 'CONTOSO\dscgmsa$' -Gmsa

# Revert to SYSTEM
.\bootstrap\Set-DscFleetRunAsAccount.ps1 -SystemAccount
```

#### Caveats

- **Run-Command leakage:** if you push run-as creds via the dashboard's
  Azure Run-Command provision flow, the credentials are interpolated
  into the script content which Azure persists in the VM instance view
  for ~7 days. Prefer `Set-DscFleetRunAsAccount.ps1` post-provision when
  the security model matters.
- **LSA recoverable by local SYSTEM:** Task Scheduler-stored passwords
  are protected, not invulnerable. They can be retrieved by anyone with
  SYSTEM/local-admin and LSASS access. gMSA eliminates this.
- **`Log on as a batch job`:** the run-as account needs
  `SeBatchLogonRight`. Local administrators have it by default; domain
  GPO can deny it. If the task fails to start with `0x80070534`, that's
  the reason.
- **gMSA prerequisites:** VM must be domain-joined; KDS root key must
  exist; `Test-ADServiceAccount <name>` should return `True` on the VM
  before registering the task.

## Local development

```powershell
# Re-sync the .psm1 from Classes/*.ps1 after editing a class
.\modules\DscV3.RegFile\build\Sync-Module.ps1

# Run the test suite
Invoke-Pester .\tests\Pester
```

## Releases

Tag the platform repo (`git tag v1.0.0 && git push --tags`). The CI release
job publishes:

- `DscV3.RegFile-vX.Y.Z.zip` — module-only, drop into AllUsers module path.
- `dsc-fleet-vX.Y.Z.zip` — full platform (bootstrap + module + schemas + docs).

Pin servers to a specific tag with `Install-DscV3.ps1 -PlatformRef vX.Y.Z`.