# DscV3.Discovery — root module (GENERATED — do not edit by hand).
#
# Class-based DSC v3 resources for the Microsoft.DSC/PowerShell adapter.
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

# ============================================================================
# Classes\ChocolateyPackage.ps1
# ============================================================================
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


# ============================================================================
# Classes\MsiFromShare.ps1
# ============================================================================
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


# ============================================================================
# Classes\PSResourceInstall.ps1
# ============================================================================
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


# ============================================================================
# Classes\RegFile.ps1
# ============================================================================
# RegFile — bulk-import a Windows .reg file with idempotent verification.
#
# Key   : Path  — local or UNC path to the .reg file
# Hash  : Optional SHA256 of the .reg file contents. If specified, the file's
#         actual hash MUST match before import (defence against tampering of
#         a share-hosted .reg file).
#
# Idempotency:
#   * Get()  parses the .reg and reads each target value from the registry.
#   * Test() returns $true only when, for every value in the .reg:
#       Ensure=Present : registry value exists and equals the .reg value
#       Ensure=Absent  : registry value does not exist
#   * Set()  for Present runs `reg.exe import "<Path>"`.
#            for Absent  removes each value (and empty keys) listed in the .reg.

[DscResource()]
class RegFile {
    [DscProperty(Key)]             [string] $Path
    [DscProperty()]                [string] $Hash    = ''
    [DscProperty()]                [Ensure] $Ensure  = [Ensure]::Present
    [DscProperty(NotConfigurable)] [string] $ActualHash
    [DscProperty(NotConfigurable)] [int]    $ValuesChecked
    [DscProperty(NotConfigurable)] [int]    $ValuesMatching

    [RegFile] Get() {
        $current        = [RegFile]::new()
        $current.Path   = $this.Path
        $current.Hash   = $this.Hash
        $current.Ensure = $this.Ensure
        $current.ActualHash      = ''
        $current.ValuesChecked   = 0
        $current.ValuesMatching  = 0

        if (-not (Test-Path -LiteralPath $this.Path)) {
            return $current
        }
        $current.ActualHash = (Get-FileHash -LiteralPath $this.Path -Algorithm SHA256).Hash

        $entries = [RegFile]::ParseRegFile($this.Path)
        $current.ValuesChecked = $entries.Count
        foreach ($e in $entries) {
            if ([RegFile]::RegistryValueMatches($e)) {
                $current.ValuesMatching++
            }
        }
        return $current
    }

    [bool] Test() {
        if (-not (Test-Path -LiteralPath $this.Path)) {
            throw "RegFile: Path '$($this.Path)' is not reachable."
        }
        if ($this.Hash) {
            $actual = (Get-FileHash -LiteralPath $this.Path -Algorithm SHA256).Hash
            if ($actual -ne $this.Hash) {
                throw "RegFile: SHA256 mismatch for '$($this.Path)'. Expected $($this.Hash), got $actual."
            }
        }
        $entries = [RegFile]::ParseRegFile($this.Path)
        if ($entries.Count -eq 0) { return $true }

        if ($this.Ensure -eq [Ensure]::Present) {
            foreach ($e in $entries) {
                if (-not [RegFile]::RegistryValueMatches($e)) { return $false }
            }
            return $true
        }
        # Absent: every value listed in the .reg must NOT exist.
        foreach ($e in $entries) {
            if ([RegFile]::RegistryValueExists($e)) { return $false }
        }
        return $true
    }

    [void] Set() {
        if ($this.Ensure -eq [Ensure]::Present) {
            $proc = Start-Process -FilePath reg.exe `
                                  -ArgumentList @('import', "`"$($this.Path)`"") `
                                  -Wait -PassThru -NoNewWindow
            if ($proc.ExitCode -ne 0) {
                throw "reg.exe import '$($this.Path)' exited with code $($proc.ExitCode)."
            }
            return
        }
        # Absent: walk the parsed entries and remove each named value.
        # Empty default-value entries cause whole-key deletion.
        $entries = [RegFile]::ParseRegFile($this.Path)
        foreach ($e in $entries) {
            $psPath = [RegFile]::ToPsPath($e.Key)
            if (-not (Test-Path -LiteralPath $psPath)) { continue }
            if ([string]::IsNullOrEmpty($e.Name)) {
                # Default value — clear it; never delete the key automatically.
                try { Remove-ItemProperty -LiteralPath $psPath -Name '(default)' -ErrorAction Stop } catch { Write-Verbose "Ignored: $_" }
            }
            else {
                Remove-ItemProperty -LiteralPath $psPath -Name $e.Name -ErrorAction SilentlyContinue
            }
        }
    }

    # --- helpers -----------------------------------------------------------

    # Map a hive prefix used in .reg files to the PowerShell registry drive.
    static [hashtable] $HiveMap = @{
        'HKEY_LOCAL_MACHINE' = 'HKLM:'
        'HKEY_CURRENT_USER'  = 'HKCU:'
        'HKEY_CLASSES_ROOT'  = 'HKCR:'
        'HKEY_USERS'         = 'HKU:'
        'HKEY_CURRENT_CONFIG'= 'HKCC:'
    }

    static [string] ToPsPath([string] $regKey) {
        $parts = $regKey -split '\\', 2
        $hive  = [RegFile]::HiveMap[$parts[0]]
        if (-not $hive) { throw "RegFile: unknown registry hive '$($parts[0])'." }
        if ($parts.Count -eq 1) { return $hive }
        return "$hive\$($parts[1])"
    }

    # Parse a Windows .reg file (UTF-16 LE typical, but we let .NET sniff BOM).
    # Returns an array of @{ Key; Name; Type; Value }.
    static [System.Collections.Generic.List[hashtable]] ParseRegFile([string] $path) {
        $list = [System.Collections.Generic.List[hashtable]]::new()
        $lines = [System.IO.File]::ReadAllLines($path)

        $currentKey = $null
        $buffer     = $null  # for line continuations (\ at EOL)

        for ($i = 0; $i -lt $lines.Count; $i++) {
            $raw = $lines[$i]
            if ($null -ne $buffer) {
                $buffer += $raw.TrimStart()
                $raw = $buffer
                $buffer = $null
            }
            $trim = $raw.Trim()
            if ($trim.StartsWith(';') -or $trim -eq '' -or $trim.StartsWith('Windows Registry Editor') -or $trim -eq 'REGEDIT4') {
                continue
            }
            if ($trim.StartsWith('[') -and $trim.EndsWith(']')) {
                $key = $trim.Substring(1, $trim.Length - 2)
                # A leading '-' inside the brackets indicates key deletion in .reg
                # syntax. We only model value-level operations here, so skip.
                if ($key.StartsWith('-')) { $currentKey = $null; continue }
                $currentKey = $key
                continue
            }
            if ($null -eq $currentKey) { continue }
            if ($raw.EndsWith('\')) {
                $buffer = $raw.Substring(0, $raw.Length - 1)
                continue
            }
            $entry = [RegFile]::ParseValueLine($currentKey, $raw)
            if ($entry) { $list.Add($entry) }
        }
        return $list
    }

    static [hashtable] ParseValueLine([string] $key, [string] $line) {
        # Value lines look like:
        #   "Name"="string value"
        #   @="default string"
        #   "Name"=dword:00000001
        #   "Name"=hex(7):41,00,00,00
        #   "Name"=-                        (deletion — we don't enforce in Test)
        $eq = $line.IndexOf('=')
        if ($eq -lt 0) { return $null }
        $left  = $line.Substring(0, $eq).Trim()
        $right = $line.Substring($eq + 1).Trim()

        if ($left -eq '@') {
            $name = ''
        }
        elseif ($left.StartsWith('"') -and $left.EndsWith('"')) {
            $name = $left.Substring(1, $left.Length - 2) -replace '\\"', '"' -replace '\\\\', '\'
        }
        else {
            return $null
        }

        if ($right -eq '-') {
            return @{ Key = $key; Name = $name; Type = 'DELETE'; Value = $null }
        }

        if ($right.StartsWith('"')) {
            $value = $right.TrimStart('"').TrimEnd('"') -replace '\\"', '"' -replace '\\\\', '\'
            return @{ Key = $key; Name = $name; Type = 'String'; Value = $value }
        }
        if ($right.StartsWith('dword:')) {
            $hex = $right.Substring(6)
            return @{ Key = $key; Name = $name; Type = 'DWord'; Value = [int][Convert]::ToUInt32($hex, 16) }
        }
        if ($right.StartsWith('qword:')) {
            $hex = $right.Substring(6)
            return @{ Key = $key; Name = $name; Type = 'QWord'; Value = [long][Convert]::ToUInt64($hex, 16) }
        }
        if ($right.StartsWith('hex')) {
            # hex(<n>):aa,bb,cc — n=2 expand_sz, 7 multi_sz, 0/1 binary/sz, 4 dword(BE).
            # For Test purposes we only compare the raw byte sequence.
            $colon = $right.IndexOf(':')
            $bytes = ($right.Substring($colon + 1) -split ',') |
                     Where-Object { $_ -match '^[0-9A-Fa-f]+$' } |
                     ForEach-Object { [byte][Convert]::ToInt32($_, 16) }
            return @{ Key = $key; Name = $name; Type = 'Binary'; Value = [byte[]]$bytes }
        }
        return $null
    }

    static [bool] RegistryValueExists([hashtable] $entry) {
        $psPath = [RegFile]::ToPsPath($entry.Key)
        if (-not (Test-Path -LiteralPath $psPath)) { return $false }
        $valueName = if ([string]::IsNullOrEmpty($entry.Name)) { '(default)' } else { $entry.Name }
        $props = Get-ItemProperty -LiteralPath $psPath -ErrorAction SilentlyContinue
        if (-not $props) { return $false }
        return $null -ne ($props.PSObject.Properties[$valueName])
    }

    static [bool] RegistryValueMatches([hashtable] $entry) {
        if ($entry.Type -eq 'DELETE') {
            return -not [RegFile]::RegistryValueExists($entry)
        }
        $psPath = [RegFile]::ToPsPath($entry.Key)
        if (-not (Test-Path -LiteralPath $psPath)) { return $false }
        $valueName = if ([string]::IsNullOrEmpty($entry.Name)) { '(default)' } else { $entry.Name }
        try {
            $current = (Get-ItemProperty -LiteralPath $psPath -Name $valueName -ErrorAction Stop).$valueName
        } catch {
            return $false
        }
        switch ($entry.Type) {
            'String' { return [string]$current -eq [string]$entry.Value }
            'DWord'  { return [int]$current   -eq [int]$entry.Value }
            'QWord'  { return [long]$current  -eq [long]$entry.Value }
            'Binary' {
                $a = [byte[]]$current; $b = [byte[]]$entry.Value
                if ($a.Length -ne $b.Length) { return $false }
                for ($i = 0; $i -lt $a.Length; $i++) {
                    if ($a[$i] -ne $b[$i]) { return $false }
                }
                return $true
            }
        }
        return $false
    }
}


# ============================================================================
# Classes\WingetPackage.ps1
# ============================================================================
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



