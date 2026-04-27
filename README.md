# dsc-fleet

The **platform** repo for managing DSC v3 across a fleet of Windows Servers
(Azure VM + Arc). Pairs with **[anwather/dsc-fleet-configs](https://github.com/anwather/dsc-fleet-configs)**,
which holds the actual `.dsc.yaml` documents the runner applies.

## What's where

| Path             | Purpose                                                                         |
| ---------------- | ------------------------------------------------------------------------------- |
| `bootstrap/`     | `Install-Prerequisites.ps1`, `Install-DscV3.ps1`, `Invoke-DscRunner.ps1`.       |
| `modules/`       | `DscV3.RegFile` — single custom class-based DSC v3 resource (`RegFile`).        |
| `reporting/`     | Azure Function (PowerShell) + Bicep IaC + Workbook for fleet compliance (coming soon). |
| `schemas/`       | Cached DSC v3 JSON schemas for offline validation in CI.                        |
| `tests/`         | Pester tests (sync verify, schema, parse).                                      |
| `docs/`          | `pilot-rollout.md` — staged rollout plan.                                       |
| `.github/`       | CI: lint + Pester + sync verify, on-tag release zips.                           |

## Resource model

The platform deliberately keeps custom code to the absolute minimum. One
custom resource is shipped because nothing equivalent exists upstream:

| Resource                                    | Source                                  | Adapter                          |
| ------------------------------------------- | --------------------------------------- | -------------------------------- |
| `DscV3.RegFile/RegFile`                     | This repo (`modules/DscV3.RegFile`)     | `Microsoft.DSC/PowerShell`       |
| `Microsoft.WinGet.DSC/WinGetPackage`        | PSGallery (`Microsoft.WinGet.DSC`)      | `Microsoft.DSC/PowerShell`       |
| `PSDscResources/*` (MsiPackage, Script, …)  | PSGallery (`PSDscResources`)            | `Microsoft.Windows/WindowsPowerShell` |
| `PSDesiredStateConfiguration/*` (Service, PSModule, PSRepository) | In-box PowerShell 5.1                | `Microsoft.Windows/WindowsPowerShell` |
| `Microsoft.Windows/Registry`                | DSC v3 CLI (built-in)                   | none                             |

Both PSGallery modules are installed by `Install-Prerequisites.ps1` to the
AllUsers scope so they are picked up by the WindowsPowerShell adapter under
SYSTEM. See the **configs** repo for ready-to-paste samples for each.

## Supported OS

The bootstrap targets **Windows Server 2019, 2022, and 2025 (x64 only)**.
PowerShell 5.1 is the only baseline requirement on the target machine —
PowerShell 7, the DSC v3 CLI, and Git for Windows are pulled directly from
their official GitHub release artifacts (MSI / zip / Inno installer).

> **WS2019 caveat**: winget does not ship on Server 2019. Configurations
> using `Microsoft.WinGet.DSC/WinGetPackage` will fail there — use
> `PSDscResources/MsiPackage` instead, or filter by OS.

## How a server gets onboarded

```powershell
# As Admin (or via Invoke-AzVMRunCommand) on each target server:
.\bootstrap\Install-DscV3.ps1 `
    -PlatformRepoUrl 'https://github.com/anwather/dsc-fleet.git' `
    -PlatformRef     'v1.0.0' `
    -ConfigsRepoUrl  'https://github.com/anwather/dsc-fleet-configs.git' `
    -ConfigsRef      'main' `
    -ReportingEndpoint 'https://<funcname>.azurewebsites.net/api/runs?code=<key>'
```

The bootstrap:

1. Calls `Install-Prerequisites.ps1` (direct downloads of pwsh, dsc, git;
   PSResourceGet from PSGallery; then `Microsoft.WinGet.DSC` and
   `PSDscResources` from PSGallery to AllUsers scope).
2. Clones this repo to `C:\ProgramData\DscV3\platform`.
3. Installs `DscV3.RegFile` to the AllUsers module path (and removes any
   legacy `DscV3.Discovery` install).
4. Installs `Invoke-DscRunner.ps1` to `C:\ProgramData\DscV3\bin\`.
5. Clones the **configs** repo to `C:\ProgramData\DscV3\repo`.
6. Registers SYSTEM scheduled task `DscV3-Apply` (every 30 min, jittered).

The runner refreshes the configs repo on each cycle — to ship a config change
you only need to push to `dsc-fleet-configs`. Platform changes require a
re-bootstrap (intentional — slower lifecycle).

## Local development

```powershell
# Re-sync the .psm1 from Classes/*.ps1 after editing a class
.\modules\DscV3.RegFile\build\Sync-Module.ps1

# Run the test suite
Invoke-Pester .\tests\Pester
```

## Reporting backend (coming soon)

```powershell
az deployment group create -g rg-dscv3 `
    -f reporting\bicep\main.bicep -p namePrefix=dscv3prod
```

Outputs include `functionUrl`, `dceEndpoint`, `dcrImmutableId`. Then import
`reporting/workbook/dscv3-fleet.workbook.json` into Azure Monitor Workbooks.

See `docs/pilot-rollout.md` for the staged production rollout plan.

## Releases

Tag the platform repo (`git tag v1.0.0 && git push --tags`). The CI release
job publishes:

* `DscV3.RegFile-vX.Y.Z.zip` — module-only, drop into AllUsers module path.
* `dsc-fleet-vX.Y.Z.zip` — full platform (bootstrap + module + reporting + docs).

Pin servers to a specific tag with `Install-DscV3.ps1 -PlatformRef vX.Y.Z`.
