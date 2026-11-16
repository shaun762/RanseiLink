namespace RomRecon.Nds;

/// <summary>CRC-16 as used by the NDS header (reflected polynomial 0xA001, initial value 0xFFFF).</summary>
public static class Crc16
{
    public static ushort Compute(ReadOnlySpan<byte> data)
    {
        uint crc = 0xFFFF;
        foreach (byte b in data)
        {
            crc ^= b;
            for (int i = 0; i < 8; i++)
            {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1;
            }
        }
        return (ushort)crc;
    }
}
