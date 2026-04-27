# Workbook — DSC v3 Fleet

`dscv3-fleet.workbook.json` is a Microsoft Azure Workbook that visualises the
ingested DSC v3 run data.

## Import

1. Azure portal → **Monitor** → **Workbooks** → **+ New** → switch to the
   advanced editor (`</>` icon).
2. Paste the contents of `dscv3-fleet.workbook.json`.
3. Click **Done editing** → **Save** → choose subscription / RG / region.
4. When prompted for a Log Analytics workspace, pick the one created by
   `reporting/bicep/main.bicep`.

## Sections

| Section                | Source                  | Notes                                              |
| ---------------------- | ----------------------- | -------------------------------------------------- |
| Tiles                  | `DscV3RunSummary_CL`    | Servers, runs, success%, drifted count.            |
| Outcomes over time     | `DscV3RunSummary_CL`    | Hourly bins of total / drifted / failed.           |
| Per-server compliance  | `DscV3RunSummary_CL`    | Latest run per (Host, Config); colour-graded.      |
| Most-drifted resources | `DscV3Run_CL`           | Aggregated per (ResourceType, ResourceName).       |
| Recent errors          | `DscV3Run_CL`           | Last 200 rows where `Error != ''`.                 |

## Filters

- **TimeRange** — 1h / 1d / 7d / 30d (default 30d).
- **Group**     — multi-select pulled from `DscV3RunSummary_CL | distinct Group`.
- **Config**    — multi-select pulled from `DscV3RunSummary_CL | distinct Config`.

## Future enhancements

- Workbook **action** → Logic App → Arc `Run-Command` → `Invoke-DscRunner.ps1 -Now`
  for an ad-hoc "apply now" button per server. Defer to phase 2.
- Alert rule on `DscV3RunSummary_CL | where Success == false | summarize count() by Host`
  exceeding a per-host threshold.
