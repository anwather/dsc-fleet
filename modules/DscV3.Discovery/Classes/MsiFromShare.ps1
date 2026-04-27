# MsiFromShare — install/remove a Windows Installer (MSI) package whose source
# lives on an SMB share or local path. Detection uses the MSI ProductId so the
# resource is independent of how the package was originally installed.
#
# Key   : ProductId  — MSI ProductCode GUID, e.g. '{12345678-90AB-CDEF-...}'
# Drift : Presence vs Ensure (and optional VersionAtLeast check)

[DscResource()]
class MsiFromShare {
    [DscProperty(Key)]             [string] $ProductId
    [DscProperty(Mandatory)]       [string] $SourcePath
    [DscProperty()]                [string] $ProductName
    [DscProperty()]                [string] $Arguments      = '/quiet /norestart'
    [DscProperty()]                [string] $VersionAtLeast = ''
    [DscProperty()]                [string] $LogPath        = ''
    [DscProperty()]                [Ensure] $Ensure         = [Ensure]::Present
    [DscProperty(NotConfigurable)] [string] $InstalledVersion
    [DscProperty(NotConfigurable)] [bool]   $Installed

    [MsiFromShare] Get() {
        $current             = [MsiFromShare]::new()
        $current.ProductId   = $this.ProductId
        $current.SourcePath  = $this.SourcePath
        $current.ProductName = $this.ProductName
        $current.Arguments   = $this.Arguments
        $current.LogPath     = $this.LogPath
        $current.VersionAtLeast = $this.VersionAtLeast
        $current.Ensure      = [Ensure]::Absent
        $current.Installed   = $false
        $current.InstalledVersion = ''

        $info = [MsiFromShare]::QueryInstalled($this.ProductId)
        if ($info) {
            $current.Installed        = $true
            $current.InstalledVersion = $info.DisplayVersion
            if (-not $current.ProductName) { $current.ProductName = $info.DisplayName }
            $current.Ensure           = [Ensure]::Present
        }
        return $current
    }

    [bool] Test() {
        $state = $this.Get()
        if ($this.Ensure -eq [Ensure]::Present) {
            if (-not $state.Installed) { return $false }
            if ($this.VersionAtLeast) {
                try {
                    $have = [version]$state.InstalledVersion
                    $want = [version]$this.VersionAtLeast
                    if ($have -lt $want) { return $false }
                } catch {
                    # If versions can't be parsed, fall back to string equality.
                    if ($state.InstalledVersion -ne $this.VersionAtLeast) { return $false }
                }
            }
            return $true
        }
        return -not $state.Installed
    }

    [void] Set() {
        if ($this.Ensure -eq [Ensure]::Present) {
            if (-not (Test-Path -LiteralPath $this.SourcePath)) {
                throw "MsiFromShare: SourcePath '$($this.SourcePath)' is not reachable."
            }
            $msiArgs = @('/i', "`"$($this.SourcePath)`"")
            $msiArgs += $this.Arguments -split ' '
            if ($this.LogPath) { $msiArgs += @('/L*v', "`"$($this.LogPath)`"") }
            [MsiFromShare]::InvokeMsiExec($msiArgs)
        }
        else {
            $msiArgs = @('/x', $this.ProductId)
            $msiArgs += $this.Arguments -split ' '
            if ($this.LogPath) { $msiArgs += @('/L*v', "`"$($this.LogPath)`"") }
            [MsiFromShare]::InvokeMsiExec($msiArgs)
        }
    }

    # --- helpers -----------------------------------------------------------

    static [pscustomobject] QueryInstalled([string] $productId) {
        # MSI products are always under Uninstall; check both 64- and 32-bit views.
        $roots = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
        )
        foreach ($root in $roots) {
            $key = Join-Path $root $productId
            if (Test-Path -LiteralPath $key) {
                $props = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
                if ($props) {
                    return [pscustomobject]@{
                        DisplayName    = $props.DisplayName
                        DisplayVersion = $props.DisplayVersion
                    }
                }
            }
        }
        return $null
    }

    static [void] InvokeMsiExec([string[]] $arguments) {
        $proc = Start-Process -FilePath msiexec.exe -ArgumentList $arguments -Wait -PassThru -NoNewWindow
        # 0 = success; 3010 = success, reboot required (idempotent — the system
        # is in the desired state, just pending a reboot).
        if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
            throw "msiexec $($arguments -join ' ') exited with code $($proc.ExitCode)."
        }
    }
}
