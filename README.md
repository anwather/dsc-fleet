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
   dashboard (single-use provision token) and creates the SYSTEM scheduled
   task `DscV3-Apply` that invokes the runner every minute.
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
and creates the SYSTEM scheduled task `DscV3-Apply` that runs every
minute. The runner then polls the dashboard, applies due assignments,
and POSTs the results back.

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