#requires -Version 5.1
#requires -RunAsAdministrator
<#
.SYNOPSIS
    Install all prerequisites for DSC v3 fleet management on a Windows Server.

.DESCRIPTION
    SYSTEM-context safe. Installs (idempotently) using *direct downloads* from
    the official upstream release sources -- no winget required. winget on a
    fresh Windows Server SYSTEM session is unreliable (App Installer must be
    primed interactively first; on WS2019 it is not present at all), so the
    bootstrap pulls each tool directly:

      * PowerShell 7 (LTS)  -- MSI from github.com/PowerShell/PowerShell
      * DSC v3 CLI          -- zip from github.com/PowerShell/DSC (pinned)
      * Git for Windows     -- self-extracting installer from github.com/git-for-windows/git
      * PSResourceGet       -- Install-Module from PSGallery (TLS 1.2 forced)
      * winget              -- *detection only* (optional, recorded for diagnostics)

    All resolution uses absolute paths -- never relies on PATH being refreshed
    inside the current SYSTEM session.

    Emits a structured status object at the end so callers (Invoke-AzVMRunCommand,
    a remoting script, CI, etc.) can confirm "all green" with a single read.

.NOTES
    Supported operating systems: Windows Server 2019, 2022, 2025 (x64 only).
    Older OSes will throw before any install runs.

.PARAMETER DscVersion
    Pinned DSC v3 release version (matches a tag in PowerShell/DSC). Default 3.1.3.

.PARAMETER PwshVersion
    Optional pinned PowerShell 7 LTS version (e.g. '7.4.6'). Empty = auto-detect
    latest stable from the GitHub releases API.

.PARAMETER GitVersion
    Optional pinned Git for Windows version (e.g. '2.47.1'). Empty = auto-detect
    latest stable from the GitHub releases API.

.PARAMETER SkipGit
    Skip git installation (e.g. when you'll stage the repo another way).

.OUTPUTS
    Hashtable / pscustomobject with one row per component plus a top-level
    AllInstalled boolean. Also written to C:\ProgramData\DscV3\prereq-status.json.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install-Prerequisites.ps1
#>
[CmdletBinding()]
param(
    [string] $DscVersion  = '3.1.3',
    [string] $PwshVersion = '',
    [string] $GitVersion  = '',
    [switch] $SkipGit
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

# Bring in the unified logging sink. Self-bootstraps the directory if Install-DscV3
# hasn't run yet (this script is the first thing to execute on a fresh box).
$loggingModule = Join-Path $PSScriptRoot 'DscFleet.Logging.psm1'
if (Test-Path -LiteralPath $loggingModule) { Import-Module $loggingModule -Force }

$logRoot = 'C:\ProgramData\DscV3'
if (-not (Test-Path -LiteralPath $logRoot)) { New-Item -ItemType Directory -Path $logRoot -Force | Out-Null }

$tempRoot = Join-Path $env:TEMP 'DscV3-bootstrap'
if (-not (Test-Path -LiteralPath $tempRoot)) { New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null }

function Write-Step([string] $msg) {
    if (Get-Command Write-DscFleetLog -ErrorAction SilentlyContinue) {
        Write-DscFleetLog -Component 'Prereq' -Level 'INFO' -Message ('==> ' + $msg)
    } else {
        Write-Host ('==> ' + $msg) -ForegroundColor Cyan
    }
}

function Write-Info([string] $msg) {
    if (Get-Command Write-DscFleetLog -ErrorAction SilentlyContinue) {
        Write-DscFleetLog -Component 'Prereq' -Level 'INFO' -Message ('    ' + $msg)
    } else {
        Write-Host ('    ' + $msg)
    }
}

# ---------------------------------------------------------------------------
# OS gate -- WS2019 minimum, x64 only
# ---------------------------------------------------------------------------
function Assert-SupportedOS {
    $os = Get-CimInstance Win32_OperatingSystem
    $caption = $os.Caption
    $version = [Version]$os.Version
    $arch    = $os.OSArchitecture

    Write-Info "Detected OS:       $caption"
    Write-Info "Detected version:  $($os.Version)"
    Write-Info "Architecture:      $arch"

    if ($arch -notmatch '64') {
        throw "Unsupported architecture '$arch'. dsc-fleet requires 64-bit Windows."
    }
    # Windows Server 2019 = NT 10.0.17763. Anything below that is unsupported.
    if ($version -lt [Version]'10.0.17763') {
        throw "Unsupported OS '$caption' (version $($os.Version)). dsc-fleet requires Windows Server 2019 or later."
    }
    return $caption
}

# ---------------------------------------------------------------------------
# Download helper with TLS1.2 + retries
# ---------------------------------------------------------------------------
function Invoke-FileDownload {
    param(
        [Parameter(Mandatory)] [string] $Url,
        [Parameter(Mandatory)] [string] $Destination,
        [int] $Retries = 3
    )
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            Write-Info "download (attempt $attempt): $Url"
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Destination -ErrorAction Stop
            return
        } catch {
            if ($attempt -ge $Retries) { throw }
            Start-Sleep -Seconds (5 * $attempt)
        }
    }
}

function Invoke-GitHubApi {
    param([Parameter(Mandatory)] [string] $Url)
    [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $headers = @{ 'User-Agent' = 'dsc-fleet-bootstrap' }
    return Invoke-RestMethod -UseBasicParsing -Uri $Url -Headers $headers -ErrorAction Stop
}

# ---------------------------------------------------------------------------
# Component resolvers (absolute paths, post-install). StrictMode-safe:
# never dereference .Source on a null result of Get-Command.
# ---------------------------------------------------------------------------
function Resolve-Pwsh {
    $candidates = @(
        'C:\Program Files\PowerShell\7\pwsh.exe',
        'C:\Program Files\PowerShell\7-preview\pwsh.exe'
    )
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source } else { return $null }
}

function Resolve-Dsc {
    $candidates = @(
        "$env:ProgramFiles\DSC\dsc.exe",
        "$env:LOCALAPPDATA\Microsoft\WinGet\Links\dsc.exe",
        "$env:ProgramFiles\WinGet\Links\dsc.exe"
    )
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    # Fall back to a recursive search under Program Files
    $found = Get-ChildItem -Path 'C:\Program Files' -Filter dsc.exe -Recurse -ErrorAction SilentlyContinue |
                Select-Object -First 1 -ExpandProperty FullName
    if ($found) { return $found }
    $cmd = Get-Command dsc -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source } else { return $null }
}

function Resolve-Git {
    $candidates = @(
        'C:\Program Files\Git\cmd\git.exe',
        'C:\Program Files\Git\bin\git.exe'
    )
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    $cmd = Get-Command git -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source } else { return $null }
}

function Get-WingetPath {
    # Detection only -- not used to drive any installs.
    $candidate = Get-ChildItem -Path 'C:\Program Files\WindowsApps' `
        -Filter winget.exe -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match 'Microsoft\.DesktopAppInstaller_' } |
        Sort-Object { [version]($_.Directory.Name -replace '^Microsoft\.DesktopAppInstaller_([\d\.]+).*','$1') } -Descending |
        Select-Object -First 1 -ExpandProperty FullName
    if ($candidate) { return $candidate }
    $cmd = Get-Command winget -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source } else { return $null }
}

function Get-VersionSafe {
    param([string] $ExePath, [string[]] $Arguments = @('--version'))
    if (-not $ExePath -or -not (Test-Path -LiteralPath $ExePath)) { return $null }
    try {
        $out = (& $ExePath @Arguments) 2>&1 | Select-Object -First 1
        return ($out | Out-String).Trim()
    } catch {
        return "ERROR: $_"
    }
}

# ---------------------------------------------------------------------------
# Direct installers
# ---------------------------------------------------------------------------
function Install-PwshDirect {
    param([string] $Version)

    if (-not $Version) {
        Write-Info 'Resolving latest PowerShell 7 LTS release from GitHub'
        # The /releases/latest endpoint follows the "Latest" flag, which
        # PowerShell publishes for the current LTS.
        try {
            $rel = Invoke-GitHubApi 'https://api.github.com/repos/PowerShell/PowerShell/releases/latest'
            $Version = ($rel.tag_name -replace '^v','')
        } catch {
            Write-Info "GitHub API lookup failed ($($_.Exception.Message)); falling back to pinned 7.4.6"
            $Version = '7.4.6'
        }
    }
    $msiName = "PowerShell-$Version-win-x64.msi"
    $url     = "https://github.com/PowerShell/PowerShell/releases/download/v$Version/$msiName"
    $dest    = Join-Path $tempRoot $msiName

    Write-Info "Installing PowerShell $Version from $url"
    Invoke-FileDownload -Url $url -Destination $dest

    $msiArgs = @(
        '/i', "`"$dest`"",
        '/quiet', '/norestart',
        'ADD_PATH=1',
        'ENABLE_PSREMOTING=0',
        'REGISTER_MANIFEST=1'
    )
    Write-Info "msiexec $($msiArgs -join ' ')"
    $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru -NoNewWindow
    # 0 = success, 3010 = success but reboot needed
    if ($p.ExitCode -notin 0, 3010) {
        throw "PowerShell 7 MSI install failed (exit $($p.ExitCode))."
    }
}

function Install-VcRedistDirect {
    # dsc.exe (Rust) and other native binaries require the VS 2015-2022 x64
    # runtime (VCRUNTIME140.dll, VCRUNTIME140_1.dll, MSVCP140.dll). A fresh
    # Windows Server image does not ship these.
    $marker = 'C:\Windows\System32\VCRUNTIME140.dll'
    if (Test-Path -LiteralPath $marker) {
        Write-Info 'Visual C++ 2015-2022 x64 Runtime already present'
        return
    }
    $url  = 'https://aka.ms/vs/17/release/vc_redist.x64.exe'
    $dest = Join-Path $tempRoot 'vc_redist.x64.exe'
    Write-Info "Installing Visual C++ 2015-2022 x64 Runtime from $url"
    Invoke-FileDownload -Url $url -Destination $dest

    $p = Start-Process -FilePath $dest -ArgumentList '/install','/quiet','/norestart' -Wait -PassThru -NoNewWindow
    # 0 = success, 3010 = success-reboot, 1638 = newer already installed
    if ($p.ExitCode -notin 0, 3010, 1638) {
        throw "Visual C++ Redistributable install failed (exit $($p.ExitCode))."
    }
}

function Install-DscDirect {
    param([Parameter(Mandatory)][string] $Version)

    $zipName = "DSC-$Version-x86_64-pc-windows-msvc.zip"
    $url     = "https://github.com/PowerShell/DSC/releases/download/v$Version/$zipName"
    $dest    = Join-Path $tempRoot $zipName
    $extract = Join-Path $tempRoot "dsc-$Version"

    Write-Info "Installing DSC v3 $Version from $url"
    Invoke-FileDownload -Url $url -Destination $dest

    if (Test-Path -LiteralPath $extract) { Remove-Item -LiteralPath $extract -Recurse -Force }
    Expand-Archive -LiteralPath $dest -DestinationPath $extract -Force

    $installDir = 'C:\Program Files\DSC'
    if (-not (Test-Path -LiteralPath $installDir)) {
        New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    }
    # Copy everything under the extract root into Program Files\DSC, replacing.
    Get-ChildItem -LiteralPath $extract -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $installDir -Recurse -Force
    }

    # Persist on machine PATH (idempotent, case-insensitive check)
    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if ($machinePath -notmatch [regex]::Escape($installDir)) {
        Write-Info "Adding $installDir to machine PATH"
        $newPath = ($machinePath.TrimEnd(';')) + ';' + $installDir
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'Machine')
    } else {
        Write-Info "$installDir already on machine PATH"
    }
}

function Install-GitDirect {
    param([string] $Version)

    Write-Info 'Resolving Git for Windows release from GitHub'
    try {
        $rel = Invoke-GitHubApi 'https://api.github.com/repos/git-for-windows/git/releases/latest'
        if (-not $Version) {
            # Tags look like 'v2.47.1.windows.1' -- strip the v and the .windows.N suffix
            $Version = ($rel.tag_name -replace '^v','' -replace '\.windows\.\d+$','')
        }
        # Asset name pattern: Git-2.47.1-64-bit.exe
        $asset = $rel.assets | Where-Object { $_.name -match '^Git-[\d\.]+-64-bit\.exe$' } | Select-Object -First 1
        if (-not $asset) { throw 'No Git-*-64-bit.exe asset on the latest release.' }
        $url = $asset.browser_download_url
        $exeName = $asset.name
    } catch {
        if (-not $Version) { $Version = '2.47.1' }
        $exeName = "Git-$Version-64-bit.exe"
        $url     = "https://github.com/git-for-windows/git/releases/download/v$Version.windows.1/$exeName"
        Write-Info "GitHub API lookup failed ($($_.Exception.Message)); falling back to $url"
    }

    $dest = Join-Path $tempRoot $exeName
    Write-Info "Installing Git for Windows from $url"
    Invoke-FileDownload -Url $url -Destination $dest

    $silentArgs = @(
        '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/NOCANCEL',
        '/SP-', '/CLOSEAPPLICATIONS', '/RESTARTAPPLICATIONS'
    )
    Write-Info "$exeName $($silentArgs -join ' ')"
    $p = Start-Process -FilePath $dest -ArgumentList $silentArgs -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -ne 0) {
        throw "Git for Windows installer failed (exit $($p.ExitCode))."
    }
}

# ===========================================================================
# Begin install
# ===========================================================================
Write-Step 'OS check'
$osCaption = Assert-SupportedOS

# ---------------------------------------------------------------------------
# 1. PowerShell 7
# ---------------------------------------------------------------------------
Write-Step 'PowerShell 7'
$pwsh = Resolve-Pwsh
if (-not $pwsh) {
    Install-PwshDirect -Version $PwshVersion
    $pwsh = Resolve-Pwsh
} else {
    Write-Info "Already present at $pwsh"
}

# ---------------------------------------------------------------------------
# 2. DSC v3 CLI
# ---------------------------------------------------------------------------
Write-Step "DSC v3 CLI (target $DscVersion)"
$dsc = Resolve-Dsc
$dscCurrent = if ($dsc) { Get-VersionSafe -ExePath $dsc } else { $null }
$needDsc = $true
if ($dscCurrent) {
    $cleanVer = ($dscCurrent -replace '^dsc\s+','').Trim()
    if ($cleanVer -eq $DscVersion) {
        Write-Info "Already at pinned $DscVersion"
        $needDsc = $false
    } else {
        Write-Info "Found $cleanVer, will install pinned $DscVersion"
    }
}
if ($needDsc) {
    Install-VcRedistDirect
    Install-DscDirect -Version $DscVersion
    $dsc = Resolve-Dsc
}

# ---------------------------------------------------------------------------
# 3. Git for Windows
# ---------------------------------------------------------------------------
$git = $null
if (-not $SkipGit) {
    Write-Step 'Git for Windows'
    $git = Resolve-Git
    if (-not $git) {
        Install-GitDirect -Version $GitVersion
        $git = Resolve-Git
    } else {
        Write-Info "Already present at $git"
    }
} else {
    Write-Step 'Git for Windows (skipped)'
}

# ---------------------------------------------------------------------------
# 4. PSResourceGet (PS 5.1 SYSTEM-safe install path)
# ---------------------------------------------------------------------------
Write-Step 'Microsoft.PowerShell.PSResourceGet'
[Net.ServicePointManager]::SecurityProtocol = `
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
    Write-Info 'Installing NuGet PackageProvider'
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null
}
if ((Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue).InstallationPolicy -ne 'Trusted') {
    Write-Info 'Trusting PSGallery'
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
}
$psrg = Get-Module -ListAvailable Microsoft.PowerShell.PSResourceGet | Sort-Object Version -Descending | Select-Object -First 1
if (-not $psrg) {
    Install-Module Microsoft.PowerShell.PSResourceGet -Scope AllUsers -Force -AllowClobber
    $psrg = Get-Module -ListAvailable Microsoft.PowerShell.PSResourceGet | Sort-Object Version -Descending | Select-Object -First 1
} else {
    Write-Info "Already present (v$($psrg.Version))"
}

# ---------------------------------------------------------------------------
# 4b. PSGallery modules installed via PSResourceGet
#     - Microsoft.WinGet.DSC : Microsoft-published class-based DSC v3
#                              WinGetPackage resource (loaded by the
#                              Microsoft.DSC/PowerShell adapter automatically).
#     - PSDscResources       : Microsoft-maintained replacements for the
#                              Windows PowerShell built-in DSC resources
#                              (MsiPackage, Service, WindowsFeature, etc.)
#                              loaded via Microsoft.Windows/WindowsPowerShell.
# ---------------------------------------------------------------------------
Write-Step 'PSGallery modules (Microsoft.WinGet.DSC, PSDscResources) via PSResourceGet'
# Import the freshly-installed PSResourceGet module into the *current* PS 5.1
# session before invoking Install-PSResource.
try {
    Import-Module Microsoft.PowerShell.PSResourceGet -Force -ErrorAction Stop
} catch {
    Write-Info "Import-Module Microsoft.PowerShell.PSResourceGet failed: $($_.Exception.Message)"
    throw
}
# Ensure PSGallery is trusted in the PSResourceGet repo store (separate from
# the legacy PowerShellGet PSRepository trust set above).
$psgRepo = Get-PSResourceRepository -Name PSGallery -ErrorAction SilentlyContinue
if (-not $psgRepo) {
    Write-Info 'Registering PSGallery in PSResourceGet repo store'
    Register-PSResourceRepository -PSGallery -Trusted -ErrorAction Stop
} elseif (-not $psgRepo.Trusted) {
    Write-Info 'Marking PSResourceGet PSGallery repo as Trusted'
    Set-PSResourceRepository -Name PSGallery -Trusted -ErrorAction Stop
}

$galleryModules = @(
    @{ Name = 'Microsoft.WinGet.DSC'; Description = 'Microsoft-published WinGetPackage class-based DSC v3 resource.' }
    @{ Name = 'PSDscResources';       Description = 'Microsoft-maintained replacements for built-in Windows PowerShell DSC resources.' }
)
$galleryStatus = [ordered]@{}

# Helper: Get-Module -ListAvailable caches the module table in PS 5.1, so a
# freshly-installed module is invisible until the session restarts. Look at
# the AllUsers module directory directly to bypass the cache.
function Get-InstalledModuleInfo {
    param([string]$Name)
    $candidates = @(
        Join-Path 'C:\Program Files\WindowsPowerShell\Modules' $Name
        Join-Path 'C:\Program Files\PowerShell\Modules'        $Name
    )
    foreach ($base in $candidates) {
        if (-not (Test-Path -LiteralPath $base)) { continue }
        $verDir = Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -as [version] } |
                  Sort-Object { [version]$_.Name } -Descending |
                  Select-Object -First 1
        if (-not $verDir) { continue }
        $psd1 = Join-Path $verDir.FullName "$Name.psd1"
        if (Test-Path -LiteralPath $psd1) {
            return [pscustomobject]@{ Name = $Name; Version = $verDir.Name; Path = $psd1 }
        }
    }
    return $null
}

foreach ($mod in $galleryModules) {
    $existing = Get-InstalledModuleInfo -Name $mod.Name
    if (-not $existing) {
        Write-Info "Installing $($mod.Name) from PSGallery"
        Install-PSResource -Name $mod.Name -Scope AllUsers -TrustRepository -Reinstall:$false -ErrorAction Stop
        $existing = Get-InstalledModuleInfo -Name $mod.Name
    } else {
        Write-Info "$($mod.Name) already present (v$($existing.Version))"
    }
    $galleryStatus[$mod.Name] = [ordered]@{
        Required    = $true
        Installed   = [bool]$existing
        Path        = if ($existing) { $existing.Path } else { $null }
        Version     = if ($existing) { $existing.Version } else { $null }
        Description = $mod.Description
    }
}

# ---------------------------------------------------------------------------
# 5. Winget -- detection only (optional)
# ---------------------------------------------------------------------------
Write-Step 'Winget (detection only)'
$winget = Get-WingetPath
if ($winget) {
    Write-Info "winget present at $winget"
} else {
    Write-Info 'winget not present (expected on WS2019; harmless on WS2022/2025 since bootstrap no longer requires it)'
}

# ---------------------------------------------------------------------------
# Build status report
# ---------------------------------------------------------------------------
$status = [ordered]@{
    Timestamp     = [DateTime]::UtcNow.ToString('s') + 'Z'
    Host          = $env:COMPUTERNAME
    OS            = $osCaption
    Components    = [ordered]@{
        Pwsh = [ordered]@{
            Required  = $true
            Installed = [bool]$pwsh
            Path      = $pwsh
            Version   = if ($pwsh) { Get-VersionSafe -ExePath $pwsh -Arguments @('-NoProfile','-Command','$PSVersionTable.PSVersion.ToString()') } else { $null }
        }
        Dsc = [ordered]@{
            Required  = $true
            Installed = [bool]$dsc
            Path      = $dsc
            Version   = if ($dsc) { (Get-VersionSafe -ExePath $dsc) -replace '^dsc\s+','' } else { $null }
            Pinned    = $DscVersion
        }
        Git = [ordered]@{
            Required  = (-not $SkipGit)
            Installed = [bool]$git
            Path      = $git
            Version   = if ($git) { (Get-VersionSafe -ExePath $git) -replace '^git version\s+','' } else { $null }
        }
        PSResourceGet = [ordered]@{
            Required  = $true
            Installed = [bool]$psrg
            Path      = if ($psrg) { $psrg.Path } else { $null }
            Version   = if ($psrg) { $psrg.Version.ToString() } else { $null }
        }
        Winget = [ordered]@{
            # No longer required for bootstrap -- we direct-download everything.
            Required  = $false
            Installed = [bool]$winget
            Path      = $winget
            Version   = if ($winget) { (Get-VersionSafe -ExePath $winget) } else { $null }
        }
        GalleryModules = $galleryStatus
    }
}

$missing = @()
foreach ($name in $status.Components.Keys) {
    if ($name -eq 'GalleryModules') { continue }
    $c = $status.Components[$name]
    if ($c.Required -and -not $c.Installed) { $missing += $name }
}
foreach ($modName in $status.Components.GalleryModules.Keys) {
    $g = $status.Components.GalleryModules[$modName]
    if ($g.Required -and -not $g.Installed) { $missing += "GalleryModule:$modName" }
}
$status.AllInstalled = ($missing.Count -eq 0)
$status.Missing      = $missing

# Persist
$statusPath = Join-Path $logRoot 'prereq-status.json'
($status | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $statusPath -Encoding utf8

# Best-effort cleanup of the temp download dir (don't fail the run if it's locked)
try {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
} catch {
    Write-Info "Temp cleanup failed (non-fatal): $($_.Exception.Message)"
}

# Console summary
Write-Host ''
Write-Host '================ DSC v3 Prerequisites ================' -ForegroundColor Cyan
Write-Host ("  OS: {0}" -f $osCaption)
foreach ($name in $status.Components.Keys) {
    if ($name -eq 'GalleryModules') { continue }
    $c = $status.Components[$name]
    $mark = if ($c.Installed) { '[ OK ]' } elseif ($c.Required) { '[FAIL]' } else { '[skip]' }
    $color = if ($c.Installed) { 'Green' } elseif ($c.Required) { 'Red' } else { 'Yellow' }
    $ver = if ($c.Version) { " v$($c.Version)" } else { '' }
    Write-Host ("  {0}  {1,-15}{2}" -f $mark, $name, $ver) -ForegroundColor $color
    if ($c.Path) { Write-Host ("           {0}" -f $c.Path) -ForegroundColor DarkGray }
}
foreach ($modName in $status.Components.GalleryModules.Keys) {
    $g = $status.Components.GalleryModules[$modName]
    $mark = if ($g.Installed) { '[ OK ]' } elseif ($g.Required) { '[FAIL]' } else { '[skip]' }
    $color = if ($g.Installed) { 'Green' } elseif ($g.Required) { 'Red' } else { 'Yellow' }
    $ver = if ($g.Version) { " v$($g.Version)" } else { '' }
    Write-Host ("  {0}  {1,-30}{2}" -f $mark, $modName, $ver) -ForegroundColor $color
    if ($g.Path) { Write-Host ("           {0}" -f $g.Path) -ForegroundColor DarkGray }
}
Write-Host ''
if ($status.AllInstalled) {
    Write-Host 'ALL PREREQUISITES INSTALLED.' -ForegroundColor Green
} else {
    Write-Host ("MISSING: {0}" -f ($missing -join ', ')) -ForegroundColor Red
}
Write-Host "Status JSON: $statusPath"
Write-Host '======================================================' -ForegroundColor Cyan

# Exit code reflects readiness
if (-not $status.AllInstalled) { exit 1 }
exit 0
