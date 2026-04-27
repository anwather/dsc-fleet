# dsc-fleet

The **platform** repo for managing DSC v3 across a fleet of Windows Servers
(Azure VM + Arc). Pairs with:

- **[anwather/dsc-fleet-configs](https://github.com/anwather/dsc-fleet-configs)** —
  the actual `.dsc.yaml` documents the runner applies (Git-mode delivery).
- **[anwather/dsc-fleet-dashboard](https://github.com/anwather/dsc-fleet-dashboard)** —
  optional self-hostable dashboard that adds a UI, scheduling, and per-server
  compliance reporting (Dashboard-mode delivery).

## Two delivery modes

The runner (`bootstrap/Invoke-DscRunner.ps1`) supports two ways of getting
configurations onto a server. Pick one per fleet — they don't mix on a single
host.

| Mode      | How configs arrive                                | Where state lives             | When to use                                       |
| --------- | ------------------------------------------------- | ----------------------------- | ------------------------------------------------- |
| Git       | `git pull` of `dsc-fleet-configs` on each cycle   | `assignments.json` in the repo | No central infra; small fleets; air-gapped scenarios |
| Dashboard | HTTP poll of dsc-fleet-dashboard `/api/agents/*`  | Postgres in the dashboard     | UI for ops; per-server scheduling; live status     |

Both modes share the same `DscV3.RegFile` module and prerequisite installer.

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
| `PSDscResources/*` (MsiPackage, Script, …)                        | PSGallery (`PSDscResources`)        | `Microsoft.Windows/WindowsPowerShell` |
| `PSDesiredStateConfiguration/*` (Service, PSModule, PSRepository) | In-box PowerShell 5.1               | `Microsoft.Windows/WindowsPowerShell` |
| `Microsoft.Windows/Registry`                                      | DSC v3 CLI (built-in)               | none                                  |

Both PSGallery modules are installed by `Install-Prerequisites.ps1` to the
AllUsers scope so they are picked up by the WindowsPowerShell adapter under
SYSTEM. See the configs repo for ready-to-paste samples for each.

## Supported OS

The bootstrap targets **Windows Server 2019, 2022, and 2025 (x64 only)**.
PowerShell 5.1 is the only baseline requirement on the target machine —
PowerShell 7, the DSC v3 CLI, and Git for Windows are pulled directly from
their official GitHub release artifacts (MSI / zip / Inno installer).

> **WS2019 caveat**: winget does not ship on Server 2019. Configurations
> using `Microsoft.WinGet.DSC/WinGetPackage` will fail there — use
> `PSDscResources/MsiPackage` instead, or filter by OS.

## Onboarding — Git mode

Run as Admin (or via `Invoke-AzVMRunCommand`) on each target server:

```powershell
.\bootstrap\Install-DscV3.ps1 `
    -PlatformRepoUrl 'https://github.com/anwather/dsc-fleet.git' `
    -PlatformRef     'v1.0.0' `
    -ConfigsRepoUrl  'https://github.com/anwather/dsc-fleet-configs.git' `
    -ConfigsRef      'main'
```

The bootstrap:

1. Calls `Install-Prerequisites.ps1` (direct downloads of pwsh, dsc, git;
   PSResourceGet from PSGallery; then `Microsoft.WinGet.DSC` and
   `PSDscResources` from PSGallery to AllUsers scope).
2. Clones this repo to `C:\ProgramData\DscV3\platform`.
3. Installs `DscV3.RegFile` to the AllUsers module path (and removes any
   legacy `DscV3.Discovery` install).
4. Installs `Invoke-DscRunner.ps1` to `C:\ProgramData\DscV3\bin\`.
5. Clones the configs repo to `C:\ProgramData\DscV3\repo`.
6. Registers SYSTEM scheduled task `DscV3-Apply` (every 30 min, jittered,
   running the runner in `-Mode Git`).

The runner refreshes the configs repo on each cycle — to ship a config change
you only need to push to `dsc-fleet-configs`. Platform changes require a
re-bootstrap (intentional — slower lifecycle).

## Onboarding — Dashboard mode

First set up the dashboard following
[anwather/dsc-fleet-dashboard](https://github.com/anwather/dsc-fleet-dashboard).
Then on each target server:

1. Run `Install-DscV3.ps1` exactly as for Git mode (it lays down the
   prerequisites, the module, and the runner). The Git-mode scheduled task
   that this registers will be reconfigured in step 3.
2. From the dashboard UI: **Add Server** → fill sub/RG/VM → save → click
   **Provision** to receive a single-use provision token.
3. From an Admin shell on the target server (or via `Invoke-AzVMRunCommand`):

   ```powershell
   .\bootstrap\Register-DashboardAgent.ps1 `
       -DashboardUrl    'https://dsc-fleet.internal' `
       -ProvisionToken  '<token from UI>' `
       -ServerId        '<server uuid from UI>'
   ```

   This calls `POST /api/agents/register`, writes
   `C:\ProgramData\DscV3\agent.config.json` (SYSTEM + Administrators ACL),
   and reconfigures the `DscV3-Apply` scheduled task to invoke the runner
   in `-Mode Dashboard`.

The runner then polls the dashboard each cycle, fetches assignments,
downloads the YAML for each one, applies it, and POSTs the result back.
See the dashboard repo for the full wire protocol.

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
