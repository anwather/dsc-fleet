using namespace System.Net

param($Request, $TriggerMetadata)

$ErrorActionPreference = 'Stop'

function New-Response {
    param([HttpStatusCode] $Status, $Body)
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = $Status
        Body       = ($Body | ConvertTo-Json -Depth 10)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}

try {
    $payload = $Request.Body
    if (-not $payload) { New-Response -Status BadRequest -Body @{ error = 'Empty body.' }; return }
    foreach ($k in 'runId','host','group','config','mode','exitCode','startUtc','endUtc') {
        if (-not $payload.PSObject.Properties[$k]) {
            New-Response -Status BadRequest -Body @{ error = "Missing field '$k'." }; return
        }
    }

    # Parse the raw dsc output to extract per-resource results.
    $resourceRows = @()
    $driftedCount = 0
    if ($payload.PSObject.Properties['dscOutput'] -and $payload.dscOutput) {
        try {
            $dsc = $payload.dscOutput | ConvertFrom-Json -ErrorAction Stop
            if ($dsc -and $dsc.PSObject.Properties['results']) {
                foreach ($r in $dsc.results) {
                    $inDesired = [bool]($r.inDesiredState ?? $false)
                    if (-not $inDesired) { $driftedCount++ }
                    $resourceRows += [pscustomobject]@{
                        TimeGenerated  = $payload.endUtc
                        RunId          = $payload.runId
                        Host           = $payload.host
                        Group          = $payload.group
                        Config         = $payload.config
                        ResourceName   = [string]$r.name
                        ResourceType   = [string]$r.type
                        InDesiredState = $inDesired
                        Drifted        = (-not $inDesired)
                        Error          = if ($r.PSObject.Properties['error']) { [string]$r.error } else { $null }
                        ResultJson     = ($r | ConvertTo-Json -Compress -Depth 10)
                    }
                }
            }
        } catch {
            Write-Warning "Could not parse dscOutput as JSON: $_"
        }
    }

    $summaryRow = [pscustomobject]@{
        TimeGenerated  = $payload.endUtc
        RunId          = $payload.runId
        Host           = $payload.host
        Os             = [string]($payload.os         ?? '')
        Group          = $payload.group
        Config         = $payload.config
        Mode           = $payload.mode
        Verb           = [string]($payload.verb       ?? $payload.mode)
        StartUtc       = $payload.startUtc
        EndUtc         = $payload.endUtc
        ExitCode       = [int]$payload.exitCode
        Success        = [bool]($payload.success      ?? ($payload.exitCode -eq 0))
        ResourceCount  = $resourceRows.Count
        DriftedCount   = $driftedCount
        ArcTagsJson    = if ($payload.PSObject.Properties['arcTags']) { ($payload.arcTags | ConvertTo-Json -Compress) } else { '{}' }
    }

    $dce      = $env:DCE_ENDPOINT
    $dcrId    = $env:DCR_IMMUTABLE_ID
    $streamR  = $env:DCR_STREAM_RUN
    $streamS  = $env:DCR_STREAM_SUMMARY
    $apiVer   = $env:INGEST_API_VERSION ?? '2023-01-01'
    $audience = $env:INGEST_AUDIENCE    ?? 'https://monitor.azure.com//.default'

    if ($dce -and $dcrId) {
        $token = (Get-AzAccessToken -ResourceUrl $audience.TrimEnd('/.default') -ErrorAction Stop).Token
        $headers = @{ Authorization = "Bearer $token"; 'Content-Type' = 'application/json' }

        if ($streamS) {
            $uri  = "$dce/dataCollectionRules/$dcrId/streams/$streamS`?api-version=$apiVer"
            $body = (@($summaryRow) | ConvertTo-Json -Depth 10 -AsArray)
            Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body | Out-Null
        }
        if ($streamR -and $resourceRows.Count -gt 0) {
            $uri  = "$dce/dataCollectionRules/$dcrId/streams/$streamR`?api-version=$apiVer"
            $body = ($resourceRows | ConvertTo-Json -Depth 10 -AsArray)
            Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body $body | Out-Null
        }
    } else {
        Write-Warning 'DCE_ENDPOINT or DCR_IMMUTABLE_ID not configured — skipping Log Analytics ingest.'
    }

    New-Response -Status OK -Body @{ accepted = $true; runId = $payload.runId; resources = $resourceRows.Count; drifted = $driftedCount }
}
catch {
    Write-Error $_
    New-Response -Status InternalServerError -Body @{ error = $_.Exception.Message }
}
