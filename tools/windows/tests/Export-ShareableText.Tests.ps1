BeforeAll {
    $script:Script = (Resolve-Path ([IO.Path]::Combine($PSScriptRoot, '..', 'Export-ShareableText.ps1'))).Path
    . $script:Script -Path 'unused'
    Mock Write-Host {}
    function New-TextFile([string]$Name, [string]$Content) { $p = Join-Path $TestDrive $Name; [IO.File]::WriteAllText($p, $Content); return $p }
}

Describe 'Refuses anything that is not plain diagnostic text' {
    It 'refuses ROM/save/dump/binary file names even if the content is text' {
        foreach ($n in 'game.nds', 'gap.bin', 'arm9_decompressed.bin', 'save.sav', 'x.state1', 'overlay9_0.txt', 'arm9.txt', 'a.png', 'a.dll') {
            $p = New-TextFile $n 'plain'
            (Test-ShareableTextFile $p).Ok | Should -BeFalse -Because $n
        }
    }
    It 'refuses binary content and invalid UTF-8 and non-text extensions' {
        $p = Join-Path $TestDrive 'bin.txt'; [IO.File]::WriteAllBytes($p, [byte[]](65, 0, 66))
        (Test-ShareableTextFile $p).Reason | Should -Match 'binary'
        $q = Join-Path $TestDrive 'bad.txt'; [IO.File]::WriteAllBytes($q, [byte[]](0xFF, 0xFE, 0x41, 0x80, 0x81))
        (Test-ShareableTextFile $q).Ok | Should -BeFalse
        (Test-ShareableTextFile (New-TextFile 'a.docx' 'x')).Reason | Should -Match 'only'
    }
    It 'refuses oversized files' {
        $p = New-TextFile 'big.txt' ('x' * 300000)
        (Test-ShareableTextFile $p 256).Reason | Should -Match 'too big'
        (Test-ShareableTextFile $p 400).Ok | Should -BeTrue
    }
    It 'accepts a normal report' { (Test-ShareableTextFile (New-TextFile 'report.txt' "line 1`r`nline 2")).Ok | Should -BeTrue }
    It 'refuses a missing file' { (Test-ShareableTextFile (Join-Path $TestDrive 'nope.txt')).Ok | Should -BeFalse }
}

Describe 'Redaction' {
    It 'redacts user name, profile paths and computer name but keeps useful structure' {
        $r = ConvertTo-RedactedText -Text "ROM: C:\Users\SurfaceUser42\PokemonConquestDev\original\Pokemon Conquest.nds`nowner SurfaceUser42 on SURFACE-LAPTOP-3`n/home/surfaceuser42/x" -UserName 'SurfaceUser42' -ComputerName 'SURFACE-LAPTOP-3'
        $r.Text | Should -Not -Match 'SurfaceUser42'
        $r.Text | Should -Not -Match 'SURFACE-LAPTOP-3'
        $r.Text | Should -Match 'C:\\Users\\<user>\\PokemonConquestDev\\original\\Pokemon Conquest.nds'
        $r.Text | Should -Match '/home/<user>/x'
    }
    It 'redacts e-mail, URL credentials and secret settings' {
        $t = "mail me at someone@example.com`nurl https://bob:hunter2@host.example/x`ncheevos_password = `"abc`"`nnetplay_nickname = Bob`nmy_api_key: ABCDEF`nsavefile_directory = `":\saves`""
        $r = ConvertTo-RedactedText -Text $t -UserName 'zz' -ComputerName 'zz'
        $r.Text | Should -Not -Match 'someone@example.com'
        $r.Text | Should -Not -Match 'hunter2'
        $r.Text | Should -Not -Match 'abc"'
        $r.Text | Should -Not -Match 'Bob'
        $r.Text | Should -Not -Match 'ABCDEF'
        $r.Text | Should -Match 'savefile_directory = ":\\saves"'     # harmless settings are untouched
        $r.Counts.Keys | Should -Contain 'secret-setting'
    }
    It 'redacts tokens, IPs, MACs and product keys but KEEPS hashes, game codes and ordinary words' {
        $sha = 'a' * 8 + '0123456789' * 5 + 'abcdef'    # 64 hex chars
        $t = "SHA-256 $sha`nsha1 da39a3ee5e6b4b0d3255bfef95601890afd80709`ncode VPYT region North America`ntoken Zm9vYmFyMTIzNDU2Nzg5MGFiY2RlZmdoaWprbG1ub3BxcnN0`nip 192.168.1.20 and 127.0.0.1 mac aa:bb:cc:dd:ee:ff key ABCDE-12345-FGHIJ-67890-KLMNO`nRanseiLink.GuiCore.ViewModels.ModelViewModels.MapPointViewModel"
        $r = ConvertTo-RedactedText -Text $t -UserName 'zz' -ComputerName 'zz'
        $r.Text | Should -Match $sha
        $r.Text | Should -Match 'da39a3ee5e6b4b0d3255bfef95601890afd80709'
        $r.Text | Should -Match 'VPYT region North America'
        $r.Text | Should -Not -Match 'Zm9vYmFy'
        $r.Text | Should -Not -Match '192\.168\.1\.20'
        $r.Text | Should -Match '127\.0\.0\.1'
        $r.Text | Should -Not -Match 'aa:bb:cc:dd:ee:ff'
        $r.Text | Should -Not -Match 'ABCDE-12345'
        $r.Text | Should -Match 'RanseiLink\.GuiCore\.ViewModels\.ModelViewModels\.MapPointViewModel'
    }
    It 'leaves text without sensitive data unchanged' {
        $t = "== ROM header ==`nTitle / code: 'POKEMON CONQ' / VPYT`nARM9: file 0x4000 size 0x1A2B3C ram 0x02000000"
        (ConvertTo-RedactedText -Text $t -UserName 'zz' -ComputerName 'zz').Text | Should -Be $t
    }
}

Describe 'Export writes a NEW file and never touches the input' {
    It 'writes a redacted copy with a header, leaves the input byte-identical, and never overwrites' {
        $p = New-TextFile 'report.txt' "user C:\Users\Someone\x`nsha $('b' * 64)"
        $before = [IO.File]::ReadAllBytes($p)
        $out = Join-Path $TestDrive 'out'
        $failed = Export-ShareableText -Files @($p) -OutDirectory $out
        $failed | Should -Be 0
        $files = @(Get-ChildItem -LiteralPath $out -File)
        $files.Count | Should -Be 1
        $text = Get-Content -LiteralPath $files[0].FullName -Raw
        $text | Should -Match '^# REDACTED copy'
        $text | Should -Not -Match 'Someone'
        [IO.File]::ReadAllBytes($p) | Should -Be $before
        $firstHash = (Get-FileHash -LiteralPath $files[0].FullName).Hash
        [void](Export-ShareableText -Files @($p) -OutDirectory $out)
        @(Get-ChildItem -LiteralPath $out -File).Count | Should -Be 2           # a second run adds a file, it does not replace
        (Get-FileHash -LiteralPath $files[0].FullName).Hash | Should -Be $firstHash
    }
    It 'returns a failure count and writes nothing for refused files' {
        $p = Join-Path $TestDrive 'gap.bin'; [IO.File]::WriteAllBytes($p, [byte[]](1, 2, 3))
        $out = Join-Path $TestDrive 'out2'
        (Export-ShareableText -Files @($p) -OutDirectory $out) | Should -Be 1
        Test-Path -LiteralPath $out | Should -BeFalse
    }
    It 'contains no network primitives' {
        (Get-Content -LiteralPath $script:Script -Raw) | Should -Not -Match '(?i)Invoke-WebRequest|Invoke-RestMethod|\biwr\b|\birm\b|WebClient|HttpClient|Start-BitsTransfer|System\.Net|Send-MailMessage|\bcurl\b|\bwget\b'
    }
}
