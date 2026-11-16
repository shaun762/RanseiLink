# Pester 5 tests for tools/guard. Uses only synthetic data: the "ROM" is a fabricated header-shaped byte array, never real game data.

BeforeAll {
    $script:GuardDir = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:GuardScript = Join-Path $script:GuardDir 'Test-RepoForRomData.ps1'
    . $script:GuardScript
    Mock Write-Host {}

    $hostPath = (Get-Process -Id $PID).Path
    if ($hostPath -match '[\\/]dotnet(\.exe)?$') { $script:PwshExe = $hostPath; $script:PwshPrefix = @((Join-Path $PSHOME 'pwsh.dll')) }
    else { $script:PwshExe = $hostPath; $script:PwshPrefix = @() }
    $script:IsWindowsHost = ([Environment]::OSVersion.Platform -eq 'Win32NT')

    function New-FakeNdsBytes {
        param([int]$Size = 0x8000, [string]$GameCode = 'ABCD')
        $b = New-Object byte[] $Size
        [Text.Encoding]::ASCII.GetBytes('FAKETITLE').CopyTo($b, 0)
        [Text.Encoding]::ASCII.GetBytes($GameCode).CopyTo($b, 0x0C)
        function Put([int]$o, [uint32]$v) { [BitConverter]::GetBytes($v).CopyTo($b, $o) }
        Put 0x20 0x4000; Put 0x2C 0x800      # ARM9
        Put 0x30 0x5000; Put 0x3C 0x400      # ARM7
        Put 0x40 0x6000; Put 0x44 0x100      # FNT
        Put 0x48 0x6200; Put 0x4C 0x80       # FAT
        return $b
    }

    function Invoke-GuardProcess {
        param([string[]]$Arguments, [string]$WorkDir)
        $previous = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        Push-Location $WorkDir
        try {
            $out = & $script:PwshExe @($script:PwshPrefix + @('-NoProfile', '-File', $script:GuardScript) + $Arguments) 2>&1 | ForEach-Object { $_.ToString() } | Out-String
            return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
        }
        finally { Pop-Location; $ErrorActionPreference = $previous }
    }

    function New-TestRepo {
        $dir = Join-Path $TestDrive ('repo_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        git -C $dir init -q -b main
        git -C $dir config user.email 'test@example.invalid'
        git -C $dir config user.name 'Test'
        git -C $dir config commit.gpgsign false
        [IO.File]::WriteAllText((Join-Path $dir 'README.md'), 'hello')
        git -C $dir add README.md
        git -C $dir commit -q -m init
        return $dir
    }

    function Get-Candidate([string]$Name, [byte[]]$Bytes) {
        $copy = $Bytes
        [pscustomobject]@{ Path = $Name; Size = $copy.Length; GetPrefix = { param($n) $take = [Math]::Min($n, $copy.Length); $r = New-Object byte[] $take; [Array]::Copy($copy, $r, $take); , $r }.GetNewClosure() }
    }
}

Describe 'NDS ROM header detection (content based)' {
    It 'recognises a ROM-shaped header regardless of region or game' {
        foreach ($code in 'VPYT', 'VPYJ', 'ABCD', 'A9Z0') {
            $b = New-FakeNdsBytes -GameCode $code
            Test-NdsRomHeader $b $b.Length | Should -BeTrue
        }
    }
    It 'does not need a valid header CRC (hacked ROMs are caught too)' {
        $b = New-FakeNdsBytes
        [BitConverter]::GetBytes([uint16]0x1234).CopyTo($b, 0x15E)
        Test-NdsRomHeader $b $b.Length | Should -BeTrue
    }
    It 'rejects text, random data, short data and inconsistent headers' {
        $text = [Text.Encoding]::ASCII.GetBytes('x' * 0x9000)
        Test-NdsRomHeader $text $text.Length | Should -BeFalse
        $rng = New-Object byte[] 0x9000; (New-Object Random 42).NextBytes($rng)
        Test-NdsRomHeader $rng $rng.Length | Should -BeFalse
        Test-NdsRomHeader (New-Object byte[] 100) 100 | Should -BeFalse
        $b = New-FakeNdsBytes; [BitConverter]::GetBytes([uint32]0x7FFFFFFF).CopyTo($b, 0x2C)   # ARM9 size beyond the file
        Test-NdsRomHeader $b $b.Length | Should -BeFalse
    }
}

Describe 'Rules' {
    It 'flags forbidden names and folders' {
        $files = 'game.nds', 'a/b/save.sav', 'x.srm', 'x.state1', 'x.state.auto', 'dumps/arm9.bin', 'out/overlay9_3_decompressed.bin', 'gap.bin', 'PokemonConquestDev/original/x.txt', 'rom_dumps/a.txt', 'recon_0123abcd_20260101/report.txt'
        $c = $files | ForEach-Object { Get-Candidate $_ ([Text.Encoding]::ASCII.GetBytes('plain text')) }
        $f = @(Get-GuardFindings -Candidates $c -Allowlist @())
        foreach ($name in $files) { ($f | Where-Object { $_.Path -eq $name }) | Should -Not -BeNullOrEmpty -Because $name }
    }
    It 'catches a ROM hidden behind an innocent name' {
        $f = @(Get-GuardFindings -Candidates @(Get-Candidate 'docs/notes.txt' (New-FakeNdsBytes)) -Allowlist @())
        ($f | Where-Object Rule -eq 'nds-rom') | Should -Not -BeNullOrEmpty
    }
    It 'passes ordinary text, source and a text file that merely mentions a game code' {
        $c = @((Get-Candidate 'a.cs' ([Text.Encoding]::UTF8.GetBytes('class A {}'))), (Get-Candidate 'b.md' ([Text.Encoding]::UTF8.GetBytes('VPYT VPYJ VPYP'))))
        @(Get-GuardFindings -Candidates $c -Allowlist @()).Count | Should -Be 0
    }
    It 'flags unlisted binaries and archives, and honours the allowlist for them' {
        $bin = New-Object byte[] 500; $bin[10] = 0; for ($i = 20; $i -lt 120; $i++) { $bin[$i] = 7 }
        $f = @(Get-GuardFindings -Candidates @((Get-Candidate 'img/new.png' $bin), (Get-Candidate 'x/data.zip' ([Text.Encoding]::ASCII.GetBytes('PK text')))) -Allowlist @())
        ($f | Where-Object { $_.Path -eq 'img/new.png' -and $_.Rule -eq 'binary' }) | Should -Not -BeNullOrEmpty
        ($f | Where-Object { $_.Path -eq 'x/data.zip' -and $_.Rule -eq 'archive' }) | Should -Not -BeNullOrEmpty
        @(Get-GuardFindings -Candidates @(Get-Candidate 'img/new.png' $bin) -Allowlist @('img/new.png')).Count | Should -Be 0
        @(Get-GuardFindings -Candidates @(Get-Candidate 'img/new.png' $bin) -Allowlist @('img/*')).Count | Should -Be 0
    }
    It 'flags oversize files' {
        $c = [pscustomobject]@{ Path = 'big.txt'; Size = 3MB; GetPrefix = { param($n) , ([byte[]][Text.Encoding]::ASCII.GetBytes('text')) } }
        @(Get-GuardFindings -Candidates @($c) -Allowlist @() -MaxFileMB 1 | Where-Object Rule -eq 'oversize').Count | Should -Be 1
        @(Get-GuardFindings -Candidates @($c) -Allowlist @() -MaxFileMB 5).Count | Should -Be 0
    }
    It 'NEVER lets the allowlist excuse ROMs, saves or dump names' {
        $c = @((Get-Candidate 'x.nds' ([Text.Encoding]::ASCII.GetBytes('t'))), (Get-Candidate 'notes.txt' (New-FakeNdsBytes)), (Get-Candidate 'a/arm9.bin' ([Text.Encoding]::ASCII.GetBytes('t'))))
        @(Get-GuardFindings -Candidates $c -Allowlist @('*', 'x.nds', 'notes.txt', 'a/arm9.bin')).Count | Should -BeGreaterOrEqual 3
    }
    It 'parses the allowlist (comments, blanks, backslashes)' {
        $f = Join-Path $TestDrive 'allow.txt'
        [IO.File]::WriteAllText($f, "# comment`n`nimg\a.png   # why`n  docs/*.png`n")
        Read-GuardAllowlist $f | Should -Be @('img/a.png', 'docs/*.png')
    }
    It 'ships an allowlist that covers every currently tracked binary (baseline is clean)' {
        $root = (Resolve-Path ([IO.Path]::Combine($script:GuardDir, '..', '..'))).Path
        $r = Invoke-GuardProcess @('-Mode', 'All', '-RepoRoot', $root) $root
        $r.ExitCode | Should -Be 0 -Because $r.Output
    }
}

Describe 'Modes on a real git repository' {
    It 'Staged: blocks a ROM disguised as a .txt and checks the STAGED content, not the working tree' {
        $repo = New-TestRepo
        [IO.File]::WriteAllBytes((Join-Path $repo 'notes.txt'), (New-FakeNdsBytes))
        git -C $repo add notes.txt
        [IO.File]::WriteAllText((Join-Path $repo 'notes.txt'), 'innocent text now')   # working tree changed after staging
        $r = Invoke-GuardProcess @('-Mode', 'Staged', '-RepoRoot', $repo) $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'nds-rom'
    }
    It 'Staged: allows ordinary files' {
        $repo = New-TestRepo
        [IO.File]::WriteAllText((Join-Path $repo 'a.txt'), 'hello')
        git -C $repo add a.txt
        (Invoke-GuardProcess @('-Mode', 'Staged', '-RepoRoot', $repo) $repo).ExitCode | Should -Be 0
    }
    It 'Range: flags a ROM committed on a branch, passes a clean branch' {
        $repo = New-TestRepo
        git -C $repo checkout -q -b clean; [IO.File]::WriteAllText((Join-Path $repo 'c.txt'), 'c'); git -C $repo add c.txt; git -C $repo commit -q -m c
        (Invoke-GuardProcess @('-Mode', 'Range', '-Base', 'main', '-Head', 'clean', '-RepoRoot', $repo) $repo).ExitCode | Should -Be 0
        git -C $repo checkout -q -b dirty main
        [IO.File]::WriteAllBytes((Join-Path $repo 'rom.dat'), (New-FakeNdsBytes)); git -C $repo add rom.dat; git -C $repo commit -q --no-verify -m rom
        $r = Invoke-GuardProcess @('-Mode', 'Range', '-Base', 'main', '-Head', 'dirty', '-RepoRoot', $repo) $repo
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'rom.dat'
    }
    It 'All: scans every tracked file' {
        $repo = New-TestRepo
        [IO.File]::WriteAllBytes((Join-Path $repo 'sneaky.bin'), (New-FakeNdsBytes)); git -C $repo add sneaky.bin; git -C $repo commit -q -m s
        (Invoke-GuardProcess @('-Mode', 'All', '-RepoRoot', $repo) $repo).ExitCode | Should -Be 1
    }
    It 'Paths: checks explicit files' {
        $f = Join-Path $TestDrive 'x.bin'; [IO.File]::WriteAllBytes($f, (New-FakeNdsBytes))
        $repo = New-TestRepo
        (Invoke-GuardProcess @('-Mode', 'Paths', '-Path', $f, '-RepoRoot', $repo) $repo).ExitCode | Should -Be 1
    }
}

Describe 'Git hooks (pre-commit and pre-push)' -Skip:([Environment]::OSVersion.Platform -eq 'Win32NT') {
    BeforeAll {
        # the hooks call "pwsh" from PATH; make sure the host that runs these tests is reachable under that name
        $script:ShimDir = Join-Path $TestDrive 'shim'; New-Item -ItemType Directory -Path $script:ShimDir | Out-Null
        $shim = "#!/bin/sh`nexec `"$($script:PwshExe)`" $($script:PwshPrefix -join ' ') `"`$@`"`n"
        [IO.File]::WriteAllText((Join-Path $script:ShimDir 'pwsh'), $shim)
        chmod +x (Join-Path $script:ShimDir 'pwsh')
        $script:OldPath = $env:PATH
        $env:PATH = $script:ShimDir + [IO.Path]::PathSeparator + $env:PATH

        function New-HookedRepo {
            $repo = New-TestRepo
            Copy-Item -Recurse $script:GuardDir (Join-Path $repo 'guard_tmp')
            New-Item -ItemType Directory -Path (Join-Path $repo 'tools') | Out-Null
            Move-Item (Join-Path $repo 'guard_tmp') ([IO.Path]::Combine($repo, 'tools', 'guard'))
            foreach ($h in 'run-guard.sh', 'pre-commit', 'pre-push') { chmod +x ([IO.Path]::Combine($repo, 'tools', 'guard', 'hooks', $h)) }
            git -C $repo add tools; git -C $repo commit -q --no-verify -m guard
            & ([IO.Path]::Combine($repo, 'tools', 'guard', 'Install-Guards.ps1')) -RepoRoot $repo | Out-Null
            return $repo
        }
    }
    AfterAll { $env:PATH = $script:OldPath }

    It 'Install-Guards sets core.hooksPath for this clone only' {
        $repo = New-HookedRepo
        (git -C $repo config --local --get core.hooksPath) | Should -Be 'tools/guard/hooks'
    }
    It 'pre-commit refuses a ROM and accepts text' {
        $repo = New-HookedRepo
        [IO.File]::WriteAllBytes((Join-Path $repo 'notes.txt'), (New-FakeNdsBytes)); git -C $repo add notes.txt
        git -C $repo commit -q -m 'bad' 2>&1 | Out-Null
        $LASTEXITCODE | Should -Not -Be 0
        (git -C $repo log --oneline | Measure-Object).Count | Should -Be 2   # init + guard only
        git -C $repo reset -q; [IO.File]::WriteAllText((Join-Path $repo 'ok.txt'), 'ok'); git -C $repo add ok.txt
        git -C $repo commit -q -m 'good' 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0
    }
    It 'pre-push refuses to push a ROM that was committed with --no-verify, and allows a clean push' {
        $repo = New-HookedRepo
        $bare = Join-Path $TestDrive ('bare_' + [guid]::NewGuid().ToString('N') + '.git'); git init -q --bare $bare
        git -C $repo remote add origin $bare
        git -C $repo push -q origin main 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0                                   # clean first push
        git -C $repo checkout -q -b topic
        [IO.File]::WriteAllBytes((Join-Path $repo 'x.dat'), (New-FakeNdsBytes)); git -C $repo add x.dat; git -C $repo commit -q --no-verify -m 'sneaky'
        $out = git -C $repo push origin topic 2>&1 | Out-String
        $LASTEXITCODE | Should -Not -Be 0
        $out | Should -Match 'ROM guard FAILED'
        (git -C $bare branch --list topic) | Should -BeNullOrEmpty    # nothing reached the "remote"
    }
    It 'fails closed when no PowerShell can be found' {
        $repo = New-HookedRepo
        $savedPath = $env:PATH; $env:PATH = '/usr/bin:/bin'
        try {
            if (Get-Command pwsh -ErrorAction SilentlyContinue) { Set-ItResult -Skipped -Because 'a pwsh exists in /usr/bin on this machine'; return }
            [IO.File]::WriteAllText((Join-Path $repo 'ok.txt'), 'ok'); git -C $repo add ok.txt
            git -C $repo commit -q -m 'x' 2>&1 | Out-Null
            $LASTEXITCODE | Should -Not -Be 0
        }
        finally { $env:PATH = $savedPath }
    }
}

Describe 'No network primitives in the guard' {
    It 'contains none' {
        foreach ($f in 'Test-RepoForRomData.ps1', 'Install-Guards.ps1', 'hooks/run-guard.sh', 'hooks/pre-commit', 'hooks/pre-push') {
            $t = Get-Content -LiteralPath (Join-Path $script:GuardDir $f) -Raw
            $t | Should -Not -Match '(?i)Invoke-WebRequest|Invoke-RestMethod|\biwr\b|\birm\b|WebClient|HttpClient|Start-BitsTransfer|System\.Net|Send-MailMessage|\bcurl\b|\bwget\b|\bscp\b|\bssh\b'
        }
    }
}
