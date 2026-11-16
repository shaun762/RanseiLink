using System.Buffers.Binary;
using System.Text;

namespace RomRecon.Analysis;

public enum HitKind { LiteralWord, ArmImmediate, ThumbImmediate, AsciiString }

/// <param name="Region">e.g. "arm9", "overlay9_3"</param>
/// <param name="Address">RAM address if the region has a known load address, otherwise the offset within the region</param>
public sealed record ScanHit(string Region, uint Address, uint OffsetInRegion, HitKind Kind, string Detail, string Label);

public sealed record ScanOptions
{
    /// <summary>Values that, if encoded as an instruction immediate or a literal-pool word, are reported.</summary>
    public IReadOnlyDictionary<uint, string> Values { get; init; } = DefaultValues;
    /// <summary>Thumb scanning is noisy (data and ARM code decode as plausible Thumb), so it is opt-in.</summary>
    public bool IncludeThumb { get; init; }
    /// <summary>Literal-pool (aligned 32-bit word) scanning for values this large or larger; small values are far too common as data.</summary>
    public uint MinLiteralWordValue { get; init; } = 0x100;
    public IReadOnlyList<string> Strings { get; init; } = DefaultStrings;

    public static readonly IReadOnlyDictionary<uint, string> DefaultValues = new Dictionary<uint, string>
    {
        [200] = "species count (200)",
        [199] = "last species id (199)",
        [201] = "species count + 1",
        [252] = "warrior count (252)",
        [251] = "last warrior id (251)",
        [0x2580] = "end of Pokemon.dat records (200 * 0x30)",
        [0x25C0] = "Pokemon.dat evolution table offset",
        [0xC4E0] = "MaxLink table size (252 * 200 = 50400)",
        [1400] = "default evolution-table entry",
        [1100] = "'no scenario pokemon' sentinel",
        [0x30B] = "scenario pokemon count in save [S] (779)",
    };

    public static readonly IReadOnlyList<string> DefaultStrings =
    [
        "Pokemon.dat", "BaseBushou", "ScenarioPokemon", "ScenarioAppearPokemon", "Kuni.dat", "POKEMON_TEX", "stl_pokemon",
    ];
}

/// <summary>
/// Heuristic, READ-ONLY search of machine code for constants that may encode the Pokemon capacity. Everything it reports is a
/// *candidate*: an instruction that happens to contain the value 200 is not necessarily about Pokemon. Findings must be
/// confirmed with a disassembler / emulator breakpoint (docs/expansion/ROM_ANALYSIS.md).
/// </summary>
public static class ConstantScanner
{
    private static readonly string[] ArmOps =
        ["AND", "EOR", "SUB", "RSB", "ADD", "ADC", "SBC", "RSC", "TST", "TEQ", "CMP", "CMN", "ORR", "MOV", "BIC", "MVN"];

    public static List<ScanHit> Scan(string region, ReadOnlySpan<byte> image, uint baseAddress, ScanOptions options)
    {
        var hits = new List<ScanHit>();
        ScanArmAndLiterals(region, image, baseAddress, options, hits);
        if (options.IncludeThumb) { ScanThumb(region, image, baseAddress, options, hits); }
        ScanStrings(region, image, baseAddress, options, hits);
        return hits;
    }

    private static void ScanArmAndLiterals(string region, ReadOnlySpan<byte> img, uint baseAddr, ScanOptions o, List<ScanHit> hits)
    {
        for (int off = 0; off + 4 <= img.Length; off += 4)
        {
            uint w = BinaryPrimitives.ReadUInt32LittleEndian(img.Slice(off, 4));
            uint addr = baseAddr + (uint)off;

            if (w >= o.MinLiteralWordValue && o.Values.TryGetValue(w, out var litLabel))
            {
                hits.Add(new ScanHit(region, addr, (uint)off, HitKind.LiteralWord, $"word 0x{w:X8}", litLabel));
            }

            uint cond = w >> 28;
            if (cond == 0xF || ((w >> 25) & 7) != 1) { continue; } // not ARM data-processing with immediate operand
            uint opcode = (w >> 21) & 0xF;
            bool s = ((w >> 20) & 1) != 0;
            if (opcode is >= 8 and <= 11 && !s) { continue; } // TST/TEQ/CMP/CMN without S are other instructions (MSR/...)
            uint imm8 = w & 0xFF;
            int rot = (int)((w >> 8) & 0xF) * 2;
            uint value = rot == 0 ? imm8 : (imm8 >> rot) | (imm8 << (32 - rot));
            if (!o.Values.TryGetValue(value, out var label)) { continue; }
            uint rn = (w >> 16) & 0xF, rd = (w >> 12) & 0xF;
            string detail = opcode is 13 or 15
                ? $"{ArmOps[opcode]}{(s ? "S" : "")} r{rd}, #{value}"
                : opcode is >= 8 and <= 11
                    ? $"{ArmOps[opcode]} r{rn}, #{value}"
                    : $"{ArmOps[opcode]}{(s ? "S" : "")} r{rd}, r{rn}, #{value}";
            hits.Add(new ScanHit(region, addr, (uint)off, HitKind.ArmImmediate, $"{detail}  (cond 0x{cond:X}, word 0x{w:X8})", label));
        }
    }

    private static void ScanThumb(string region, ReadOnlySpan<byte> img, uint baseAddr, ScanOptions o, List<ScanHit> hits)
    {
        string[] ops = ["MOV", "CMP", "ADD", "SUB"];
        for (int off = 0; off + 2 <= img.Length; off += 2)
        {
            ushort h = BinaryPrimitives.ReadUInt16LittleEndian(img.Slice(off, 2));
            if ((h >> 13) != 1) { continue; } // 001oo rrr iiiiiiii
            uint imm = (uint)(h & 0xFF);
            if (!o.Values.TryGetValue(imm, out var label)) { continue; }
            hits.Add(new ScanHit(region, baseAddr + (uint)off, (uint)off, HitKind.ThumbImmediate,
                $"{ops[(h >> 11) & 3]} r{(h >> 8) & 7}, #{imm}  (halfword 0x{h:X4}; low confidence)", label));
        }
    }

    private static void ScanStrings(string region, ReadOnlySpan<byte> img, uint baseAddr, ScanOptions o, List<ScanHit> hits)
    {
        foreach (var s in o.Strings)
        {
            var needle = Encoding.ASCII.GetBytes(s);
            int from = 0;
            while (from <= img.Length - needle.Length)
            {
                int idx = img[from..].IndexOf(needle);
                if (idx < 0) { break; }
                int at = from + idx;
                hits.Add(new ScanHit(region, baseAddr + (uint)at, (uint)at, HitKind.AsciiString, $"\"{s}\"", "game-data file/archive name"));
                from = at + needle.Length;
            }
        }
    }
}
