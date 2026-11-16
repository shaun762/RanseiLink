using System.Buffers.Binary;
using System.Text;

namespace RomRecon.Nds;

/// <summary>
/// The fixed 0x200-byte Nintendo DS cartridge header, field offsets per GBATEK.
/// NOTE: the entry address (0x24) and RAM/load address (0x28) are read in the GBATEK order here. The RanseiLink
/// <c>NdsHeader</c> class reads them in the opposite order (Core/RomFs/NdsHeader.cs:33-35); this tool does not rely on it.
/// </summary>
public sealed record NdsHeader
{
    public const int Size = 0x200;
    public const int HeaderCrcOffset = 0x15E;
    public const int LogoCrcOffset = 0x15C;
    public const ushort ExpectedLogoCrc = 0xCF56;

    public required string GameTitle { get; init; }
    public required string GameCode { get; init; }
    public required string MakerCode { get; init; }
    public byte UnitCode { get; init; }
    public byte DeviceCapacity { get; init; }
    public byte RomVersion { get; init; }

    public uint Arm9Offset { get; init; }
    public uint Arm9Entry { get; init; }
    public uint Arm9RamAddress { get; init; }
    public uint Arm9Size { get; init; }
    public uint Arm7Offset { get; init; }
    public uint Arm7Entry { get; init; }
    public uint Arm7RamAddress { get; init; }
    public uint Arm7Size { get; init; }

    public uint FntOffset { get; init; }
    public uint FntSize { get; init; }
    public uint FatOffset { get; init; }
    public uint FatSize { get; init; }

    public uint Arm9OverlayOffset { get; init; }
    public uint Arm9OverlaySize { get; init; }
    public uint Arm7OverlayOffset { get; init; }
    public uint Arm7OverlaySize { get; init; }

    public uint IconBannerOffset { get; init; }
    public uint UsedRomSize { get; init; }
    public uint HeaderSize { get; init; }

    public ushort LogoCrcStored { get; init; }
    public ushort LogoCrcComputed { get; init; }
    public ushort HeaderCrcStored { get; init; }
    public ushort HeaderCrcComputed { get; init; }

    public bool LogoCrcValid => LogoCrcStored == LogoCrcComputed;
    public bool HeaderCrcValid => HeaderCrcStored == HeaderCrcComputed;

    public static NdsHeader Parse(ReadOnlySpan<byte> span)
    {
        if (span.Length < Size)
        {
            throw new InvalidDataException($"File is too small to contain an NDS header ({span.Length} < {Size} bytes).");
        }
        byte[] d = span[..Size].ToArray(); // local functions cannot capture spans
        uint U32(int o) => BinaryPrimitives.ReadUInt32LittleEndian(d.AsSpan(o, 4));
        ushort U16(int o) => BinaryPrimitives.ReadUInt16LittleEndian(d.AsSpan(o, 2));
        static string Ascii(ReadOnlySpan<byte> s) => Encoding.ASCII.GetString(s).TrimEnd('\0', ' ');

        return new NdsHeader
        {
            GameTitle = Ascii(d.AsSpan(0x00, 12)),
            GameCode = Ascii(d.AsSpan(0x0C, 4)),
            MakerCode = Ascii(d.AsSpan(0x10, 2)),
            UnitCode = d[0x12],
            DeviceCapacity = d[0x14],
            RomVersion = d[0x1E],
            Arm9Offset = U32(0x20),
            Arm9Entry = U32(0x24),
            Arm9RamAddress = U32(0x28),
            Arm9Size = U32(0x2C),
            Arm7Offset = U32(0x30),
            Arm7Entry = U32(0x34),
            Arm7RamAddress = U32(0x38),
            Arm7Size = U32(0x3C),
            FntOffset = U32(0x40),
            FntSize = U32(0x44),
            FatOffset = U32(0x48),
            FatSize = U32(0x4C),
            Arm9OverlayOffset = U32(0x50),
            Arm9OverlaySize = U32(0x54),
            Arm7OverlayOffset = U32(0x58),
            Arm7OverlaySize = U32(0x5C),
            IconBannerOffset = U32(0x68),
            UsedRomSize = U32(0x80),
            HeaderSize = U32(0x84),
            LogoCrcStored = U16(LogoCrcOffset),
            LogoCrcComputed = Crc16.Compute(d.AsSpan(0xC0, 0x9C)),
            HeaderCrcStored = U16(HeaderCrcOffset),
            HeaderCrcComputed = Crc16.Compute(d.AsSpan(0, HeaderCrcOffset)),
        };
    }
}
