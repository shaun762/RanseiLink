<#
.SYNOPSIS
    Prepares diagnostic TEXT for sharing with an AI reviewer: refuses anything that is not plain text, redacts identifying or
    sensitive values, and writes the result to a NEW file. Nothing is uploaded or sent anywhere.

.DESCRIPTION
    Implements AGENTS.md rule 7 ("only send text-based diagnostic results"). It will REFUSE to process:
      * binary data (NUL bytes or control characters), including anything that looks like a ROM, save, dump or decompressed code
      * files other than .txt .json .log .md .csv
      * file names such as gap.bin, *.nds, *.sav, *.state, arm9*.bin, *_decompressed.bin
      * files larger than -MaxKB (default 256 KB)
    It redacts: Windows user name and profile paths, computer name, e-mail addresses, URLs with credentials, passwords/tokens/API keys
    in "key = value" lines (including RetroArch cheevos_*/netplay_* settings), long token-like strings, IP and MAC addresses and
    product-key-shaped strings. SHA-256/SHA-1/MD5 hashes are kept (they identify your ROM dump, which is useful and not sensitive).
    ALWAYS read the result before pasting it. Redaction is pattern-based and cannot know everything that is private to you.

    Never overwrites: the output is a new file (shareable_<name>_<timestamp>.txt). The input is only read.
    Compatible with Windows PowerShell 5.1 and PowerShell 7+. Makes no network calls.

.PARAMETER Path
    One or more text files (for example RomRecon's report.txt).
.PARAMETER OutDir
    Where to put the redacted copies (default: a "shareable" folder next to the first input).
.PARAMETER Show
    Also print the redacted text to the console.
.PARAMETER Copy
    Also put the redacted text of the (last) file on the clipboard.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)][string[]]$Path,
    [string]$OutDir,
    [int]$MaxKB = 256,
    [switch]$Show,
    [switch]$Copy
)

$script:ShareableExtensions = @('.txt', '.json', '.log', '.md', '.csv')
$script:RefusedNamePattern = '(?i)\.(nds|dsi|srl|sav|srm|dsv|bin|dat|state\d*|savestate|pac|link|ncgr|nclr|ncer|nanr|nsbmd|nsbtx|zip|7z|rar|gz|png|exe|dll)$|_decompressed|(^|[\\/])gap\.bin$|(^|[\\/])arm[79]|(^|[\\/])overlay'

function Test-ShareableTextFile([string]$File, [int]$MaxKB = 256) {
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return [pscustomobject]@{ Ok = $false; Reason = 'file not found' } }
    $name = [IO.Path]::GetFileName($File)
    $ext = [IO.Path]::GetExtension($File).ToLowerInvariant()
    if ($name -match $script:RefusedNamePattern) { return [pscustomobject]@{ Ok = $false; Reason = "the name '$name' looks like ROM/save/dump/binary data, which must never be shared" } }
    if ($script:ShareableExtensions -notcontains $ext) { return [pscustomobject]@{ Ok = $false; Reason = "only $($script:ShareableExtensions -join ' ') files can be prepared (got '$ext')" } }
    $len = (Get-Item -LiteralPath $File).Length
    if ($len -gt ($MaxKB * 1KB)) { return [pscustomobject]@{ Ok = $false; Reason = "file is $([Math]::Round($len / 1KB)) KB (limit $MaxKB KB) - too big to be a diagnostic report" } }
    $bytes = [IO.File]::ReadAllBytes($File)
    foreach ($b in $bytes) {
        if ($b -eq 0 -or ($b -lt 0x20 -and $b -ne 9 -and $b -ne 10 -and $b -ne 13) -or $b -eq 0x7F) {
            return [pscustomobject]@{ Ok = $false; Reason = 'contains binary/control bytes, so it is not plain text' }
        }
    }
    try { [void](New-Object Text.UTF8Encoding($false, $true)).GetString($bytes) } catch { return [pscustomobject]@{ Ok = $false; Reason = 'is not valid UTF-8 text' } }
    return [pscustomobject]@{ Ok = $true; Reason = '' }
}

function ConvertTo-RedactedText {
    param([Parameter(Mandatory = $true)][string]$Text, [string]$UserName = [Environment]::UserName, [string]$ComputerName = [Environment]::MachineName)
    $counts = [ordered]@{}
    $apply = {
        param([string]$category, [string]$pattern, $replacement)
        $script:__n = 0
        $evaluator = if ($replacement -is [Text.RegularExpressions.MatchEvaluator]) { $replacement } else { [Text.RegularExpressions.MatchEvaluator] { param($m) $script:__n++; $m.Result($replacement) } }
        $result = [regex]::Replace($script:__text, $pattern, $evaluator)
        if ($script:__n -gt 0) { $counts[$category] = $script:__n }
        $script:__text = $result
    }
    $script:__text = $Text
    # key = value secrets (RetroArch cheevos_*, netplay_*, and anything named like a credential)
    & $apply 'secret-setting' '(?im)^(\s*(?:cheevos_(?:username|password|token)|netplay_(?:nickname|password|spectate_password|ip_address|custom_mitm_server)|ai_service_url|[A-Za-z0-9_]*(?:password|passwd|secret|token|api_?key)[A-Za-z0-9_]*)\s*[=:]\s*).*$' '${1}<redacted>'
    & $apply 'url-credentials' '(?i)\b([a-z][a-z0-9+.\-]*://)[^/\s:@]+:[^/\s@]+@' '${1}<redacted>@'
    & $apply 'email' '\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b' '<email>'
    & $apply 'profile-path' '(?i)([A-Z]:\\Users\\)[^\\\s"''<>|]+' '${1}<user>'
    & $apply 'profile-path' '(?<=/(?:home|Users)/)[^/\s"'']+' '<user>'
    if ($UserName -and $UserName.Length -ge 2) { & $apply 'user-name' ('(?i)(?<![A-Za-z0-9])' + [regex]::Escape($UserName) + '(?![A-Za-z0-9])') '<user>' }
    if ($ComputerName -and $ComputerName.Length -ge 2) { & $apply 'computer-name' ('(?i)(?<![A-Za-z0-9])' + [regex]::Escape($ComputerName) + '(?![A-Za-z0-9])') '<computer>' }
    & $apply 'product-key' '\b[A-Z0-9]{5}(?:-[A-Z0-9]{5}){4}\b' '<product-key>'
    & $apply 'mac-address' '\b(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b' '<mac>'
    & $apply 'ip-address' '\b(?!127\.|0\.)(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b' '<ip>'
    # long token-like strings: letters AND digits, 32+ chars, but keep plain hex hashes (MD5/SHA-1/SHA-256 lengths)
    $tokenEvaluator = [Text.RegularExpressions.MatchEvaluator] {
        param($m)
        $v = $m.Value
        if ($v -match '^[0-9a-fA-F]+$' -and ($v.Length -eq 32 -or $v.Length -eq 40 -or $v.Length -eq 64)) { return $v }
        if ($v -match '[A-Za-z]' -and $v -match '\d') { $script:__n++; return '<token>' }
        return $v
    }
    & $apply 'long-token' '\b[A-Za-z0-9+/_=\-]{32,}\b' $tokenEvaluator
    $out = $script:__text
    Remove-Variable -Scope Script -Name __text, __n -ErrorAction SilentlyContinue
    return [pscustomobject]@{ Text = $out; Counts = $counts }
}

function Get-UnusedShareablePath([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $Path }
    $dir = [IO.Path]::GetDirectoryName($Path); $base = [IO.Path]::GetFileNameWithoutExtension($Path); $ext = [IO.Path]::GetExtension($Path)
    $n = 2
    while ($true) { $c = [IO.Path]::Combine($dir, "${base}_$n$ext"); if (-not (Test-Path -LiteralPath $c)) { return $c }; $n++ }
}

function Export-ShareableText {
    param([string[]]$Files, [string]$OutDirectory, [int]$MaxKB = 256, [switch]$ShowText, [switch]$CopyToClipboard)
    $failed = 0
    foreach ($f in $Files) {
        $check = Test-ShareableTextFile $f $MaxKB
        if (-not $check.Ok) { Write-Host "[REFUSED] $f : $($check.Reason)" -ForegroundColor Red; $failed++; continue }
        $raw = [IO.File]::ReadAllText($f)
        $red = ConvertTo-RedactedText $raw
        $summary = if ($red.Counts.Count -eq 0) { 'none found' } else { ($red.Counts.GetEnumerator() | ForEach-Object { "$($_.Key) x$($_.Value)" }) -join ', ' }
        $header = "# REDACTED copy of '$([IO.Path]::GetFileName($f))' prepared $((Get-Date).ToString('yyyy-MM-dd HH:mm')) by Export-ShareableText.ps1`r`n# Redactions: $summary`r`n# Plain text only; contains no ROM data. REVIEW IT before sharing.`r`n`r`n"
        $dir = $OutDirectory
        if (-not $dir) { $dir = [IO.Path]::Combine([IO.Path]::GetDirectoryName((Resolve-Path -LiteralPath $f).Path), 'shareable') }
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        $target = Get-UnusedShareablePath ([IO.Path]::Combine($dir, 'shareable_' + [IO.Path]::GetFileNameWithoutExtension($f) + '_' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.txt'))
        $fs = [IO.File]::Open($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($header + $red.Text); $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
        Write-Host "[OK] $f -> $target" -ForegroundColor Green
        Write-Host "     redactions: $summary"
        if ($ShowText) { Write-Host ''; Write-Host ($header + $red.Text) }
        if ($CopyToClipboard) { Set-Clipboard -Value ($header + $red.Text); Write-Host '     (copied to the clipboard)' }
    }
    return $failed
}

if ($MyInvocation.InvocationName -ne '.') {
    $failedCount = Export-ShareableText -Files $Path -OutDirectory $OutDir -MaxKB $MaxKB -ShowText:$Show -CopyToClipboard:$Copy
    if ($failedCount -gt 0) { exit 1 }
}
