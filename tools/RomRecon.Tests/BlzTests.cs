using RomRecon.Code;

namespace RomRecon.Tests;

public class BlzTests
{
    [Fact]
    public void Overlay_style_vector_from_ndspy_decompresses_to_original()
    {
        var compressed = Convert.FromBase64String(BlzVectors.OverlayStyle_Seed1_Len4000);
        var result = Blz.Decompress(compressed);
        Assert.Equal(Synthetic.Pattern(4000, 1), result);
    }

    [Fact]
    public void Arm9_style_vector_keeps_uncompressed_prefix_and_decompresses_tail()
    {
        var prefix = Synthetic.Pattern(0x4000, 3);
        var compressed = prefix.Concat(Convert.FromBase64String(BlzVectors.Arm9Tail_Seed7_Len3000)).ToArray();
        var result = Blz.Decompress(compressed);
        Assert.Equal(prefix.Concat(Synthetic.Pattern(3000, 7)).ToArray(), result);
    }

    [Fact]
    public void Appended_post_data_is_preserved()
    {
        var prefix = Synthetic.Pattern(0x4000, 3);
        byte[] appended = [0x21, 0x06, 0xC0, 0xDE, 1, 2, 3, 4, 5, 6, 7, 8];
        var compressed = prefix.Concat(Convert.FromBase64String(BlzVectors.Arm9Tail_Seed7_Len3000)).Concat(appended).ToArray();
        var result = Blz.Decompress(compressed);
        Assert.Equal(prefix.Concat(Synthetic.Pattern(3000, 7)).Concat(appended).ToArray(), result);
    }

    [Fact]
    public void Data_stored_without_a_footer_is_rejected_by_the_strict_decoder()
    {
        // ndspy's compress() "stores" incompressible data followed by a zero word and decompress() then returns it as-is. This tool
        // only calls the decoder for regions the ROM flags as compressed, so it is deliberately stricter: no plausible footer => error.
        var stored = Convert.FromBase64String(BlzVectors.Stored_Seed99_Len64);
        Assert.Equal(Synthetic.Pattern(64, 99), stored.Take(64).ToArray());
        Assert.Equal<byte>([0, 0, 0, 0], stored[^4..]);
        Assert.False(Blz.TryDecompress(stored, out _, out var error));
        Assert.Contains("plausible footer", error);
    }

    [Fact]
    public void Zero_extra_size_marks_stored_data_and_is_returned_unmodified()
    {
        var data = new byte[64];
        for (int i = 0; i < 56; i++) { data[i] = (byte)(i + 1); }
        BitConverter.GetBytes((8u << 24) | 8u).CopyTo(data, 56); // plausible footer
        // last 4 bytes (extraSize) stay 0 => ndspy's "stored" marker
        Assert.Equal(data, Blz.Decompress(data));
    }

    [Fact]
    public void Plain_data_is_rejected_not_misread()
    {
        Assert.False(Blz.TryDecompress(new byte[] { 1, 2, 3 }, out _, out var error));
        Assert.NotNull(error);
    }

    [Fact]
    public void Truncated_streams_fail_cleanly()
    {
        var good = Convert.FromBase64String(BlzVectors.OverlayStyle_Seed1_Len4000);
        // dropping bytes from the front removes compressed data the decoder needs
        for (int cut = 1; cut < good.Length; cut += 97)
        {
            var truncated = good[cut..];
            try { Blz.Decompress(truncated); }
            catch (InvalidDataException) { /* expected */ }
        }
    }

    [Fact]
    public void Random_garbage_never_throws_other_exceptions_or_hangs()
    {
        var rng = new Random(12345);
        for (int i = 0; i < 3000; i++)
        {
            var data = new byte[rng.Next(16, 300)];
            rng.NextBytes(data);
            // make a plausible footer often so the decoder is actually exercised
            if (i % 2 == 0)
            {
                int hdr = 8 + rng.Next(0, 4);
                uint word = ((uint)hdr << 24) | (uint)rng.Next(hdr, data.Length);
                BitConverter.GetBytes(word).CopyTo(data, data.Length - 8);
                BitConverter.GetBytes((uint)rng.Next(0, 5000)).CopyTo(data, data.Length - 4);
                for (int k = data.Length - hdr; k < data.Length - 8; k++) { data[k] = 0xFF; }
            }
            try { Blz.Decompress(data); }
            catch (InvalidDataException) { }
        }
    }

    [Fact]
    public void Absurd_output_size_is_refused()
    {
        var data = new byte[64];
        BitConverter.GetBytes((8u << 24) | 40u).CopyTo(data, 56);
        BitConverter.GetBytes(0x7FFFFFFFu).CopyTo(data, 60);
        Assert.Throws<InvalidDataException>(() => Blz.Decompress(data));
    }
}
