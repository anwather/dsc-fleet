Describe 'Sync-Module' {
    BeforeAll {
        $repoRoot   = Resolve-Path "$PSScriptRoot/../.."
        $script:syncScript = Join-Path $repoRoot 'modules/DscV3.Discovery/build/Sync-Module.ps1'
        $script:psm1Path   = Join-Path $repoRoot 'modules/DscV3.Discovery/DscV3.Discovery.psm1'
    }
    It 'verify mode succeeds on a freshly synced module' {
        & $syncScript                # write
        & $syncScript -Verify        # check
        $LASTEXITCODE | Should -Be 0
    }
    It 'generated .psm1 contains all 5 expected DscResource classes' {
        $content = Get-Content -Raw $psm1Path
        foreach ($name in 'WingetPackage','ChocolateyPackage','MsiFromShare','PSResourceInstall','RegFile') {
            $content | Should -Match "(?ms)\[DscResource\(\)\]\s*class\s+$name\b"
        }
    }
}
