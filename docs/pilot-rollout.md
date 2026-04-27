# Pilot rollout

A staged plan to take the DSC v3 fleet management capability from zero to all
servers without breaking production.

> Cadences below are sequencing only — actual scheduling is per-environment.
> This guide covers Git-mode delivery. For Dashboard-mode rollout, see the
> [dsc-fleet-dashboard](https://github.com/anwather/dsc-fleet-dashboard) repo.

## Stage 0 — single-host lab

- A single non-production Windows Server (Azure VM or Arc-enrolled).
- Run `bootstrap/Install-DscV3.ps1` with `-WhatIf` first, then live.
- Manually invoke the runner: `Start-ScheduledTask DscV3-Apply`.
- Verify under `C:\ProgramData\DscV3\runs\` that JSON output files are written
  and exit codes are 0.

**Gate:** all sample configs return success on the lab host.

## Stage 1 — canary (≤5 servers)

- Tag canary servers with `Canary=true` (Arc) or rename to `*-canary`.
- The `canary` group runs everything in `mode: test` hourly — report-only,
  never `Set`.
- Inspect `C:\ProgramData\DscV3\runs\*.json` (or wire the dashboard up — see
  below) for drift the enforce mode would have caused. Adjust configs
  accordingly.

**Gate:** zero unexpected drift entries for ≥7 days; no failed runs.

## Stage 2 — first production wave (10–20 servers)

- Move 10–20 representative servers into real production groups.
- Keep `mode: set` but only enable **registry** + **service-baseline**
  configurations first.

**Gate:** Successful% ≥ 99 across two cycles; on-call paged ≤0 times.

## Stage 3 — full fleet

- Move remaining servers into membership.
- Enable application configs (Winget, MSI-from-share, `.reg` import).
- Switch bootstrap `-PlatformRef` from `main` to a tag (e.g., `v1.0.0`).

## Stage 4 — operationalise

- Document on-call runbook: how to inspect run JSON locally, how to re-run a
  single config (`Invoke-DscRunner.ps1 -OnlyGroup <g> -Now`), how to pause a
  config (move it out of the group in `assignments.json`, tag, push).
- Quarterly review of pinned versions (`dsc.exe`, PSResourceGet, modules).

## Optional: add the dashboard

For a UI, per-server scheduling, and centralised compliance:

- Stand up [`dsc-fleet-dashboard`](https://github.com/anwather/dsc-fleet-dashboard).
- For each existing server, run `bootstrap/Register-DashboardAgent.ps1` with
  a provision token from the UI. This switches that server's `DscV3-Apply`
  task from Git mode to Dashboard mode.
- The Git-mode `assignments.json` is no longer consulted on switched servers.
  Configs and assignments now flow from the dashboard's database.

You can switch a fleet server-by-server — Git-mode and Dashboard-mode hosts
coexist happily in the same environment.

## Rollback

- **Per-config (Git mode):** revert YAML in repo, tag, bump `-PlatformRef`.
  Next run reverts.
- **Per-server:** `Disable-ScheduledTask DscV3-Apply`. Change stays, stops
  being enforced.
- **Full:** `Unregister-ScheduledTask DscV3-Apply -Confirm:$false`; remove
  `C:\ProgramData\DscV3`.

## Risks tracked during pilot

| Risk                                                  | Mitigation                                                  |
| ----------------------------------------------------- | ----------------------------------------------------------- |
| `dsc.exe` version drift bootstrap ↔ runtime           | Pin `DscVersion` in bootstrap; CI installs the same pinned. |
| `Microsoft.PowerShell.PSResourceGet` not preinstalled | Bootstrap installs it.                                      |
| WindowsPowerShell adapter required for `Service`      | Documented; runtime is Windows-only.                        |
| Module changes invisible to adapter (cache stale)     | Bootstrap deletes `PSAdapterCache.json` on every install.   |
