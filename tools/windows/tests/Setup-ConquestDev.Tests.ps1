# Pester 5 tests for Setup-ConquestDev.ps1. Uses ONLY synthetic, obviously fake files - no ROMs, no RetroArch.
# Run:  Invoke-Pester -Path tools/windows/tests

BeforeAll {
    $script:ScriptPath = (Resolve-Path ([IO.Path]::Combine($PSScriptRoot, '..', 'Setup-ConquestDev.ps1'))).Path
    . $script:ScriptPath                 # dot-sourcing must define functions without running anything
    $script:NonInteractiveMode = $true
    $script:AssumeYesMode = $false
    Mock Write-Host {}

    function New-FakeNds {
        param([string]$Path, [string]$GameCode = 'VPYT', [switch]$BadCrc, [int]$Size = 0x800)
        $b = New-Object byte[] $Size
        [Text.Encoding]::ASCII.GetBytes('FAKETITLE').CopyTo($b, 0)
        [Text.Encoding]::ASCII.GetBytes($GameCode).CopyTo($b, 0x0C)
        for ($i = 0x200; $i -lt $Size; $i++) { $b[$i] = [byte](($i * 31) % 251) }
        $crc = Get-Crc16 $b 0 0x15E
        if ($BadCrc) { $crc = ($crc + 1) -band 0xFFFF }
        [BitConverter]::GetBytes([uint16]$crc).CopyTo($b, 0x15E)
        [IO.File]::WriteAllBytes($Path, $b)
        return $Path
    }

    function New-FakeRetroArch {
        param([string]$Root, [switch]$WithCore, [string]$ExtraCfg = '')
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $Root 'retroarch.exe'), [byte[]](1, 2, 3))
        New-Item -ItemType Directory -Path (Join-Path $Root 'cores') -Force | Out-Null
        if ($WithCore) { [IO.File]::WriteAllBytes(([IO.Path]::Combine($Root, 'cores', 'melondsds_libretro.dll')), [byte[]](9)) }
        $cfg = @('savefile_directory = ":\saves"', 'savestate_directory = ":\states"', 'libretro_directory = ":\cores"', 'playlist_directory = ":\playlists"', 'config_save_on_exit = "true"') -join "`n"
        [IO.File]::WriteAllText((Join-Path $Root 'retroarch.cfg'), $cfg + "`n" + $ExtraCfg)
        foreach ($d in 'saves', 'states', 'playlists') { New-Item -ItemType Directory -Path (Join-Path $Root $d) -Force | Out-Null }
        return $Root
    }

    function Get-Tree([string]$Dir) {
        Get-ChildItem -LiteralPath $Dir -Recurse -File | Sort-Object FullName | ForEach-Object { '{0}|{1}|{2}' -f $_.FullName, $_.Length, (Get-FileSha256 $_.FullName) }
    }
}

Describe 'Script hygiene' {
    It 'is ASCII only (Windows PowerShell 5.1 reads BOM-less files as ANSI)' {
        $bytes = [IO.File]::ReadAllBytes($script:ScriptPath)
        ($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }
    It 'parses without errors' {
        $errs = $null; $tokens = $null
        [void][Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$tokens, [ref]$errs)
        $errs.Count | Should -Be 0
    }
    It 'contains no delete or overwrite primitives' {
        $text = Get-Content -LiteralPath $script:ScriptPath -Raw
        $text | Should -Not -Match 'Remove-Item'
        $text | Should -Not -Match '\[IO\.File\]::Delete'
        $text | Should -Not -Match '\bdel\s'
        $text | Should -Not -Match 'Move-Item'
        $text | Should -Not -Match 'Set-Content'
        $text | Should -Not -Match 'Out-File'
        $text | Should -Not -Match 'Copy-Item'
        $text | Should -Not -Match 'FileMode\]::Create\b'
        $text | Should -Not -Match 'FileMode\]::Truncate'
    }
    It 'defines its functions when dot-sourced without running the main flow' {
        Get-Command Invoke-ConquestDev -ErrorAction Stop | Should -Not -BeNullOrEmpty
        Get-Command Get-IsolatedLaunchPlan -ErrorAction Stop | Should -Not -BeNullOrEmpty
    }
}

Describe 'Path helpers' {
    It 'treats a sibling with a shared name prefix as NOT inside' {
        Test-IsUnderPath '/a/bc' '/a/b' | Should -BeFalse
        Test-IsUnderPath '/a/b/c' '/a/b' | Should -BeTrue
        Test-IsUnderPath '/a/b' '/a/b' | Should -BeTrue
        Test-IsUnderPath '/a/b/' '/a/b' | Should -BeTrue
    }
    It 'detects overlap in either direction' {
        Test-PathsOverlap '/x/saves' '/x/saves/sub' | Should -BeTrue
        Test-PathsOverlap '/x/saves/sub' '/x/saves' | Should -BeTrue
        Test-PathsOverlap '/x/saves' '/x/savesX' | Should -BeFalse
    }
    It 'finds a git root above a path' {
        $repo = Join-Path $TestDrive 'repo'
        New-Item -ItemType Directory -Path (Join-Path $repo '.git'), ([IO.Path]::Combine($repo, 'a', 'b')) -Force | Out-Null
        Find-GitRoot ([IO.Path]::Combine($repo, 'a', 'b')) | Should -Be (Get-NormalizedPath $repo)
        Find-GitRoot (Join-Path $TestDrive 'nowhere') | Should -BeNullOrEmpty
    }
}

Describe 'CRC and NDS header' {
    It 'matches the CRC-16/MODBUS check value' {
        Get-Crc16 ([Text.Encoding]::ASCII.GetBytes('123456789')) 0 9 | Should -Be 0x4B37
    }
    It 'parses a valid header' {
        $p = New-FakeNds (Join-Path $TestDrive 'ok.nds') -GameCode 'VPYJ'
        $h = Read-NdsHeaderInfo $p
        $h.GameCode | Should -Be 'VPYJ'
        $h.Region | Should -Be 'Japan'
        $h.IsConquest | Should -BeTrue
        $h.HeaderCrcValid | Should -BeTrue
        $h.Title | Should -Be 'FAKETITLE'
    }
    It 'flags a bad CRC and an unknown game code' {
        $h = Read-NdsHeaderInfo (New-FakeNds (Join-Path $TestDrive 'bad.nds') -GameCode 'ABCD' -BadCrc)
        $h.HeaderCrcValid | Should -BeFalse
        $h.IsConquest | Should -BeFalse
        $h.Region | Should -Be 'unknown'
    }
    It 'rejects tiny files, missing files and archives with a clear message' {
        $tiny = Join-Path $TestDrive 'tiny.nds'; [IO.File]::WriteAllBytes($tiny, [byte[]](1, 2, 3))
        { Read-NdsHeaderInfo $tiny } | Should -Throw '*too small*'
        { Read-NdsHeaderInfo (Join-Path $TestDrive 'nope.nds') } | Should -Throw '*not found*'
        $zip = Join-Path $TestDrive 'g.zip'; [IO.File]::WriteAllBytes($zip, (New-Object byte[] 1000))
        { Read-NdsHeaderInfo $zip } | Should -Throw '*archive*'
    }
    It 'never modifies the file it reads' {
        $p = New-FakeNds (Join-Path $TestDrive 'ro.nds')
        $before = Get-FileSha256 $p; $t = (Get-Item $p).LastWriteTimeUtc
        Set-ItemProperty -LiteralPath $p -Name IsReadOnly -Value $true
        try { [void](Read-NdsHeaderInfo $p) } finally { Set-ItemProperty -LiteralPath $p -Name IsReadOnly -Value $false }
        Get-FileSha256 $p | Should -Be $before
        (Get-Item $p).LastWriteTimeUtc | Should -Be $t
    }
}

Describe 'Copying never overwrites' {
    It 'copies, verifies the hash, and leaves the source alone' {
        $src = New-FakeNds (Join-Path $TestDrive 'src.nds'); $dst = [IO.Path]::Combine($TestDrive, 'out', 'copy.nds')
        $before = Get-FileSha256 $src; $t = (Get-Item $src).LastWriteTimeUtc
        $r = Copy-FileNoOverwrite -Source $src -Destination $dst
        $r.Verified | Should -BeTrue
        Get-FileSha256 $dst | Should -Be $before
        Get-FileSha256 $src | Should -Be $before
        (Get-Item $src).LastWriteTimeUtc | Should -Be $t
    }
    It 'refuses to replace an existing destination and leaves it byte-identical' {
        $src = New-FakeNds (Join-Path $TestDrive 's2.nds'); $dst = Join-Path $TestDrive 'existing.bin'
        [IO.File]::WriteAllBytes($dst, [byte[]](7, 7, 7))
        { Copy-FileNoOverwrite -Source $src -Destination $dst } | Should -Throw
        [IO.File]::ReadAllBytes($dst) | Should -Be ([byte[]](7, 7, 7))
    }
    It 'can copy a read-only source' {
        $src = New-FakeNds (Join-Path $TestDrive 's3.nds'); $dst = Join-Path $TestDrive 'c3.nds'
        Set-ItemProperty -LiteralPath $src -Name IsReadOnly -Value $true
        try { (Copy-FileNoOverwrite -Source $src -Destination $dst).Verified | Should -BeTrue } finally { Set-ItemProperty -LiteralPath $src -Name IsReadOnly -Value $false }
    }
    It 'Get-UnusedPath and Write-NewTextFile pick fresh names' {
        $p = Join-Path $TestDrive 'note.txt'
        $a = Write-NewTextFile $p 'one'; $b = Write-NewTextFile $p 'two'
        $a | Should -Be $p
        $b | Should -Not -Be $p
        Get-Content -LiteralPath $p -Raw | Should -Be 'one'
        Get-Content -LiteralPath $b -Raw | Should -Be 'two'
    }
}

Describe 'Workspace and original ROM registration' {
    BeforeEach {
        $script:ws = Get-WorkspacePaths (Join-Path $TestDrive ('ws_' + [guid]::NewGuid().ToString('N')))
        $script:rom = New-FakeNds (Join-Path $TestDrive ('rom_' + [guid]::NewGuid().ToString('N') + '.nds'))
        $script:hdr = Read-NdsHeaderInfo $script:rom
    }
    It 'creates every folder and keeps pre-existing files untouched' {
        New-Item -ItemType Directory -Path $script:ws.Original -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:ws.Original 'README.txt'), 'mine')
        New-Workspace $script:ws
        foreach ($sub in 'original', 'experimental', 'output', 'diagnostics', 'backups', 'manifests', 'logs', 'emulator') { Test-Path (Join-Path $script:ws.Root $sub) | Should -BeTrue }
        Get-Content (Join-Path $script:ws.Original 'README.txt') -Raw | Should -Be 'mine'
    }
    It 'copies the ROM into original, marks it read-only and keeps the source identical' {
        New-Workspace $script:ws
        $before = Get-FileSha256 $script:rom; $t = (Get-Item $script:rom).LastWriteTimeUtc
        $reg = Register-OriginalRom $script:rom $script:ws $script:hdr
        $reg.Action | Should -Be 'Copied'
        $reg.Sha256 | Should -Be $before
        (Get-Item $reg.Path).IsReadOnly | Should -BeTrue
        Get-FileSha256 $script:rom | Should -Be $before
        (Get-Item $script:rom).LastWriteTimeUtc | Should -Be $t
    }
    It 'is idempotent: a second registration reports AlreadyPresent and changes nothing' {
        New-Workspace $script:ws
        [void](Register-OriginalRom $script:rom $script:ws $script:hdr)
        $tree = Get-Tree $script:ws.Original
        (Register-OriginalRom $script:rom $script:ws $script:hdr).Action | Should -Be 'AlreadyPresent'
        Get-Tree $script:ws.Original | Should -Be $tree
    }
    It 'never overwrites a different file of the same name (non-interactive => skipped)' {
        New-Workspace $script:ws
        $dest = Join-Path $script:ws.Original ([IO.Path]::GetFileName($script:rom))
        [IO.File]::WriteAllBytes($dest, [byte[]](1, 2, 3, 4))
        $reg = Register-OriginalRom $script:rom $script:ws $script:hdr
        $reg.Action | Should -Be 'SkippedConflict'
        [IO.File]::ReadAllBytes($dest) | Should -Be ([byte[]](1, 2, 3, 4))
    }
    It 'writes a manifest that matches the copy, and never replaces an existing manifest' {
        New-Workspace $script:ws
        $reg = Register-OriginalRom $script:rom $script:ws $script:hdr
        $m1 = Write-RomManifest $script:ws $reg $script:hdr $script:rom
        $j = Get-Content $m1 -Raw | ConvertFrom-Json
        $j.sha256 | Should -Be $reg.Sha256
        $j.gameCode | Should -Be 'VPYT'
        $before = Get-FileSha256 $m1
        # same file again: the existing manifest is reused, nothing new is written
        (Write-RomManifest $script:ws $reg $script:hdr $script:rom) | Should -Be $m1
        @(Get-ChildItem $script:ws.Manifests -Filter '*.json').Count | Should -Be 1
        # a different file with the same name must get its own manifest and must not replace the first
        $other = [pscustomobject]@{ Path = $reg.Path; Sha256 = ('0' * 64) }
        $m3 = Write-RomManifest $script:ws $other $script:hdr $script:rom
        $m3 | Should -Not -Be $m1
        Get-FileSha256 $m1 | Should -Be $before
    }
    It 'Verify passes, then detects a tampered original' {
        New-Workspace $script:ws
        $reg = Register-OriginalRom $script:rom $script:ws $script:hdr
        [void](Write-RomManifest $script:ws $reg $script:hdr $script:rom)
        Invoke-Verify $script:ws | Should -BeTrue
        Set-ItemProperty -LiteralPath $reg.Path -Name IsReadOnly -Value $false
        [IO.File]::WriteAllBytes($reg.Path, [byte[]](0, 0, 0))
        Invoke-Verify $script:ws | Should -BeFalse
    }
    It 'refuses workspace locations inside a git tree or overlapping RetroArch folders' {
        $ra = [pscustomobject]@{ Dir = (Join-Path $TestDrive 'RA'); SaveDir = ([IO.Path]::Combine($TestDrive, 'RA', 'saves')); StateDir = ([IO.Path]::Combine($TestDrive, 'RA', 'states')) }
        $repo = Join-Path $TestDrive 'somerepo'; New-Item -ItemType Directory -Path (Join-Path $repo '.git') -Force | Out-Null
        { Assert-WorkspaceLocationSafe (Join-Path $repo 'ws') $ra } | Should -Throw '*git working tree*'
        { Assert-WorkspaceLocationSafe ([IO.Path]::Combine($TestDrive, 'RA', 'ws')) $ra } | Should -Throw '*RetroArch*'
        { Assert-WorkspaceLocationSafe ([IO.Path]::Combine($TestDrive, 'RA', 'saves', 'ws')) $ra } | Should -Throw
        { Assert-WorkspaceLocationSafe (Join-Path $TestDrive 'clean_ws') $ra } | Should -Not -Throw
    }
}

Describe 'RetroArch detection' {
    It 'resolves :\\ relative, default and absolute directories' {
        $d = Join-Path $TestDrive 'RAx'
        Resolve-RetroArchDirectory ':\saves' $d 'saves' | Should -Be (Get-NormalizedPath (Join-Path $d 'saves'))
        Resolve-RetroArchDirectory 'default' $d 'states' | Should -Be (Get-NormalizedPath (Join-Path $d 'states'))
        Resolve-RetroArchDirectory '' $d 'cores' | Should -Be (Get-NormalizedPath (Join-Path $d 'cores'))
        Resolve-RetroArchDirectory (Join-Path $TestDrive 'abs') $d 'x' | Should -Be (Get-NormalizedPath (Join-Path $TestDrive 'abs'))
    }
    It 'reads a config and finds exe, cores and directories from a folder hint' {
        $root = New-FakeRetroArch (Join-Path $TestDrive 'RetroArch') -WithCore
        $info = Get-RetroArchInfo $root $null
        $info.Exe | Should -Be (Get-NormalizedPath (Join-Path $root 'retroarch.exe'))
        $info.SaveDir | Should -Be (Get-NormalizedPath (Join-Path $root 'saves'))
        $info.Cores.Count | Should -Be 1
        $info.Config['config_save_on_exit'] | Should -Be 'true'
    }
    It 'does not modify the owner config while reading it' {
        $root = New-FakeRetroArch (Join-Path $TestDrive 'RA2') -WithCore
        $before = Get-FileSha256 (Join-Path $root 'retroarch.cfg')
        [void](Get-RetroArchInfo $root $null)
        Get-FileSha256 (Join-Path $root 'retroarch.cfg') | Should -Be $before
    }
    It 'finds Conquest ROMs from playlists and ignores other games' {
        $root = New-FakeRetroArch (Join-Path $TestDrive 'RA3') -WithCore
        $good = New-FakeNds (Join-Path $TestDrive 'Pokemon Conquest.nds') 'VPYT'
        $other = New-FakeNds (Join-Path $TestDrive 'Other Game.nds') 'ABCD'
        $lpl = @{ version = '1.5'; items = @(@{ path = $good; label = 'Pokemon Conquest' }, @{ path = $other; label = 'Conquest Fake' }, @{ path = 'C:\gone\x.nds'; label = 'Pokemon Conquest' }) } | ConvertTo-Json -Depth 4
        [IO.File]::WriteAllText(([IO.Path]::Combine($root, 'playlists', 'Nintendo - DS.lpl')), $lpl)
        $c = @(Find-ConquestRomCandidates (Get-RetroArchInfo $root $null) @())
        $c.Count | Should -Be 1
        $c[0].GameCode | Should -Be 'VPYT'
    }
}

Describe 'Save backup is explicit, copy-only and verified' {
    BeforeEach {
        $script:raRoot = New-FakeRetroArch (Join-Path $TestDrive ('RA_' + [guid]::NewGuid().ToString('N'))) -WithCore
        $script:ra = Get-RetroArchInfo $script:raRoot $null
        $script:ws = Get-WorkspacePaths (Join-Path $TestDrive ('wsb_' + [guid]::NewGuid().ToString('N')))
        New-Workspace $script:ws
        New-Item -ItemType Directory -Path ([IO.Path]::Combine($script:raRoot, 'saves', 'melonDS DS')), (Join-Path $script:raRoot 'states') -Force | Out-Null
        [IO.File]::WriteAllBytes(([IO.Path]::Combine($script:raRoot, 'saves', 'melonDS DS', 'Pokemon Conquest.srm')), [byte[]](1, 2, 3, 4))
        [IO.File]::WriteAllBytes(([IO.Path]::Combine($script:raRoot, 'states', 'Pokemon Conquest.state1')), [byte[]](5, 6, 7))
        [IO.File]::WriteAllBytes(([IO.Path]::Combine($script:raRoot, 'saves', 'Other Game.srm')), [byte[]](9))
        $script:romFile = Join-Path $TestDrive 'Pokemon Conquest.nds'
    }
    It 'finds saves (including per-core sub-folders) and states by ROM name only' {
        $f = @(Find-RetroArchSaveFiles $script:ra 'Pokemon Conquest' $null)
        $f.Count | Should -Be 2
        ($f | Where-Object { $_.FullName -like '*Other Game*' }) | Should -BeNullOrEmpty
    }
    It 'looks beside the ROM only when retroarch.cfg says saves live in the content folder, and not recursively' {
        $romDir = Join-Path $TestDrive ('roms_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $romDir 'sub') -Force | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $romDir 'Pokemon Conquest.srm'), [byte[]](1))
        [IO.File]::WriteAllBytes(([IO.Path]::Combine($romDir, 'sub', 'Pokemon Conquest.srm')), [byte[]](2))
        @(Find-RetroArchSaveFiles $script:ra 'Pokemon Conquest' $romDir | Where-Object { $_.Kind -eq 'next-to-rom' }).Count | Should -Be 0
        $inContent = $script:ra.PSObject.Copy(); $inContent.SaveInContentDir = $true
        $beside = @(Find-RetroArchSaveFiles $inContent 'Pokemon Conquest' $romDir | Where-Object { $_.Kind -eq 'next-to-rom' })
        $beside.Count | Should -Be 1
    }
    It 'does nothing unless the BACKUP phrase is typed (non-interactive => cancelled)' {
        $before = Get-Tree $script:raRoot
        Invoke-BackupRetroArchSaves $script:ws $script:ra $script:romFile | Should -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath $script:ws.Backups -Directory).Count | Should -Be 0
        Get-Tree $script:raRoot | Should -Be $before
    }
    It 'does nothing when the wrong phrase is typed' {
        Mock Test-IsInteractive { $true }
        Mock Read-Host { 'backup' }
        Invoke-BackupRetroArchSaves $script:ws $script:ra $script:romFile | Should -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath $script:ws.Backups -Directory).Count | Should -Be 0
    }
    It 'copies verified, read-only backups with a manifest and leaves every original untouched' {
        Mock Test-IsInteractive { $true }
        Mock Read-Host { 'BACKUP' }
        $before = Get-Tree $script:raRoot
        $dest = Invoke-BackupRetroArchSaves $script:ws $script:ra $script:romFile
        $dest | Should -Not -BeNullOrEmpty
        Get-Tree $script:raRoot | Should -Be $before            # sources unchanged, nothing moved or deleted
        $m = Get-Content (Join-Path $dest 'backup_manifest.json') -Raw | ConvertFrom-Json
        @($m.files).Count | Should -Be 2
        @($m.files | Where-Object { -not $_.verified }).Count | Should -Be 0
        foreach ($f in $m.files) { (Get-FileSha256 $f.backup) | Should -Be $f.sha256 }
        (Get-Item $m.files[0].backup).IsReadOnly | Should -BeTrue
    }
    It 'a second backup goes to a new folder and never touches the first' {
        Mock Test-IsInteractive { $true }
        Mock Read-Host { 'BACKUP' }
        $d1 = Invoke-BackupRetroArchSaves $script:ws $script:ra $script:romFile
        $t1 = Get-Tree $d1
        $d2 = Invoke-BackupRetroArchSaves $script:ws $script:ra $script:romFile
        $d2 | Should -Not -Be $d1
        Get-Tree $d1 | Should -Be $t1
    }
}

Describe 'Isolated launch cannot reach the real playthrough' {
    BeforeEach {
        $script:raRoot = New-FakeRetroArch (Join-Path $TestDrive ('RAi_' + [guid]::NewGuid().ToString('N'))) -WithCore
        $script:ra = Get-RetroArchInfo $script:raRoot $null
        $script:ws = Get-WorkspacePaths (Join-Path $TestDrive ('wsi_' + [guid]::NewGuid().ToString('N')))
        New-Workspace $script:ws
        $script:exp = New-FakeNds (Join-Path $script:ws.Experimental 'exp_test.nds')
        $script:orig = New-FakeNds (Join-Path $script:ws.Original 'Pokemon Conquest.nds')
    }
    It 'builds a plan that uses a config COPY and an appended override file' {
        $p = Get-IsolatedLaunchPlan -Paths $script:ws -RetroArch $script:ra -Rom $script:exp -OriginalRom $script:orig
        $p.Arguments[0] | Should -Be '--config'
        $p.Arguments[1] | Should -Be ('"' + (Join-Path $script:ws.IsolatedRA 'retroarch.cfg') + '"')
        $p.Arguments[2] | Should -Be '--appendconfig'
        $p.ConfigCopy | Should -Not -Be $script:ra.ConfigPath
        $p.OverrideText | Should -Match 'config_save_on_exit = "false"'
        $p.OverrideText | Should -Match 'savestate_auto_load = "false"'
        $p.OverrideText | Should -Match 'history_list_enable = "false"'
        $p.OverrideText | Should -Match ([regex]::Escape('savefile_directory = "' + (Join-Path $script:ws.IsolatedRA 'saves') + '"'))
    }
    It 'never points saves, states or playlists at the owner directories' {
        $p = Get-IsolatedLaunchPlan -Paths $script:ws -RetroArch $script:ra -Rom $script:exp
        Test-PathsOverlap $p.SaveDir $script:ra.SaveDir | Should -BeFalse
        Test-PathsOverlap $p.StateDir $script:ra.StateDir | Should -BeFalse
        $p.OverrideText | Should -Not -Match ([regex]::Escape($script:ra.SaveDir))
        $p.OverrideText | Should -Not -Match ([regex]::Escape($script:ra.PlaylistDir))
        $p.WatchedOwnerDirs | Should -Contain $script:ra.SaveDir
    }
    It 'refuses ROMs outside experimental/output' {
        $outside = New-FakeNds (Join-Path $TestDrive 'elsewhere.nds')
        { Get-IsolatedLaunchPlan -Paths $script:ws -RetroArch $script:ra -Rom $outside } | Should -Throw '*only ROMs inside*'
    }
    It 'refuses the original ROM' {
        { Get-IsolatedLaunchPlan -Paths $script:ws -RetroArch $script:ra -Rom $script:orig -OriginalRom $script:orig } | Should -Throw
    }
    It 'accepts a ROM in the output folder' {
        $o = New-FakeNds (Join-Path $script:ws.Output 'patched.nds')
        { Get-IsolatedLaunchPlan -Paths $script:ws -RetroArch $script:ra -Rom $o } | Should -Not -Throw
    }
    It 'refuses when the isolated folders would overlap the owner save or state folder' {
        $evil = $script:ra.PSObject.Copy(); $evil.SaveDir = (Join-Path $script:ws.IsolatedRA 'saves')
        { Get-IsolatedLaunchPlan -Paths $script:ws -RetroArch $evil -Rom $script:exp } | Should -Throw '*overlaps your real RetroArch*'
        $evil2 = $script:ra.PSObject.Copy(); $evil2.StateDir = $script:ws.Root
        { Get-IsolatedLaunchPlan -Paths $script:ws -RetroArch $evil2 -Rom $script:exp } | Should -Throw '*overlaps*'
    }
    It 'refuses without RetroArch, config or core' {
        $noExe = [pscustomobject]@{ Exe = $null; ConfigPath = $null; Cores = @(); SaveDir = $null; StateDir = $null; Dir = $null; PlaylistDir = $null }
        { Get-IsolatedLaunchPlan -Paths $script:ws -RetroArch $noExe -Rom $script:exp } | Should -Throw '*not found*'
        $noCore = New-FakeRetroArch (Join-Path $TestDrive ('RAnc_' + [guid]::NewGuid().ToString('N')))
        { Get-IsolatedLaunchPlan -Paths $script:ws -RetroArch (Get-RetroArchInfo $noCore $null) -Rom $script:exp } | Should -Throw '*core*'
    }
    It 'dry run starts nothing and writes nothing' {
        Mock Start-Process {}
        $p = Get-IsolatedLaunchPlan -Paths $script:ws -RetroArch $script:ra -Rom $script:exp
        $before = Get-Tree $script:ws.Root
        Invoke-IsolatedLaunch $p
        Should -Invoke Start-Process -Times 0 -Exactly
        Get-Tree $script:ws.Root | Should -Be $before
    }
    It 'launch needs confirmation, then copies the config, writes overrides and launches with -Wait' {
        Mock Start-Process {}
        Mock Confirm-Action { $true }
        $p = Get-IsolatedLaunchPlan -Paths $script:ws -RetroArch $script:ra -Rom $script:exp
        $ownerBefore = Get-Tree $script:raRoot
        Invoke-IsolatedLaunch $p -DoLaunch
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { $Wait }
        Test-Path $p.ConfigCopy | Should -BeTrue
        Test-Path $p.OverridesPath | Should -BeTrue
        Get-Tree $script:raRoot | Should -Be $ownerBefore       # owner's config/saves untouched
    }
    It 'launch is skipped when the user says no' {
        Mock Start-Process {}
        Mock Confirm-Action { $false }
        $p = Get-IsolatedLaunchPlan -Paths $script:ws -RetroArch $script:ra -Rom $script:exp
        Invoke-IsolatedLaunch $p -DoLaunch
        Should -Invoke Start-Process -Times 0 -Exactly
    }
    It 'tripwire notices a change in the owner folders' {
        $a = Get-DirectorySnapshot $script:ra.SaveDir
        [IO.File]::WriteAllBytes((Join-Path $script:ra.SaveDir 'x.srm'), [byte[]](1))
        $b = Get-DirectorySnapshot $script:ra.SaveDir
        Test-SnapshotsEqual $a $b | Should -BeFalse
        Test-SnapshotsEqual $b (Get-DirectorySnapshot $script:ra.SaveDir) | Should -BeTrue
    }
    It 'refuses to continue if an existing overrides file differs (never overwrites)' {
        Mock Start-Process {}
        Mock Confirm-Action { $true }
        $p = Get-IsolatedLaunchPlan -Paths $script:ws -RetroArch $script:ra -Rom $script:exp
        New-Item -ItemType Directory -Path $script:ws.IsolatedRA -Force | Out-Null
        [IO.File]::WriteAllText($p.OverridesPath, 'savefile_directory = "C:\\real\\saves"')
        { Invoke-IsolatedLaunch $p -DoLaunch } | Should -Throw '*differs*'
        Should -Invoke Start-Process -Times 0 -Exactly
        Get-Content $p.OverridesPath -Raw | Should -Be 'savefile_directory = "C:\\real\\saves"'
    }
}

Describe 'Cloud-synchronised locations are refused' {
    It 'recognises well-known sync folder names anywhere in the path' {
        foreach ($leaf in 'OneDrive', 'OneDrive - Personal', 'OneDrive - Contoso Ltd', 'Dropbox', 'Dropbox (Personal)', 'Google Drive', 'GoogleDrive', 'My Drive', 'iCloudDrive', 'Box', 'MEGA', 'pCloud Drive', 'Nextcloud') {
            Test-IsCloudSyncedPath ([IO.Path]::Combine($TestDrive, $leaf, 'Games', 'PokemonConquestDev')) | Should -Not -BeNullOrEmpty -Because $leaf
        }
    }
    It 'does not flag ordinary folders' {
        Test-IsCloudSyncedPath ([IO.Path]::Combine($TestDrive, 'PokemonConquestDev')) | Should -BeNullOrEmpty
        Test-IsCloudSyncedPath ([IO.Path]::Combine($TestDrive, 'OneDriveBackupNotes', 'x')) | Should -BeNullOrEmpty
    }
    It 'honours the OneDrive environment variables' {
        $od = [IO.Path]::Combine($TestDrive, 'redirected_od'); New-Item -ItemType Directory -Path $od | Out-Null
        $old = $env:OneDriveConsumer; $env:OneDriveConsumer = $od
        try {
            Test-IsCloudSyncedPath ([IO.Path]::Combine($od, 'x', 'ws')) | Should -Match 'OneDriveConsumer'
            Test-IsCloudSyncedPath ([IO.Path]::Combine($TestDrive, 'elsewhere')) | Should -BeNullOrEmpty
        }
        finally { $env:OneDriveConsumer = $old }
    }
    It 'detects sync marker folders in any ancestor' {
        $root = [IO.Path]::Combine($TestDrive, 'dbx_root'); New-Item -ItemType Directory -Path ([IO.Path]::Combine($root, '.dropbox')), ([IO.Path]::Combine($root, 'a', 'b')) -Force | Out-Null
        Test-IsCloudSyncedPath ([IO.Path]::Combine($root, 'a', 'b', 'ws')) | Should -Match 'sync marker'
    }
    It 'follows a junction/symlink into a cloud folder' {
        $cloud = [IO.Path]::Combine($TestDrive, 'OneDrive', 'inner'); New-Item -ItemType Directory -Path $cloud -Force | Out-Null
        $link = [IO.Path]::Combine($TestDrive, 'innocent_link')
        $type = if ([Environment]::OSVersion.Platform -eq 'Win32NT') { 'Junction' } else { 'SymbolicLink' }
        New-Item -ItemType $type -Path $link -Target $cloud | Out-Null
        Test-IsCloudSyncedPath $link | Should -Match 'link'
    }
    It 'Assert-WorkspaceLocationSafe throws for a workspace in OneDrive and the message explains why' {
        $ra = [pscustomobject]@{ Dir = [IO.Path]::Combine($TestDrive, 'RAx'); SaveDir = $null; StateDir = $null }
        { Assert-WorkspaceLocationSafe ([IO.Path]::Combine($TestDrive, 'OneDrive', 'PokemonConquestDev')) $ra } | Should -Throw '*cloud-synchronised*'
    }
}

Describe 'The setup script makes no network calls' {
    It 'contains no network primitives (winget, used only with -InstallMissing and confirmation, is the one external program)' {
        $text = Get-Content -LiteralPath $script:ScriptPath -Raw
        $text | Should -Not -Match '(?i)Invoke-WebRequest|Invoke-RestMethod|\biwr\b|\birm\b|WebClient|HttpClient|Start-BitsTransfer|System\.Net|Send-MailMessage|\bcurl\b|\bwget\b|Test-NetConnection|\bscp\b|\bssh\b|Install-Module|Save-Module'
    }
}

Describe 'Confirmation helper' {
    It 'answers no when non-interactive' {
        $script:NonInteractiveMode = $true
        Confirm-Action 'x' | Should -BeFalse
        Confirm-Action 'x' -Safe | Should -BeFalse
    }
    It '-AssumeYes only affects -Safe prompts' {
        $script:AssumeYesMode = $true
        try {
            Confirm-Action 'x' -Safe | Should -BeTrue
            Confirm-Action 'x' | Should -BeFalse
            Read-Phrase 'type' 'BACKUP' | Should -BeFalse
        }
        finally { $script:AssumeYesMode = $false }
    }
}

Describe 'End to end: the script run as a user would run it' {
    BeforeAll {
        # The current host may be the 'dotnet' muxer (pwsh installed as a dotnet tool); handle both.
        $hostPath = (Get-Process -Id $PID).Path
        if ($hostPath -match '[\\/]dotnet(\.exe)?$') { $script:pwshExe = $hostPath; $script:pwshPrefix = @((Join-Path $PSHOME 'pwsh.dll')) }
        else { $script:pwshExe = $hostPath; $script:pwshPrefix = @() }
        function Invoke-ChildPwsh {
            param([string[]]$Arguments)
            # Windows PowerShell 5.1 wraps a native command's stderr lines in ErrorRecords and Pester runs tests with
            # $ErrorActionPreference = 'Stop', which would turn the child's (expected) error output into a terminating error.
            $previous = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try { & $script:pwshExe @($script:pwshPrefix + @('-NoProfile', '-File', $script:ScriptPath) + $Arguments) 2>&1 | ForEach-Object { $_.ToString() } | Out-String }
            finally { $ErrorActionPreference = $previous }
        }
        $script:raRoot = New-FakeRetroArch (Join-Path $TestDrive 'RA_e2e') -WithCore
    }
    It 'sets up the workspace from a ROM path non-interactively, twice, without touching the source' {
        $rom = New-FakeNds (Join-Path $TestDrive 'Pokemon Conquest (USA).nds')
        $ws = Join-Path $TestDrive 'e2e_ws'
        $before = Get-FileSha256 $rom; $t = (Get-Item $rom).LastWriteTimeUtc
        $args1 = @('-Action', 'Setup', '-WorkspaceRoot', $ws, '-RomPath', $rom, '-RetroArchPath', $script:raRoot, '-NonInteractive', '-AssumeYes')
        [void](Invoke-ChildPwsh $args1)
        $LASTEXITCODE | Should -Be 0
        foreach ($d in 'original', 'experimental', 'output', 'diagnostics', 'backups', 'manifests', 'logs', 'emulator') { Test-Path (Join-Path $ws $d) | Should -BeTrue }
        $copy = [IO.Path]::Combine($ws, 'original', 'Pokemon Conquest (USA).nds')
        Get-FileSha256 $copy | Should -Be $before
        (Get-Item $copy).IsReadOnly | Should -BeTrue
        @(Get-ChildItem (Join-Path $ws 'manifests') -Filter '*.json').Count | Should -Be 1
        Test-Path (Join-Path $ws 'workspace.json') | Should -BeTrue
        $tree = Get-Tree $ws | Where-Object { $_ -notmatch '[\\/]logs[\\/]' }
        $out2 = Invoke-ChildPwsh $args1
        $LASTEXITCODE | Should -Be 0
        ($out2 -match 'already present and identical') | Should -BeTrue
        @(Get-Tree $ws | Where-Object { $_ -notmatch '[\\/]logs[\\/]' }) | Should -Be @($tree)
        Get-FileSha256 $rom | Should -Be $before
        (Get-Item $rom).LastWriteTimeUtc | Should -Be $t
        # the owner's RetroArch tree is untouched too
        Get-ChildItem $script:raRoot -Recurse -File | ForEach-Object { $_.LastWriteTimeUtc -lt (Get-Date).AddMinutes(-0.001) } | Should -Not -Contain $false
    }
    It 'refuses a workspace inside a git repository' {
        $repo = Join-Path $TestDrive 'repo_e2e'; New-Item -ItemType Directory -Path (Join-Path $repo '.git') -Force | Out-Null
        $rom = New-FakeNds (Join-Path $TestDrive 'r2.nds')
        $out = Invoke-ChildPwsh @('-Action', 'Setup', '-WorkspaceRoot', (Join-Path $repo 'ws'), '-RomPath', $rom, '-RetroArchPath', $script:raRoot, '-NonInteractive', '-AssumeYes')
        $LASTEXITCODE | Should -Not -Be 0
        $out | Should -Match 'git working tree'
        Test-Path (Join-Path $repo 'ws') | Should -BeFalse
    }
    It 'requires -RomPath when non-interactive instead of guessing' {
        $out = Invoke-ChildPwsh @('-Action', 'Setup', '-WorkspaceRoot', (Join-Path $TestDrive 'ws_norom'), '-RetroArchPath', $script:raRoot, '-NonInteractive', '-AssumeYes')
        $LASTEXITCODE | Should -Not -Be 0
        $out | Should -Match 'No ROM given'
    }
    It 'Check reports tools and does not create a workspace' {
        $ws = Join-Path $TestDrive 'ws_check'
        $out = Invoke-ChildPwsh @('-Action', 'Check', '-WorkspaceRoot', $ws, '-RetroArchPath', $script:raRoot, '-NonInteractive')
        $LASTEXITCODE | Should -Be 0
        $out | Should -Match 'Tools'
        Test-Path $ws | Should -BeFalse
    }
}
