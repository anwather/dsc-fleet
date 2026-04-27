Describe 'Sync-Module' {
    BeforeAll {
        $repoRoot   = Resolve-Path "$PSScriptRoot/../.."
        $script:syncScript = Join-Path $repoRoot 'modules/DscV3.RegFile/build/Sync-Module.ps1'
        $script:psm1Path   = Join-Path $repoRoot 'modules/DscV3.RegFile/DscV3.RegFile.psm1'
    }
    It 'verify mode succeeds on a freshly synced module' {
        & $syncScript                # write
        & $syncScript -Verify        # check
        $LASTEXITCODE | Should -Be 0
    }
    It 'generated .psm1 contains the RegFile DscResource class' {
        $content = Get-Content -Raw $psm1Path
        $content | Should -Match "(?ms)\[DscResource\(\)\]\s*class\s+RegFile\b"
    }
    It 'generated .psm1 does not contain the deprecated 4 classes' {
        $content = Get-Content -Raw $psm1Path
        foreach ($name in 'WingetPackage','ChocolateyPackage','MsiFromShare','PSResourceInstall') {
            $content | Should -Not -Match "(?ms)\[DscResource\(\)\]\s*class\s+$name\b"
        }
    }
}
