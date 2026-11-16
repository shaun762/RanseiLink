using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;

namespace RomRecon.Nds;

public sealed record NdsFile(string Path, int FileId, uint Start, uint End)
{
    public uint Length => End - Start;
}

public sealed record OverlayEntry(
    int Index, uint Id, uint RamAddress, uint RamSize, uint BssSize,
    uint StaticInitStart, uint StaticInitEnd, uint FileId, uint CompressedSize, byte Flags)
{
    /// <summary>Per ndspy (code.py loadOverlayTable): high byte of the last word holds the flags; bit 0 = compressed.</summary>
    public bool IsCompressed => (Flags & 1) != 0;
}

/// <summary>
/// READ-ONLY view of a Nintendo DS ROM image. The file is opened with FileAccess.Read / FileShare.Read, there is no
/// code path that writes to it, and every read is bounds-checked against the real file length.
/// </summary>
public sealed class NdsRom : IDisposable
{
    private const long MaxTableBytes = 32 * 1024 * 1024;
    private readonly FileStream _stream;
    private List<NdsFile>? _files;
    private readonly List<string> _warnings = [];

    public string Path { get; }
    public long Length { get; }
    public NdsHeader Header { get; }
    public IReadOnlyList<string> Warnings => _warnings;

    private NdsRom(string path, FileStream stream, NdsHeader header)
    {
        Path = path;
        _stream = stream;
        Length = stream.Length;
        Header = header;
    }

    public static NdsRom Open(string path)
    {
        // Read-only, shared-read: cannot modify the file, and does not lock out the emulator.
        var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16, FileOptions.RandomAccess);
        try
        {
            var buf = new byte[NdsHeader.Size];
            int n = stream.Read(buf, 0, buf.Length);
            if (n < NdsHeader.Size)
            {
                throw new InvalidDataException($"File is too small to be a Nintendo DS ROM ({stream.Length} bytes).");
            }
            var header = NdsHeader.Parse(buf);
            var rom = new NdsRom(path, stream, header);
            rom.ValidateLayout();
            return rom;
        }
        catch
        {
            stream.Dispose();
            throw;
        }
    }

    private void ValidateLayout()
    {
        void Region(string name, uint offset, uint size)
        {
            if (size == 0) { return; }
            if ((long)offset + size > Length)
            {
                _warnings.Add($"{name} [0x{offset:X}, +0x{size:X}) extends beyond the end of the file (0x{Length:X}).");
            }
        }
        Region("ARM9", Header.Arm9Offset, Header.Arm9Size);
        Region("ARM7", Header.Arm7Offset, Header.Arm7Size);
        Region("FNT", Header.FntOffset, Header.FntSize);
        Region("FAT", Header.FatOffset, Header.FatSize);
        Region("ARM9 overlay table", Header.Arm9OverlayOffset, Header.Arm9OverlaySize);
        Region("ARM7 overlay table", Header.Arm7OverlayOffset, Header.Arm7OverlaySize);
        if (!Header.HeaderCrcValid) { _warnings.Add($"Header CRC mismatch: stored 0x{Header.HeaderCrcStored:X4}, computed 0x{Header.HeaderCrcComputed:X4}."); }
        if (!Header.LogoCrcValid) { _warnings.Add($"Logo CRC mismatch: stored 0x{Header.LogoCrcStored:X4}, computed 0x{Header.LogoCrcComputed:X4}."); }
        if (Header.UsedRomSize > Length) { _warnings.Add($"Header says the ROM uses 0x{Header.UsedRomSize:X} bytes but the file is only 0x{Length:X} (trimmed or truncated dump)."); }
    }

    public byte[] Read(long offset, long count)
    {
        if (offset < 0 || count < 0 || offset + count > Length)
        {
            throw new InvalidDataException($"Read of 0x{count:X} bytes at 0x{offset:X} is outside the ROM (length 0x{Length:X}).");
        }
        var buf = new byte[count];
        _stream.Position = offset;
        _stream.ReadExactly(buf);
        return buf;
    }

    public byte[] ReadArm9() => Read(Header.Arm9Offset, Header.Arm9Size);
    public byte[] ReadArm7() => Read(Header.Arm7Offset, Header.Arm7Size);

    /// <summary>Bytes that follow ARM9 in the ROM: ndspy treats consecutive 12-byte blocks starting 21 06 C0 DE as post-ARM9 data.</summary>
    public byte[] ReadArm9PostData()
    {
        long pos = (long)Header.Arm9Offset + Header.Arm9Size;
        var result = new List<byte>();
        while (pos + 12 <= Length)
        {
            var b = Read(pos, 12);
            if (b[0] != 0x21 || b[1] != 0x06 || b[2] != 0xC0 || b[3] != 0xDE) { break; }
            result.AddRange(b);
            pos += 12;
        }
        return result.ToArray();
    }

    public IReadOnlyList<OverlayEntry> ReadOverlayTable(bool arm9)
    {
        uint offset = arm9 ? Header.Arm9OverlayOffset : Header.Arm7OverlayOffset;
        uint size = arm9 ? Header.Arm9OverlaySize : Header.Arm7OverlaySize;
        var list = new List<OverlayEntry>();
        if (size == 0 || size > MaxTableBytes || (long)offset + size > Length) { return list; }
        var t = Read(offset, size);
        for (int i = 0, idx = 0; i + 32 <= t.Length; i += 32, idx++)
        {
            uint U(int o) => BinaryPrimitives.ReadUInt32LittleEndian(t.AsSpan(i + o, 4));
            uint packed = U(0x1C);
            list.Add(new OverlayEntry(idx, U(0), U(4), U(8), U(0xC), U(0x10), U(0x14), U(0x18), packed & 0xFFFFFF, (byte)(packed >> 24)));
        }
        return list;
    }

    public (uint Start, uint End)? GetFatEntry(uint fileId)
    {
        long pos = (long)Header.FatOffset + (long)fileId * 8;
        if ((long)fileId * 8 + 8 > Header.FatSize || pos + 8 > Length) { return null; }
        var b = Read(pos, 8);
        return (BinaryPrimitives.ReadUInt32LittleEndian(b), BinaryPrimitives.ReadUInt32LittleEndian(b.AsSpan(4)));
    }

    public byte[]? ReadOverlay(OverlayEntry ov)
    {
        var fat = GetFatEntry(ov.FileId);
        if (fat is null || fat.Value.End < fat.Value.Start) { return null; }
        return Read(fat.Value.Start, fat.Value.End - fat.Value.Start);
    }

    public byte[] ReadFile(NdsFile file) => Read(file.Start, file.Length);

    /// <summary>All files in the NDS file system (File Name Table + File Allocation Table).</summary>
    public IReadOnlyList<NdsFile> Files => _files ??= ReadFiles();

    public NdsFile? FindFile(string path) =>
        Files.FirstOrDefault(f => string.Equals(f.Path, path.Replace('\\', '/').TrimStart('/'), StringComparison.OrdinalIgnoreCase));

    private List<NdsFile> ReadFiles()
    {
        var result = new List<NdsFile>();
        if (Header.FntSize == 0 || Header.FntSize > MaxTableBytes || (long)Header.FntOffset + Header.FntSize > Length
            || Header.FatSize > MaxTableBytes || (long)Header.FatOffset + Header.FatSize > Length)
        {
            _warnings.Add("File system tables are missing or outside the ROM; no files listed.");
            return result;
        }
        var fnt = Read(Header.FntOffset, Header.FntSize);
        var fat = Read(Header.FatOffset, Header.FatSize);
        int fatCount = fat.Length / 8;
        var visited = new HashSet<int>();

        void Walk(int dirIndex, string prefix, int depth)
        {
            if (depth > 32 || !visited.Add(dirIndex)) { return; }
            int mainEntry = dirIndex * 8;
            if (mainEntry + 8 > fnt.Length) { return; }
            uint subOffset = BinaryPrimitives.ReadUInt32LittleEndian(fnt.AsSpan(mainEntry, 4));
            int fileId = BinaryPrimitives.ReadUInt16LittleEndian(fnt.AsSpan(mainEntry + 4, 2));
            long p = subOffset;
            while (p < fnt.Length)
            {
                byte t = fnt[p++];
                if (t == 0) { break; }
                int len = t & 0x7F;
                if (p + len > fnt.Length) { break; }
                string name = Encoding.UTF8.GetString(fnt, (int)p, len);
                p += len;
                if ((t & 0x80) != 0)
                {
                    if (p + 2 > fnt.Length) { break; }
                    int sub = BinaryPrimitives.ReadUInt16LittleEndian(fnt.AsSpan((int)p, 2)) & 0xFFF;
                    p += 2;
                    Walk(sub, prefix + name + "/", depth + 1);
                }
                else
                {
                    if (fileId < fatCount)
                    {
                        uint start = BinaryPrimitives.ReadUInt32LittleEndian(fat.AsSpan(fileId * 8, 4));
                        uint end = BinaryPrimitives.ReadUInt32LittleEndian(fat.AsSpan(fileId * 8 + 4, 4));
                        if (end >= start && end <= Length) { result.Add(new NdsFile(prefix + name, fileId, start, end)); }
                        else { _warnings.Add($"File '{prefix}{name}' has an invalid FAT range [0x{start:X}, 0x{end:X})."); }
                    }
                    fileId++;
                }
            }
        }
        Walk(0, "", 0);
        return result;
    }

    /// <summary>Streams the whole file through SHA-256. Used before/after analysis to prove the ROM was not modified.</summary>
    public static string Sha256Hex(string path)
    {
        using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16, FileOptions.SequentialScan);
        return Convert.ToHexString(SHA256.HashData(fs)).ToLowerInvariant();
    }

    public void Dispose() => _stream.Dispose();
}
