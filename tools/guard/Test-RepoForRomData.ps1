<#
.SYNOPSIS
    Blocks ROMs, saves, ROM-derived binaries and unexplained binary files from entering the git repository.

.DESCRIPTION
    Implements the technical side of the ROM-handling rules in AGENTS.md. It inspects file CONTENT, not just names:
    a Nintendo DS ROM renamed to "notes.txt" is still caught by its header structure.

    Modes
      Staged : files staged for commit (used by the pre-commit hook)
      Range  : files added/changed between -Base and -Head (pre-push hook, CI pull requests)
      All    : every tracked file (CI full scan)
      Paths  : explicit files on disk (-Path)

    Rules (a finding fails the check, exit code 1)
      forbidden-name   ROM/save/state/dump file names (*.nds, *.sav, *.srm, arm9*.bin, *_decompressed.bin, gap.bin, ...)
      forbidden-dir    paths inside PokemonConquestDev/, rom_dumps/, recon_*/
      nds-rom          file content has the structure of an NDS ROM header (any extension, any game, any region)
      archive          .zip/.7z/.rar/... (could hide a ROM)                       [allowlistable]
      oversize         larger than -MaxFileMB                                    [allowlistable]
      binary           contains binary data and is not listed in the allowlist    [allowlistable]

    forbidden-name, forbidden-dir and nds-rom can NEVER be allowlisted.
    The allowlist (tools/guard/binary-allowlist.txt) holds repo-relative paths/globs, one per line, '#' starts a comment.
    Adding to it is a visible, reviewable change.

    Limits: a git hook can be bypassed with --no-verify, and only sees what git sees. CI re-runs this check on every pull
    request. Neither stops you from uploading a file by other means; AGENTS.md rule 1 still applies.

    Fails CLOSED: any internal error exits with code 2 and blocks the commit/push/CI job.
    Compatible with Windows PowerShell 5.1 and PowerShell 7+. Makes no network calls.
#>
[CmdletBinding()]
param(
    [ValidateSet('Staged', 'Range', 'All', 'Paths')]
    [string]$Mode = 'Staged',
    [string]$Base,
    [string]$Head = 'HEAD',
    [string[]]$Path,
    [string]$RepoRoot,
    [string]$AllowlistPath,
    [int]$MaxFileMB = 5,
    [switch]$Quiet
)

$script:ForbiddenNamePatterns = @(
    '(?i)\.(nds|dsi|srl|sav|srm|dsv|savestate)$',
    '(?i)\.state(\d+|\.auto)?$',
    '(?i)(^|/)arm[79][^/]*\.bin$',
    '(?i)(^|/)overlay[^/]*\.bin$',
    '(?i)_decompressed\.bin$',
    '(?i)(^|/)gap\.bin$',
    '(?i)(^|/)y9\.bin$'
)
$script:ForbiddenDirPatterns = @('(?i)(^|/)PokemonConquestDev(/|$)', '(?i)(^|/)rom_dumps(/|$)', '(?i)(^|/)recon_[0-9a-f]{8}_')
$script:ArchivePattern = '(?i)\.(zip|7z|rar|gz|tgz|xz|bz2|tar|cab|iso)$'

function Get-GuardRepoRoot([string]$Hint) {
    if ($Hint) { return (Resolve-Path -LiteralPath $Hint).Path }
    $r = & git rev-parse --show-toplevel 2>$null
    if (-not $r) { throw 'Not inside a git repository (use -RepoRoot).' }
    return $r.Trim()
}

function Invoke-GitText([string]$Repo, [string[]]$GitArgs) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = 'git'
    $psi.WorkingDirectory = $Repo
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.Arguments = (($GitArgs | ForEach-Object { if ($_ -match '[\s"]') { '"' + $_.Replace('"', '\"') + '"' } else { $_ } }) -join ' ')
    $p = [Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEnd()
    [void]$p.StandardError.ReadToEnd()
    $p.WaitForExit()
    if ($p.ExitCode -ne 0) { return $null }
    return $out
}

# Reads at most $Count bytes of a git object (index entry or revision blob) without loading huge blobs into memory.
function Get-GitBlobPrefix([string]$Repo, [string]$Spec, [int]$Count) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = 'git'
    $psi.WorkingDirectory = $Repo
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.Arguments = 'cat-file blob "' + $Spec.Replace('"', '\"') + '"'
    $p = [Diagnostics.Process]::Start($psi)
    try {
        $buf = New-Object byte[] $Count
        $total = 0
        $stream = $p.StandardOutput.BaseStream
        while ($total -lt $Count) {
            $n = $stream.Read($buf, $total, $Count - $total)
            if ($n -le 0) { break }
            $total += $n
        }
        $result = New-Object byte[] $total
        [Array]::Copy($buf, $result, $total)
        return $result
    }
    finally {
        if (-not $p.HasExited) { try { $p.Kill() } catch { Write-Verbose 'process already ended' } }
        [void]$p.StandardError.ReadToEnd()
    }
}

function Get-GitBlobSize([string]$Repo, [string]$Spec) {
    $out = Invoke-GitText $Repo @('cat-file', '-s', $Spec)
    if ($null -eq $out) { return -1 }
    return [long]$out.Trim()
}

# Structural test for an NDS ROM header (GBATEK layout). Header CRC is deliberately NOT required so hacked/patched ROMs are caught too.
function Test-NdsRomHeader([byte[]]$Prefix, [long]$FileSize) {
    if ($Prefix.Length -lt 0x200 -or $FileSize -lt 0x4000) { return $false }
    for ($i = 0x0C; $i -lt 0x10; $i++) {
        $c = $Prefix[$i]
        if (-not (($c -ge 0x30 -and $c -le 0x39) -or ($c -ge 0x41 -and $c -le 0x5A))) { return $false }
    }
    for ($i = 0; $i -lt 12; $i++) { if ($Prefix[$i] -ne 0 -and ($Prefix[$i] -lt 0x20 -or $Prefix[$i] -gt 0x7E)) { return $false } }
    function U32([int]$o) { return [BitConverter]::ToUInt32($Prefix, $o) }
    $arm9Off = U32 0x20; $arm9Size = U32 0x2C; $arm7Off = U32 0x30; $arm7Size = U32 0x3C
    $fntOff = U32 0x40; $fntSize = U32 0x44; $fatOff = U32 0x48; $fatSize = U32 0x4C
    if ($arm9Off -lt 0x200 -or $arm9Size -eq 0 -or ([long]$arm9Off + $arm9Size) -gt $FileSize) { return $false }
    if ($arm7Off -lt 0x200 -or $arm7Size -eq 0 -or ([long]$arm7Off + $arm7Size) -gt $FileSize) { return $false }
    if ($fntSize -eq 0 -or ([long]$fntOff + $fntSize) -gt $FileSize) { return $false }
    if ($fatSize -eq 0 -or ([long]$fatOff + $fatSize) -gt $FileSize) { return $false }
    return $true
}

function Test-ContainsBinaryData([byte[]]$Prefix) {
    $limit = [Math]::Min($Prefix.Length, 8192)
    for ($i = 0; $i -lt $limit; $i++) { if ($Prefix[$i] -eq 0) { return $true } }
    return $false
}

function Read-GuardAllowlist([string]$File) {
    $entries = New-Object System.Collections.Generic.List[string]
    if ($File -and (Test-Path -LiteralPath $File)) {
        foreach ($line in [IO.File]::ReadAllLines($File)) {
            $t = ($line -replace '#.*$', '').Trim()
            if ($t) { $entries.Add($t.Replace('\', '/')) }
        }
    }
    return $entries.ToArray()
}

function Test-IsAllowlisted([string]$RelPath, [string[]]$Allowlist) {
    foreach ($a in $Allowlist) {
        if ($RelPath -like $a -or $RelPath -ieq $a) { return $true }
    }
    return $false
}

# Prefix reader for a candidate. Candidates are plain data (Kind = git|disk) so no closures are needed (closures break function
# lookup when the script is launched through some wrappers, e.g. GitHub Actions' "pwsh -command"). Tests may supply a GetPrefix scriptblock.
function Get-CandidatePrefix($Candidate, [int]$Count) {
    if ($Candidate.PSObject.Properties['GetPrefix']) { return (, (& $Candidate.GetPrefix $Count)) }
    switch ($Candidate.Kind) {
        'git' { return (, (Get-GitBlobPrefix $Candidate.Repo $Candidate.Spec $Count)) }
        'disk' { return (, (Read-DiskPrefix $Candidate.Full $Count)) }
        default { throw "Unknown candidate kind '$($Candidate.Kind)' for $($Candidate.Path)" }
    }
}

# Core: $Candidates are objects with Path (repo-relative, forward slashes), Size and either (Kind, Repo, Spec | Full) or GetPrefix.
function Get-GuardFindings {
    param([object[]]$Candidates, [string[]]$Allowlist, [int]$MaxFileMB = 5)
    $findings = New-Object System.Collections.Generic.List[object]
    foreach ($c in $Candidates) {
        $p = $c.Path.Replace('\', '/')
        $add = { param($rule, $msg) $findings.Add([pscustomobject]@{ Path = $p; Rule = $rule; Message = $msg }) }
        foreach ($pat in $script:ForbiddenNamePatterns) { if ($p -match $pat) { & $add 'forbidden-name' 'ROM/save/state/dump file names may never be committed.'; break } }
        foreach ($pat in $script:ForbiddenDirPatterns) { if ($p -match $pat) { & $add 'forbidden-dir' 'Workspace, dump and diagnostics folders may never be committed.'; break } }
        $prefix = [byte[]](Get-CandidatePrefix $c 16384)
        if (Test-NdsRomHeader $prefix $c.Size) { & $add 'nds-rom' 'Content has the structure of a Nintendo DS ROM (commercial or not). ROMs may never be committed or uploaded.' }
        $allowed = Test-IsAllowlisted $p $Allowlist
        if (-not $allowed) {
            if ($p -match $script:ArchivePattern) { & $add 'archive' 'Archives can hide ROMs. Not allowed unless added to tools/guard/binary-allowlist.txt in a reviewed change.' }
            if ($c.Size -gt ([long]$MaxFileMB * 1MB)) { & $add 'oversize' "File is $([Math]::Round($c.Size / 1MB, 1)) MB (limit $MaxFileMB MB)." }
            if (Test-ContainsBinaryData $prefix) { & $add 'binary' 'Binary file that is not in tools/guard/binary-allowlist.txt. If it is original work (not derived from a ROM), add it there in a reviewed change.' }
        }
    }
    return $findings.ToArray()
}

function Get-GuardCandidates {
    param([string]$Mode, [string]$Repo, [string]$Base, [string]$Head, [string[]]$Path)
    $list = New-Object System.Collections.Generic.List[object]
    switch ($Mode) {
        'Staged' {
            $names = Invoke-GitText $Repo @('diff', '--cached', '--name-only', '--diff-filter=ACMR', '-z')
            foreach ($n in @($names -split "`0" | Where-Object { $_ })) {
                $spec = ':' + $n
                $list.Add([pscustomobject]@{ Path = $n; Size = (Get-GitBlobSize $Repo $spec); Kind = 'git'; Repo = $Repo; Spec = $spec })
            }
        }
        'Range' {
            if (-not $Base) { throw '-Mode Range needs -Base <ref>.' }
            $mb = (Invoke-GitText $Repo @('merge-base', $Base, $Head))
            $from = if ($mb) { $mb.Trim() } else { $Base }
            $names = Invoke-GitText $Repo @('diff', '--name-only', '--diff-filter=ACMR', '-z', "$from..$Head")
            foreach ($n in @($names -split "`0" | Where-Object { $_ })) {
                $spec = $Head + ':' + $n
                $list.Add([pscustomobject]@{ Path = $n; Size = (Get-GitBlobSize $Repo $spec); Kind = 'git'; Repo = $Repo; Spec = $spec })
            }
        }
        'All' {
            $names = Invoke-GitText $Repo @('ls-files', '-z')
            foreach ($n in @($names -split "`0" | Where-Object { $_ })) {
                $full = [IO.Path]::Combine($Repo, $n)
                if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
                $list.Add([pscustomobject]@{ Path = $n; Size = (Get-Item -LiteralPath $full -Force).Length; Kind = 'disk'; Full = $full })
            }
        }
        'Paths' {
            foreach ($f in $Path) {
                $full = (Resolve-Path -LiteralPath $f).Path
                $rel = $full
                if ($full.StartsWith($Repo, [StringComparison]::OrdinalIgnoreCase)) { $rel = $full.Substring($Repo.Length).TrimStart('\', '/') }
                $list.Add([pscustomobject]@{ Path = $rel; Size = (Get-Item -LiteralPath $full -Force).Length; Kind = 'disk'; Full = $full })
            }
        }
    }
    return $list.ToArray()
}

function Read-DiskPrefix([string]$File, [int]$Count) {
    $fs = [IO.File]::Open($File, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $buf = New-Object byte[] $Count
        $n = $fs.Read($buf, 0, $Count)
        $r = New-Object byte[] $n
        [Array]::Copy($buf, $r, $n)
        return $r
    }
    finally { $fs.Dispose() }
}

function Invoke-RomGuard {
    $ErrorActionPreference = 'Stop'   # a check that errors out must never look like a check that passed
    try { return (Invoke-RomGuardCore) }
    catch {
        Write-Host ''
        Write-Host "ROM guard could not complete and therefore REFUSES (fail closed): $($_.Exception.Message)" -ForegroundColor Red
        return 2
    }
}

function Invoke-RomGuardCore {
    $repo = Get-GuardRepoRoot $RepoRoot
    $allowFile = $AllowlistPath
    if (-not $allowFile) { $allowFile = [IO.Path]::Combine($repo, 'tools', 'guard', 'binary-allowlist.txt') }
    $allow = Read-GuardAllowlist $allowFile
    $cands = Get-GuardCandidates -Mode $Mode -Repo $repo -Base $Base -Head $Head -Path $Path
    $findings = @(Get-GuardFindings -Candidates $cands -Allowlist $allow -MaxFileMB $MaxFileMB)
    if (-not $Quiet) { Write-Host ("ROM guard ({0}): checked {1} file(s)." -f $Mode, @($cands).Count) }
    if ($findings.Count -gt 0) {
        Write-Host ''
        Write-Host "ROM guard FAILED - $($findings.Count) problem(s):" -ForegroundColor Red
        foreach ($f in $findings) { Write-Host ("  [{0}] {1}`n      {2}" -f $f.Rule, $f.Path, $f.Message) -ForegroundColor Red }
        Write-Host ''
        Write-Host 'Never commit or push ROMs, saves, save states, dumps or ROM-derived binaries (see AGENTS.md). Unstage/remove the file; do not bypass this check.' -ForegroundColor Yellow
        return 1
    }
    if (-not $Quiet) { Write-Host 'ROM guard: OK' -ForegroundColor Green }
    return 0
}

if ($MyInvocation.InvocationName -ne '.') {
    exit (Invoke-RomGuard)
}
