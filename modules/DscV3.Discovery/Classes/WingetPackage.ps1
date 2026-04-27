# WingetPackage — install/remove a Windows Package Manager (winget) package.
#
# Key   : Id           — winget package identifier (e.g. '7zip.7zip')
# Drift : Version mismatch (when Version specified) or presence vs Ensure
#
# Notes:
#   * Requires winget on PATH. The bootstrap script ensures this.
#   * 'Latest' version means "any version installed satisfies Present".

[DscResource()]
class WingetPackage {
    [DscProperty(Key)]                 [string] $Id
    [DscProperty()]                    [string] $Version = 'Latest'
    [DscProperty()]                    [string] $Source  = 'winget'
    [DscProperty()]                    [Ensure] $Ensure  = [Ensure]::Present
    [DscProperty(NotConfigurable)]     [string] $InstalledVersion
    [DscProperty(NotConfigurable)]     [bool]   $Installed

    [WingetPackage] Get() {
        $current             = [WingetPackage]::new()
        $current.Id          = $this.Id
        $current.Version     = $this.Version
        $current.Source      = $this.Source
        $current.Ensure      = [Ensure]::Absent
        $current.Installed   = $false
        $current.InstalledVersion = ''

        $info = [WingetPackage]::QueryInstalled($this.Id)
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
        # Absent
        return -not $state.Installed
    }

    [void] Set() {
        if ($this.Ensure -eq [Ensure]::Present) {
            $cliArgs = @('install', '--id', $this.Id, '--exact',
                      '--source', $this.Source, '--silent',
                      '--accept-package-agreements', '--accept-source-agreements')
            if ($this.Version -and $this.Version -ne 'Latest') {
                $cliArgs += @('--version', $this.Version)
            }
            [WingetPackage]::InvokeWinget($cliArgs)
        }
        else {
            $cliArgs = @('uninstall', '--id', $this.Id, '--exact',
                      '--source', $this.Source, '--silent',
                      '--accept-source-agreements')
            [WingetPackage]::InvokeWinget($cliArgs)
        }
    }

    # --- helpers -----------------------------------------------------------

    static [pscustomobject] QueryInstalled([string] $id) {
        $output = & winget list --id $id --exact --source winget --accept-source-agreements 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $output) { return $null }
        # winget output is column-aligned text; the version column is the 2nd
        # whitespace-separated token after the Id when an exact match exists.
        foreach ($line in $output) {
            if ($line -match "^\s*\S+\s+$([regex]::Escape($id))\s+(\S+)") {
                return [pscustomobject]@{ Id = $id; Version = $Matches[1] }
            }
        }
        return $null
    }

    static [void] InvokeWinget([string[]] $arguments) {
        & winget @arguments | Out-Host
        if ($LASTEXITCODE -ne 0) {
            throw "winget $($arguments -join ' ') exited with code $LASTEXITCODE."
        }
    }
}
