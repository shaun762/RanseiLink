<#
.SYNOPSIS
    Creates a safe, isolated Pokemon Conquest development workspace on Windows and (optionally) runs read-only ROM analysis.

.DESCRIPTION
    Run with no arguments for the guided setup:

        powershell -ExecutionPolicy Bypass -File .\tools\windows\Setup-ConquestDev.ps1

    What it does, in order (Action = Setup, the default):
      1. Reports which tools are installed (git, .NET SDK 10, RetroArch + melonDS core, standalone emulators, ndstool, ...).
      2. Creates the PokemonConquestDev workspace with separate original / experimental / output / diagnostics / backups /
         emulator folders.
      3. Lets you pick your existing ROM (auto-detected from RetroArch playlists, or browse/paste a path), VALIDATES it, and
         COPIES it into <workspace>\original. The source file is only ever opened for reading. Both copies are SHA-256 hashed
         and compared, and a manifest is written.

    Other actions: Check, Verify, Recon, SelfTest, BackupRetroArchSaves, LaunchIsolated, Status.

    SAFETY GUARANTEES (all enforced in code and covered by tests/Setup-ConquestDev.Tests.ps1)
      * The script never deletes anything.
      * The script never overwrites an existing file: files are created with FileMode.CreateNew. If something already exists
        it is left alone and you are told.
      * Your ROM and your RetroArch saves/states/config are opened read-only and never modified, moved or deleted.
      * Saves/states are only ever COPIED, and only by the separate BackupRetroArchSaves action after you type BACKUP.
      * LaunchIsolated always runs RetroArch with a COPY of your config plus overrides that redirect saves and save states
        into <workspace>\emulator\retroarch, and refuses to run if that is not provably separate from your normal directories.
      * The workspace may not be inside a git working tree, so nothing here can be committed by accident.
      * Nothing is uploaded anywhere. The script makes no network calls (winget, only with -InstallMissing and your
        confirmation, is the one external program that may).

    Compatible with Windows PowerShell 5.1 and PowerShell 7+. ASCII-only on purpose.

.PARAMETER Action
    Setup | Check | Verify | Recon | SelfTest | BackupRetroArchSaves | LaunchIsolated | Status

.PARAMETER WorkspaceRoot
    Default: %USERPROFILE%\PokemonConquestDev

.PARAMETER RomPath
    Your existing Pokemon Conquest .nds file. If omitted you are offered detected candidates, a file dialog, or a path prompt.

.PARAMETER RetroArchPath
    RetroArch folder or retroarch.exe. Auto-detected if omitted.

.PARAMETER RetroArchConfig
    Path to retroarch.cfg. Auto-detected if omitted.

.PARAMETER ExperimentalRom
    LaunchIsolated only: the ROM to run. Must be inside <workspace>\experimental or <workspace>\output.

.PARAMETER CorePath
    LaunchIsolated only: libretro core DLL (default: the melonDS core found in your RetroArch).

.PARAMETER Launch
    LaunchIsolated only: actually start RetroArch (default is a dry run that prints the plan).

.PARAMETER InstallMissing
    Offer to install missing tools with winget (each install asks for confirmation).

.PARAMETER NonInteractive
    Never prompt. Anything that would need a confirmation is skipped instead.

.PARAMETER AssumeYes
    Auto-accept harmless prompts (creating the workspace folders, and -Action Recon which you asked for explicitly). It can NOT bypass
    BACKUP typing, the launch confirmation, or any safety refusal.

.PARAMETER RomSearchPath
    Extra folders to scan (2 levels deep) for .nds files whose header says Pokemon Conquest.
#>
[CmdletBinding()]
param(
    [ValidateSet('Setup', 'Check', 'Verify', 'Recon', 'SelfTest', 'BackupRetroArchSaves', 'LaunchIsolated', 'Status')]
    [string]$Action = 'Setup',
    [string]$WorkspaceRoot,
    [string]$RomPath,
    [string]$RetroArchPath,
    [string]$RetroArchConfig,
    [string]$ExperimentalRom,
    [string]$CorePath,
    [switch]$Launch,
    [switch]$InstallMissing,
    [switch]$NonInteractive,
    [switch]$AssumeYes,
    [string[]]$RomSearchPath
)

$script:ScriptVersion = '1.0.0'
$script:ConquestGameCodes = @('VPYT', 'VPYJ', 'VPYP')
$script:RegionNames = @{ 'VPYT' = 'North America'; 'VPYJ' = 'Japan'; 'VPYP' = 'Europe' }

# ----------------------------------------------------------------------------------------------------------------------
# Output helpers
# ----------------------------------------------------------------------------------------------------------------------
function Write-Section([string]$Text) { Write-Host ''; Write-Host "== $Text ==" -ForegroundColor Cyan }
function Write-Ok([string]$Text) { Write-Host "  [ OK ] $Text" -ForegroundColor Green }
function Write-Warn([string]$Text) { Write-Host "  [WARN] $Text" -ForegroundColor Yellow }
function Write-Bad([string]$Text) { Write-Host "  [FAIL] $Text" -ForegroundColor Red }
function Write-Info([string]$Text) { Write-Host "         $Text" }

# ----------------------------------------------------------------------------------------------------------------------
# Confirmation. There is deliberately NO destructive operation in this script; confirmations guard harmless actions and
# the explicit BACKUP phrase. In NonInteractive mode every confirmation is answered "no".
# ----------------------------------------------------------------------------------------------------------------------
function Test-IsInteractive {
    if ($script:NonInteractiveMode) { return $false }
    try { return [Environment]::UserInteractive } catch { return $false }
}

function Confirm-Action {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Message, [switch]$Safe)
    if ($Safe -and $script:AssumeYesMode) { Write-Info "$Message -> yes (-AssumeYes)"; return $true }
    if (-not (Test-IsInteractive)) { Write-Info "$Message -> no (non-interactive)"; return $false }
    $answer = Read-Host "$Message [y/N]"
    return ($answer -match '^(y|yes)$')
}

function Read-Phrase {
    param([Parameter(Mandatory)][string]$Prompt, [Parameter(Mandatory)][string]$Expected)
    if (-not (Test-IsInteractive)) { return $false }
    $answer = Read-Host $Prompt
    return ($answer -ceq $Expected)
}

# ----------------------------------------------------------------------------------------------------------------------
# Paths
# ----------------------------------------------------------------------------------------------------------------------
function Get-NormalizedPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    return $full.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
}

function Test-PathComparisonIgnoresCase {
    return ([IO.Path]::DirectorySeparatorChar -eq '\')
}

function Test-IsSamePath([string]$A, [string]$B) {
    $cmp = if (Test-PathComparisonIgnoresCase) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    return [string]::Equals((Get-NormalizedPath $A), (Get-NormalizedPath $B), $cmp)
}

# True if Child is the same as, or inside, Parent.
function Test-IsUnderPath([string]$Child, [string]$Parent) {
    $cmp = if (Test-PathComparisonIgnoresCase) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $c = Get-NormalizedPath $Child
    $p = Get-NormalizedPath $Parent
    if ([string]::Equals($c, $p, $cmp)) { return $true }
    return $c.StartsWith($p + [IO.Path]::DirectorySeparatorChar, $cmp)
}

# True if the two directories overlap in either direction (equal, or one inside the other).
function Test-PathsOverlap([string]$A, [string]$B) {
    return ((Test-IsUnderPath $A $B) -or (Test-IsUnderPath $B $A))
}

function Find-GitRoot([string]$Path) {
    $dir = Get-NormalizedPath $Path
    while ($dir) {
        if ((Test-Path -LiteralPath ([IO.Path]::Combine($dir, '.git')))) { return $dir }
        $parent = [IO.Path]::GetDirectoryName($dir)
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $dir) { break }
        $dir = $parent
    }
    return $null
}

function Get-RepoRoot {
    # <repo>\tools\windows\Setup-ConquestDev.ps1
    $here = $PSScriptRoot
    if (-not $here) { $here = (Get-Location).Path }
    return (Get-NormalizedPath ([IO.Path]::Combine($here, '..', '..')))
}

# ----------------------------------------------------------------------------------------------------------------------
# Hashing, CRC and NDS header
# ----------------------------------------------------------------------------------------------------------------------
function Get-FileSha256([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    # FileAccess.Read + FileShare.Read: cannot modify the file.
    $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $hash = $sha.ComputeHash($fs)
        return ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
    }
    finally { $fs.Dispose(); $sha.Dispose() }
}

function Get-Crc16([byte[]]$Bytes, [int]$Offset, [int]$Length) {
    $crc = 0xFFFF
    for ($i = $Offset; $i -lt ($Offset + $Length); $i++) {
        $crc = $crc -bxor $Bytes[$i]
        for ($b = 0; $b -lt 8; $b++) {
            if (($crc -band 1) -ne 0) { $crc = (($crc -shr 1) -bxor 0xA001) } else { $crc = ($crc -shr 1) }
        }
    }
    return $crc
}

# Reads the 0x200-byte header (read-only) and returns an object, or throws with a human-readable message.
function Read-NdsHeaderInfo([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "File not found: $Path" }
    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    if (@('.zip', '.7z', '.rar', '.gz', '.xz', '.bz2') -contains $ext) {
        throw "'$Path' is an archive ($ext). Extract the .nds file first, then point the script at it."
    }
    $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $len = $fs.Length
        if ($len -lt 0x200) { throw "File is too small to be a Nintendo DS ROM ($len bytes)." }
        $buf = New-Object byte[] 0x200
        $read = $fs.Read($buf, 0, 0x200)
        if ($read -lt 0x200) { throw 'Could not read the 512-byte ROM header.' }
    }
    finally { $fs.Dispose() }
    $title = ([Text.Encoding]::ASCII.GetString($buf, 0, 12)).TrimEnd([char]0, ' ')
    $code = [Text.Encoding]::ASCII.GetString($buf, 0x0C, 4)
    $stored = [BitConverter]::ToUInt16($buf, 0x15E)
    $computed = Get-Crc16 $buf 0 0x15E
    $region = $script:RegionNames[$code]
    if (-not $region) { $region = 'unknown' }
    return [pscustomobject]@{
        Path             = (Get-NormalizedPath $Path)
        Length           = $len
        Title            = $title
        GameCode         = $code
        Region           = $region
        IsConquest       = ($script:ConquestGameCodes -contains $code)
        HeaderCrcStored  = $stored
        HeaderCrcComputed = $computed
        HeaderCrcValid   = ($stored -eq $computed)
    }
}

# ----------------------------------------------------------------------------------------------------------------------
# Copy without ever overwriting (FileMode.CreateNew) and verify by hash.
# ----------------------------------------------------------------------------------------------------------------------
function Copy-FileNoOverwrite {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination)
    $destDir = [IO.Path]::GetDirectoryName((Get-NormalizedPath $Destination))
    if (-not (Test-Path -LiteralPath $destDir)) { [void](New-Item -ItemType Directory -Path $destDir -Force) }
    $in = [IO.File]::Open($Source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        # CreateNew throws IOException if the destination exists - it can never clobber a file.
        $out = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $buffer = New-Object byte[] (1MB)
            while (($n = $in.Read($buffer, 0, $buffer.Length)) -gt 0) { $out.Write($buffer, 0, $n) }
        }
        finally { $out.Dispose() }
    }
    finally { $in.Dispose() }
    $srcHash = Get-FileSha256 $Source
    $dstHash = Get-FileSha256 $Destination
    return [pscustomobject]@{ Source = $Source; Destination = $Destination; Sha256Source = $srcHash; Sha256Destination = $dstHash; Verified = ($srcHash -eq $dstHash) }
}

# Chooses a file name that does not exist yet: name.ext, name_2.ext, name_3.ext ...
function Get-UnusedPath([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $Path }
    $dir = [IO.Path]::GetDirectoryName($Path)
    $base = [IO.Path]::GetFileNameWithoutExtension($Path)
    $ext = [IO.Path]::GetExtension($Path)
    $n = 2
    while ($true) {
        $candidate = [IO.Path]::Combine($dir, "${base}_$n$ext")
        if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
        $n++
    }
}

function Set-ReadOnly([string]$Path) {
    $item = Get-Item -LiteralPath $Path
    $item.Attributes = ($item.Attributes -bor [IO.FileAttributes]::ReadOnly)
}

# Writes text to a NEW file; never replaces. Returns the path actually written.
function Write-NewTextFile([string]$Path, [string]$Content) {
    $target = Get-UnusedPath $Path
    $dir = [IO.Path]::GetDirectoryName($target)
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $fs = [IO.File]::Open($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($Content)
        $fs.Write($bytes, 0, $bytes.Length)
    }
    finally { $fs.Dispose() }
    return $target
}

# ----------------------------------------------------------------------------------------------------------------------
# Tool detection
# ----------------------------------------------------------------------------------------------------------------------
function Get-CommandPath([string]$Name) {
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-DotNetSdkVersions {
    $dotnet = Get-CommandPath 'dotnet'
    if (-not $dotnet) { return @() }
    try { return @(& $dotnet --list-sdks 2>$null | ForEach-Object { ($_ -split ' ')[0] }) } catch { return @() }
}

function Test-DotNetSdkAtLeast([string[]]$Versions, [int]$Major) {
    foreach ($v in $Versions) {
        $m = 0
        if ([int]::TryParse(($v -split '\.')[0], [ref]$m) -and $m -ge $Major) { return $true }
    }
    return $false
}

function Find-FirstExistingFile([string[]]$Candidates) {
    foreach ($c in $Candidates) {
        if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { return (Get-NormalizedPath $c) }
    }
    return $null
}

function Find-RetroArchExe([string]$Hint) {
    if ($Hint) {
        if (Test-Path -LiteralPath $Hint -PathType Leaf) { return (Get-NormalizedPath $Hint) }
        $exe = [IO.Path]::Combine($Hint, 'retroarch.exe')
        if (Test-Path -LiteralPath $exe -PathType Leaf) { return (Get-NormalizedPath $exe) }
        return $null
    }
    $candidates = New-Object System.Collections.Generic.List[string]
    $running = Get-Process -Name 'retroarch' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($running -and $running.Path) { $candidates.Add($running.Path) }
    $onPath = Get-CommandPath 'retroarch.exe'
    if ($onPath) { $candidates.Add($onPath) }
    foreach ($root in @($env:APPDATA, $env:LOCALAPPDATA, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:USERPROFILE, 'C:\', 'C:\Emulators', 'D:\')) {
        if (-not $root) { continue }
        $candidates.Add([IO.Path]::Combine($root, 'RetroArch', 'retroarch.exe'))
        $candidates.Add([IO.Path]::Combine($root, 'RetroArch-Win64', 'retroarch.exe'))
        $candidates.Add([IO.Path]::Combine($root, 'Programs', 'RetroArch', 'retroarch.exe'))
    }
    if (${env:ProgramFiles(x86)}) { $candidates.Add([IO.Path]::Combine(${env:ProgramFiles(x86)}, 'Steam', 'steamapps', 'common', 'RetroArch', 'retroarch.exe')) }
    return (Find-FirstExistingFile $candidates.ToArray())
}

# Parses retroarch.cfg ("key = "value"") into a hashtable. Read-only.
function Read-RetroArchConfig([string]$ConfigPath) {
    $cfg = @{}
    foreach ($line in [IO.File]::ReadAllLines($ConfigPath)) {
        if ($line -match '^\s*([A-Za-z0-9_\[\]]+)\s*=\s*"?(.*?)"?\s*$') { $cfg[$Matches[1]] = $Matches[2] }
    }
    return $cfg
}

# RetroArch stores ':\saves' (relative to the install dir), 'default' or an absolute path.
function Resolve-RetroArchDirectory([string]$Value, [string]$RetroArchDir, [string]$DefaultRelative) {
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -eq 'default') {
        if ($DefaultRelative) { return (Get-NormalizedPath ([IO.Path]::Combine($RetroArchDir, $DefaultRelative))) }
        return $null
    }
    if ($Value.StartsWith(':')) {
        $rel = $Value.Substring(1).TrimStart('\', '/')
        return (Get-NormalizedPath ([IO.Path]::Combine($RetroArchDir, $rel)))
    }
    return (Get-NormalizedPath $Value)
}

function Find-RetroArchConfigPath([string]$ExePath, [string]$Hint) {
    if ($Hint) {
        if (Test-Path -LiteralPath $Hint -PathType Leaf) { return (Get-NormalizedPath $Hint) }
        return $null
    }
    $candidates = @()
    if ($ExePath) { $candidates += [IO.Path]::Combine([IO.Path]::GetDirectoryName($ExePath), 'retroarch.cfg') }
    if ($env:APPDATA) { $candidates += [IO.Path]::Combine($env:APPDATA, 'RetroArch', 'retroarch.cfg') }
    return (Find-FirstExistingFile $candidates)
}

# Everything we need to know about the owner's RetroArch, resolved to absolute paths.
function Get-RetroArchInfo([string]$PathHint, [string]$ConfigHint) {
    $exe = Find-RetroArchExe $PathHint
    $cfgPath = Find-RetroArchConfigPath $exe $ConfigHint
    $info = [ordered]@{ Exe = $exe; Dir = $null; ConfigPath = $cfgPath; Config = @{}; SaveDir = $null; StateDir = $null; CoresDir = $null; Cores = @(); PlaylistDir = $null; SaveInContentDir = $false; StateInContentDir = $false }
    if ($exe) { $info.Dir = [IO.Path]::GetDirectoryName($exe) }
    $baseDir = $info.Dir
    if (-not $baseDir -and $cfgPath) { $baseDir = [IO.Path]::GetDirectoryName($cfgPath) }
    if ($cfgPath) {
        $cfg = Read-RetroArchConfig $cfgPath
        $info.Config = $cfg
        if ($baseDir) {
            $info.SaveDir = Resolve-RetroArchDirectory $cfg['savefile_directory'] $baseDir 'saves'
            $info.StateDir = Resolve-RetroArchDirectory $cfg['savestate_directory'] $baseDir 'states'
            $info.CoresDir = Resolve-RetroArchDirectory $cfg['libretro_directory'] $baseDir 'cores'
            $info.PlaylistDir = Resolve-RetroArchDirectory $cfg['playlist_directory'] $baseDir 'playlists'
        }
        $info.SaveInContentDir = ($cfg['savefiles_in_content_dir'] -eq 'true')
        $info.StateInContentDir = ($cfg['savestates_in_content_dir'] -eq 'true')
    }
    elseif ($baseDir) {
        $info.SaveDir = Resolve-RetroArchDirectory '' $baseDir 'saves'
        $info.StateDir = Resolve-RetroArchDirectory '' $baseDir 'states'
        $info.CoresDir = Resolve-RetroArchDirectory '' $baseDir 'cores'
        $info.PlaylistDir = Resolve-RetroArchDirectory '' $baseDir 'playlists'
    }
    if ($info.CoresDir -and (Test-Path -LiteralPath $info.CoresDir)) {
        $info.Cores = @(Get-ChildItem -LiteralPath $info.CoresDir -Filter 'melonds*_libretro.dll' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    }
    return [pscustomobject]$info
}

function Get-ToolStatus([object]$RetroArch) {
    $rows = New-Object System.Collections.Generic.List[object]
    function Add-Row([string]$Name, [string]$Need, [bool]$Found, [string]$Detail, [string]$Hint) {
        $rows.Add([pscustomobject]@{ Name = $Name; Need = $Need; Found = $Found; Detail = $Detail; Hint = $Hint })
    }
    $psv = $PSVersionTable.PSVersion
    Add-Row 'PowerShell >= 5.1' 'Required' ($psv.Major -gt 5 -or ($psv.Major -eq 5 -and $psv.Minor -ge 1)) $psv.ToString() 'winget install --id Microsoft.PowerShell -e'
    $git = Get-CommandPath 'git'
    Add-Row 'git' 'Required' ([bool]$git) $git 'winget install --id Git.Git -e'
    $sdks = Get-DotNetSdkVersions
    Add-Row '.NET SDK >= 10' 'Required' (Test-DotNetSdkAtLeast $sdks 10) ($sdks -join ', ') 'winget install --id Microsoft.DotNet.SDK.10 -e'
    $ra = $RetroArch.Exe
    Add-Row 'RetroArch' 'Existing' ([bool]$ra) $ra 'Already installed by you; pass -RetroArchPath if not detected.'
    Add-Row 'RetroArch config' 'Existing' ([bool]$RetroArch.ConfigPath) $RetroArch.ConfigPath 'Pass -RetroArchConfig <path to retroarch.cfg>.'
    Add-Row 'melonDS libretro core' 'Existing' ($RetroArch.Cores.Count -gt 0) ($RetroArch.Cores -join '; ') 'Install via RetroArch: Load Core > Download a Core > Nintendo DS (melonDS DS).'
    $melon = Find-FirstExistingFile @(
        (Get-CommandPath 'melonDS.exe'), (Get-CommandPath 'melonDS'),
        [IO.Path]::Combine([string]$env:ProgramFiles, 'melonDS', 'melonDS.exe'),
        [IO.Path]::Combine([string]$env:LOCALAPPDATA, 'Microsoft', 'WinGet', 'Links', 'melonDS.exe'))
    Add-Row 'melonDS (standalone)' 'Recommended' ([bool]$melon) $melon 'winget install --id melonDS.melonDS -e   (isolated test emulator; see EMULATOR_TESTING.md)'
    $desmume = Find-FirstExistingFile @((Get-CommandPath 'DeSmuME.exe'), (Get-CommandPath 'desmume.exe'), [IO.Path]::Combine([string]$env:ProgramFiles, 'DeSmuME', 'DeSmuME_X432R_x64.exe'))
    Add-Row 'DeSmuME (standalone)' 'Optional' ([bool]$desmume) $desmume 'Download from https://desmume.org (debugger/memory viewer); no verified winget id.'
    $ndstool = Get-CommandPath 'ndstool'
    Add-Row 'ndstool' 'Optional' ([bool]$ndstool) $ndstool 'Part of devkitPro; only needed to cross-check ARM9 extraction (RomRecon does not need it).'
    $python = Get-CommandPath 'python'
    Add-Row 'Python 3' 'Optional' ([bool]$python) $python 'winget install --id Python.Python.3.12 -e   (only to cross-check with ndspy)'
    $ghidra = $null
    if ($env:GHIDRA_INSTALL_DIR -and (Test-Path -LiteralPath $env:GHIDRA_INSTALL_DIR)) { $ghidra = $env:GHIDRA_INSTALL_DIR }
    Add-Row 'Ghidra' 'Optional' ([bool]$ghidra) $ghidra 'https://ghidra-sre.org ; set GHIDRA_INSTALL_DIR. Needed later for disassembly.'
    return $rows.ToArray()
}

function Show-ToolStatus([object[]]$Rows) {
    Write-Section 'Tools'
    foreach ($r in $Rows) {
        $detail = if ($r.Detail) { " ($($r.Detail))" } else { '' }
        if ($r.Found) { Write-Ok "$($r.Name) [$($r.Need)]$detail" }
        elseif ($r.Need -eq 'Required') { Write-Bad "$($r.Name) [$($r.Need)] missing.  Install: $($r.Hint)" }
        else { Write-Warn "$($r.Name) [$($r.Need)] not found.  $($r.Hint)" }
    }
}

# winget ids that were actually seen on winstall.app / the winget-pkgs repository while writing this script.
$script:WingetIds = @{ 'git' = 'Git.Git'; '.NET SDK >= 10' = 'Microsoft.DotNet.SDK.10'; 'melonDS (standalone)' = 'melonDS.melonDS'; 'Python 3' = 'Python.Python.3.12' }

function Invoke-InstallMissing([object[]]$Rows) {
    $winget = Get-CommandPath 'winget'
    if (-not $winget) { Write-Warn 'winget not found; install the missing tools manually (hints above).'; return }
    foreach ($r in ($Rows | Where-Object { -not $_.Found })) {
        $id = $script:WingetIds[$r.Name]
        if (-not $id) { continue }
        if (Confirm-Action "Install '$($r.Name)' now with: winget install --id $id -e ?") {
            & $winget install --id $id -e --accept-package-agreements --accept-source-agreements
        }
    }
    Write-Info 'Re-open this PowerShell window afterwards so PATH changes are picked up, then re-run the script.'
}

# ----------------------------------------------------------------------------------------------------------------------
# ROM discovery
# ----------------------------------------------------------------------------------------------------------------------
function Find-ConquestRomCandidates([object]$RetroArch, [string[]]$SearchPaths) {
    $paths = New-Object System.Collections.Generic.List[string]
    if ($RetroArch -and $RetroArch.PlaylistDir -and (Test-Path -LiteralPath $RetroArch.PlaylistDir)) {
        foreach ($lpl in Get-ChildItem -LiteralPath $RetroArch.PlaylistDir -Filter '*.lpl' -File -ErrorAction SilentlyContinue) {
            try {
                $json = Get-Content -LiteralPath $lpl.FullName -Raw | ConvertFrom-Json
                foreach ($item in @($json.items)) {
                    if ($item.path -and $item.path -notmatch '#' -and ($item.path -match '\.nds$') -and (($item.label -match 'conquest') -or ($item.path -match 'conquest'))) { $paths.Add([string]$item.path) }
                }
            }
            catch { Write-Verbose "Could not parse playlist $($lpl.FullName): $_" }
        }
    }
    foreach ($root in @($SearchPaths)) {
        if ($root -and (Test-Path -LiteralPath $root -PathType Container)) {
            foreach ($f in Get-ChildItem -LiteralPath $root -Filter '*.nds' -File -Recurse -Depth 2 -ErrorAction SilentlyContinue) { $paths.Add($f.FullName) }
        }
    }
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($p in ($paths | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
        try { $h = Read-NdsHeaderInfo $p; if ($h.IsConquest) { $result.Add($h) } } catch { Write-Verbose "Skipping $p : $_" }
    }
    return $result.ToArray()
}

function Show-FileDialog {
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title = 'Select your Pokemon Conquest .nds file (it will be COPIED, not modified)'
        $dlg.Filter = 'Nintendo DS ROM (*.nds)|*.nds|All files (*.*)|*.*'
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.FileName }
    }
    catch { Write-Verbose "File dialog unavailable: $_" }
    return $null
}

function Select-Rom([string]$Given, [object]$RetroArch, [string[]]$SearchPaths) {
    if ($Given) { return $Given }
    if (-not (Test-IsInteractive)) { throw 'No ROM given. Re-run with -RomPath "C:\path\to\Pokemon Conquest.nds".' }
    $cands = @(Find-ConquestRomCandidates $RetroArch $SearchPaths)
    Write-Section 'Select your ROM'
    $i = 1
    foreach ($c in $cands) { Write-Host ("  [{0}] {1}  ({2}, {3})" -f $i, $c.Path, $c.GameCode, $c.Region); $i++ }
    Write-Host '  [B] Browse for a file...'
    Write-Host '  [P] Paste a path'
    while ($true) {
        $answer = Read-Host 'Choose'
        if ($answer -match '^\d+$' -and [int]$answer -ge 1 -and [int]$answer -le $cands.Count) { return $cands[[int]$answer - 1].Path }
        if ($answer -match '^[bB]$') { $f = Show-FileDialog; if ($f) { return $f } else { Write-Warn 'No file chosen.' } }
        if ($answer -match '^[pP]$') { $p = (Read-Host 'Full path to the .nds file').Trim('"'); if ($p) { return $p } }
    }
}

# ----------------------------------------------------------------------------------------------------------------------
# Workspace
# ----------------------------------------------------------------------------------------------------------------------
$script:WorkspaceSubfolders = @('original', 'experimental', 'output', 'diagnostics', 'backups', 'manifests', 'logs', 'emulator')

function Get-WorkspacePaths([string]$Root) {
    $r = Get-NormalizedPath $Root
    return [pscustomobject]@{
        Root         = $r
        Original     = [IO.Path]::Combine($r, 'original')
        Experimental = [IO.Path]::Combine($r, 'experimental')
        Output       = [IO.Path]::Combine($r, 'output')
        Diagnostics  = [IO.Path]::Combine($r, 'diagnostics')
        Backups      = [IO.Path]::Combine($r, 'backups')
        Manifests    = [IO.Path]::Combine($r, 'manifests')
        Logs         = [IO.Path]::Combine($r, 'logs')
        Emulator     = [IO.Path]::Combine($r, 'emulator')
        IsolatedRA   = [IO.Path]::Combine($r, 'emulator', 'retroarch')
        Settings     = [IO.Path]::Combine($r, 'workspace.json')
    }
}

function Assert-WorkspaceLocationSafe([string]$Root, [object]$RetroArch) {
    $git = Find-GitRoot $Root
    if ($git) { throw "The workspace '$Root' is inside a git working tree ('$git'). Choose a location outside any repository (ROM-derived files must never be committable)." }
    if ($RetroArch -and $RetroArch.Dir -and (Test-PathsOverlap $Root $RetroArch.Dir)) { throw "The workspace may not overlap your RetroArch folder ('$($RetroArch.Dir)')." }
    foreach ($d in @($RetroArch.SaveDir, $RetroArch.StateDir)) {
        if ($d -and (Test-PathsOverlap $Root $d)) { throw "The workspace may not overlap your RetroArch save/state folder ('$d')." }
    }
}

function New-Workspace([object]$Paths) {
    foreach ($sub in $script:WorkspaceSubfolders) {
        $p = [IO.Path]::Combine($Paths.Root, $sub)
        if (-not (Test-Path -LiteralPath $p)) { [void](New-Item -ItemType Directory -Path $p -Force); Write-Ok "created $p" }
        else { Write-Info "exists  $p" }
    }
    $notes = @{
        'original'     = "Verified, read-only copies of your own ROM. Never edit files here. (Created by Setup-ConquestDev.ps1)"
        'experimental' = "Scratch ROMs and mods for experiments. Only ROMs in this folder or in 'output' can be launched by -Action LaunchIsolated."
        'output'       = "Patched ROMs and build products. Treat as disposable."
        'diagnostics'  = "RomRecon reports and local analysis files. Derived from your ROM: do not share or commit."
        'backups'      = "Copies of RetroArch saves/states made by -Action BackupRetroArchSaves."
    }
    foreach ($k in $notes.Keys) {
        $readme = [IO.Path]::Combine($Paths.Root, $k, 'README.txt')
        if (-not (Test-Path -LiteralPath $readme)) { [void](Write-NewTextFile $readme $notes[$k]) }
    }
}

function Register-OriginalRom([string]$SourceRom, [object]$Paths, [object]$Header) {
    $name = [IO.Path]::GetFileName($SourceRom)
    $dest = [IO.Path]::Combine($Paths.Original, $name)
    $srcHash = Get-FileSha256 $SourceRom
    if (Test-Path -LiteralPath $dest) {
        $existing = Get-FileSha256 $dest
        if ($existing -eq $srcHash) {
            Write-Ok "original copy already present and identical (SHA-256 $srcHash)"
            return [pscustomobject]@{ Path = $dest; Sha256 = $srcHash; Action = 'AlreadyPresent' }
        }
        Write-Warn "'$dest' already exists with DIFFERENT content. It will not be overwritten."
        if (-not (Confirm-Action 'Copy your ROM alongside it under a new name instead?')) { return [pscustomobject]@{ Path = $dest; Sha256 = $existing; Action = 'SkippedConflict' } }
        $dest = Get-UnusedPath $dest
    }
    $res = Copy-FileNoOverwrite -Source $SourceRom -Destination $dest
    if (-not $res.Verified) {
        Write-Bad "Hash mismatch after copy! source $($res.Sha256Source) vs copy $($res.Sha256Destination). The copy was NOT deleted; remove it yourself and retry."
        throw 'ROM copy verification failed.'
    }
    Set-ReadOnly $dest
    Write-Ok "copied and verified -> $dest"
    Write-Info "SHA-256 $($res.Sha256Destination)"
    return [pscustomobject]@{ Path = $dest; Sha256 = $res.Sha256Destination; Action = 'Copied' }
}

function Write-RomManifest([object]$Paths, [object]$Registered, [object]$Header, [string]$SourcePath) {
    # Re-running setup must not litter the workspace: reuse an existing manifest that already describes this exact file.
    foreach ($m in @(Get-ChildItem -LiteralPath $Paths.Manifests -Filter 'original_*.json' -File -ErrorAction SilentlyContinue)) {
        try {
            $j = Get-Content -LiteralPath $m.FullName -Raw | ConvertFrom-Json
            if ($j.sha256 -eq $Registered.Sha256 -and $j.file -eq [IO.Path]::GetFileName($Registered.Path)) { return $m.FullName }
        }
        catch { Write-Verbose "Ignoring unreadable manifest $($m.FullName)" }
    }
    $manifest = [ordered]@{
        schema        = 1
        createdUtc    = [DateTime]::UtcNow.ToString('o')
        scriptVersion = $script:ScriptVersion
        file          = [IO.Path]::GetFileName($Registered.Path)
        sha256        = $Registered.Sha256
        sizeBytes     = (Get-Item -LiteralPath $Registered.Path).Length
        gameCode      = $Header.GameCode
        region        = $Header.Region
        title         = $Header.Title
        headerCrcValid = $Header.HeaderCrcValid
        sourceDirectory = [IO.Path]::GetDirectoryName($SourcePath)
        note          = 'Hashes identify your own ROM; the ROM itself is never stored in git or uploaded.'
    }
    $path = [IO.Path]::Combine($Paths.Manifests, ('original_' + [IO.Path]::GetFileNameWithoutExtension($Registered.Path) + '.json'))
    return (Write-NewTextFile $path ($manifest | ConvertTo-Json -Depth 4))
}

function Write-WorkspaceSettings([object]$Paths, [object]$RetroArch, [object]$Registered) {
    if (Test-Path -LiteralPath $Paths.Settings) { Write-Info "workspace.json exists - left unchanged"; return }
    $s = [ordered]@{
        schema = 1; createdUtc = [DateTime]::UtcNow.ToString('o'); workspaceRoot = $Paths.Root
        originalRom = $Registered.Path; originalRomSha256 = $Registered.Sha256
        retroArchExe = $RetroArch.Exe; retroArchConfig = $RetroArch.ConfigPath
        retroArchSaveDir = $RetroArch.SaveDir; retroArchStateDir = $RetroArch.StateDir
    }
    [void](Write-NewTextFile $Paths.Settings ($s | ConvertTo-Json -Depth 4))
}

function Read-WorkspaceSettings([object]$Paths) {
    if (Test-Path -LiteralPath $Paths.Settings) { return (Get-Content -LiteralPath $Paths.Settings -Raw | ConvertFrom-Json) }
    return $null
}

function Get-OriginalRomPath([object]$Paths) {
    $s = Read-WorkspaceSettings $Paths
    if ($s -and $s.originalRom -and (Test-Path -LiteralPath $s.originalRom)) { return $s.originalRom }
    $roms = @(Get-ChildItem -LiteralPath $Paths.Original -Filter '*.nds' -File -ErrorAction SilentlyContinue)
    if ($roms.Count -ge 1) { return $roms[0].FullName }
    return $null
}

# ----------------------------------------------------------------------------------------------------------------------
# RetroArch save/state backup (explicit, copy-only)
# ----------------------------------------------------------------------------------------------------------------------
function Find-RetroArchSaveFiles([object]$RetroArch, [string]$RomBaseName, [string]$RomDirectory) {
    $found = New-Object System.Collections.Generic.List[object]
    $roots = @(
        @{ Dir = $RetroArch.SaveDir; Kind = 'saves' },
        @{ Dir = $RetroArch.StateDir; Kind = 'states' }
    )
    # Only when retroarch.cfg says saves/states live next to the content; then look in that one folder only (not recursively).
    $besideRom = ($RomDirectory -and ($RetroArch.SaveInContentDir -or $RetroArch.StateInContentDir))
    if ($besideRom) { $roots += @{ Dir = $RomDirectory; Kind = 'next-to-rom'; Flat = $true } }
    foreach ($r in $roots) {
        if (-not $r.Dir -or -not (Test-Path -LiteralPath $r.Dir)) { continue }
        # sort_savefiles_enable puts files in per-core subfolders, so the saves/states folders are searched recursively.
        $recurse = -not $r.Flat
        $files = @(Get-ChildItem -LiteralPath $r.Dir -Recurse:$recurse -File -ErrorAction SilentlyContinue | Where-Object {
                $_.Name.StartsWith($RomBaseName + '.', [StringComparison]::OrdinalIgnoreCase) -and
                $_.Extension -notmatch '^\.(nds|zip|7z)$'
            })
        foreach ($f in $files) { $found.Add([pscustomobject]@{ Kind = $r.Kind; Root = $r.Dir; FullName = $f.FullName; Length = $f.Length; LastWriteTime = $f.LastWriteTime }) }
    }
    return $found.ToArray()
}

function Invoke-BackupRetroArchSaves([object]$Paths, [object]$RetroArch, [string]$RomFile) {
    Write-Section 'Back up RetroArch saves and save states (copy only)'
    if (-not $RomFile) { throw 'Which game? Pass -RomPath (your normal ROM) so the matching save files can be found by name.' }
    $base = [IO.Path]::GetFileNameWithoutExtension($RomFile)
    $files = @(Find-RetroArchSaveFiles $RetroArch $base ([IO.Path]::GetDirectoryName((Get-NormalizedPath $RomFile))))
    if ($files.Count -eq 0) {
        Write-Warn "No save or save-state files named '$base.*' were found in:"
        Write-Info "saves : $($RetroArch.SaveDir)"; Write-Info "states: $($RetroArch.StateDir)"
        return $null
    }
    foreach ($f in $files) { Write-Info ("{0,-11} {1,10:N0} bytes  {2}  {3}" -f $f.Kind, $f.Length, $f.LastWriteTime.ToString('yyyy-MM-dd HH:mm'), $f.FullName) }
    if (Get-Process -Name 'retroarch' -ErrorAction SilentlyContinue) {
        Write-Warn 'RetroArch is running. Close it first so no save is half-written during the copy.'
        if (-not (Confirm-Action 'Continue anyway?')) { return $null }
    }
    Write-Host ''
    Write-Host "This will COPY $($files.Count) file(s) into $($Paths.Backups). Your originals are not touched." -ForegroundColor Yellow
    if (-not (Read-Phrase 'Type BACKUP (capitals) to proceed, anything else cancels' 'BACKUP')) { Write-Info 'Cancelled. Nothing was copied.'; return $null }

    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $dest = Get-UnusedPath ([IO.Path]::Combine($Paths.Backups, "retroarch_$stamp"))
    [void](New-Item -ItemType Directory -Path $dest -Force)
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($f in $files) {
        $rel = $f.FullName.Substring((Get-NormalizedPath $f.Root).Length).TrimStart('\', '/')
        $target = [IO.Path]::Combine($dest, $f.Kind, $rel)
        $res = Copy-FileNoOverwrite -Source $f.FullName -Destination $target
        if (-not $res.Verified) { Write-Bad "verification FAILED for $($f.FullName)" } else { Set-ReadOnly $target; Write-Ok "backed up $($f.FullName)" }
        $entries.Add([ordered]@{ source = $f.FullName; backup = $target; sha256 = $res.Sha256Destination; verified = $res.Verified })
    }
    $manifest = [ordered]@{ schema = 1; createdUtc = [DateTime]::UtcNow.ToString('o'); game = $base; files = $entries.ToArray() }
    $mp = Write-NewTextFile ([IO.Path]::Combine($dest, 'backup_manifest.json')) ($manifest | ConvertTo-Json -Depth 5)
    Write-Info "manifest: $mp"
    Write-Info 'To restore manually: close RetroArch and copy files back yourself. This script never restores or overwrites.'
    return $dest
}

# ----------------------------------------------------------------------------------------------------------------------
# Isolated RetroArch launch (never touches the real playthrough)
# ----------------------------------------------------------------------------------------------------------------------
function ConvertTo-QuotedArg([string]$Value) { return ('"' + $Value.Replace('"', '\"') + '"') }

function Get-IsolatedLaunchPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Paths,
        [Parameter(Mandatory)][object]$RetroArch,
        [Parameter(Mandatory)][string]$Rom,
        [string]$Core,
        [string]$OriginalRom
    )
    if (-not $RetroArch.Exe) { throw 'RetroArch was not found; pass -RetroArchPath.' }
    if (-not $RetroArch.ConfigPath) { throw 'retroarch.cfg was not found; pass -RetroArchConfig.' }
    if (-not (Test-Path -LiteralPath $Rom -PathType Leaf)) { throw "Experimental ROM not found: $Rom" }

    # 1. only ROMs from the experiment folders may be launched
    $inExperimental = Test-IsUnderPath $Rom $Paths.Experimental
    $inOutput = Test-IsUnderPath $Rom $Paths.Output
    if (-not ($inExperimental -or $inOutput)) { throw "Refusing to launch '$Rom': only ROMs inside '$($Paths.Experimental)' or '$($Paths.Output)' may be launched with the isolated profile." }
    if ($OriginalRom -and (Test-IsSamePath $Rom $OriginalRom)) { throw 'Refusing to launch the original ROM through the experiment profile.' }

    # 2. isolated directories must be provably separate from the owner's real ones
    $isoSaves = [IO.Path]::Combine($Paths.IsolatedRA, 'saves')
    $isoStates = [IO.Path]::Combine($Paths.IsolatedRA, 'states')
    foreach ($real in @($RetroArch.SaveDir, $RetroArch.StateDir)) {
        if ($real -and ((Test-PathsOverlap $isoSaves $real) -or (Test-PathsOverlap $isoStates $real))) {
            throw "Refusing to launch: isolated folder overlaps your real RetroArch save/state folder '$real'."
        }
    }
    if ($RetroArch.Dir -and (Test-PathsOverlap $Paths.IsolatedRA $RetroArch.Dir)) { throw 'Refusing to launch: the isolated profile overlaps the RetroArch install folder.' }

    # 3. core
    $coreFile = $Core
    if (-not $coreFile -and $RetroArch.Cores.Count -gt 0) { $coreFile = $RetroArch.Cores | Select-Object -First 1 }
    if (-not $coreFile) { throw 'No melonDS core found in RetroArch; pass -CorePath <melondsds_libretro.dll>.' }

    $cfgCopy = [IO.Path]::Combine($Paths.IsolatedRA, 'retroarch.cfg')
    $overrides = [IO.Path]::Combine($Paths.IsolatedRA, 'isolated_overrides.cfg')
    $isoPlaylists = [IO.Path]::Combine($Paths.IsolatedRA, 'playlists')
    $isoConfigDir = [IO.Path]::Combine($Paths.IsolatedRA, 'config')
    $isoCoreOptions = [IO.Path]::Combine($Paths.IsolatedRA, 'retroarch-core-options.cfg')
    $isoShots = [IO.Path]::Combine($Paths.Diagnostics, 'screenshots')
    $overrideText = @(
        '# Written by Setup-ConquestDev.ps1. Appended LAST, so these win over retroarch.cfg.',
        ('savefile_directory = "{0}"' -f $isoSaves),
        ('savestate_directory = "{0}"' -f $isoStates),
        ('playlist_directory = "{0}"' -f $isoPlaylists),
        ('rgui_config_directory = "{0}"' -f $isoConfigDir),
        ('core_options_path = "{0}"' -f $isoCoreOptions),
        ('screenshot_directory = "{0}"' -f $isoShots),
        'history_list_enable = "false"',
        'savefiles_in_content_dir = "false"',
        'savestates_in_content_dir = "false"',
        'sort_savefiles_enable = "false"',
        'sort_savestates_enable = "false"',
        'sort_savefiles_by_content_enable = "false"',
        'sort_savestates_by_content_enable = "false"',
        'savestate_auto_save = "false"',
        'savestate_auto_load = "false"',
        'config_save_on_exit = "false"'
    ) -join "`r`n"
    $argList = @('--config', (ConvertTo-QuotedArg $cfgCopy), '--appendconfig', (ConvertTo-QuotedArg $overrides), '-L', (ConvertTo-QuotedArg $coreFile), (ConvertTo-QuotedArg $Rom))
    return [pscustomobject]@{
        Exe          = $RetroArch.Exe
        Rom          = (Get-NormalizedPath $Rom)
        Core         = $coreFile
        ConfigCopy   = $cfgCopy
        SourceConfig = $RetroArch.ConfigPath
        OverridesPath = $overrides
        OverrideText = $overrideText
        SaveDir      = $isoSaves
        StateDir     = $isoStates
        ExtraDirs    = @($isoPlaylists, $isoConfigDir, $isoShots)
        WatchedOwnerDirs = @(@($RetroArch.SaveDir, $RetroArch.StateDir, $RetroArch.PlaylistDir) | Where-Object { $_ })
        Arguments    = $argList
    }
}

# Cheap tripwire: count, total size and newest write time of every file under a directory.
function Get-DirectorySnapshot([string]$Dir) {
    if (-not $Dir -or -not (Test-Path -LiteralPath $Dir)) { return [pscustomobject]@{ Dir = $Dir; Exists = $false; Count = 0; Bytes = 0; Newest = [DateTime]::MinValue } }
    $files = @(Get-ChildItem -LiteralPath $Dir -Recurse -File -ErrorAction SilentlyContinue)
    $bytes = 0; $newest = [DateTime]::MinValue
    foreach ($f in $files) { $bytes += $f.Length; if ($f.LastWriteTimeUtc -gt $newest) { $newest = $f.LastWriteTimeUtc } }
    return [pscustomobject]@{ Dir = $Dir; Exists = $true; Count = $files.Count; Bytes = $bytes; Newest = $newest }
}

function Test-SnapshotsEqual([object]$A, [object]$B) {
    return ($A.Exists -eq $B.Exists -and $A.Count -eq $B.Count -and $A.Bytes -eq $B.Bytes -and $A.Newest -eq $B.Newest)
}

function Invoke-IsolatedLaunch([object]$Plan, [switch]$DoLaunch) {
    Write-Section 'Isolated RetroArch launch plan'
    Write-Info "ROM       : $($Plan.Rom)"
    Write-Info "Core      : $($Plan.Core)"
    Write-Info "Config    : $($Plan.ConfigCopy)   (a COPY of $($Plan.SourceConfig); yours is not touched)"
    Write-Info "Saves     : $($Plan.SaveDir)"
    Write-Info "States    : $($Plan.StateDir)"
    Write-Info "Command   : `"$($Plan.Exe)`" $($Plan.Arguments -join ' ')"
    if (-not $DoLaunch) { Write-Info 'Dry run. Add -Launch to start it.'; return }
    if (-not (Confirm-Action 'Start RetroArch with this isolated profile now?')) { return }
    foreach ($d in (@($Plan.SaveDir, $Plan.StateDir) + @($Plan.ExtraDirs))) { if (-not (Test-Path -LiteralPath $d)) { [void](New-Item -ItemType Directory -Path $d -Force) } }
    if (-not (Test-Path -LiteralPath $Plan.ConfigCopy)) { [void](Copy-FileNoOverwrite -Source $Plan.SourceConfig -Destination $Plan.ConfigCopy) }
    $ovPath = $Plan.OverridesPath
    if (Test-Path -LiteralPath $ovPath) {
        $current = [IO.File]::ReadAllText($ovPath)
        if ($current.Trim() -ne $Plan.OverrideText.Trim()) { throw "Existing '$ovPath' differs from the safe overrides this script wants. Move it aside yourself and re-run (the script never overwrites)." }
    }
    else { [void](Write-NewTextFile $ovPath $Plan.OverrideText) }
    # Tripwire: snapshot YOUR save/state/playlist folders, run, and compare after RetroArch exits.
    $before = @($Plan.WatchedOwnerDirs | ForEach-Object { Get-DirectorySnapshot $_ })
    Write-Info 'RetroArch is starting; this window waits until you close it so it can verify your own saves were not touched.'
    Start-Process -FilePath $Plan.Exe -ArgumentList $Plan.Arguments -Wait | Out-Null
    $changed = $false
    foreach ($b in $before) {
        $a = Get-DirectorySnapshot $b.Dir
        if (-not (Test-SnapshotsEqual $a $b)) { $changed = $true; Write-Bad "CHANGED during the experiment: $($b.Dir)  (files $($b.Count)->$($a.Count), bytes $($b.Bytes)->$($a.Bytes))" }
        else { Write-Ok "unchanged: $($b.Dir)" }
    }
    if ($changed) { Write-Warn 'Something in your normal RetroArch folders changed. Restore from the backup you made with -Action BackupRetroArchSaves if needed.' }
}

# ----------------------------------------------------------------------------------------------------------------------
# Verify / Status / Recon / SelfTest
# ----------------------------------------------------------------------------------------------------------------------
function Invoke-Verify([object]$Paths) {
    Write-Section 'Verify workspace'
    if (-not (Test-Path -LiteralPath $Paths.Root)) { Write-Bad "workspace not found: $($Paths.Root)"; return $false }
    $allOk = $true
    foreach ($sub in $script:WorkspaceSubfolders) { $p = [IO.Path]::Combine($Paths.Root, $sub); if (Test-Path -LiteralPath $p) { Write-Ok "$sub" } else { Write-Bad "missing folder: $sub"; $allOk = $false } }
    foreach ($m in @(Get-ChildItem -LiteralPath $Paths.Manifests -Filter 'original_*.json' -File -ErrorAction SilentlyContinue)) {
        $j = Get-Content -LiteralPath $m.FullName -Raw | ConvertFrom-Json
        $romPath = [IO.Path]::Combine($Paths.Original, $j.file)
        if (-not (Test-Path -LiteralPath $romPath)) { Write-Bad "ROM listed in $($m.Name) is missing: $romPath"; $allOk = $false; continue }
        $h = Get-FileSha256 $romPath
        if ($h -eq $j.sha256) { Write-Ok "$($j.file) matches its manifest (SHA-256 $h)" } else { Write-Bad "$($j.file) does NOT match its manifest ($h vs $($j.sha256))"; $allOk = $false }
        $ro = ((Get-Item -LiteralPath $romPath).Attributes -band [IO.FileAttributes]::ReadOnly) -ne 0
        if ($ro) { Write-Ok 'original is read-only' } else { Write-Warn 'original is not marked read-only' }
    }
    return $allOk
}

function Invoke-Recon([object]$Paths) {
    Write-Section 'Read-only ROM analysis (RomRecon)'
    $rom = Get-OriginalRomPath $Paths
    if (-not $rom) { Write-Bad 'No original ROM registered yet; run -Action Setup first.'; return }
    $dotnet = Get-CommandPath 'dotnet'
    if (-not $dotnet) { Write-Bad '.NET SDK not found. Install it (winget install --id Microsoft.DotNet.SDK.10 -e) and re-run.'; return }
    $proj = [IO.Path]::Combine((Get-RepoRoot), 'tools', 'RomRecon', 'RomRecon.csproj')
    if (-not (Test-Path -LiteralPath $proj)) { Write-Bad "RomRecon project not found at $proj (run this script from a clone of the repository)."; return }
    Write-Info "ROM    : $rom"
    Write-Info "Output : $($Paths.Diagnostics) (a new sub-folder per run)"
    if (-not (Confirm-Action 'Run the read-only analysis now? (does not modify the ROM; verifies its hash before and after)' -Safe)) { return }
    & $dotnet run --project $proj -c Release -- all $rom --out $Paths.Diagnostics
    if ($LASTEXITCODE -ne 0) { Write-Bad "RomRecon exited with code $LASTEXITCODE" } else { Write-Ok 'analysis complete; see the diagnostics folder' }
}

function Invoke-SelfTest {
    Write-Section 'Self-test (synthetic data only, no ROM needed)'
    $dotnet = Get-CommandPath 'dotnet'
    if (-not $dotnet) { Write-Bad '.NET SDK not found.'; return }
    $proj = [IO.Path]::Combine((Get-RepoRoot), 'tools', 'RomRecon.Tests', 'RomRecon.Tests.csproj')
    & $dotnet test $proj -c Release
}

function Show-Status([object]$Paths, [object]$RetroArch) {
    Write-Section 'Status'
    Write-Info "workspace : $($Paths.Root) $(if (Test-Path -LiteralPath $Paths.Root) { '(exists)' } else { '(not created yet)' })"
    $rom = if (Test-Path -LiteralPath $Paths.Original) { Get-OriginalRomPath $Paths } else { $null }
    Write-Info "original  : $(if ($rom) { $rom } else { '(none registered)' })"
    Write-Info "RetroArch : $($RetroArch.Exe)"
    Write-Info "config    : $($RetroArch.ConfigPath)"
    Write-Info "your saves: $($RetroArch.SaveDir)"
    Write-Info "your state: $($RetroArch.StateDir)"
    Write-Info "isolated  : $($Paths.IsolatedRA)"
}

# ----------------------------------------------------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------------------------------------------------
function Invoke-ConquestDev {
    [CmdletBinding()]
    param()
    $ErrorActionPreference = 'Stop'
    $script:NonInteractiveMode = [bool]$NonInteractive
    $script:AssumeYesMode = [bool]$AssumeYes

    $root = $WorkspaceRoot
    if (-not $root) { $root = [IO.Path]::Combine([string]$env:USERPROFILE, 'PokemonConquestDev') }
    $paths = Get-WorkspacePaths $root
    $ra = Get-RetroArchInfo $RetroArchPath $RetroArchConfig

    Write-Host "Pokemon Conquest dev environment - Setup-ConquestDev.ps1 v$($script:ScriptVersion)" -ForegroundColor Cyan
    Write-Host 'Safe by design: never deletes, never overwrites, only reads your ROM/saves. Nothing is uploaded.'

    switch ($Action) {
        'Check' {
            $rows = Get-ToolStatus $ra; Show-ToolStatus $rows
            if ($InstallMissing) { Invoke-InstallMissing $rows }
        }
        'Status' { Show-Status $paths $ra }
        'Verify' { $ok = Invoke-Verify $paths; if (-not $ok) { exit 1 } }
        'Recon' { Invoke-Recon $paths }
        'SelfTest' { Invoke-SelfTest }
        'BackupRetroArchSaves' {
            if (-not $RomPath) { $RomPath = Get-OriginalRomPath $paths }
            if (-not $ra.Exe -and -not $ra.ConfigPath) { throw 'RetroArch not found; pass -RetroArchPath / -RetroArchConfig.' }
            if (-not $RomPath) { throw 'Pass -RomPath (the ROM name you normally play, to match its save files).' }
            [void](Invoke-BackupRetroArchSaves $paths $ra $RomPath)
        }
        'LaunchIsolated' {
            if (-not $ExperimentalRom) { throw 'Pass -ExperimentalRom <path inside the workspace experimental or output folder>.' }
            $orig = Get-OriginalRomPath $paths
            $plan = Get-IsolatedLaunchPlan -Paths $paths -RetroArch $ra -Rom $ExperimentalRom -Core $CorePath -OriginalRom $orig
            Invoke-IsolatedLaunch $plan -DoLaunch:$Launch
        }
        'Setup' {
            $rows = Get-ToolStatus $ra
            Show-ToolStatus $rows
            if ($InstallMissing) { Invoke-InstallMissing $rows; $rows = Get-ToolStatus $ra }
            $missingRequired = @($rows | Where-Object { $_.Need -eq 'Required' -and -not $_.Found })
            if ($missingRequired.Count -gt 0) { Write-Warn 'Required tools are missing. Setup of the workspace and ROM copy continues; install them (or use -InstallMissing) before building/analysing.' }

            Assert-WorkspaceLocationSafe $paths.Root $ra
            Write-Section "Workspace: $($paths.Root)"
            if (-not (Test-Path -LiteralPath $paths.Root)) {
                if (-not (Confirm-Action "Create the workspace folder '$($paths.Root)' and its sub-folders?" -Safe)) { Write-Info 'Cancelled.'; return }
            }
            New-Workspace $paths

            try { [void](Start-Transcript -Path (Get-UnusedPath ([IO.Path]::Combine($paths.Logs, 'setup_' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.log'))) -ErrorAction Stop) } catch { Write-Verbose "Transcript unavailable: $_" }

            $romSource = Select-Rom $RomPath $ra $RomSearchPath
            $header = Read-NdsHeaderInfo $romSource
            Write-Section 'ROM check'
            Write-Info "file   : $($header.Path)"
            Write-Info "title  : $($header.Title)   code: $($header.GameCode)   region: $($header.Region)   size: $($header.Length) bytes"
            if ($header.IsConquest) { Write-Ok 'game code is a known Pokemon Conquest release' } else {
                Write-Warn "game code '$($header.GameCode)' is not a known Pokemon Conquest code (VPYT/VPYJ/VPYP)."
                if (-not (Confirm-Action 'Continue anyway?')) { throw 'Cancelled: not a Pokemon Conquest ROM.' }
            }
            if ($header.HeaderCrcValid) { Write-Ok 'header CRC is valid' } else { Write-Warn "header CRC mismatch (stored 0x$($header.HeaderCrcStored.ToString('X4')), computed 0x$($header.HeaderCrcComputed.ToString('X4'))) - modified or damaged dump?" }
            if (Test-IsUnderPath $romSource $paths.Root) { Write-Warn 'The ROM is already inside the workspace; it will still be copied into original\.' }

            Write-Section 'Copy ROM into the workspace (source is only read)'
            $registered = Register-OriginalRom $romSource $paths $header
            if ($registered.Action -ne 'SkippedConflict') {
                $mp = Write-RomManifest $paths $registered $header $romSource
                Write-Ok "manifest: $mp"
                Write-WorkspaceSettings $paths $ra $registered
            }

            Write-Section 'Next steps'
            Write-Info '1. Read-only analysis : .\tools\windows\Setup-ConquestDev.ps1 -Action Recon'
            Write-Info '2. Back up your saves : .\tools\windows\Setup-ConquestDev.ps1 -Action BackupRetroArchSaves   (explicit, copy-only)'
            Write-Info '3. Test an experiment : .\tools\windows\Setup-ConquestDev.ps1 -Action LaunchIsolated -ExperimentalRom <file in experimental\>'
            Write-Info 'Your normal RetroArch setup and playthrough are untouched.'
            if ($registered.Action -ne 'SkippedConflict' -and (Confirm-Action 'Run the read-only ROM analysis now? (needs the .NET SDK; builds RomRecon first)')) { Invoke-Recon $paths }
            try { Stop-Transcript | Out-Null } catch { Write-Verbose 'no transcript running' }
        }
    }
}

# Dot-sourcing (. .\Setup-ConquestDev.ps1) loads the functions without running anything - used by the Pester tests.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-ConquestDev
}
