# PSResourceInstall — install/remove a PowerShell module via PSResourceGet
# (Microsoft.PowerShell.PSResourceGet, the PowerShellGet v3 successor).
#
# Key   : Name
# Drift : Module not installed, or installed Version != requested Version

[DscResource()]
class PSResourceInstall {
    [DscProperty(Key)]             [string] $Name
    [DscProperty()]                [string] $Version    = 'Latest'
    [DscProperty()]                [string] $Repository = 'PSGallery'
    [DscProperty()]                [string] $Scope      = 'AllUsers'
    [DscProperty()]                [bool]   $TrustRepository = $true
    [DscProperty()]                [Ensure] $Ensure     = [Ensure]::Present
    [DscProperty(NotConfigurable)] [string] $InstalledVersion
    [DscProperty(NotConfigurable)] [bool]   $Installed

    [PSResourceInstall] Get() {
        $current             = [PSResourceInstall]::new()
        $current.Name        = $this.Name
        $current.Version     = $this.Version
        $current.Repository  = $this.Repository
        $current.Scope       = $this.Scope
        $current.TrustRepository  = $this.TrustRepository
        $current.Ensure      = [Ensure]::Absent
        $current.Installed   = $false
        $current.InstalledVersion = ''

        [PSResourceInstall]::EnsurePSResourceGet()
        $found = Get-PSResource -Name $this.Name -ErrorAction SilentlyContinue |
                 Sort-Object -Property Version -Descending |
                 Select-Object -First 1
        if ($found) {
            $current.Installed        = $true
            $current.InstalledVersion = $found.Version.ToString()
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
        [PSResourceInstall]::EnsurePSResourceGet()
        if ($this.TrustRepository) {
            $repo = Get-PSResourceRepository -Name $this.Repository -ErrorAction SilentlyContinue
            if ($repo -and -not $repo.Trusted) {
                Set-PSResourceRepository -Name $this.Repository -Trusted | Out-Null
            }
        }

        if ($this.Ensure -eq [Ensure]::Present) {
            $params = @{
                Name            = $this.Name
                Repository      = $this.Repository
                Scope           = $this.Scope
                AcceptLicense   = $true
                TrustRepository = $true
                Reinstall       = $false
            }
            if ($this.Version -and $this.Version -ne 'Latest') {
                $params['Version'] = $this.Version
            }
            Install-PSResource @params -ErrorAction Stop | Out-Null
        }
        else {
            Uninstall-PSResource -Name $this.Name -ErrorAction Stop
        }
    }

    # --- helpers -----------------------------------------------------------

    static [void] EnsurePSResourceGet() {
        if (-not (Get-Module -ListAvailable -Name Microsoft.PowerShell.PSResourceGet)) {
            throw 'PSResourceInstall requires Microsoft.PowerShell.PSResourceGet. Bootstrap should install it.'
        }
        Import-Module Microsoft.PowerShell.PSResourceGet -ErrorAction Stop
    }
}
