using System.Buffers.Binary;
using System.Text;
using RomRecon.Analysis;

namespace RomRecon.Tests;

public class ScannerTests
{
    private static byte[] Words(params uint[] words)
    {
        var b = new byte[words.Length * 4];
        for (int i = 0; i < words.Length; i++) { BinaryPrimitives.WriteUInt32LittleEndian(b.AsSpan(i * 4), words[i]); }
        return b;
    }

    [Fact]
    public void Finds_arm_immediates_with_ram_addresses_and_mnemonics()
    {
        // 0: nop  4: cmp r0,#200  8: mov r1,#201  C: cmp r2,#9600 (0x96 ror 26 = 0x2580)  10: add r0,r0,#5 (must not match)
        var img = Words(0xE1A00000, 0xE35000C8, 0xE3A010C9, 0xE3520D96, 0xE2800005);
        var hits = ConstantScanner.Scan("arm9", img, 0x02000000, new ScanOptions());
        var arm = hits.Where(h => h.Kind == HitKind.ArmImmediate).ToList();
        Assert.Equal(3, arm.Count);
        Assert.Contains(arm, h => h.Address == 0x02000004 && h.Detail.StartsWith("CMP r0, #200"));
        Assert.Contains(arm, h => h.Address == 0x02000008 && h.Detail.StartsWith("MOV r1, #201"));
        Assert.Contains(arm, h => h.Address == 0x0200000C && h.Detail.StartsWith("CMP r2, #9600"));
    }

    [Fact]
    public void Ignores_non_immediate_forms_and_unconditional_space()
    {
        // 0xE15000C8 is "cmp r0, r8, ..." (register operand, bit 25 clear); 0xF35000C8 is cond=0xF (unconditional/BLX space)
        var img = Words(0xE15000C8, 0xF35000C8, 0xE30000C8 /* TST without S => not a data-processing instruction */);
        Assert.DoesNotContain(ConstantScanner.Scan("arm9", img, 0, new ScanOptions()), h => h.Kind == HitKind.ArmImmediate);
    }

    [Fact]
    public void Finds_literal_pool_words_for_large_constants_only()
    {
        var img = Words(0x25C0, 200, 0xC4E0, 1400);
        var hits = ConstantScanner.Scan("ov", img, 0x02100000, new ScanOptions()).Where(h => h.Kind == HitKind.LiteralWord).ToList();
        Assert.Equal(3, hits.Count); // 200 is below MinLiteralWordValue and is NOT reported as a literal
        Assert.Contains(hits, h => h.Address == 0x02100000 && h.Label.Contains("evolution table offset"));
        Assert.Contains(hits, h => h.Address == 0x02100008 && h.Label.Contains("MaxLink"));
    }

    [Fact]
    public void Thumb_scanning_is_opt_in()
    {
        byte[] thumb = [0xC8, 0x28, 0x00, 0x00]; // cmp r0,#200 ; (0x28C8)
        Assert.DoesNotContain(ConstantScanner.Scan("a", thumb, 0, new ScanOptions()), h => h.Kind == HitKind.ThumbImmediate);
        var on = ConstantScanner.Scan("a", thumb, 0x100, new ScanOptions { IncludeThumb = true }).Where(h => h.Kind == HitKind.ThumbImmediate).ToList();
        Assert.Single(on);
        Assert.Equal(0x100u, on[0].Address);
        Assert.StartsWith("CMP r0, #200", on[0].Detail);
    }

    [Fact]
    public void Custom_values_replace_defaults()
    {
        var img = Words(0xE35000C8, 0xE3500041);
        var hits = ConstantScanner.Scan("x", img, 0, new ScanOptions { Values = new Dictionary<uint, string> { [0x41] = "mine" } });
        Assert.Single(hits);
        Assert.Equal("mine", hits[0].Label);
    }

    [Fact]
    public void Finds_game_file_name_strings()
    {
        var img = new byte[64];
        Encoding.ASCII.GetBytes("data/Pokemon.dat\0").CopyTo(img, 8);
        var hits = ConstantScanner.Scan("arm9", img, 0x02000000, new ScanOptions()).Where(h => h.Kind == HitKind.AsciiString).ToList();
        Assert.Single(hits);
        Assert.Equal(0x02000000u + 8 + 5, hits[0].Address);
    }
}
