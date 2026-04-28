# Pilot rollout

A staged plan to take the DSC v3 fleet management capability from zero to all
servers without breaking production. All delivery is via the dashboard
([dsc-fleet-dashboard](https://github.com/anwather/dsc-fleet-dashboard)).

> Cadences below are sequencing only — actual scheduling is per-environment.

## Stage 0 — single-host lab

- Stand up a `dsc-fleet-dashboard` instance (minikube is fine for the lab).
- Pick a single non-production Windows Server (Azure VM or Arc-enrolled).
- On the server: `bootstrap/Install-DscV3.ps1` (use `-WhatIf` first).
- In the dashboard UI: add the server, click Provision, copy the token.
- On the server: `bootstrap/Register-DashboardAgent.ps1` with the token.
- Author one trivial config in the dashboard (e.g., a `RegFile` write to
  `HKLM\Software\DscV3Lab`) and assign it.
- After the next runner cycle, verify the dashboard shows
  `lastRunAt` + `Compliant`, and that
  `C:\ProgramData\DscV3\runs\*.json` contains the expected output.

**Gate:** all sample configs return success on the lab host; dashboard
reports compliance correctly.

## Stage 1 — canary (≤5 servers)

- Onboard 5 representative non-production servers via the same flow.
- Assign read-only / report-style configs first (registry reads, idempotent
  baselines) so any failures are recoverable.
- Watch the dashboard's per-server **Prereqs** and **Runs** tabs each cycle.

**Gate:** zero unexpected failures for ≥7 days; no on-call pages.

## Stage 2 — first production wave (10–20 servers)

- Onboard 10–20 production servers.
- Add **registry** + **service-baseline** configurations and assign them
  to the canary + production servers.

**Gate:** Successful% ≥ 99 across two cycles; on-call paged ≤0 times.

## Stage 3 — full fleet

- Onboard remaining servers.
- Add application configs (Winget, MSI-from-share, `.reg` import) and
  assign them.
- Switch bootstrap `-PlatformRef` from `main` to a tag (e.g., `v1.0.0`)
  for new onboardings.

## Stage 4 — operationalise

- Document on-call runbook: how to read run JSON locally, how to pause an
  assignment in the UI, how to mark a server for re-provisioning, how to
  remove a decommissioned server.
- Quarterly review of pinned versions (`dsc.exe`, PSResourceGet, modules).

## Rollback

- **Per-config:** delete or unassign the config in the dashboard. The next
  runner cycle picks up the removal; the assignment lifecycle moves
  through `removing` → `removed`.
- **Per-server:** in the dashboard, click **Remove server** (soft-delete
  hides it from all lists). To stop the agent on the host as well:
  `Disable-ScheduledTask DscV3-Apply` on the server.
- **Full:** on each server,
  `Unregister-ScheduledTask DscV3-Apply -Confirm:$false`; remove
  `C:\ProgramData\DscV3`. Tear down the dashboard.

## Risks tracked during pilot

| Risk                                                  | Mitigation                                                  |
| ----------------------------------------------------- | ----------------------------------------------------------- |
| `dsc.exe` version drift bootstrap ↔ runtime           | Pin `DscVersion` in bootstrap; CI installs the same pinned. |
| `Microsoft.PowerShell.PSResourceGet` not preinstalled | Bootstrap installs it.                                      |
| WindowsPowerShell adapter required for `Service`      | Documented; runtime is Windows-only.                        |
| Module changes invisible to adapter (cache stale)     | Bootstrap deletes `PSAdapterCache.json` on every install.   |
| Dashboard unreachable from agent                      | Runner exits cleanly; next cycle retries. Cloudflared tunnel for lab. |