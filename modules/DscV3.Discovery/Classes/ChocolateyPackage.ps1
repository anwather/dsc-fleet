# ChocolateyPackage — install/remove a Chocolatey package.
#
# Key   : Name
# Drift : Version mismatch (when Version specified) or presence vs Ensure

[DscResource()]
class ChocolateyPackage {
    [DscProperty(Key)]             [string] $Name
    [DscProperty()]                [string] $Version = 'Latest'
    [DscProperty()]                [string] $Source  = 'chocolatey'
    [DscProperty()]                [Ensure] $Ensure  = [Ensure]::Present
    [DscProperty(NotConfigurable)] [string] $InstalledVersion
    [DscProperty(NotConfigurable)] [bool]   $Installed

    [ChocolateyPackage] Get() {
        $current             = [ChocolateyPackage]::new()
        $current.Name        = $this.Name
        $current.Version     = $this.Version
        $current.Source      = $this.Source
        $current.Ensure      = [Ensure]::Absent
        $current.Installed   = $false
        $current.InstalledVersion = ''

        $info = [ChocolateyPackage]::QueryInstalled($this.Name)
        if ($info) {
            $current.Installed        = $true
            $current.InstalledVersion = $info.Version
            $current.Ensure           = [Ensure]::Present
        }
        return $current
    }

    [bool] Test() {
        $state = $this.Get()
        if ($this.Ensure -eq [Ensure]::Present) {
            if (-not $state.Installed) { return $false }
            if ($this.Version -and $this.Version -ne 'Latest' -and $state.InstalledVersion -ne $this.Version) {
                return $false
            }
            return $true
        }
        return -not $state.Installed
    }

    [void] Set() {
        if ($this.Ensure -eq [Ensure]::Present) {
            $cliArgs = @('install', $this.Name, '-y', '--no-progress',
                      '--source', $this.Source)
            if ($this.Version -and $this.Version -ne 'Latest') {
                $cliArgs += @('--version', $this.Version)
            }
            [ChocolateyPackage]::InvokeChoco($cliArgs)
        }
        else {
            [ChocolateyPackage]::InvokeChoco(@('uninstall', $this.Name, '-y', '--no-progress'))
        }
    }

    # --- helpers -----------------------------------------------------------

    static [pscustomobject] QueryInstalled([string] $name) {
        # `choco list --local-only --exact` prints `name version` lines.
        $output = & choco list --local-only --exact --limit-output $name 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $output) { return $null }
        foreach ($line in $output) {
            $parts = $line -split '\|'
            if ($parts.Count -ge 2 -and $parts[0] -ieq $name) {
                return [pscustomobject]@{ Name = $parts[0]; Version = $parts[1] }
            }
        }
        return $null
    }

    static [void] InvokeChoco([string[]] $arguments) {
        & choco @arguments | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw "choco $($arguments -join ' ') exited with code $LASTEXITCODE."
        }
    }
}
