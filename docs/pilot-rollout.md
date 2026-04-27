# Pilot rollout

A staged plan to take the DSC v3 fleet management capability from zero to all
servers without breaking production.

> Cadences below are sequencing only — actual scheduling is per-environment.

## Stage 0 — single-host lab

- A single non-production Windows Server (Azure VM or Arc-enrolled).
- Run `bootstrap/Install-DscV3.ps1 -RepoUrl <repo> -RepoRef main -ReportingEndpoint ''`
  with `-WhatIf` first, then live.
- Manually invoke the runner: `Start-ScheduledTask DscV3-Apply`.
- Verify under `C:\ProgramData\DscV3\runs\` that JSON output files are written
  and exit codes are 0.

**Gate:** all 6 example configs return success on the lab host.

## Stage 1 — reporting backend

- Deploy `reporting/bicep/main.bicep` to a dedicated RG.
- Capture outputs: `functionUrl`, `dceEndpoint`, `dcrImmutableId`.
- Re-run bootstrap with `-ReportingEndpoint <functionUrl>?code=<funcKey>`.
- Verify rows arrive: `DscV3RunSummary_CL | take 10`.
- Import `reporting/workbook/dscv3-fleet.workbook.json`.

**Gate:** end-to-end pipeline (server → Function → Log Analytics → Workbook)
green for ≥24h.

## Stage 2 — canary (≤5 servers)

- Tag canary servers with `Canary=true` (Arc) or rename to `*-canary`.
- The `canary` group runs everything in `mode: test` hourly — report-only,
  never `Set`.
- Watch the Workbook's "Most-drifted resources" tile for drift the enforce
  mode would have caused. Adjust configs accordingly.

**Gate:** zero unexpected drift entries for ≥7 days; no failed runs.

## Stage 3 — first production wave (10–20 servers)

- Move 10–20 representative servers into real production groups.
- Keep `mode: set` but only enable **registry** + **service-baseline**
  configurations first.

**Gate:** Successful% ≥ 99 across two cycles; on-call paged ≤0 times.

## Stage 4 — full fleet

- Move remaining servers into membership.
- Enable application configs (Winget, MSI-from-share, `.reg` import).
- Switch bootstrap `-RepoRef` from `main` to a tag (e.g., `v1.0.0`).
- Add an alert rule:
  ```kql
  DscV3RunSummary_CL
  | where TimeGenerated > ago(2h)
  | summarize Failed = countif(Success == false), Total = count() by Host
  | where Failed * 1.0 / Total >= 0.5
  ```

## Stage 5 — operationalise

- Document on-call runbook: how to read the Workbook, how to re-run a single
  config (`Invoke-DscRunner.ps1 -OnlyGroup <g> -Now`), how to pause a config
  (move it out of the group in `assignments.json`, tag, push).
- Quarterly review of pinned versions (`dsc.exe`, PSResourceGet, modules).

## Rollback

- **Per-config:** revert YAML in repo, tag, bump `RepoRef`. Next run reverts.
- **Per-server:** `Disable-ScheduledTask DscV3-Apply`. Change stays, stops being enforced.
- **Full:** `Unregister-ScheduledTask DscV3-Apply -Confirm:$false`; remove `C:\ProgramData\DscV3`.

## Risks tracked during pilot

| Risk                                                  | Mitigation                                                  |
| ----------------------------------------------------- | ----------------------------------------------------------- |
| `dsc.exe` version drift bootstrap ↔ runtime           | Pin `DscVersion` in bootstrap; CI installs the same pinned. |
| 100+ servers DDoSing Function at 03:00                | Scheduled task `RandomDelay = 30min`.                       |
| `Microsoft.PowerShell.PSResourceGet` not preinstalled | Bootstrap installs it.                                      |
| WindowsPowerShell adapter required for `Service`      | Documented; runtime is Windows-only.                        |
| Module changes invisible to adapter (cache stale)    | Bootstrap deletes `PSAdapterCache.json` on every install.   |
