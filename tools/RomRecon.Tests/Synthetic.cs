using System.Buffers.Binary;
using System.Text;
using RomRecon.Nds;

namespace RomRecon.Tests;

/// <summary>Deterministic, obviously-fake data generators. NOTHING here is derived from a commercial ROM.</summary>
public static class Synthetic
{
    /// <summary>Same recipe as the Python used to generate <see cref="BlzVectors"/>.</summary>
    public static byte[] Pattern(int length, int seed)
    {
        long x = seed;
        var output = new List<byte>(length + 64);
        long Next() { x = (x * 1103515245L + 12345L) & 0x7fffffffL; return x; }
        while (output.Count < length)
        {
            long r = Next();
            if (output.Count >= 64 && (r >> 8) % 3 != 0)
            {
                output.AddRange(output.GetRange(output.Count - 64, 64));
            }
            else
            {
                for (int i = 0; i < 64; i++) { output.Add((byte)((Next() >> 16) & 0xFF)); }
            }
        }
        return output.Take(length).ToArray();
    }
}

public sealed record SyntheticOverlay(uint RamAddress, byte[] Data, bool CompressedFlag);

/// <summary>Builds a minimal but structurally valid NDS image (header + CRCs + ARM9/ARM7 + overlay table + FNT/FAT + files).</summary>
public sealed class SyntheticNds
{
    public string GameCode { get; set; } = "VPYT";
    public string Title { get; set; } = "SYNTHETIC";
    public byte[] Arm9 { get; set; } = new byte[0x4100];
    public uint Arm9Ram { get; set; } = 0x02000000;
    public byte[] Arm7 { get; set; } = new byte[0x200];
    public uint Arm7Ram { get; set; } = 0x02380000;
    public List<SyntheticOverlay> Overlays9 { get; } = [];
    public SortedDictionary<string, byte[]> Files { get; } = new(StringComparer.Ordinal);

    private static int Align(int v, int a = 0x200) => (v + a - 1) / a * a;

    public byte[] Build()
    {
        // ---- file system tree
        var dirs = new List<string> { "" };
        foreach (var p in Files.Keys)
        {
            var parts = p.Split('/');
            string cur = "";
            for (int i = 0; i < parts.Length - 1; i++)
            {
                cur = cur.Length == 0 ? parts[i] : cur + "/" + parts[i];
                if (!dirs.Contains(cur)) { dirs.Add(cur); }
            }
        }
        dirs = dirs.OrderBy(d => d.Count(c => c == '/') + (d.Length == 0 ? -1 : 0)).ThenBy(d => d, StringComparer.Ordinal).ToList();
        int DirId(string d) => dirs.IndexOf(d);
        string Parent(string d) => d.Contains('/') ? d[..d.LastIndexOf('/')] : "";

        int nextFileId = Overlays9.Count;
        var firstFileId = new Dictionary<string, int>();
        var fileIds = new Dictionary<string, int>();
        foreach (var d in dirs)
        {
            firstFileId[d] = nextFileId;
            foreach (var f in Files.Keys.Where(k => (k.Contains('/') ? k[..k.LastIndexOf('/')] : "") == d))
            {
                fileIds[f] = nextFileId++;
            }
        }
        int totalFiles = nextFileId;

        // sub tables
        var sub = new List<byte[]>();
        foreach (var d in dirs)
        {
            var ms = new MemoryStream();
            foreach (var f in Files.Keys.Where(k => (k.Contains('/') ? k[..k.LastIndexOf('/')] : "") == d))
            {
                var name = Encoding.UTF8.GetBytes(f[(f.LastIndexOf('/') + 1)..]);
                ms.WriteByte((byte)name.Length); ms.Write(name);
            }
            foreach (var child in dirs.Where(c => c.Length > 0 && Parent(c) == d))
            {
                var name = Encoding.UTF8.GetBytes(child[(child.LastIndexOf('/') + 1)..]);
                ms.WriteByte((byte)(0x80 | name.Length)); ms.Write(name);
                ms.Write(BitConverter.GetBytes((ushort)(0xF000 + DirId(child))));
            }
            ms.WriteByte(0);
            sub.Add(ms.ToArray());
        }
        var fnt = new MemoryStream();
        int subOffset = dirs.Count * 8;
        for (int i = 0; i < dirs.Count; i++)
        {
            fnt.Write(BitConverter.GetBytes((uint)subOffset));
            fnt.Write(BitConverter.GetBytes((ushort)firstFileId[dirs[i]]));
            fnt.Write(BitConverter.GetBytes(i == 0 ? (ushort)dirs.Count : (ushort)(0xF000 + DirId(Parent(dirs[i])))));
            subOffset += sub[i].Length;
        }
        foreach (var s in sub) { fnt.Write(s); }
        var fntBytes = fnt.ToArray();

        // ---- layout
        int arm9Off = 0x4000;
        int arm7Off = Align(arm9Off + Arm9.Length);
        int fntOff = Align(arm7Off + Arm7.Length);
        int fatOff = Align(fntOff + fntBytes.Length);
        int fatSize = totalFiles * 8;
        int ovtOff = Align(fatOff + fatSize);
        int ovtSize = Overlays9.Count * 32;
        int dataStart = Align(ovtOff + ovtSize);

        var fat = new byte[fatSize];
        var blobs = new List<(int off, byte[] data)>();
        int cursor = dataStart;
        for (int i = 0; i < Overlays9.Count; i++)
        {
            BinaryPrimitives.WriteUInt32LittleEndian(fat.AsSpan(i * 8), (uint)cursor);
            BinaryPrimitives.WriteUInt32LittleEndian(fat.AsSpan(i * 8 + 4), (uint)(cursor + Overlays9[i].Data.Length));
            blobs.Add((cursor, Overlays9[i].Data));
            cursor = Align(cursor + Overlays9[i].Data.Length);
        }
        foreach (var (path, data) in Files)
        {
            int id = fileIds[path];
            BinaryPrimitives.WriteUInt32LittleEndian(fat.AsSpan(id * 8), (uint)cursor);
            BinaryPrimitives.WriteUInt32LittleEndian(fat.AsSpan(id * 8 + 4), (uint)(cursor + data.Length));
            blobs.Add((cursor, data));
            cursor = Align(cursor + data.Length);
        }

        var rom = new byte[Math.Max(cursor, dataStart)];
        void U32(int o, uint v) => BinaryPrimitives.WriteUInt32LittleEndian(rom.AsSpan(o, 4), v);
        Encoding.ASCII.GetBytes(Title.PadRight(12, '\0')[..12]).CopyTo(rom, 0);
        Encoding.ASCII.GetBytes(GameCode).CopyTo(rom, 0x0C);
        Encoding.ASCII.GetBytes("01").CopyTo(rom, 0x10);
        U32(0x20, (uint)arm9Off); U32(0x24, Arm9Ram); U32(0x28, Arm9Ram); U32(0x2C, (uint)Arm9.Length);
        U32(0x30, (uint)arm7Off); U32(0x34, Arm7Ram); U32(0x38, Arm7Ram); U32(0x3C, (uint)Arm7.Length);
        U32(0x40, (uint)fntOff); U32(0x44, (uint)fntBytes.Length);
        U32(0x48, (uint)fatOff); U32(0x4C, (uint)fatSize);
        U32(0x50, (uint)ovtOff); U32(0x54, (uint)ovtSize);
        U32(0x80, (uint)rom.Length); U32(0x84, 0x4000);
        // logo area: arbitrary bytes, then CRCs
        for (int i = 0xC0; i < 0x15C; i++) { rom[i] = (byte)(i * 7); }
        BinaryPrimitives.WriteUInt16LittleEndian(rom.AsSpan(NdsHeader.LogoCrcOffset), Crc16.Compute(rom.AsSpan(0xC0, 0x9C)));
        BinaryPrimitives.WriteUInt16LittleEndian(rom.AsSpan(NdsHeader.HeaderCrcOffset), Crc16.Compute(rom.AsSpan(0, NdsHeader.HeaderCrcOffset)));

        Arm9.CopyTo(rom, arm9Off); Arm7.CopyTo(rom, arm7Off);
        fntBytes.CopyTo(rom, fntOff); fat.CopyTo(rom, fatOff);
        for (int i = 0; i < Overlays9.Count; i++)
        {
            var o = Overlays9[i];
            int e = ovtOff + i * 32;
            U32(e + 0, (uint)i); U32(e + 4, o.RamAddress); U32(e + 8, (uint)o.Data.Length); U32(e + 0xC, 0);
            U32(e + 0x10, 0); U32(e + 0x14, 0); U32(e + 0x18, (uint)i);
            U32(e + 0x1C, (uint)o.Data.Length | (o.CompressedFlag ? 1u << 24 : 0));
        }
        foreach (var (off, data) in blobs) { data.CopyTo(rom, off); }
        return rom;
    }

    /// <summary>Writes the image to a new temp file and returns its path.</summary>
    public string WriteToTemp(string? dir = null)
    {
        string path = Path.Combine(dir ?? Path.GetTempPath(), $"synthetic_{Guid.NewGuid():N}.nds");
        File.WriteAllBytes(path, Build());
        return path;
    }
}

/// <summary>Fake Pokemon-Conquest-shaped data tables matching the layout assumptions the tool checks.</summary>
public static class FakeConquest
{
    public static byte[] PokemonDat(int evoLength = 12)
    {
        const int stride = 0x30, count = 200;
        int evoOffset = 0x25C0;
        int size = (evoOffset + 4 + evoLength + 3) & ~3;
        var d = new byte[size];
        for (int i = 0; i < count; i++)
        {
            var rec = d.AsSpan(i * stride, stride);
            rec[44] = (byte)i;                                              // NameOrderIndex (unique)
            uint w8 = (uint)(1400 | (1400 << 11) | ((i + 1) << 22));       // evolution none + national dex number
            BinaryPrimitives.WriteUInt32LittleEndian(rec.Slice(32, 4), w8);
        }
        for (int i = 0; i < 64; i++) { d[count * stride + i] = (byte)(i % 5); } // the mysterious gap
        BinaryPrimitives.WriteUInt32LittleEndian(d.AsSpan(evoOffset), (uint)evoLength);
        for (int i = 0; i < evoLength; i++) { d[evoOffset + 4 + i] = (byte)(i + 1); }
        return d;
    }

    public static byte[] LinkArchive(int entries)
    {
        var d = new byte[16 + entries * 8];
        "LINK"u8.CopyTo(d);
        BinaryPrimitives.WriteUInt32LittleEndian(d.AsSpan(4), (uint)entries);
        BinaryPrimitives.WriteUInt32LittleEndian(d.AsSpan(8), 4);
        return d;
    }

    public static SyntheticNds Rom(string gameCode = "VPYT", int linkEntries = 200)
    {
        var nds = new SyntheticNds { GameCode = gameCode };
        nds.Files["data/Pokemon.dat"] = PokemonDat();
        nds.Files["data/BaseBushouMaxSyncTable.dat"] = new byte[252 * 200];
        int kStride = gameCode == "VPYJ" ? 0x14 : 0x18;
        nds.Files["data/Kuni.dat"] = new byte[17 * kStride];
        for (int sc = 0; sc < 11; sc++)
        {
            var sp = new byte[200 * 8];
            for (int i = 0; i < 200; i++) { sp[i * 8] = (byte)(i % 199); }
            sp[199 * 8] = 200; // the "none" sentinel in the last entry
            nds.Files[$"data/Scenario/Scenario{sc:D2}/ScenarioPokemon.dat"] = sp;
            var ap = new byte[0xC8]; ap[3] = 0x20;
            nds.Files[$"data/Scenario/Scenario{sc:D2}/ScenarioAppearPokemon.dat"] = ap;
        }
        foreach (var n in new[] { "TEX", "ATX", "DTX", "PAC" }) { nds.Files[$"graphics/model_pokemon/POKEMON_{n}.ALL"] = LinkArchive(linkEntries); }
        foreach (var n in new[] { "ci", "sr", "s", "b", "m", "l", "wu" }) { nds.Files[$"graphics/still/stl_pokemon_{n}/stl_pokemon_{n}.G2DR"] = LinkArchive(8); }
        return nds;
    }
}
