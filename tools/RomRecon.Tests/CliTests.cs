using System.Security.Cryptography;
using System.Text.Json;
using RomRecon.Nds;

namespace RomRecon.Tests;

public class CliTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "romrecon_tests_" + Guid.NewGuid().ToString("N"));
    public CliTests() => Directory.CreateDirectory(_dir);
    public void Dispose()
    {
        foreach (var f in Directory.EnumerateFiles(_dir, "*", SearchOption.AllDirectories)) { File.SetAttributes(f, FileAttributes.Normal); }
        Directory.Delete(_dir, true);
    }

    private (int code, string stdout, string stderr) Run(params string[] args)
    {
        var o = new StringWriter(); var e = new StringWriter();
        int code = Cli.Run(args, o, e);
        return (code, o.ToString(), e.ToString());
    }

    private string MakeRom(SyntheticNds? nds = null)
    {
        string p = (nds ?? FakeConquest.Rom()).WriteToTemp(_dir);
        return p;
    }

    [Fact]
    public void Full_run_succeeds_and_reports_unchanged_rom()
    {
        var rom = MakeRom();
        var (code, stdout, stderr) = Run("all", rom);
        Assert.Equal(Cli.Ok, code);
        Assert.Equal("", stderr);
        Assert.Contains("ROM header", stdout);
        Assert.Contains("[integrity] ROM SHA-256 unchanged", stdout);
        Assert.Contains("Pokemon-related tables", stdout);
    }

    [Fact]
    public void Analysis_never_modifies_a_read_only_rom()
    {
        var rom = MakeRom();
        var before = SHA256.HashData(File.ReadAllBytes(rom));
        var mtime = File.GetLastWriteTimeUtc(rom);
        File.SetAttributes(rom, FileAttributes.ReadOnly);
        var (code, _, _) = Run("all", rom, "--thumb", "--arm7");
        Assert.Equal(Cli.Ok, code);
        File.SetAttributes(rom, FileAttributes.Normal);
        Assert.Equal(before, SHA256.HashData(File.ReadAllBytes(rom)));
        Assert.Equal(mtime, File.GetLastWriteTimeUtc(rom));
    }

    [Fact]
    public void Rom_is_opened_without_write_access_even_when_others_hold_it()
    {
        var rom = MakeRom();
        using var other = new FileStream(rom, FileMode.Open, FileAccess.Read, FileShare.Read); // a reader (e.g. an emulator) holds it
        using var r = NdsRom.Open(rom);                                                         // shared read must work
        Assert.Equal("VPYT", r.Header.GameCode);
        // On Windows (where the real tool runs) FileShare.Read also stops a writer sneaking in. .NET on Unix only emulates sharing with
        // advisory locks that do not exclude writers, so this part is Windows-only.
        if (OperatingSystem.IsWindows())
        {
            Assert.Throws<IOException>(() => new FileStream(rom, FileMode.Open, FileAccess.Write, FileShare.ReadWrite));
        }
    }

    [Fact]
    public void Out_option_creates_a_new_directory_with_reports_and_never_overwrites()
    {
        var rom = MakeRom();
        var outBase = Path.Combine(_dir, "diag");
        var (c1, o1, _) = Run("all", rom, "--out", outBase);
        var (c2, o2, _) = Run("all", rom, "--out", outBase);
        Assert.Equal(Cli.Ok, c1); Assert.Equal(Cli.Ok, c2);
        var dirs = Directory.GetDirectories(outBase);
        Assert.Equal(2, dirs.Length); // second run created a different directory
        foreach (var d in dirs)
        {
            Assert.True(File.Exists(Path.Combine(d, "report.txt")));
            using var doc = JsonDocument.Parse(File.ReadAllText(Path.Combine(d, "report.json")));
            Assert.Equal("VPYT", doc.RootElement.GetProperty("Header").GetProperty("GameCode").GetString());
        }
    }

    [Fact]
    public void Out_inside_a_git_working_tree_is_refused_unless_allowed()
    {
        var rom = MakeRom();
        var fakeRepo = Path.Combine(_dir, "repo");
        Directory.CreateDirectory(Path.Combine(fakeRepo, ".git"));
        var (code, _, stderr) = Run("all", rom, "--out", Path.Combine(fakeRepo, "out"));
        Assert.Equal(Cli.OutputRefused, code);
        Assert.Contains("git working tree", stderr);
        Assert.False(Directory.Exists(Path.Combine(fakeRepo, "out")));
        var (code2, _, _) = Run("all", rom, "--out", Path.Combine(fakeRepo, "out"), "--allow-in-repo");
        Assert.Equal(Cli.Ok, code2);
    }

    [Fact]
    public void Out_inside_a_cloud_synchronised_folder_is_refused_even_with_allow_in_repo()
    {
        var rom = MakeRom();
        foreach (var leaf in new[] { "OneDrive", "OneDrive - Personal", "Dropbox", "Google Drive", "iCloudDrive" })
        {
            var target = Path.Combine(_dir, leaf, "diag");
            var (code, _, stderr) = Run("all", rom, "--out", target);
            Assert.Equal(Cli.OutputRefused, code);
            Assert.Contains("cloud-synchronised", stderr);
            Assert.False(Directory.Exists(target), leaf);
            Assert.Equal(Cli.OutputRefused, Run("all", rom, "--out", target, "--allow-in-repo").code);
        }
    }

    [Fact]
    public void Out_with_a_sync_marker_folder_in_an_ancestor_is_refused()
    {
        var root = Path.Combine(_dir, "synced");
        Directory.CreateDirectory(Path.Combine(root, ".dropbox"));
        Assert.Equal(Cli.OutputRefused, Run("all", MakeRom(), "--out", Path.Combine(root, "x", "y")).code);
    }

    [Fact]
    public void Out_through_a_symlink_into_a_cloud_folder_is_refused()
    {
        var cloud = Path.Combine(_dir, "OneDrive", "real");
        Directory.CreateDirectory(cloud);
        var link = Path.Combine(_dir, "innocent");
        try { Directory.CreateSymbolicLink(link, cloud); }
        catch (Exception e) when (e is UnauthorizedAccessException or IOException) { return; } // symlinks need privileges on some Windows setups
        Assert.Equal(Cli.OutputRefused, Run("all", MakeRom(), "--out", Path.Combine(link, "diag")).code);
    }

    [Fact]
    public void Compressed_overlay_is_decompressed_and_scanned_and_extracted_on_request()
    {
        var nds = FakeConquest.Rom();
        // a compressed overlay whose decompressed content (the seed-1 pattern) is known
        nds.Overlays9.Add(new SyntheticOverlay(0x02100000, Convert.FromBase64String(BlzVectors.OverlayStyle_Seed1_Len4000), true));
        var rom = MakeRom(nds);
        var (code, stdout, _) = Run("overlays", rom, "--out", Path.Combine(_dir, "o"), "--extract-code");
        Assert.Equal(Cli.Ok, code);
        Assert.Contains("compressed yes decompressed yes", stdout);
        var extracted = Directory.GetFiles(Path.Combine(_dir, "o"), "overlay9_0_decompressed.bin", SearchOption.AllDirectories).Single();
        Assert.Equal(Synthetic.Pattern(4000, 1), File.ReadAllBytes(extracted));
    }

    [Fact]
    public void Corrupt_compressed_overlay_is_reported_and_not_scanned()
    {
        var nds = FakeConquest.Rom();
        var bad = new byte[200]; bad[199] = 0x01; // not a valid BLZ stream
        nds.Overlays9.Add(new SyntheticOverlay(0x02100000, bad, true));
        var (code, stdout, _) = Run("overlays", MakeRom(nds));
        Assert.Equal(Cli.Ok, code);
        Assert.Contains("NOTE: BLZ decompression failed", stdout);
    }

    [Fact]
    public void Scan_command_finds_a_planted_capacity_compare_in_arm9()
    {
        var nds = FakeConquest.Rom();
        nds.Arm9 = new byte[0x4100];
        BitConverter.GetBytes(0xE35000C8u).CopyTo(nds.Arm9, 0x4010); // cmp r0,#200
        var (code, stdout, _) = Run("scan", MakeRom(nds));
        Assert.Equal(Cli.Ok, code);
        Assert.Contains("0x02004010", stdout);
        Assert.Contains("CMP r0, #200", stdout);
    }

    [Fact]
    public void Not_a_rom_and_bad_arguments_give_distinct_exit_codes()
    {
        var junk = Path.Combine(_dir, "junk.nds");
        File.WriteAllBytes(junk, new byte[50]);
        Assert.Equal(Cli.BadInput, Run("all", junk).code);
        Assert.Equal(Cli.BadInput, Run("all", Path.Combine(_dir, "missing.nds")).code);
        Assert.Equal(Cli.Usage, Run("all").code);
        Assert.Equal(Cli.Usage, Run("--nonsense", junk).code);
        Assert.Equal(Cli.Usage, Run("all", junk, "--values", "abc").code);
    }

    [Fact]
    public void Dump_gap_writes_exactly_64_bytes()
    {
        var rom = MakeRom();
        var (code, _, _) = Run("tables", rom, "--out", Path.Combine(_dir, "g"), "--dump-gap");
        Assert.Equal(Cli.Ok, code);
        var gap = Directory.GetFiles(Path.Combine(_dir, "g"), "gap.bin", SearchOption.AllDirectories).Single();
        Assert.Equal(64, new FileInfo(gap).Length);
    }
}
