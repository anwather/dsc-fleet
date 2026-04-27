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
                try { Remove-ItemProperty -LiteralPath $psPath -Name '(default)' -ErrorAction Stop } catch { }
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
