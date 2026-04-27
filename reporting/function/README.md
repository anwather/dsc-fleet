# DSC v3 Reporting — Azure Function

HTTP-triggered PowerShell Function that ingests a single run JSON document
posted by `bootstrap/Invoke-DscRunner.ps1` and writes it to a Log Analytics
workspace via the Azure Monitor **Logs Ingestion API** (DCR-based).

```
[Server]  POST /api/runs  →  [Function] →  [DCE/DCR] → [Log Analytics: DscV3Run_CL]
```

## Tables

Two custom tables in the workspace (DCR-based, JSON):

| Table                 | One row per       | Key columns                                         |
| --------------------- | ----------------- | --------------------------------------------------- |
| `DscV3Run_CL`         | resource result   | TimeGenerated, Host, Group, Config, ResourceName, InDesiredState, Drifted, Error |
| `DscV3RunSummary_CL`  | configuration run | TimeGenerated, RunId, Host, Group, Config, Mode, ExitCode, Success, ResourceCount, DriftedCount |

The function fans the dsc JSON output out into one summary row + N resource
rows so that the Workbook can pivot on either grain without parsing nested
JSON in KQL.

## Configuration (App settings)

| Setting              | Description                                       |
| -------------------- | ------------------------------------------------- |
| `DCE_ENDPOINT`       | Data Collection Endpoint URI.                     |
| `DCR_IMMUTABLE_ID`   | Immutable ID of the Data Collection Rule.         |
| `DCR_STREAM_RUN`     | Stream name for `DscV3Run_CL`.                    |
| `DCR_STREAM_SUMMARY` | Stream name for `DscV3RunSummary_CL`.             |
| `INGEST_API_VERSION` | Default `2023-01-01`.                             |
| `INGEST_AUDIENCE`    | Default `https://monitor.azure.com//.default`.    |

Auth: the Function App's system-assigned MI must be granted **Monitoring
Metrics Publisher** on the DCR.

## Local dev

```powershell
func start --port 7071
Invoke-RestMethod -Uri http://localhost:7071/api/runs -Method Post `
    -InFile sample-run.json -ContentType application/json
```
