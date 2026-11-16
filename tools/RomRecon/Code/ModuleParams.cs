using System.Buffers.Binary;

namespace RomRecon.Code;

/// <summary>
/// The NitroSDK "module params" block near the start of the ARM9 static module. Layout and search heuristic follow
/// ndspy (code.py: _searchForCodeSettingsOffs): the magic bytes 21 06 C0 DE DE C0 06 21 sit at offset i; the block
/// starts at i-0x1C:
///   i-0x1C autoload list start | i-0x18 autoload list end | i-0x14 autoload data start
///   i-0x10 static BSS start    | i-0x0C static BSS end    | i-0x08 compressed static end
///   i-0x04 SDK version         | i      magic
/// A non-zero "compressed static end" means the static module is BLZ-compressed (the bootloader clears it after
/// decompressing). Confirmed only against ndspy/bootloader sources [S]; not verified on a real Conquest ROM yet.
/// </summary>
public sealed record ModuleParams(
    int MagicOffset, uint AutoloadListStart, uint AutoloadListEnd, uint AutoloadStart,
    uint StaticBssStart, uint StaticBssEnd, uint CompressedStaticEnd, uint SdkVersion)
{
    public bool IsCompressed => CompressedStaticEnd != 0;

    private static ReadOnlySpan<byte> Magic => [0x21, 0x06, 0xC0, 0xDE, 0xDE, 0xC0, 0x06, 0x21];

    public static ModuleParams? Find(ReadOnlySpan<byte> arm9)
    {
        int limit = Math.Min(arm9.Length - 8, 0x8000);
        for (int i = 0x1C; i <= limit; i += 4)
        {
            if (!arm9.Slice(i, 8).SequenceEqual(Magic)) { continue; }
            int blockStart = i - 0x1C;
            byte[] block = arm9.Slice(blockStart, 0x20).ToArray(); // local functions cannot capture spans
            uint U(int back) => BinaryPrimitives.ReadUInt32LittleEndian(block.AsSpan(i - back - blockStart, 4));
            return new ModuleParams(i, U(0x1C), U(0x18), U(0x14), U(0x10), U(0x0C), U(0x08), U(0x04));
        }
        return null;
    }
}
