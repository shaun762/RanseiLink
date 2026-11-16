using RomRecon.Analysis;
using RomRecon.Code;
using RomRecon.Nds;

namespace RomRecon;

public sealed record ReconOptions
{
    public ScanOptions Scan { get; init; } = new();
    public bool ScanArm7 { get; init; }
    public int MaxHitsPerRegion { get; init; } = 100;
}

/// <param name="CompressionEvidence">Human-readable explanation of how the compression state was determined.</param>
public sealed record CodeRegion(
    string Name, uint FileOffset, uint Size, uint RamAddress, bool? Compressed, string CompressionEvidence,
    bool Decompressed, uint ImageSize, string Sha256, string? Note);

public sealed record ScanSummary(string Region, string Label, HitKind Kind, int Count);

public sealed record ReconReport
{
    public required string RomFileName { get; init; }
    public required long RomLength { get; init; }
    public required string Sha256 { get; init; }
    public required NdsHeader Header { get; init; }
    public required List<string> Warnings { get; init; }
    public required ModuleParams? ModuleParams { get; init; }
    public required List<CodeRegion> CodeRegions { get; init; }
    public required List<OverlayEntry> Arm9Overlays { get; init; }
    public required List<OverlayEntry> Arm7Overlays { get; init; }
    public required int FileCount { get; init; }
    public required List<NdsFile> Files { get; init; }
    public required List<TableFinding> Tables { get; init; }
    public required List<ScanSummary> ScanSummaries { get; init; }
    public required List<ScanHit> Hits { get; init; }
    public required int TotalHits { get; init; }
    public required byte[] Arm9Post { get; init; }
}

/// <summary>Decompressed images kept in memory so the CLI can optionally write them to a local, non-repo directory.</summary>
public sealed record ExtractedImage(string Name, byte[] Data);

public static class Recon
{
    public static (ReconReport Report, List<ExtractedImage> Images) Run(NdsRom rom, string sha256, ReconOptions opt)
    {
        var images = new List<ExtractedImage>();
        var regions = new List<CodeRegion>();
        var allHits = new List<ScanHit>();
        var summaries = new List<ScanSummary>();
        int totalHits = 0;

        void Scan(string name, byte[] image, uint ramBase)
        {
            var hits = ConstantScanner.Scan(name, image, ramBase, opt.Scan);
            totalHits += hits.Count;
            foreach (var g in hits.GroupBy(h => (h.Kind, h.Label)).OrderBy(g => g.Key.Kind).ThenBy(g => g.Key.Label))
            {
                summaries.Add(new ScanSummary(name, g.Key.Label, g.Key.Kind, g.Count()));
            }
            allHits.AddRange(hits.Take(opt.MaxHitsPerRegion));
        }

        // ---- ARM9
        var h = rom.Header;
        byte[] arm9 = rom.ReadArm9();
        var mp = ModuleParams.Find(arm9);
        bool? compressed;
        string evidence;
        bool footerPlausible = Blz.DetectAppendedData(arm9) is not null;
        if (mp is not null)
        {
            compressed = mp.IsCompressed;
            evidence = $"module params found at ARM9+0x{mp.MagicOffset:X}; compressed-static-end = 0x{mp.CompressedStaticEnd:X8}; BLZ footer {(footerPlausible ? "plausible" : "not plausible")}";
        }
        else
        {
            compressed = null;
            evidence = $"module params magic not found in the first 0x8000 bytes; BLZ footer {(footerPlausible ? "plausible (compression suspected)" : "not plausible")}";
        }

        byte[] arm9Image = arm9; bool dec = false; string? note = null;
        if (compressed == true || (compressed is null && footerPlausible))
        {
            if (Blz.TryDecompress(arm9, out var d, out var err)) { arm9Image = d; dec = true; images.Add(new ExtractedImage("arm9_decompressed.bin", d)); }
            else { note = $"BLZ decompression failed: {err}. The scan below runs on COMPRESSED bytes and is NOT meaningful. Decompress with ndstool/ndspy and re-run."; }
        }
        regions.Add(new CodeRegion("arm9", h.Arm9Offset, h.Arm9Size, h.Arm9RamAddress, compressed, evidence, dec, (uint)arm9Image.Length, Sha(arm9), note));
        if (note is null || compressed == false) { Scan("arm9", arm9Image, h.Arm9RamAddress); }

        // ---- ARM7 (optional scan)
        byte[] arm7 = rom.ReadArm7();
        regions.Add(new CodeRegion("arm7", h.Arm7Offset, h.Arm7Size, h.Arm7RamAddress, null, "ARM7 compression is not analysed", false, (uint)arm7.Length, Sha(arm7), null));
        if (opt.ScanArm7) { Scan("arm7", arm7, h.Arm7RamAddress); }

        // ---- ARM9 overlays
        var ov9 = rom.ReadOverlayTable(arm9: true).ToList();
        foreach (var ov in ov9)
        {
            var data = rom.ReadOverlay(ov);
            string name = $"overlay9_{ov.Id}";
            if (data is null)
            {
                regions.Add(new CodeRegion(name, 0, 0, ov.RamAddress, ov.IsCompressed, "overlay table flag", false, 0, "", "FAT entry for this overlay is missing or invalid"));
                continue;
            }
            byte[] image = data; bool odec = false; string? onote = null;
            if (ov.IsCompressed)
            {
                if (Blz.TryDecompress(data, out var d, out var err)) { image = d; odec = true; images.Add(new ExtractedImage($"{name}_decompressed.bin", d)); }
                else { onote = $"BLZ decompression failed: {err}"; }
            }
            var fat = rom.GetFatEntry(ov.FileId);
            regions.Add(new CodeRegion(name, fat?.Start ?? 0, (uint)data.Length, ov.RamAddress, ov.IsCompressed, "overlay table flag (bit 0 of the high byte of word 7)", odec, (uint)image.Length, Sha(data), onote));
            if (onote is null) { Scan(name, image, ov.RamAddress); }
        }
        var ov7 = rom.ReadOverlayTable(arm9: false).ToList();

        var report = new ReconReport
        {
            RomFileName = Path.GetFileName(rom.Path),
            RomLength = rom.Length,
            Sha256 = sha256,
            Header = h,
            Warnings = rom.Warnings.ToList(),
            ModuleParams = mp,
            CodeRegions = regions,
            Arm9Overlays = ov9,
            Arm7Overlays = ov7,
            FileCount = rom.Files.Count,
            Files = rom.Files.ToList(),
            Tables = TableReport.Build(rom),
            ScanSummaries = summaries,
            Hits = allHits,
            TotalHits = totalHits,
            Arm9Post = rom.ReadArm9PostData(),
        };
        report.Warnings.AddRange(rom.Warnings.Skip(report.Warnings.Count)); // warnings raised while walking the file system
        return (report, images);
    }

    private static string Sha(byte[] data) => Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(data)).ToLowerInvariant();
}
