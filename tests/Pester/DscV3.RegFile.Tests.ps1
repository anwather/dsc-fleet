#requires -Version 7.2
using module ..\..\modules\DscV3.RegFile\DscV3.RegFile.psm1

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

Describe 'RegFile.ParseValueLine — typed hex(*) decoding' {
    BeforeAll {
        $repoRoot = Resolve-Path "$PSScriptRoot/../.."
    }

    It 'hex(b): decodes 8 little-endian bytes to QWord' {
        # 0x000001b186600000 LE bytes 00,00,60,86,b1,01,00,00
        $line = '"Q"=hex(b):00,00,60,86,b1,01,00,00'
        $entry = [RegFile]::ParseValueLine('HKEY_CURRENT_USER\Software\X', $line)
        $entry.Type  | Should -Be 'QWord'
        $entry.Value | Should -Be ([long]1861975277568)
    }

    It 'hex(b): with non-8 byte length falls back to Binary (no throw)' {
        $line = '"Q"=hex(b):01,02,03'
        $entry = [RegFile]::ParseValueLine('HKEY_CURRENT_USER\Software\X', $line)
        $entry.Type | Should -Be 'Binary'
    }

    It 'hex(2): decodes UTF-16 LE bytes to ExpandString and trims trailing NULs' {
        # "%TEMP%" in UTF-16 LE plus a single NUL terminator.
        $line = '"E"=hex(2):25,00,54,00,45,00,4d,00,50,00,25,00,00,00'
        $entry = [RegFile]::ParseValueLine('HKEY_CURRENT_USER\Software\X', $line)
        $entry.Type  | Should -Be 'ExpandString'
        $entry.Value | Should -Be '%TEMP%'
    }

    It 'hex(7): decodes UTF-16 LE bytes to MultiString string array' {
        # ["alpha", "beta"] -> a,l,p,h,a,\0,b,e,t,a,\0,\0
        $line = '"M"=hex(7):61,00,6c,00,70,00,68,00,61,00,00,00,62,00,65,00,74,00,61,00,00,00,00,00'
        $entry = [RegFile]::ParseValueLine('HKEY_CURRENT_USER\Software\X', $line)
        $entry.Type     | Should -Be 'MultiString'
        ,$entry.Value   | Should -BeOfType [string[]]
        @($entry.Value).Count | Should -Be 2
        $entry.Value[0] | Should -Be 'alpha'
        $entry.Value[1] | Should -Be 'beta'
    }

    It 'plain hex: stays Binary' {
        $line = '"B"=hex:de,ad,be,ef'
        $entry = [RegFile]::ParseValueLine('HKEY_CURRENT_USER\Software\X', $line)
        $entry.Type | Should -Be 'Binary'
        ,$entry.Value | Should -BeOfType [byte[]]
        $entry.Value.Length | Should -Be 4
    }
}

Describe 'RegFile.RegistryValueMatches — typed registry compare (HKCU scratch)' {
    BeforeAll {
        $script:scratchKeyReg = 'HKEY_CURRENT_USER\Software\DscV3.RegFile.Tests'
        $script:scratchKeyPs  = 'HKCU:\Software\DscV3.RegFile.Tests'
        if (-not (Test-Path $scratchKeyPs)) {
            $null = New-Item -Path $scratchKeyPs -Force
        }
    }
    AfterAll {
        if (Test-Path $script:scratchKeyPs) {
            Remove-Item -Path $script:scratchKeyPs -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'QWord matches when registry value equals parsed Int64' {
        $name = 'TestQWord'
        $val  = [long]1861827354880
        New-ItemProperty -Path $scratchKeyPs -Name $name -PropertyType QWord -Value $val -Force | Out-Null
        $entry = @{ Key = $scratchKeyReg; Name = $name; Type = 'QWord'; Value = $val }
        [RegFile]::RegistryValueMatches($entry) | Should -BeTrue
    }

    It 'QWord mismatches when registry value differs' {
        $name = 'TestQWord'
        $entry = @{ Key = $scratchKeyReg; Name = $name; Type = 'QWord'; Value = [long]1 }
        [RegFile]::RegistryValueMatches($entry) | Should -BeFalse
    }

    It 'ExpandString compares the unexpanded literal (does not silently expand %TEMP%)' {
        $name = 'TestExpand'
        New-ItemProperty -Path $scratchKeyPs -Name $name -PropertyType ExpandString -Value '%TEMP%\foo' -Force | Out-Null
        $entry = @{ Key = $scratchKeyReg; Name = $name; Type = 'ExpandString'; Value = '%TEMP%\foo' }
        [RegFile]::RegistryValueMatches($entry) | Should -BeTrue
    }

    It 'MultiString matches element-wise' {
        $name = 'TestMulti'
        $val  = @('alpha','beta','gamma')
        New-ItemProperty -Path $scratchKeyPs -Name $name -PropertyType MultiString -Value $val -Force | Out-Null
        $entry = @{ Key = $scratchKeyReg; Name = $name; Type = 'MultiString'; Value = $val }
        [RegFile]::RegistryValueMatches($entry) | Should -BeTrue
    }

    It 'MultiString mismatches when element differs' {
        $name = 'TestMulti'
        $entry = @{ Key = $scratchKeyReg; Name = $name; Type = 'MultiString'; Value = @('alpha','beta','DELTA') }
        [RegFile]::RegistryValueMatches($entry) | Should -BeFalse
    }

    It 'MultiString mismatches when length differs' {
        $name = 'TestMulti'
        $entry = @{ Key = $scratchKeyReg; Name = $name; Type = 'MultiString'; Value = @('alpha') }
        [RegFile]::RegistryValueMatches($entry) | Should -BeFalse
    }
}
