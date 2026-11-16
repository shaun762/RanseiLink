using System.Buffers.Binary;
using RomRecon.Code;
using RomRecon.Nds;

namespace RomRecon.Tests;

public class NdsParsingTests
{
    private static NdsRom Open(SyntheticNds nds, out string path)
    {
        path = nds.WriteToTemp();
        return NdsRom.Open(path);
    }

    [Fact]
    public void Header_fields_and_crcs_are_parsed()
    {
        var nds = new SyntheticNds { GameCode = "VPYJ", Title = "SYNTH" };
        using var rom = Open(nds, out var path);
        try
        {
            Assert.Equal("VPYJ", rom.Header.GameCode);
            Assert.Equal("SYNTH", rom.Header.GameTitle);
            Assert.Equal(0x4000u, rom.Header.Arm9Offset);
            Assert.Equal(0x02000000u, rom.Header.Arm9RamAddress);
            Assert.True(rom.Header.HeaderCrcValid);
            Assert.True(rom.Header.LogoCrcValid);
            Assert.Empty(rom.Warnings);
        }
        finally { rom.Dispose(); File.Delete(path); }
    }

    [Fact]
    public void Corrupted_header_is_flagged()
    {
        var bytes = new SyntheticNds().Build();
        bytes[0x0E] ^= 0xFF; // change the game code without fixing the CRC
        var path = Path.Combine(Path.GetTempPath(), $"synthetic_{Guid.NewGuid():N}.nds");
        File.WriteAllBytes(path, bytes);
        try
        {
            using var rom = NdsRom.Open(path);
            Assert.False(rom.Header.HeaderCrcValid);
            Assert.Contains(rom.Warnings, w => w.Contains("Header CRC mismatch"));
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void Tiny_and_empty_files_are_rejected()
    {
        var path = Path.Combine(Path.GetTempPath(), $"tiny_{Guid.NewGuid():N}.nds");
        File.WriteAllBytes(path, new byte[100]);
        try { Assert.Throws<InvalidDataException>(() => NdsRom.Open(path)); }
        finally { File.Delete(path); }
    }

    [Fact]
    public void File_system_lists_nested_files_with_contents()
    {
        var nds = new SyntheticNds();
        nds.Files["data/a.dat"] = [1, 2, 3];
        nds.Files["data/sub/b.dat"] = [4, 5, 6, 7];
        nds.Files["root.bin"] = [9];
        using var rom = Open(nds, out var path);
        try
        {
            var files = rom.Files.ToDictionary(f => f.Path);
            Assert.Equal(["data/a.dat", "data/sub/b.dat", "root.bin"], files.Keys.OrderBy(k => k, StringComparer.Ordinal).ToArray());
            Assert.Equal<byte>([1, 2, 3], rom.ReadFile(files["data/a.dat"]));
            Assert.Equal<byte>([4, 5, 6, 7], rom.ReadFile(files["data/sub/b.dat"]));
            Assert.Equal<byte>([9], rom.ReadFile(rom.FindFile("ROOT.BIN")!));
            Assert.Null(rom.FindFile("data/missing.dat"));
        }
        finally { rom.Dispose(); File.Delete(path); }
    }

    [Fact]
    public void Overlay_table_is_parsed_including_compressed_flag()
    {
        var nds = new SyntheticNds();
        nds.Overlays9.Add(new SyntheticOverlay(0x02100000, [1, 2, 3, 4], false));
        nds.Overlays9.Add(new SyntheticOverlay(0x02200000, [5, 6, 7, 8, 9], true));
        nds.Files["x.bin"] = [0xAA];
        using var rom = Open(nds, out var path);
        try
        {
            var t = rom.ReadOverlayTable(arm9: true);
            Assert.Equal(2, t.Count);
            Assert.Equal(0x02100000u, t[0].RamAddress);
            Assert.False(t[0].IsCompressed);
            Assert.True(t[1].IsCompressed);
            Assert.Equal<byte>([5, 6, 7, 8, 9], rom.ReadOverlay(t[1])!);
            // overlay file ids must not leak into the named file list
            Assert.Single(rom.Files);
        }
        finally { rom.Dispose(); File.Delete(path); }
    }

    [Fact]
    public void Out_of_range_reads_throw_instead_of_returning_garbage()
    {
        using var rom = Open(new SyntheticNds(), out var path);
        try
        {
            Assert.Throws<InvalidDataException>(() => rom.Read(rom.Length - 2, 10));
            Assert.Throws<InvalidDataException>(() => rom.Read(-1, 4));
        }
        finally { rom.Dispose(); File.Delete(path); }
    }

    [Fact]
    public void Module_params_detect_compression_flag()
    {
        byte[] Arm9With(uint compressedEnd)
        {
            var a = new byte[0x400];
            int magic = 0x120;
            BinaryPrimitives.WriteUInt32LittleEndian(a.AsSpan(magic - 0x1C), 0x02000800);
            BinaryPrimitives.WriteUInt32LittleEndian(a.AsSpan(magic - 0x08), compressedEnd);
            BinaryPrimitives.WriteUInt32LittleEndian(a.AsSpan(magic - 0x04), 0x0300C000);
            byte[] m = [0x21, 0x06, 0xC0, 0xDE, 0xDE, 0xC0, 0x06, 0x21];
            m.CopyTo(a, magic);
            return a;
        }
        var plain = ModuleParams.Find(Arm9With(0));
        var comp = ModuleParams.Find(Arm9With(0x02148000));
        Assert.NotNull(plain); Assert.NotNull(comp);
        Assert.False(plain!.IsCompressed);
        Assert.True(comp!.IsCompressed);
        Assert.Equal(0x120, comp.MagicOffset);
        Assert.Equal(0x02000800u, comp.AutoloadListStart);
        Assert.Equal(0x0300C000u, comp.SdkVersion);
        Assert.Null(ModuleParams.Find(new byte[0x400]));
    }
}
