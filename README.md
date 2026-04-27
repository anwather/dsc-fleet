# dsc-fleet

The **platform** repo for managing DSC v3 across a fleet of Windows Servers
(Azure VM + Arc). Pairs with **[anwather/dsc-fleet-configs](https://github.com/anwather/dsc-fleet-configs)**,
which holds the actual `.dsc.yaml` documents the runner applies.

## What's where

| Path             | Purpose                                                                         |
| ---------------- | ------------------------------------------------------------------------------- |
| `bootstrap/`     | `Install-Prerequisites.ps1`, `Install-DscV3.ps1`, `Invoke-DscRunner.ps1`.       |
| `modules/`       | `DscV3.Discovery` — class-based custom resources (Winget / Choco / MSI / etc.). |
| `reporting/`     | Azure Function (PowerShell) + Bicep IaC + Workbook for fleet compliance.       |
| `schemas/`       | Cached DSC v3 JSON schemas for offline validation in CI.                        |
| `tests/`         | Pester tests (sync verify, schema, parse).                                      |
| `docs/`          | `pilot-rollout.md` — staged rollout plan.                                       |
| `.github/`       | CI: lint + Pester + sync verify, on-tag release zips.                           |

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

1. Calls `Install-Prerequisites.ps1` (winget, pwsh, dsc, git, PSResourceGet).
2. Clones this repo to `C:\ProgramData\DscV3\platform`.
3. Installs `DscV3.Discovery` to the AllUsers module path.
4. Installs `Invoke-DscRunner.ps1` to `C:\ProgramData\DscV3\bin\`.
5. Clones the **configs** repo to `C:\ProgramData\DscV3\repo`.
6. Registers SYSTEM scheduled task `DscV3-Apply` (every 30 min, jittered).

The runner refreshes the configs repo on each cycle — to ship a config change
you only need to push to `dsc-fleet-configs`. Platform changes require a
re-bootstrap (intentional — slower lifecycle).

## Local development

```powershell
# Re-sync the .psm1 from Classes/*.ps1 after editing a class
.\modules\DscV3.Discovery\build\Sync-Module.ps1

# Run the test suite
Invoke-Pester .\tests\Pester
```

## Reporting backend

```powershell
az deployment group create -g rg-dscv3 `
    -f reporting\bicep\main.bicep -p namePrefix=dscv3prod
```

Outputs include `functionUrl`, `dceEndpoint`, `dcrImmutableId`. Then import
`reporting/workbook/dscv3-fleet.workbook.json` into Azure Monitor Workbooks.

See `docs/pilot-rollout.md` for the staged production rollout plan.

## Releases

Tag the platform repo (`git tag v1.0.0 && git push --tags`). The CI release job
publishes:

* `DscV3.Discovery-vX.Y.Z.zip` — module-only, drop into AllUsers module path.
* `dsc-fleet-vX.Y.Z.zip` — full platform (bootstrap + module + reporting + docs).

Pin servers to a specific tag with `Install-DscV3.ps1 -PlatformRef vX.Y.Z`.
