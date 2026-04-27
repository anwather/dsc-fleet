#requires -Version 7.2
<#
.SYNOPSIS
    Concatenates Classes/*.ps1 into DscV3.RegFile.psm1.

.DESCRIPTION
    The DSC v3 PowerShell adapter discovers class-based resources by parsing
    the .psm1's AST. Dot-sourced classes are invisible to that scan, so all
    [DscResource()] classes must live textually in the .psm1.

    To keep dev edits scoped, each class lives in its own file under Classes/
    and this script regenerates the .psm1 by concatenating them.

    Run this whenever you change a class file. CI runs it and fails if the
    generated .psm1 differs from what's committed.

.PARAMETER Verify
    Verify only — do not write. Exits non-zero if the on-disk .psm1 differs
    from what would be regenerated.
#>
[CmdletBinding()]
param(
    [switch] $Verify
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$moduleRoot = Split-Path -Parent $PSScriptRoot
$classDir   = Join-Path $moduleRoot 'Classes'
$psm1Path   = Join-Path $moduleRoot 'DscV3.RegFile.psm1'

# Stable load order — alphabetical except where noted (none currently inherit).
# Wrap in @() so a single-file result is still an array (StrictMode-safe .Count).
$classFiles = @(Get-ChildItem -LiteralPath $classDir -Filter '*.ps1' | Sort-Object Name)

$header = @'
# DscV3.RegFile — root module (GENERATED — do not edit by hand).
#
# Class-based DSC v3 resource for the Microsoft.DSC/PowerShell adapter.
# All classes MUST live in this file (the adapter parses the .psm1 AST to
# discover [DscResource()]-decorated classes; dot-sourced classes are not
# visible to that scan). Edit individual class files in Classes\ for dev,
# then run build\Sync-Module.ps1 to regenerate this .psm1.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

enum Ensure {
    Present
    Absent
}

'@

$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine($header)
foreach ($file in $classFiles) {
    [void]$sb.AppendLine('# ============================================================================')
    [void]$sb.AppendLine("# Classes\$($file.Name)")
    [void]$sb.AppendLine('# ============================================================================')
    [void]$sb.AppendLine((Get-Content -Raw -LiteralPath $file.FullName))
    [void]$sb.AppendLine()
}
$expected = $sb.ToString()

if ($Verify) {
    $actual = if (Test-Path -LiteralPath $psm1Path) { Get-Content -Raw -LiteralPath $psm1Path } else { '' }
    # Normalise line endings + trailing whitespace before comparing — Set-Content
    # may emit a trailing newline that the in-memory string doesn't have.
    $a = ($actual   -replace "`r`n", "`n").TrimEnd()
    $b = ($expected -replace "`r`n", "`n").TrimEnd()
    if ($a -ne $b) {
        Write-Error "DscV3.RegFile.psm1 is out of sync with Classes\*.ps1. Run build\Sync-Module.ps1."
        exit 1
    }
    Write-Host "DscV3.RegFile.psm1 is in sync." -ForegroundColor Green
    exit 0
}

Set-Content -LiteralPath $psm1Path -Value $expected -Encoding utf8BOM -NoNewline:$false
Write-Host "Wrote $psm1Path ($($expected.Length) bytes from $($classFiles.Count) class files)." -ForegroundColor Green
